/* The native loops of spu_native/ against the lifted functions they patch, whole-state:
 * all 128 registers, the 256 KiB local store, event status, the next pc and the
 * continuation function, after the lifted original and after the patched copy run from
 * the same inputs. Random inputs plus forced interrupts at every tested pc, inputs at the
 * guards' bounds, and out-of-range values that send the native loop back to the lifted one.
 *
 * Built by spu_native/tests/run_fixture.sh from the --fixture output of
 * scripts/spu_native_patch.py, in the default FPCR mode and (ARM64) under round toward zero
 * with flush-to-zero. On a host without NEON the native loops compile out and the check
 * reduces to the lifted code against itself. */
#define PAIN_SPU_NATIVE_FIXTURE 1
#include "spu_helpers.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

int g_spu_ls_watch_n;
SPU_THREAD_LOCAL void (*g_spu_trampoline_fn)(spu_context*);
void spu_indirect_branch(spu_context* ctx) { (void)ctx; }
void spu_ls_watch_slow(uint32_t lsa, int write, const uint8_t* data, uint32_t pc, uint32_t lr)
{
    (void)lsa; (void)write; (void)data; (void)pc; (void)lr;
    abort();
}
unsigned pain_fixture_interrupt_pc, pain_fixture_interrupt_after, pain_fixture_interrupt_checks;
unsigned long pain_fixture_native_units, pain_fixture_native_entries, pain_fixture_guard_exits;

#include "table_fixture.c"
#include "cull_fixture.c"

static uint32_t s_rng = 0xC497D13u;
static uint32_t rnd(void) { s_rng ^= s_rng << 13; s_rng ^= s_rng >> 17; s_rng ^= s_rng << 5; return s_rng; }

static spu_context s_stock, s_native;
static unsigned long s_cases, s_bad;

static int same_state(const char* what, unsigned i, void (*next_stock)(spu_context*), void (*next_native)(spu_context*))
{
    s_cases++;
    if (!memcmp(s_stock.gpr, s_native.gpr, sizeof s_stock.gpr) &&
        !memcmp(s_stock.ls_store, s_native.ls_store, SPU_LS_SIZE) &&
        s_stock.event_status == s_native.event_status && s_stock.pc == s_native.pc && next_stock == next_native)
        return 1;
    if (s_bad++ < 8) {
        fprintf(stderr, "FAIL %s case %u: pc %05X/%05X next %p/%p\n", what, i, s_stock.pc, s_native.pc,
                (void*)next_stock, (void*)next_native);
        for (int r = 0; r < 128; r++)
            if (memcmp(&s_stock.gpr[r], &s_native.gpr[r], 16))
                fprintf(stderr, "  r%d %08X %08X %08X %08X / %08X %08X %08X %08X\n", r,
                        s_stock.gpr[r]._u32[0], s_stock.gpr[r]._u32[1], s_stock.gpr[r]._u32[2], s_stock.gpr[r]._u32[3],
                        s_native.gpr[r]._u32[0], s_native.gpr[r]._u32[1], s_native.gpr[r]._u32[2], s_native.gpr[r]._u32[3]);
        for (unsigned a = 0; a < SPU_LS_SIZE; a++)
            if (s_stock.ls_store[a] != s_native.ls_store[a]) { fprintf(stderr, "  first LS difference at %05X\n", a); break; }
    }
    return 0;
}

static void copy_context(spu_context* to, const spu_context* from)
{
    memcpy(to, from, sizeof *to);
    to->ls = to->ls_store;
}

/* Run native then stock with an interrupt injected at the after-th check of pc (0: none).
 * A native fill skips `skipped` loop tests; the stock run gets its interrupt that many
 * checks later, the same point in the loop. */
static void run_pair(const char* what, unsigned i, void (*stock)(spu_context*), void (*native)(spu_context*),
                     unsigned pc, unsigned after, unsigned (*skipped)(unsigned long units))
{
    copy_context(&s_native, &s_stock);
    const unsigned long units = pain_fixture_native_units, entries = pain_fixture_native_entries;
    pain_fixture_interrupt_pc = pc; pain_fixture_interrupt_after = after; pain_fixture_interrupt_checks = 0;
    g_spu_trampoline_fn = NULL;
    native(&s_native);
    void (*next_native)(spu_context*) = g_spu_trampoline_fn;
    const unsigned skip = (skipped && pain_fixture_native_entries > entries) ? skipped(pain_fixture_native_units - units) : 0;
    pain_fixture_interrupt_after = after ? after + skip : 0; pain_fixture_interrupt_checks = 0;
    g_spu_trampoline_fn = NULL;
    stock(&s_stock);
    same_state(what, i, g_spu_trampoline_fn, next_native);
}

