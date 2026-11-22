/* Whole-job replay of captured PAIN ICE mesh jobs (jobmod_ca71f23d7b11_e11B00 entry 0x15B00).
 *
 * Each capture (version 2/3, magic "PICE") holds the initial and final 128 registers and
 * 256 KiB local store of one job plus a tape of every channel operation, DMA transfer,
 * atomic line operation and SPURS workload poll. The replay runs the lifted job against the
 * tape, rejects any change in the I/O sequence, compares every outgoing PUT payload, and at
 * the job's exit compares all registers and the whole local store. REPEAT=n runs each job n
 * times (every run checked) and prints the mean job time; PER_CASE=1 prints it per job.
 * Derived from the 22 Nov verifier (Evidence/2026-11-22-render-phases/verify-ice-job.c).
 * The corpus is game-derived and stays on the capture machine. See build.sh. */
#include "spu_helpers.h"
#include "spu_interp.h"
#include "spu_ls_watch_fixture.h"
#include <setjmp.h>
#include <time.h>
#include <stdlib.h>

typedef struct {
    uint32_t magic, version, slot, image, entry, exit_pc, count, bytes;
    uint64_t fpcr;
    uint32_t host_pc, lsa, eah, eal, int_enable, event_status, event_mask, host_depth;
} JobHeader;

typedef struct {
    uint32_t kind, pc, arg, lsa, size, value;
} Transfer;

enum { ORDINARY_GET = 1, ORDINARY_PUT, CHANNEL_WRITE, CHANNEL_READ, CHANNEL_COUNT, ATOMIC_LINE, WORKLOAD_POLL };
enum { TAPE_CAPACITY = 1048576, PM_IMAGE = 199 };
typedef void (*Lifted)(spu_context*);

void jobmod_ca71f23d7b11_e11B00_spu_recomp_register(void);
void spu_recomp_register(void);
int spu_irq_regs_maybe_restore(spu_context* ctx);

static Lifted mesh[SPU_LS_SIZE / 4], policy[SPU_LS_SIZE / 4];
static Lifted* registration_target;
static struct {
    JobHeader header;
    u128 before_gpr[128];
    uint8_t before_ls[SPU_LS_SIZE];
    u128 after_gpr[128];
    uint8_t after_ls[SPU_LS_SIZE];
    uint8_t tape[TAPE_CAPACITY];
} capture;
_Static_assert(sizeof(JobHeader) == 72, "unexpected capture layout");
_Static_assert(offsetof(typeof(capture), tape) == 72 + 2 * (2048 + SPU_LS_SIZE),
               "unexpected padding");

static spu_context replay;
static jmp_buf replay_exit;
static unsigned index_in_tape, bytes_in_tape, current_step, restarts;
static uint64_t started_ns, elapsed_ns;
static uint64_t now_ns(void)
{
#if defined(__APPLE__)
    return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
#else
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
#endif
}
static int saw_exit;
static unsigned audited_puts, audited_atomics, audited_polls;
uint8_t g_spu_stack_reset_hint[1024];
unsigned g_spu_stack_reset_count;
volatile int g_yz_lockstep_on;

static void reject(const char* reason)
{
    fprintf(stderr, "case %u event %u/%u, pc=%05x: %s\n", capture.header.slot,
            index_in_tape, capture.header.count, replay.pc, reason);
    longjmp(replay_exit, 1);
}

void spu_register_function(uint32_t addr, Lifted fn)
{
    if (addr >= SPU_LS_SIZE || (addr & 3u)) abort();
    registration_target[addr / 4] = fn;
}

Lifted spu_lookup(uint32_t addr, int image_id)
{
    if (addr >= SPU_LS_SIZE || (addr & 3u)) return NULL;
    if (image_id == PM_IMAGE && policy[addr / 4]) return policy[addr / 4];
    return mesh[addr / 4] ? mesh[addr / 4] : policy[addr / 4];
}

Lifted spu_lifted_lookup(const spu_context* ctx, uint32_t addr)
{
    return spu_lookup(addr, ctx->image_id);
}

void spu_spurs_taskset_syscall(spu_context* ctx)
{
    (void)ctx;
    reject("unexpected taskset syscall");
}

/* spu_trace_call / spu_trace_dump come from spu_interp.c. */

static const uint8_t* take(const spu_context* ctx, Transfer* op, unsigned kind, unsigned arg);

#include "smc.inc"
#ifdef PAIN_ICE_IRQ_CANDIDATE
#include "verify-ice-irq/ice-irq-fast.inc"
static unsigned candidate_calls;
#endif

