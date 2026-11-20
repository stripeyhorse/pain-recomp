#include "settings.h"

#include "ppu_recomp.h"

#include <array>
#include <atomic>
#include <cstdio>

extern "C" void ppu_register_function(uint64_t address, void (*function)(ppu_context*));

namespace pain_settings {
namespace {
constexpr uint32_t frontend_toc = 0x00bfd2c8;
// UI state points to the selected debug item at +0x1c and its native
// Sync Rate choice at +0x7a0. Other DebugSelected rows keep their handlers.
constexpr uint32_t frontend_state_slot = 0x00bf9aec;
constexpr uint32_t sync_rate_offset = 0x7a0;
constexpr std::array rates{60, 30, 20, 0};
constexpr uint32_t audio_profile_owner = 0x00bf9a54;
constexpr uint32_t audio_profile_keys[] = {0x00a67d20, 0x00a67d30, 0x00a67d40};

void trace_audio_profile(ppu_context* ctx)
{
    const auto owner = vm_read32(audio_profile_owner);
    const auto profile = owner ? vm_read32(owner + 0x4e4) : 0;
    if (!profile) return;

    // Call Pain's own profile lookup on the current guest thread and stack.
    // Keep the callback's return registers and original TOC intact.
    ppu_context lookup = *ctx;
    double levels[3]{};
    for (size_t i = 0; i < 3; ++i) {
        lookup.gpr[2] = frontend_toc;
        lookup.gpr[3] = profile;
        lookup.gpr[4] = audio_profile_keys[i];
        func_00132B84(&lookup);
        levels[i] = lookup.fpr[1];
    }
    std::fprintf(stderr, "[settings/native] Audio profile dialog=%.3f sfx=%.3f volume=%.3f\n",
                 levels[0], levels[1], levels[2]);
}

void audio_menu(ppu_context* ctx)
{
    // Mirror the native save branch at 0x15435c / 0x154454 so diagnostics
    // sample the profile after its setters run, without polling it per frame.
    const auto input = static_cast<uint32_t>(ctx->gpr[6]);
    const auto back = vm_read32(vm_read32(frontend_toc - 0x3758)) |
                      vm_read32(vm_read32(frontend_toc - 0x375c));
    const auto suppress_save = vm_read32(vm_read32(frontend_toc - 0x3770));
    const bool saving = input && (vm_read32(input + 0x1b8) & back) &&
                        !(vm_read32(input + 0x190) & suppress_save);
    static std::atomic_flag entered;
    if (!entered.test_and_set()) {
        std::fprintf(stderr, "[settings/native] AudioMenuActive (001541b4)\n");
        trace_audio_profile(ctx);
    }
    func_001541B4(ctx);
    if (saving) trace_audio_profile(ctx);
}

uint32_t frontend_state()
{
    const auto slot = vm_read32(frontend_state_slot);
    return slot ? vm_read32(slot) : 0;
}

void sync_rate_available(ppu_context* ctx)
{
    if (const auto state = frontend_state()) {
        for (size_t i = 0; i < rates.size(); ++i) {
            if (rates[i] != frame_cap()) continue;
            const auto selected = static_cast<uint32_t>(i);
            if (vm_read32(state + sync_rate_offset) != selected)
                vm_write32(state + sync_rate_offset, selected);
            break;
        }
    }
    func_00146FD0(ctx);
}

void debug_selected(ppu_context* ctx)
{
    const auto state = frontend_state();
    const bool sync_rate = state && vm_read32(state + 0x1c) == 3;
    const auto previous = sync_rate ? vm_read32(state + sync_rate_offset) : 0;
    func_00146DE0(ctx);
    if (!sync_rate) return;

    const auto selected = vm_read32(state + sync_rate_offset);
    if (selected >= rates.size() || selected == previous) return;
    if (!save_frame_cap(rates[selected])) {
        vm_write32(state + sync_rate_offset, previous);
        std::fprintf(stderr, "[settings/native] could not save Sync Rate to settings.ini\n");
    }
}

template<void (*Original)(ppu_context*), uint32_t Address>
void trace_menu(ppu_context* ctx)
{
    static std::atomic_flag seen;
    if (!seen.test_and_set())
        std::fprintf(stderr, "[settings/native] callback %08x\n", Address);
    Original(ctx);
}

bool matches(uint32_t slot, uint32_t address)
{
    const auto opd = vm_read32(slot);
    // OPDs for this frontend are within the loaded EBOOT's descriptor table.
    return opd >= 0x00bb7a10 && opd < 0x00bf52c8 &&
        vm_read32(opd) == address && vm_read32(opd + 4) == frontend_toc;
}
} // namespace

void install_native_hooks()
{
    if (matches(0x00bf9114, 0x00146de0) && matches(0x00bf93d0, 0x00146fd0) &&
        vm_read32(frontend_state_slot) == 0x00f01630) {
        ppu_register_function(0x00146de0, debug_selected);
        ppu_register_function(0x00146fd0, sync_rate_available);
        if (verbose()) std::fprintf(stderr, "[settings/native] Sync Rate binding installed\n");
    }
    if (!verbose()) return;
    if (!matches(0x00bf92b4, 0x001541b4) ||
        vm_read32(0x00bf9a54) == 0 || vm_read32(0x00bf9d4c) != audio_profile_keys[2]) {
        std::fprintf(stderr, "[settings/native] unknown frontend revision, trace disabled\n");
        return;
    }

    ppu_register_function(0x001541b4, audio_menu);
    if (matches(0x00bf91fc, 0x0015c7f8))
        ppu_register_function(0x0015c7f8, trace_menu<func_0015C7F8, 0x0015c7f8>);
    if (matches(0x00bf922c, 0x00158670))
        ppu_register_function(0x00158670, trace_menu<func_00158670, 0x00158670>);
    if (matches(0x00bf92cc, 0x00159c8c))
        ppu_register_function(0x00159c8c, trace_menu<func_00159C8C, 0x00159c8c>);
    if (matches(0x00bf914c, 0x00149dc4))
        ppu_register_function(0x00149dc4, trace_menu<func_00149DC4, 0x00149dc4>);
    std::fprintf(stderr, "[settings/native] frontend trace enabled\n");
}
} // namespace pain_settings