/* ---- index table, 0x07D70 ----------------------------------------------------------- */
static unsigned table_skipped(unsigned long entries_filled) { return (unsigned)entries_filled; }

static void table_inputs(unsigned i)
{
    for (int r = 0; r < 128; r++) for (int k = 0; k < 4; k++) s_stock.gpr[r]._u32[k] = rnd();
    for (unsigned a = 0; a < SPU_LS_SIZE; a += 4) { const uint32_t w = rnd(); memcpy(&s_stock.ls_store[a], &w, 4); }
    const uint32_t base = 0x1000u + ((rnd() % 0x100u) << 4);       /* r3: the job's block */
    s_stock.gpr[3]._u32[0] = base;
    uint32_t count;
    switch (i % 8) {
    case 0: count = 0; break;
    case 1: count = 8 * (1 + rnd() % 2); break;                     /* below the native minimum */
    case 2: count = 4096; break;                                    /* largest native count */
    case 3: count = 4104; break;                                    /* i * 16 would wrap: lifted */
    default: count = 8 * (2 + rnd() % 200); break;
    }
    uint32_t dst;
    switch (i % 5) {
    case 0: dst = 0x20000u + ((rnd() % 0x1000u) << 1); break;       /* even, unaligned */
    case 1: dst = 0x20001u + ((rnd() % 0x1000u) << 1); break;       /* odd: lifted */
    case 2: dst = SPU_LS_SIZE - count * 2; break;                   /* ends at the top of LS */
    case 3: dst = 0x30000u + ((rnd() % 0x100u) << 4); break;        /* aligned */
    default: dst = (SPU_LS_SIZE - count * 2 + 2 + ((rnd() % 16) << 1)) & SPU_LS_MASK; break;  /* would wrap: lifted */
    }
    /* r11 = rotqby(LS[base + 260 quadword], base + 260): the word at base+260; r10 = (r11 + 7) & -8 */
    const uint32_t raw = count ? count - (rnd() % 8) : 0;
    const uint32_t w = __builtin_bswap32(raw);
    memcpy(&s_stock.ls_store[(base + 260) & SPU_LS_MASK], &w, 4);
    const uint32_t d = __builtin_bswap32(dst);                      /* r8.word0 = LS[base + 0x340] */
    memcpy(&s_stock.ls_store[(base + 0x340) & SPU_LS_MASK], &d, 4);
    s_stock.ls = s_stock.ls_store;
    s_stock.int_enable = (i / 8) % 3 != 0;
    const uint32_t masks[] = { 0x1u, 0x2u, 0x3u, 0x402u, 0x0u, 0x10u };
    s_stock.event_mask = masks[(i / 24) % 6];
    s_stock.event_status = (i % 7 == 3) ? s_stock.event_mask : 0;    /* already pending: lifted */
    s_stock.irq_saved = (i % 29 == 7);
    s_stock.pc = 0x7D70;
}

static void table_cases(unsigned n)
{
    for (unsigned i = 0; i < n; i++) {
        table_inputs(i);
        /* interrupts: none, in the last eight iterations, at the tail test */
        const unsigned which = (i / 3) % 4;
        const unsigned pc = which == 3 ? 0x7DC8 : 0x7D9C;
        const unsigned after = which == 0 ? 0 : which == 3 ? 1 : 1 + rnd() % 9;
        run_pair("table", i, stock_00007D70, native_00007D70, pc, after, pc == 0x7D9C ? table_skipped : NULL);
    }
}

/* ---- culling plane loop, 0x04630 ----------------------------------------------------- */
static u128 cull_vector(unsigned special)
{
    static const uint32_t near_bound[] = {
        0x00000000, 0x007FFFFF, 0x00800000, 0x00800001, 0x17FFFFFF, 0x1FFFFFFF, 0x3F800000,
        0x5E7FFFFF, 0x5E800000, 0x5E800001, 0x7F7FFFFF, 0x7F800000, 0x7FC00000,
    };
    u128 v;
    for (unsigned lane = 0; lane < 4; lane++) {
        if (special == 2) v._u32[lane] = near_bound[rnd() % 13] | (rnd() & 0x80000000u);
        else if (special) v._u32[lane] = rnd();
        else v._f32[lane] = ((int)(rnd() % 101) - 50) * 0.0625f;
    }
    return v;
}

