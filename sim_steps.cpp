#include "sim_steps.h"
#include "settings/settings.h"

#include "ppu_recomp.h"
#include "vm.h"

#include <bit>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>

extern "C" {
void ppu_register_function(uint64_t address, void (*function)(ppu_context*));
unsigned cellGcm_flip_request_count(void);
}

void original_func_000CA158(ppu_context*);
void pain_frame_driver_one_step(ppu_context*);
void pain_frame_driver_counted(ppu_context*);
// SHA-256 of the lifted func_000CA158 each copy was generated from: one in the
// driver copies (sim_steps_driver.cpp), one in the wrapped chunk that holds
// original_func_000CA158. prepare_ppu.cmake writes both in one run.
extern "C" const char pain_one_step_driver_lift[];
extern "C" const char pain_lifted_driver_lift[];

// Per-step callee calls made by the driver copies, in prepare_ppu.cmake order:
// clock tick, 000DD2C4, physics, physics follow-up, world step, logic step,
// 000C88F8, 001E1948.
uint64_t pain_step_calls[8];
// Call sites of the same callees reached in the current frame, which is what
// the lifted driver would have called. Reset before each frame.
uint32_t pain_step_sites[8];

// BCES00548 01.00. func_000CA158 is the per-frame driver the main loop calls
// once per rendered frame. Every path through it runs two fixed simulation
// steps of 1/60 s (the game clock at 0x01BEC6F8 holds 60 Hz at +0x20, the step
// at +0x30, and func_0021A390 adds one step to +0x28 per tick), so the game is
// built for 30 FPS. pain_frame_driver_one_step (sim_steps_driver.cpp) is the
// lifted driver with each per-step callee limited to its first call per frame.
//
// func_000C911C stores its third argument (0 for the first step, 1 for the
// second) in the byte at 0x00C6EF3D. Its only reader, func_001EEEF0, writes an
// object's bone matrices out only on the step where (flag ^ (object+0x6DA2 !=
// 0)) is 1: the second step for most objects, the first for the others. With
// one step per frame that step is both, so the hook below presents it as such.
namespace {
constexpr uint32_t driver_opd = 0x00bbb5f8;
constexpr uint32_t publish_opd = 0x00bc59d8;
constexpr uint32_t step_flag_writer_toc = 0x00bf6334;
constexpr uint32_t step_flag_reader_toc = 0x00bfe418;
constexpr uint32_t step_flag = 0x00c6ef3d;
constexpr uint32_t clock_toc = 0x00bf6268;
constexpr uint32_t game_clock = 0x01bec6f8;
constexpr uint32_t publish_phase = 0x6da2;
constexpr const char* step_names[8] = {"tick", "dd2c4", "physics", "physics2", "world", "logic", "c88f8", "e1948"};

bool one_step;
bool stats;
bool driver_matches;
thread_local bool in_one_step;
uint64_t site_totals[8];

struct Stats {
    uint64_t frames = 0, wall_ns = 0, cpu_ns = 0, max_wall_ns = 0;
    uint64_t publishes = 0, phase_objects = 0, native = 0;
    uint64_t start_ns = 0;
    uint32_t steps = 0, flips = 0;
    uint64_t calls[8] = {};
    uint64_t sites[8] = {};
    float sim_time = 0;
} window;

#if defined(_WIN32)
enum { wall_clock, cpu_clock };
uint64_t now_ns(int) { return 0; }
#else
constexpr clockid_t wall_clock = CLOCK_MONOTONIC, cpu_clock = CLOCK_THREAD_CPUTIME_ID;
uint64_t now_ns(clockid_t id)
{
    timespec t{};
    clock_gettime(id, &t);
    return uint64_t(t.tv_sec) * 1000000000ull + uint64_t(t.tv_nsec);
}
#endif

float clock_time()
{
    return std::bit_cast<float>(vm_read32(game_clock + 0x28));
}

void reset_window(uint64_t wall)
{
    window = {};
    window.start_ns = wall;
    window.steps = vm_read32(game_clock + 0x18);
    window.sim_time = clock_time();
    window.flips = cellGcm_flip_request_count();
    std::memcpy(window.calls, pain_step_calls, sizeof window.calls);
    std::memcpy(window.sites, site_totals, sizeof window.sites);
}

void report(uint64_t wall)
{
    const double seconds = double(wall - window.start_ns) / 1e9;
    const auto steps = vm_read32(game_clock + 0x18) - window.steps;
    const double sim = double(clock_time()) - window.sim_time;
    const auto flips = cellGcm_flip_request_count() - window.flips;
    const double frames = double(window.frames ? window.frames : 1);
    uint64_t calls[8];
    for (int i = 0; i < 8; ++i) calls[i] = pain_step_calls[i] - window.calls[i];
    // The physics step is 1/60 s of simulated time per call.
    std::fprintf(stderr,
        "[sim-steps] calls/s tick=%.1f dd2c4=%.1f physics=%.1f physics2=%.1f world=%.1f logic=%.1f c88f8=%.1f e1948=%.1f "
        "physics_sim/wall=%.3f\n",
        calls[0] / seconds, calls[1] / seconds, calls[2] / seconds, calls[3] / seconds, calls[4] / seconds,
        calls[5] / seconds, calls[6] / seconds, calls[7] / seconds, calls[2] / 60.0 / seconds);
    if (one_step) {
        // What the lifted driver would have called on the same frames.
        uint64_t sites[8];
        for (int i = 0; i < 8; ++i) sites[i] = site_totals[i] - window.sites[i];
        std::fprintf(stderr,
            "[sim-steps] lifted sites/s tick=%.1f dd2c4=%.1f physics=%.1f physics2=%.1f world=%.1f logic=%.1f "
            "c88f8=%.1f e1948=%.1f\n",
            sites[0] / seconds, sites[1] / seconds, sites[2] / seconds, sites[3] / seconds, sites[4] / seconds,
            sites[5] / seconds, sites[6] / seconds, sites[7] / seconds);
    }
    std::fprintf(stderr,
        "[sim-steps] steps=%d wall=%.2fs frames=%llu flips=%u fps=%.2f clock_steps=%u "
        "sim=%.3fs sim/wall=%.3f dt=%.6f driver_wall=%.2fms driver_cpu=%.2fms driver_max=%.2fms "
        "publish_calls=%llu phase_objects=%llu publish_native=%llu\n",
        one_step ? 1 : 2, seconds, (unsigned long long)window.frames, flips, flips / seconds, steps,
        sim, sim / seconds, std::bit_cast<float>(vm_read32(game_clock + 0x30)),
        window.wall_ns / frames / 1e6, window.cpu_ns / frames / 1e6, window.max_wall_ns / 1e6,
        (unsigned long long)window.publishes, (unsigned long long)window.phase_objects,
        (unsigned long long)window.native);
    reset_window(wall);
}

// One-step self-check, every frame: each per-step callee the lifted driver
// would have reached ran exactly once, none ran that it would not have reached,
// and a clock tick that ran (clock not paused) advanced the step counter. The
// paths differ: the frontend path (+0x534 set, the menus and boot screens) has
// no clock tick in the lifted driver either, so a tick count of 0 there is the
// game's own behaviour. One line per newly seen path; on a violation, fall back
// to the lifted driver (sim_steps=2) from the next frame.
struct SelfCheck {
    uint64_t frame = 0;
    uint32_t seen[8] = {};
    int n_seen = 0;
} check;

void describe(char* out, size_t size, const uint32_t* sites)
{
    size_t used = 0;
    for (int i = 0; i < 8 && used < size; ++i)
        used += std::snprintf(out + used, size - used, "%s%s=%u", i ? " " : "", step_names[i], sites[i]);
}

void self_check(const uint64_t* before, bool paused, uint32_t clock_before)
{
    check.frame++;
    uint32_t mask = 0;
    const char* problem = nullptr;
    int bad = -1;
    for (int i = 0; i < 8; ++i) {
        site_totals[i] += pain_step_sites[i];
        const uint64_t ran = pain_step_calls[i] - before[i];
        if (pain_step_sites[i]) mask |= 1u << i;
        if (ran != (pain_step_sites[i] ? 1u : 0u) && !problem) {
            problem = "a per-step callee did not run exactly once";
            bad = i;
        }
    }
    const bool tick_ran = pain_step_calls[0] != before[0];
    const bool still_paused = vm_read8(game_clock + 0x40) != 0;
    if (!problem && tick_ran && !paused && !still_paused && vm_read32(game_clock + 0x18) == clock_before) {
        problem = "the clock tick ran but the game clock did not advance";
        bad = 0;
    }
    bool known = false;
    for (int i = 0; i < check.n_seen; ++i) known |= check.seen[i] == mask;
    if (!problem && (known || check.n_seen == 8)) return;
    char sites[256];
    describe(sites, sizeof sites, pain_step_sites);
    if (problem) {
        std::fprintf(stderr,
            "[sim-steps] self-check FAILED at frame %llu: %s (%s: lifted sites %s). Falling back to sim_steps=2.\n",
            (unsigned long long)check.frame, problem, step_names[bad], sites);
        one_step = false;
        return;
    }
    check.seen[check.n_seen++] = mask;
    std::fprintf(stderr, "[sim-steps] self-check frame %llu, new path: lifted sites %s; each ran once%s\n",
        (unsigned long long)check.frame, sites,
        pain_step_sites[0] ? (paused ? ", clock paused" : ", clock advanced 1 step") : ", no clock tick on this path");
}

void run_driver(ppu_context* ctx)
{
    if (!one_step) {
        if (stats && driver_matches) pain_frame_driver_counted(ctx);
        else original_func_000CA158(ctx);
        return;
    }
    std::memset(pain_step_sites, 0, sizeof pain_step_sites);
    uint64_t before[8];
    std::memcpy(before, pain_step_calls, sizeof before);
    const bool paused = vm_read8(game_clock + 0x40) != 0;
    const uint32_t clock_before = vm_read32(game_clock + 0x18);
    in_one_step = true;
    pain_frame_driver_one_step(ctx);
    in_one_step = false;
    self_check(before, paused, clock_before);
}

void publish_bones(ppu_context* ctx)
{
    const auto object = static_cast<uint32_t>(ctx->gpr[3]);
    const auto saved = vm_read8(step_flag);
    const bool phase = vm_read8(object + publish_phase) != 0;
    if (stats) {
        window.publishes++;
        window.phase_objects += phase;
        window.native += (saved != 0) != phase;
    }
    if (!in_one_step) {
        func_001EEEF0(ctx);
        return;
    }
    vm_write8(step_flag, phase ? 0 : 1);
    func_001EEEF0(ctx);
    vm_write8(step_flag, saved);
}
} // namespace