void spu_indirect_branch(spu_context* ctx)
{
    ctx->pc &= SPU_LS_MASK & ~3u;
    (void)spu_irq_regs_maybe_restore(ctx);
    if (++current_step > 100000) reject("dispatch limit exceeded");
    if (ctx->pc == SPURS_PM_SELECT_WORKLOAD_LS) {
        const uint32_t ea = spu_ls_read32(ctx, 0x1c4);
        Transfer op;
        const uint8_t* line = take(ctx, &op, WORKLOAD_POLL, ea);
        if (op.lsa != 0x100 || op.size != (ea ? 128 : 0) || op.value)
            reject("workload poll state changed");
        if (ea) memcpy(ctx->ls + 0x100, line, 128);
        ctx->gpr[3] = spu_make_preferred_u32(0);
        ctx->pc = ctx->gpr[0]._u32[0] & SPU_LS_MASK;
        ++audited_polls;
        return;
    }
    g_spu_trampoline_fn = spu_lookup(ctx->pc, ctx->image_id);
    if (g_spu_trampoline_fn) return;
#ifdef PAIN_ICE_IRQ_CANDIDATE
    if (pain_ice_irq_fast(ctx)) {
        ++candidate_calls;
        return;
    }
#endif
    if (!spu_smc_microstep(ctx)) reject("unlifted code could not rejoin the job");
}

void spu_stop(spu_context* ctx)
{
    (void)ctx;
    reject("unexpected SPU STOP");
}

void spu_halt(spu_context* ctx)
{
    (void)ctx;
    reject("unexpected SPU halt");
}

void spu_restart_dispatch(spu_context* ctx)
{
    if (ctx->irq_saved || ++restarts > 8)
        reject("cannot replay stack restart with pending IRQ or too many restarts");
    longjmp(replay_exit, 2);
}

void spu_jmp_no_unwind(void* env) { (void)env; }

void spu_check_stack_reset(spu_context* ctx, Lifted fn)
{
    (void)ctx;
    (void)fn;
    reject("unexpected registered stack reset");
}

void yz_lockstep_tick(spu_context* ctx)
{
    (void)ctx;
    reject("unexpected lockstep dispatch");
}

static const uint8_t* take(const spu_context* ctx, Transfer* op, unsigned kind, unsigned arg)
{
    if (index_in_tape >= capture.header.count ||
        capture.header.bytes - bytes_in_tape < sizeof *op)
        reject("missing I/O record");
    memcpy(op, capture.tape + bytes_in_tape, sizeof *op);
    if (op->size > capture.header.bytes - bytes_in_tape - sizeof *op)
        reject("short I/O record");
    if (op->kind != kind || op->arg != arg || op->pc != ctx->pc) {
        fprintf(stderr, "  expected kind=%u arg=%08x pc=%05x but reached kind=%u arg=%08x pc=%05x\n",
                op->kind, op->arg, op->pc, kind, arg, ctx->pc);
        reject("I/O sequence changed");
    }
    const uint8_t* payload = capture.tape + bytes_in_tape + sizeof *op;
    bytes_in_tape += sizeof *op + op->size;
    ++index_in_tape;
    return payload;
}

static void dma(spu_context* ctx, unsigned kind, unsigned cmd, unsigned ea,
                unsigned lsa, unsigned size, int input)
{
    if (!size) return;
    if (lsa >= SPU_LS_SIZE || size > SPU_LS_SIZE - lsa)
        reject("DMA exceeds local store");
    Transfer op;
    const uint8_t* bytes = take(ctx, &op, kind, ea);
    if (op.lsa != lsa || op.size != size || op.value != cmd)
        reject("DMA length, local address, or command changed");
    if (input) {
        memcpy(ctx->ls + lsa, bytes, size);
    } else if (memcmp(ctx->ls + lsa, bytes, size)) {
        reject("outgoing DMA payload changed");
    }
    audited_puts += kind == ORDINARY_PUT;
    audited_atomics += kind == ATOMIC_LINE;
}

static void list_transfer(spu_context* ctx, uint32_t elem, uint32_t count,
                          uint32_t dest, unsigned cmd, unsigned tag)
{
    for (uint32_t i = 0; i < count; ++i) {
        const uint32_t address = (elem + i * 8) & SPU_LS_MASK;
        const uint32_t flags_and_size = spu_ls_read32(ctx, address);
        const uint32_t ea = spu_ls_read32(ctx, address + 4);
        const unsigned size = flags_and_size & 0x7fff;
        if (size) {
            dma(ctx, ORDINARY_GET, cmd, ea, (dest & ~15u) | (ea & 15u), size, 1);
            dest = (dest & ~15u) + ((size + 15u) & ~15u);
        }
        if (flags_and_size & 0x80000000u) {
            ctx->list_stall_elem_lsa[tag] = (address + 8) & SPU_LS_MASK;
            ctx->list_stall_remaining[tag] = count - i - 1;
            ctx->list_stall_dest_lsa[tag] = dest;
            ctx->list_stall_cmd[tag] = cmd;
            ctx->list_stall_mask |= 1u << tag;
            ctx->list_stall_stat |= 1u << tag;
            ctx->event_status |= 2;
            return;
        }
    }
}