static void cull_inputs(unsigned trial)
{
    const unsigned mode = trial % 3;
    for (unsigned r = 0; r < 128; r++) s_stock.gpr[r] = cull_vector(1);
    s_stock.ls = s_stock.ls_store;
    s_stock.gpr[0]._u32[0] = 0x5400;
    s_stock.gpr[1]._u32[0] = 0x3100;
    s_stock.gpr[3] = cull_vector(mode);
    s_stock.gpr[4] = cull_vector(mode);
    s_stock.gpr[5]._u32[0] = (trial & 16) ? SPU_LS_SIZE - 0x110 : 0x2100;
    s_stock.gpr[6]._u32[0] = 0x3000 + (trial & 15);
    s_stock.int_enable = trial % 4 != 0;
    s_stock.event_status = trial % 4 == 1;
    s_stock.event_mask = trial % 8 != 5;
    s_stock.irq_saved = 0;
    s_stock.host_depth = trial % 3;
    s_stock.pc = 0x4630;
    for (unsigned i = 0; i < 16; ++i) spu_ls_write128(&s_stock, s_stock.gpr[5]._u32[0] + 16 * i, cull_vector(mode));
    u128 count = cull_vector(1);
    count._u32[0] = trial % 18;
    spu_ls_write128(&s_stock, s_stock.gpr[5]._u32[0] + 0x100, count);
    spu_ls_write128(&s_stock, s_stock.gpr[6]._u32[0], cull_vector(1));
}

static void cull_cases(unsigned n, unsigned* irq_exits, unsigned* fallbacks)
{
    for (unsigned i = 0; i < n; i++) {
        cull_inputs(i);
        unsigned pc = 0, after = 0;
        if (i % 17 < 3) {   /* a long in-range run, then an interrupt or a bad plane mid-loop */
            const u128 zeros = { ._u32 = { 0, 0, 0, 0 } };
            const u128 radius = { ._f32 = { 1.0f, 1.0f, 1.0f, 1.0f } };
            const u128 bad = { ._u32 = { 0x7F800001u, 0, 0, 0 } };
            const u128 count = { ._u32 = { 5, 9, 1, 4 } };
            s_stock.int_enable = 1; s_stock.event_mask = 1; s_stock.event_status = 0;
            s_stock.gpr[3] = zeros; s_stock.gpr[4] = radius;
            const uint32_t addr = s_stock.gpr[5]._u32[0];
            for (unsigned plane = 0; plane < 5; ++plane) spu_ls_write128(&s_stock, addr + 16 * plane, zeros);
            spu_ls_write128(&s_stock, addr + 0x100, count);
            if (i % 17 == 2) spu_ls_write128(&s_stock, addr + 32, bad);
            else { pc = i % 17 == 0 ? 0x46C0 : 0x46B0; after = 2; }
        }
        const unsigned long planes = pain_fixture_native_units, guards = pain_fixture_guard_exits;
        run_pair("cull", i, stock_00004630, native_00004630, pc, after, NULL);
        if (pc && s_native.pc == pc && pain_fixture_native_units > planes) ++*irq_exits;
        if (pain_fixture_guard_exits > guards && pain_fixture_native_units > planes) ++*fallbacks;
    }
}

static uint64_t now_ns(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
}