void func_000CA158(ppu_context* ctx)
{
    if (!stats) {
        run_driver(ctx);
        return;
    }
    const auto wall = now_ns(wall_clock);
    const auto cpu = now_ns(cpu_clock);
    if (!window.start_ns) reset_window(wall);
    run_driver(ctx);
    const auto elapsed = now_ns(wall_clock) - wall;
    window.frames++;
    window.wall_ns += elapsed;
    window.cpu_ns += now_ns(cpu_clock) - cpu;
    if (elapsed > window.max_wall_ns) window.max_wall_ns = elapsed;
    if (wall + elapsed - window.start_ns >= 5000000000ull) report(wall + elapsed);
}

void install_sim_steps()
{
    driver_matches = std::strcmp(pain_one_step_driver_lift, pain_lifted_driver_lift) == 0;
    const auto* requested_stats = std::getenv("PAIN_SIM_STATS");
    stats = requested_stats && std::strcmp(requested_stats, "1") == 0;
#if defined(_WIN32)
    if (stats) std::fprintf(stderr, "[sim-steps] PAIN_SIM_STATS needs POSIX clocks, ignored\n");
    stats = false;
#endif
    // The counting hook changes no guest state outside sim_steps=1.
    if (stats && vm_read32(publish_opd) == 0x001eeef0)
        ppu_register_function(0x001eeef0, publish_bones);
    const auto setting = pain_settings::value("sim_steps");
    const double steps = std::strtod(setting.c_str(), nullptr);
    if (steps != 1) {
        if (steps != 2)
            std::fprintf(stderr, "[sim-steps] sim_steps=%s is not 1 or 2, using 2\n", setting.c_str());
        return;
    }
    if (!driver_matches) {
        std::fprintf(stderr,
            "[sim-steps] the one-step driver was generated from another func_000CA158 (lift %.12s) than the one "
            "linked (lift %.12s); rerun prepare_deploy.sh. Using sim_steps=2\n",
            pain_one_step_driver_lift, pain_lifted_driver_lift);
        return;
    }
    if (vm_read32(driver_opd) != 0x000ca158 || vm_read32(publish_opd) != 0x001eeef0 ||
        vm_read32(step_flag_writer_toc) != step_flag || vm_read32(step_flag_reader_toc) != step_flag ||
        vm_read32(clock_toc) != game_clock) {
        std::fprintf(stderr, "[sim-steps] not the BCES00548 01.00 frame driver, using sim_steps=2\n");
        return;
    }
    ppu_register_function(0x001eeef0, publish_bones);
    one_step = true;
    std::fprintf(stderr, "[sim-steps] sim_steps=1: one simulation step per rendered frame (lift %.12s)\n",
        pain_lifted_driver_lift);
}
