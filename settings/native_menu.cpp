#include "settings.h"

#include "ppu_recomp.h"
#include "vm.h"

#include <array>
#include <atomic>
#include <cstdio>
#include <cstring>

extern "C" void ppu_register_function(uint64_t address, void (*function)(ppu_context*));

void original_func_0026E360(ppu_context*);

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

// BCES00548 BasePackage.uid, after the game's tagged pointers are resolved.
constexpr uint32_t audio_screen_offset = 0x90;
constexpr uint32_t audio_options_offset = 0x27900;
constexpr uint32_t dialog_row_offset = 0x27bec;
constexpr uint32_t sfx_row_offset = 0x27d60;
constexpr uint32_t volume_row_offset = 0x27ed4;
constexpr uint32_t volume_text_offset = 0x19c9c;
constexpr uint32_t sync_rate_row = 0x3ff20000; // Port-owned guest memory.
constexpr uint32_t sync_rate_text = sync_rate_row + 0x180;
constexpr uint32_t sync_rate_label = sync_rate_row + 0x340;
constexpr uint32_t sync_rate_row_name = sync_rate_row + 0x370;
constexpr uint32_t sync_rate_text_name = sync_rate_row + 0x380;
constexpr uint32_t sync_rate_index = 3;
bool audio_hook_installed;
uint32_t audio_screen;

void update_sync_rate_label()
{
    const auto cap = frame_cap();
    auto* label = reinterpret_cast<char*>(vm_base + sync_rate_label);
    if (cap == 0)
        std::snprintf(label, 48, "Sync Rate: Variable");
    else
        std::snprintf(label, 48, "Sync Rate: %d FPS", cap);
}

void append_audio_sync_rate(uint32_t base)
{
    // Only BasePackage for the known retail SKU has this ID and table layout.
    if (vm_read32(base + 8) != 0xd1323ede ||
        vm_read32(base + 0x38) != base + 0x3e09c) return;
    const auto screen = base + audio_screen_offset;
    const auto group = base + audio_options_offset;
    const auto dialog = base + dialog_row_offset;
    const auto sfx = base + sfx_row_offset;
    const auto volume = base + volume_row_offset;
    const auto text = base + volume_text_offset;
    if (vm_read32(volume + 0x158) == sync_rate_row) return;
    if (vm_read32(screen) != 1 || vm_read32(screen + 0x14) != group ||
        vm_read32(group) != 10 || vm_read32(group + 0x15c) != dialog ||
        vm_read32(group + 0x168) != sync_rate_index ||
        vm_read32(dialog + 0x158) != sfx || vm_read32(sfx + 0x158) != volume ||
        vm_read32(volume) != 11 || vm_read32(volume + 0x158) != 0 ||
        vm_read32(volume + 0x15c) != text || vm_read32(text) != 8) {
        if (verbose()) std::fprintf(stderr, "[settings/native] Audio menu graph did not match\n");
        return;
    }

    std::memcpy(vm_base + sync_rate_row, vm_base + volume, 0x174);
    std::memcpy(vm_base + sync_rate_text, vm_base + text, 0x1b4);
    std::memcpy(vm_base + sync_rate_row_name, "SyncRate", sizeof("SyncRate"));
    std::memcpy(vm_base + sync_rate_text_name, "SyncRateText", sizeof("SyncRateText"));
    update_sync_rate_label();

    vm_write32(sync_rate_row + 4, sync_rate_row_name);
    vm_write32(sync_rate_row + 8, 0x49a59b9e); // Native SyncRate name hash.
    vm_write32(sync_rate_row + 0xc, 0xffffffff); // No serialized object index.
    vm_write32(sync_rate_row + 0x15c, sync_rate_text);
    vm_write32(sync_rate_row + 0x160, 0xffffffff); // No slider input.
    vm_write32(sync_rate_row + 0x168, sync_rate_index);
    vm_write32(sync_rate_text + 4, sync_rate_text_name);
    vm_write32(sync_rate_text + 8, 0xd1aafbcb); // Native SyncRateText hash.
    vm_write32(sync_rate_text + 0xc, 0xffffffff);
    vm_write32(sync_rate_text + 0x14, 0); // Align to the row without a slider.
    vm_write32(sync_rate_text + 0x154, sync_rate_row);
    vm_write32(sync_rate_text + 0x158, 0); // No slider child.
    for (uint32_t offset = 0x164; offset <= 0x1a0; offset += 4)
        vm_write32(sync_rate_text + offset, sync_rate_label);
    vm_write32(sync_rate_text + 0x1ac, 0x43960000); // 300-pixel label width.

    audio_screen = screen;
    vm_write32(volume + 0x158, sync_rate_row);
    vm_write32(group + 0x168, sync_rate_index + 1);
    if (verbose()) std::fprintf(stderr, "[settings/native] Audio Sync Rate row installed\n");
}