/* ns per call, the lifted and patched function alternately, on fixed in-range inputs */
static void timings(void)
{
    static spu_context c;
    memset(&c, 0, sizeof c); c.ls = c.ls_store;
    puts("op\tsize\tpair\tlifted_ns\tnative_ns");
    for (unsigned planes = 4; planes <= 16; planes *= 2)
        for (unsigned pair = 0; pair < 3; pair++) {
            double t[2];
            for (int k = 0; k < 2; k++) {
                const int nat = (k ^ (int)pair) & 1;
                const u128 point = { ._f32 = { 0.25f, 0.5f, 0.75f, 1.0f } }, radius = { ._f32 = { 10, 10, 10, 10 } };
                const u128 plane = { ._f32 = { 1, 1, 1, 1 } }, count = { ._u32 = { planes, planes, planes, planes } };
                for (unsigned i = 0; i < planes; ++i) spu_ls_write128(&c, 0x2100 + i * 16, plane);
                spu_ls_write128(&c, 0x2200, count);
                c.gpr[6]._u32[0] = 0x3000; c.gpr[1]._u32[0] = 0x3100; c.int_enable = 0;
                const unsigned calls = 200000;
                const uint64_t t0 = now_ns();
                for (unsigned i = 0; i < calls; ++i) {
                    c.gpr[3] = point; c.gpr[4] = radius; c.gpr[5]._u32[0] = 0x2100; c.gpr[1]._u32[0] = 0x3100;
                    (nat ? native_00004630 : stock_00004630)(&c);
                }
                t[nat] = (double)(now_ns() - t0) / calls;
            }
            printf("cull\t%u\t%u\t%.2f\t%.2f\n", planes, pair, t[0], t[1]);
        }
    for (unsigned n = 64; n <= 1024; n *= 4)
        for (unsigned pair = 0; pair < 3; pair++) {
            double t[2];
            for (int k = 0; k < 2; k++) {
                const int nat = (k ^ (int)pair) & 1;
                const uint32_t base = 0x1000, cnt = __builtin_bswap32(n), dst = __builtin_bswap32(0x20000);
                memcpy(&c.ls_store[base + 260], &cnt, 4);
                memcpy(&c.ls_store[base + 0x340], &dst, 4);
                c.int_enable = 1; c.event_mask = 2; c.event_status = 0; c.irq_saved = 0;
                const unsigned calls = 20000;
                const uint64_t t0 = now_ns();
                for (unsigned i = 0; i < calls; ++i) {
                    c.gpr[3]._u32[0] = base;
                    (nat ? native_00007D70 : stock_00007D70)(&c);
                }
                t[nat] = (double)(now_ns() - t0) / calls;
            }
            printf("table\t%u\t%u\t%.2f\t%.2f\n", n, pair, t[0], t[1]);
        }
}

static int run_all(const char* mode)
{
    const unsigned long before_bad = s_bad;
    const unsigned long t0 = pain_fixture_native_entries, tu0 = pain_fixture_native_units;
    table_cases(12000);
    const unsigned long t_entries = pain_fixture_native_entries - t0, t_units = pain_fixture_native_units - tu0;
    unsigned irq = 0, fb = 0;
    const unsigned long c0 = pain_fixture_native_entries, cu0 = pain_fixture_native_units;
    cull_cases(24000, &irq, &fb);
    printf("%s: table 12000 cases, %lu native fills of %lu entries; cull 24000 cases, %lu native entries, "
           "%lu planes, %u interrupt exits after native planes, %u mid-loop fallbacks; mismatches %lu\n",
           mode, t_entries, t_units, pain_fixture_native_entries - c0, pain_fixture_native_units - cu0, irq, fb,
           s_bad - before_bad);
#if defined(__aarch64__) && defined(__ARM_NEON)
    if (spu__nv_rz() && (!t_entries || !irq || !fb)) { fprintf(stderr, "FAIL: a native path was never exercised\n"); return 1; }
#endif
    return s_bad != before_bad;
}

int main(int argc, char** argv)
{
    g_spu_ls_rdiag = g_spu_ls_wdiag = 0;
    __atomic_store_n(&pain_spu_native_cached, (int)(PAIN_NATIVE_TABLE | PAIN_NATIVE_CULL), __ATOMIC_RELAXED);
    int rc = 0;
#if defined(__aarch64__)
    uint64_t fpcr; __asm__ volatile("mrs %0, fpcr" : "=r"(fpcr));
#if !defined(SPU_FLOAT_RZ_ONLY)
    rc |= run_all("default FPCR");
#endif
    __asm__ volatile("msr fpcr, %0" :: "r"((uint64_t)SPU_FPCR_RZFZ));
    rc |= run_all("RZ+FZ FPCR");
    if (argc > 1) timings();
    __asm__ volatile("msr fpcr, %0" :: "r"(fpcr));
#else
    rc |= run_all("host");
    if (argc > 1) timings();
#endif
    printf("spu_native fixture: %lu comparisons, %lu mismatched\n", s_cases, s_bad);
    return rc;
}