static void write_dma_command(spu_context* ctx, uint32_t cmd)
{
    const uint32_t ea = ctx->mfc_eal;
    const uint32_t lsa = ctx->mfc_lsa & SPU_LS_MASK;
    if (ctx->mfc_eah) reject("unsupported nonzero DMA address high bits");
    switch (cmd) {
    case MFC_GETLLAR_CMD:
    case MFC_PUTLLC_CMD:
    case MFC_PUTLLUC_CMD:
    case MFC_PUTQLLUC_CMD:
        dma(ctx, ATOMIC_LINE, cmd, ea & ~127u, lsa & ~127u, 128, cmd == MFC_GETLLAR_CMD);
        return;
    case MFC_GET_CMD:
    case MFC_GETB_CMD:
    case MFC_GETF_CMD:
        dma(ctx, ORDINARY_GET, cmd, ea, lsa, ctx->mfc_size, 1);
        return;
    case MFC_PUT_CMD:
    case MFC_PUTB_CMD:
    case MFC_PUTF_CMD:
        dma(ctx, ORDINARY_PUT, cmd, ea, lsa, ctx->mfc_size, 0);
        return;
    case MFC_GETL_CMD:
    case MFC_GETLB_CMD:
    case MFC_GETLF_CMD:
        list_transfer(ctx, ea & SPU_LS_MASK, ctx->mfc_size / 8, lsa, cmd & ~4u, ctx->mfc_tag);
        return;
    case MFC_BARRIER_CMD:
        return;
    default:
        reject("unsupported DMA command");
    }
}

void spu_wrch(spu_context* ctx, uint32_t channel, u128 value)
{
    Transfer op;
    const uint8_t* payload = take(ctx, &op, CHANNEL_WRITE, channel);
    const uint32_t v = value._u32[0];
    if (op.size != sizeof value || op.lsa != ctx->mfc_lsa ||
        op.value != v || memcmp(payload, &value, sizeof value))
        reject("channel write value changed");
    switch (channel) {
    case MFC_LSA: ctx->mfc_lsa = v; break;
    case MFC_EAH: ctx->mfc_eah = v; break;
    case MFC_EAL: ctx->mfc_eal = v; break;
    case MFC_Size: ctx->mfc_size = v; break;
    case MFC_TagID: ctx->mfc_tag = v & 31; break;
    case MFC_WrTagMask: ctx->mfc_tag_mask = v; break;
    case MFC_Cmd: write_dma_command(ctx, v); break;
    case SPU_WrEventMask: ctx->event_mask = v; break;
    case SPU_WrEventAck:
        ctx->event_status &= ~v;
        if (ctx->list_stall_stat) ctx->event_status |= v & 2;
        break;
    case MFC_WrTagUpdate:
        if (v && (ctx->event_mask & 1)) ctx->event_status |= 1;
        break;
    case MFC_WrListStallAck: {
        const unsigned tag = v & 31;
        if (!(ctx->list_stall_mask & (1u << tag))) reject("ack for a list that did not stall");
        ctx->list_stall_mask &= ~(1u << tag);
        list_transfer(ctx, ctx->list_stall_elem_lsa[tag], ctx->list_stall_remaining[tag],
                      ctx->list_stall_dest_lsa[tag], ctx->list_stall_cmd[tag], tag);
        break;
    }
    default: reject("unsupported write channel");
    }
}

u128 spu_rdch(spu_context* ctx, uint32_t channel)
{
    Transfer op;
    const uint8_t* payload = take(ctx, &op, CHANNEL_READ, channel);
    u128 value;
    if (op.size != sizeof value || op.lsa != ctx->mfc_lsa)
        reject("channel read record has different width or MFC state");
    if (channel == MFC_RdListStallStat) ctx->list_stall_stat = 0;
    memcpy(&value, payload, sizeof value);
    return value;
}

uint32_t spu_rchcnt(spu_context* ctx, uint32_t channel)
{
    Transfer op;
    take(ctx, &op, CHANNEL_COUNT, channel);
    if (op.size || op.lsa != ctx->mfc_lsa) reject("channel count MFC state changed");
    return op.value;
}