void audio_sync_rate_input(ppu_context* ctx)
{
    if (!audio_screen || ctx->gpr[5] != audio_screen) return;
    if (ctx->gpr[4] == 0) {
        update_sync_rate_label();
        return;
    }
    if (ctx->gpr[3] != sync_rate_index || !ctx->gpr[6]) return;
    const auto input = static_cast<uint32_t>(ctx->gpr[6]);
    const auto confirm = vm_read32(vm_read32(frontend_toc - 0x37d0));
    if (!(vm_read32(input + 0x190) & confirm)) return;
    size_t next = 0;
    for (size_t i = 0; i < rates.size(); ++i) {
        if (rates[i] == frame_cap()) {
            next = (i + 1) % rates.size();
            break;
        }
    }
    if (save_frame_cap(rates[next]))
        update_sync_rate_label();
    else
        std::fprintf(stderr, "[settings/native] could not save Sync Rate to settings.ini\n");
}

void trace_audio_profile(ppu_context* ctx)
{
    const auto owner = vm_read32(audio_profile_owner);
    const auto profile = owner ? vm_read32(owner + 0x4e4) : 0;
    if (!profile) return;

    // Call Pain's own profile lookup on the current guest thread and stack.
    // Keep the callback's return registers and original TOC intact.
    ppu_context lookup = *ctx;
    std::array<double, 3> levels{};
    for (size_t i = 0; i < 3; ++i) {
        lookup.gpr[2] = frontend_toc;
        lookup.gpr[3] = profile;
        lookup.gpr[4] = audio_profile_keys[i];
        func_00132B84(&lookup);
        levels[i] = lookup.fpr[1];
    }
    static thread_local std::array<double, 3> previous{};
    static thread_local bool sampled;
    if (sampled && previous == levels) return;
    sampled = true;
    previous = levels;
    std::fprintf(stderr, "[settings/native] Audio profile dialog=%.3f sfx=%.3f volume=%.3f\n",
                 levels[0], levels[1], levels[2]);
}

void audio_menu(ppu_context* ctx)
{
    audio_sync_rate_input(ctx);
    if (!verbose()) {
        func_001541B4(ctx);
        return;
    }
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
    if (matches(0x00bf92b4, 0x001541b4) &&
        vm_read32(0x00bf9a54) == 0x00d88c00 &&
        vm_read32(0x00bf9d4c) == audio_profile_keys[2] &&
        vm_commit(sync_rate_row, 0x1000) == 0) {
        audio_hook_installed = true;
        ppu_register_function(0x001541b4, audio_menu);
    } else {
        std::fprintf(stderr, "[settings/native] Audio Sync Rate row unavailable for this revision\n");
    }
    if (!verbose()) return;
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


// 0x26e360 resolves object and string references in each loaded UID package.
// Append after the native fixups and before the screen is opened.
void func_0026E360(ppu_context* ctx)
{
    const auto base = static_cast<uint32_t>(ctx->gpr[4]);
    original_func_0026E360(ctx);
    if (pain_settings::audio_hook_installed && base)
        pain_settings::append_audio_sync_rate(base);
}
