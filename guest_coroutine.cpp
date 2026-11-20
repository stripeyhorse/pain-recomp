// PAIN's cooperative PPU stack switch at 0x00011810.
#if defined(__APPLE__) && !defined(_XOPEN_SOURCE)
#define _XOPEN_SOURCE 600
#define _DARWIN_C_SOURCE 1
#endif

#include "ppu_recomp.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <unordered_map>

#ifdef _WIN32
#include <windows.h>
#else
#include <ucontext.h>
#ifdef __APPLE__
static_assert(sizeof(ucontext_t) > 64, "Darwin ucontext requires embedded machine state");
#endif
#endif

extern "C" PPU_THREAD_LOCAL void (*g_trampoline_fn)(void*);
extern "C" int* ps3_ppu_dispatch_depth_slot();
extern "C" int* ps3_ppu_vcall_sp_slot();
extern "C" void ps3_indirect_call(ppu_context*);

namespace {
constexpr uint32_t frame_size = 0x240;
constexpr uint32_t completion_code = 0x00233350;
constexpr uint32_t active_task_slot = 0x019d987c;
constexpr size_t host_stack_size = 4 * 1024 * 1024;

struct Coroutine {
#ifdef _WIN32
    void* native = nullptr;
    ~Coroutine() { if (native && stack_owned) DeleteFiber(native); }
    bool stack_owned = false;
#else
    ucontext_t native{};
    std::unique_ptr<char[]> stack;
#endif
    uint32_t frame = 0;
    ppu_context regs{};
    int dispatch_depth = 0;
    int vcall_depth = 0;
    void (*trampoline)(void*) = nullptr;
};

// The guest copies each task's saved stack onto the same guest stack area.
// Give each task its own host stack so a yield retains the native call frames.
struct Scheduler {
    Coroutine main;
    std::unordered_map<uint32_t, Coroutine> workers;
    Coroutine* current = &main;
    ppu_context* context = nullptr;
};
thread_local Scheduler scheduler;

[[noreturn]] void fail(uint32_t frame, uint32_t code)
{
    std::fprintf(stderr, "[pain] invalid coroutine switch frame=0x%08x code=0x%08x\n",
                 frame, code);
    std::abort();
}

#ifdef _WIN32
VOID CALLBACK run_worker(void*)
#else
void run_worker()
#endif
{
    auto* ctx = scheduler.context;
    for (auto target : {static_cast<uint32_t>(ctx->ctr), completion_code}) {
        ctx->ctr = target;
        ps3_indirect_call(ctx);
        while (g_trampoline_fn) {
            const auto next = g_trampoline_fn;
            g_trampoline_fn = nullptr;
            next(ctx);
        }
    }
    // The guest scheduler loops and yields, so its bootstrap never returns.
    fail(static_cast<uint32_t>(ctx->gpr[1]), completion_code);
}

void init_worker(Coroutine& worker, const ppu_context& parent, uint32_t frame, uint32_t code)
{
    worker.regs = {};
    worker.regs.gpr[1] = frame + frame_size;
    worker.regs.gpr[2] = vm_read64(frame + 0x210);
    worker.regs.gpr[3] = vm_read64(frame + 0x228);
    worker.regs.gpr[13] = parent.gpr[13];
    worker.regs.lr = vm_read64(frame + 0x230);
    worker.regs.ctr = code;
    worker.regs.cia = code;
    worker.regs.thread_id = parent.thread_id;
    for (uint32_t i = 14; i < 32; ++i) {
        worker.regs.gpr[i] = vm_read64(frame + (i - 14) * 8);
        const uint64_t bits = vm_read64(frame + 0x90 + (i - 14) * 8);
        std::memcpy(&worker.regs.fpr[i], &bits, sizeof(bits));
    }
    std::memcpy(&worker.regs.vr[20], vm_base + frame + 0x120, 12 * 16);
    worker.regs.fpscr = vm_read64(frame + 0x1f0);
    worker.regs.cr = vm_read64(frame + 0x200);
    worker.dispatch_depth = worker.vcall_depth = 0;
    worker.trampoline = nullptr;
    worker.frame = frame;

#ifdef _WIN32
    if (!scheduler.main.native)
        scheduler.main.native = IsThreadAFiber() ? GetCurrentFiber() : ConvertThreadToFiber(nullptr);
    if (worker.native)
        DeleteFiber(worker.native);
    worker.native = CreateFiberEx(0, host_stack_size, 0, run_worker, nullptr);
    worker.stack_owned = true;
    if (!scheduler.main.native || !worker.native)
        fail(frame, code);
#else
    if (!worker.stack)
        worker.stack = std::make_unique_for_overwrite<char[]>(host_stack_size);
    if (getcontext(&worker.native) != 0)
        fail(frame, code);
    worker.native.uc_stack.ss_sp = worker.stack.get();
    worker.native.uc_stack.ss_size = host_stack_size;
    worker.native.uc_link = nullptr;
    makecontext(&worker.native, run_worker, 0);
#endif
    static thread_local unsigned starts = 0;
    if (++starts <= 8)
        std::fprintf(stderr, "[pain] guest coroutine started at 0x%08x\n", code);
}
}  // namespace

void func_00011810(ppu_context* ctx)
{
    auto& state = scheduler;
    auto& outgoing = *state.current;
    const bool on_main = state.current == &state.main;
    const uint32_t guest_slot = ctx->gpr[3];
    const uint32_t frame = vm_read32(guest_slot);
    if (frame < 0x10000 || frame > UINT32_MAX - frame_size)
        fail(frame, 0);
    const uint32_t code = vm_read64(frame + 0x220);
    auto& incoming = on_main ? state.workers[vm_read32(active_task_slot)] : state.main;
    if (!incoming.frame || incoming.regs.lr != code) {
        if (!on_main || !code || vm_read64(frame + 0x230) != completion_code)
            fail(frame, code);
        init_worker(incoming, *ctx, frame, code);
    }
    incoming.regs.gpr[1] = frame + frame_size;

    outgoing.frame = static_cast<uint32_t>(ctx->gpr[1]) - frame_size;
    outgoing.regs = *ctx;
    outgoing.dispatch_depth = *ps3_ppu_dispatch_depth_slot();
    outgoing.vcall_depth = *ps3_ppu_vcall_sp_slot();
    outgoing.trampoline = g_trampoline_fn;
    // The guest inspects the saved SP to account for its coroutine stack.
    vm_write32(guest_slot, outgoing.frame);
    vm_write64(outgoing.frame + 0x220, ctx->lr);

    state.current = &incoming;
    state.context = ctx;
    *ctx = incoming.regs;
    *ps3_ppu_dispatch_depth_slot() = incoming.dispatch_depth;
    *ps3_ppu_vcall_sp_slot() = incoming.vcall_depth;
    g_trampoline_fn = incoming.trampoline;
#ifdef _WIN32
    SwitchToFiber(incoming.native);
#else
    if (swapcontext(&outgoing.native, &incoming.native) != 0)
        fail(frame, code);
#endif
}