/* Inserted at the two original exit sites, immediately before SPU_RET. */
void pain_ice_replay_end(spu_context* ctx)
{
    elapsed_ns = now_ns() - started_ns;
    if (ctx->pc != capture.header.exit_pc || ctx->irq_saved ||
        index_in_tape != capture.header.count || bytes_in_tape != capture.header.bytes)
        reject("premature or different job exit");
    if (memcmp(ctx->gpr, capture.after_gpr, sizeof ctx->gpr))
        reject("final SPU registers differ");
    if (memcmp(ctx->ls, capture.after_ls, SPU_LS_SIZE))
        reject("final SPU local store differs");
    saw_exit = 1;
    longjmp(replay_exit, 1);
}

static int test_case(void)
{
    spu_context_init(&replay, 0);
    replay.image_id = capture.header.image;
    replay.module_img_a00 = capture.header.image;
    replay.pc = capture.header.host_pc;
    replay.mfc_lsa = capture.header.lsa;
    replay.mfc_eah = capture.header.eah;
    replay.mfc_eal = capture.header.eal;
    replay.int_enable = capture.header.int_enable;
    replay.event_status = capture.header.event_status;
    replay.event_mask = capture.header.event_mask;
    replay.host_depth = capture.header.host_depth;
    replay.status = SPU_STATUS_RUNNING;
    replay.steps = 100000;
    memcpy(replay.gpr, capture.before_gpr, sizeof replay.gpr);
    memcpy(replay.ls, capture.before_ls, SPU_LS_SIZE);
    index_in_tape = bytes_in_tape = current_step = 0;
    saw_exit = 0;
    g_spu_trampoline_fn = mesh[capture.header.entry / 4];
#if defined(__aarch64__)
    __asm__ volatile("msr fpcr, %0" :: "r"(capture.header.fpcr) : "memory");   /* the captured FP mode */
#endif
    restarts = 0;
    started_ns = now_ns();
    switch (setjmp(replay_exit)) {
    case 0:
        spu_drain_call(&replay, replay.gpr[0]._u32[0]);
        reject("job returned outside the two recorded exits");
        break;
    case 2:
        replay.host_depth = 0;
        replay.irq_frame = NULL;
        g_spu_trampoline_fn = NULL;
        spu_indirect_branch(&replay);
        SPU_DRAIN(&replay);
        reject("restarted job returned outside the two recorded exits");
        break;
    }
    return saw_exit;
}

int main(int argc, char** argv)
{
    if (argc < 2) return 2;
    registration_target = mesh;
    jobmod_ca71f23d7b11_e11B00_spu_recomp_register();
    registration_target = policy;
    spu_recomp_register();
    g_spu_ls_rdiag = g_spu_ls_wdiag = 0;
    unsigned passed = 0, other_fpcr = 0;
    double total_mean = 0;
    for (int i = 1; i < argc; ++i) {
        FILE* file = fopen(argv[i], "rb");
        if (!file) return 2;
        const size_t fixed_size = offsetof(typeof(capture), tape);
        const int valid = fread(&capture, 1, fixed_size, file) == fixed_size &&
            capture.header.magic == 0x50494345 && (capture.header.version == 2 || capture.header.version == 3) &&
            capture.header.entry == 0x15b00 && capture.header.bytes <= sizeof capture.tape &&
            fread(capture.tape, 1, capture.header.bytes, file) == capture.header.bytes &&
            fgetc(file) == EOF;
        fclose(file);
        if (!valid) {
            fprintf(stderr, "Invalid capture argument %d\n", i);
            return 2;
        }
        const unsigned repeat = getenv("REPEAT") ? (unsigned)atoi(getenv("REPEAT")) : 1, warm = repeat > 4 ? 3 : 0;
        uint64_t sum = 0;
        int ok = 1;
        for (unsigned r = 0; r < repeat && ok; ++r) {
            ok = test_case();
            if (r >= warm) sum += elapsed_ns;
        }
        passed += ok;
        if (repeat > 1 && ok) {
            const double mean = (double)sum / (repeat - warm);
            total_mean += mean;
            if (getenv("PER_CASE")) printf("case=%u mean_ns=%.0f\n", capture.header.slot, mean);
        }
        if (capture.header.fpcr != UINT64_C(0x01c00000)) ++other_fpcr;
    }
    if (total_mean > 0) printf("sum_of_case_means_ns=%.0f\n", total_mean);
    if (other_fpcr) printf("cases with another FPCR: %u\n", other_fpcr);
    printf("Job replays: %u/%d. Compared %u ordinary PUT payloads and replayed/checked %u atomic line operations.\n",
           passed, argc - 1, audited_puts, audited_atomics);
    printf("Compared %u SPURS workload polls.\n", audited_polls);
#ifdef PAIN_ICE_IRQ_CANDIDATE
    printf("Lifted IRQ prologue ran %u times.\n", candidate_calls);
    if (!candidate_calls) return 1;
#endif
    return passed != (unsigned)(argc - 1);
}
