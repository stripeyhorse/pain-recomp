#include "settings.h"

#include "ppu_recomp.h"
#include "vm.h"
#if defined(__APPLE__)
#include "rsx_metal_backend.h"
#endif

#include <array>
#include <atomic>
#include <algorithm>
#include <span>
#include <cstdio>
#include <cstdlib>
#include <cstring>

extern "C" void ppu_register_function(uint64_t address, void (*function)(ppu_context*));

void original_func_0024487C(ppu_context*);
void original_func_0024206C(ppu_context*);

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

// BCES00548 runtime records, after the native screen instance is built.
constexpr uint32_t audio_screen_hash = 0xc26abd39;
constexpr uint32_t audio_group_hash = 0x9e2e3ce5;
constexpr uint32_t audio_row_hashes[] = {0x45f96eb4, 0x5506f19d, 0x35bbc2a3};
constexpr uint32_t row_size = 0x174;
constexpr uint32_t row_store = 0x3ff20000;
constexpr uint32_t video_rows = row_store + 0xa00;
constexpr uint32_t rows_per_page = 7;
constexpr uint32_t text_store = row_store + 0x2000;
constexpr uint32_t text_slot_size = 0x240;
constexpr uint32_t label_offset = 0x1b4;
constexpr uint32_t sync_rate_index = 3;
constexpr uint32_t video_index = 4;
constexpr uint32_t no_handler = 0xffffffff;
bool audio_hook_installed;
uint32_t audio_screen;
uint32_t audio_group;
uint32_t package_text;
enum class Page : uint32_t { display, image, audio };
constexpr uint32_t first_row(Page page)
{
    return video_rows + static_cast<uint32_t>(page) * rows_per_page * row_size;
}
constexpr uint32_t text_slot(Page page, uint32_t index)
{
    return 2 + static_cast<uint32_t>(page) * rows_per_page + index;
}
uint32_t display_count, image_count, audio_sidebar;
Page current_page = Page::audio;
constexpr std::array group_fields{0x10u, 0x14u, 0x1cu, 0x20u, 0x158u, 0x15cu, 0x168u};
std::array<uint32_t, group_fields.size()> audio_fields;
std::array<uint32_t, 16> audio_titles;
uint32_t audio_sidebar_next;
constexpr uint32_t sidebar_label = row_store + 0x4800;

using namespace std::literals;
constexpr std::array toggle{"off"sv, "on"sv};
constexpr std::array sizes{"auto"sv, "1280x720"sv, "1600x900"sv, "1920x1080"sv,
                           "2560x1440"sv, "3840x2160"sv};
constexpr std::array aspects{"fit"sv, "stretch"sv};
constexpr std::array aa{"off"sv, "fxaa"sv, "smaa"sv};
constexpr std::array vibrance{"-0.5"sv, "0"sv, "0.25"sv, "0.5"sv, "1"sv};
constexpr std::array contrast{"0.75"sv, "1"sv, "1.1"sv, "1.25"sv, "1.5"sv};
constexpr std::array sharpen{"0"sv, "0.25"sv, "0.5"sv, "1"sv};
constexpr std::array anisotropic{"0"sv, "2"sv, "4"sv, "8"sv, "16"sv};
constexpr std::array scales{"50"sv, "100"sv, "150"sv, "200"sv};

enum class Availability { window, sync, metal_post };
struct VideoSetting {
    std::string_view key;
    const char* label;
    std::span<const std::string_view> choices;
    Availability availability;
    bool restart;
};

constexpr std::array video_options{
    VideoSetting{"fullscreen", "Fullscreen", toggle, Availability::window, true},
    VideoSetting{"window_size", "Window Size", sizes, Availability::window, true},
    VideoSetting{"fullscreen_size", "Fullscreen Output", sizes, Availability::window, true},
    VideoSetting{"aspect", "Aspect", aspects, Availability::window, false},
    VideoSetting{"vsync", "Vsync", toggle, Availability::sync, false},
    VideoSetting{"post_scale", "Post-process Scale", scales, Availability::metal_post, false},
    VideoSetting{"aa", "Anti-aliasing", aa, Availability::metal_post, false},
    VideoSetting{"vibrance", "Vibrance", vibrance, Availability::metal_post, false},
    VideoSetting{"contrast", "Contrast", contrast, Availability::metal_post, false},
    VideoSetting{"sharpen", "Sharpen", sharpen, Availability::metal_post, false},
    VideoSetting{"anisotropic", "Anisotropy", anisotropic, Availability::metal_post, true},
};
std::array<const VideoSetting*, video_options.size()> available_video;

bool supported(Availability requirement)
{
#if defined(__APPLE__)
    if (!rsx_metal_backend_has_register_present()) return false;
    if (requirement == Availability::metal_post) return true;
    return value("metal_headless") != "on" && !std::getenv("PS3RECOMP_HOST_SURFACES");
#elif defined(PS3RECOMP_RSX_VULKAN)
    return requirement != Availability::metal_post && value("vulkan_window") == "on";
#elif defined(_WIN32)
    return requirement == Availability::sync;
#else
    (void)requirement;
    return false;
#endif
}

uint32_t text_at(uint32_t slot) { return text_store + slot * text_slot_size; }

void set_label(uint32_t slot, const char* label)
{
    std::snprintf(reinterpret_cast<char*>(vm_base + text_at(slot) + label_offset), 96, "%s", label);
}

void update_sync_rate_label()
{
    std::array<char, 96> label{};
    if (const auto cap = frame_cap())
        std::snprintf(label.data(), label.size(), "Sync Rate: %d FPS", cap);
    else
        std::snprintf(label.data(), label.size(), "Sync Rate: Variable");
    set_label(0, label.data());
}

uint32_t option_count(Page page) { return page == Page::display ? display_count : image_count; }

bool has_image_link(Page page) { return page == Page::display && image_count != 0; }

const VideoSetting& page_option(Page page, uint32_t i)
{
    return *available_video[i + (page == Page::image ? display_count : 0)];
}

uint32_t back_row(Page page) { return option_count(page) + has_image_link(page); }

void update_video_label(Page page, uint32_t i)
{
    const auto& option = page_option(page, i);
    const auto current = value(option.key);
    std::array<char, 96> label{};
    const bool restart = option.restart ||
#if defined(__APPLE__)
        false;
#else
        option.key == "aspect" || option.key == "vsync";
#endif
    std::snprintf(label.data(), label.size(), "%s: %.*s%s%s", option.label,
                  static_cast<int>(current.size()), current.data(),
                  option.key == "post_scale" ? "%" : "", restart ? " (restart)" : "");
    set_label(text_slot(page, i), label.data());
}

void add_row(uint32_t rows, uint32_t group, uint32_t index, uint32_t text_slot, uint32_t handler)
{
    const auto row = rows + index * row_size;
    const auto text = text_at(text_slot);
    std::memcpy(vm_base + text, vm_base + package_text, label_offset);
    vm_write32(row + 0xc, no_handler); // No serialized object index.
    vm_write32(row + 0x154, group);
    vm_write32(row + 0x158, 0);
    vm_write32(row + 0x15c, text);
    vm_write32(row + 0x160, no_handler); // No slider.
    vm_write32(row + 0x164, handler);
    vm_write32(row + 0x168, index);
    vm_write32(row + 0x170, 0xfffffffd); // Keep this screen after Cross.
    vm_write32(text + 0xc, no_handler);
    vm_write32(text + 0x14, 0);
    vm_write32(text + 0x154, row);
    vm_write32(text + 0x158, 0);
    for (uint32_t offset = 0x164; offset <= 0x1a0; offset += 4)
        vm_write32(text + offset, text + label_offset);
    vm_write32(text + 0x1ac, 0x43e10000); // 450-pixel label width.
    if (index) vm_write32(row - row_size + 0x158, row);
    else vm_write32(group + 0x15c, row);
    vm_write32(group + 0x168, index + 1);
}

uint32_t selected_handler(uint32_t manager)
{
    const auto table = vm_read32(manager + 0x1180);
    const auto header = vm_read32(manager + 0x994);
    if (!table || !header) return no_handler;
    const auto count = vm_read32(header + 0x10);
    if (!count || count > 1024) return no_handler;
    // The registered DebugSelected descriptor has the ordinary row-selected
    // ABI. Our hook routes the Audio screen's added rows to their port actions.
    const auto opd = vm_read32(0x00bf9114);
    for (uint32_t i = 0; i < count; ++i)
        if (vm_read32(table + i * 4) == opd) return i;
    return no_handler;
}

void append_audio_settings(uint32_t manager, uint32_t screen, uint32_t group)
{
    if (!screen || !group || vm_read32(screen) != 1 ||
        vm_read32(screen + 8) != audio_screen_hash ||
        vm_read32(screen + 0x14) != group || vm_read32(group) != 10 ||
        vm_read32(group + 8) != audio_group_hash)
        return;
    const auto handler = selected_handler(manager);
    if (handler == no_handler) {
        if (verbose()) std::fprintf(stderr, "[settings/native] native selection handler unavailable\n");
        return;
    }
    const auto dialog = vm_read32(group + 0x15c);
    if (!dialog || dialog == first_row(Page::display) || dialog == first_row(Page::image)) return;
    if (dialog == row_store) {
        audio_screen = screen;
        audio_group = group;
        for (uint32_t i = 0; i < vm_read32(group + 0x168) && i <= video_index; ++i)
            vm_write32(row_store + i * row_size + 0x154, group);
        for (const auto page : {Page::display, Page::image})
            for (uint32_t i = 0; option_count(page) && i <= back_row(page); ++i)
                vm_write32(first_row(page) + i * row_size + 0x154, group);
        return;
    }
    const auto sfx = dialog + row_size;
    const auto volume = sfx + row_size;
    const auto text = vm_read32(volume + 0x15c);
    if (vm_read32(group + 0x168) != sync_rate_index ||
        vm_read32(dialog) != 11 || vm_read32(sfx) != 11 || vm_read32(volume) != 11 ||
        vm_read32(dialog + 8) != audio_row_hashes[0] ||
        vm_read32(sfx + 8) != audio_row_hashes[1] ||
        vm_read32(volume + 8) != audio_row_hashes[2] ||
        vm_read32(dialog + 0x158) != sfx || vm_read32(sfx + 0x158) != volume ||
        vm_read32(volume + 0x158) != 0 || !text || vm_read32(text) != 8) {
        if (verbose()) std::fprintf(stderr, "[settings/native] Audio menu graph did not match\n");
        return;
    }

    audio_screen = screen;
    audio_group = group;
    current_page = Page::audio;
    package_text = text;
    const auto background = vm_read32(screen + 0x10);
    const auto buttons = background ? vm_read32(background + 0x158) : 0;
    const auto header = buttons ? vm_read32(buttons + 0x158) : 0;
    audio_sidebar = header && vm_read32(header) == 8 && vm_read32(header + 8) == 0xb52ca7a
        ? header : 0;
    // Draw follows +0x158, but selection uses first + index * 0x174.
    std::memcpy(vm_base + row_store, vm_base + dialog, row_size * sync_rate_index);
    for (uint32_t i = 0; i < sync_rate_index; ++i) {
        const auto row = row_store + i * row_size;
        const auto row_text = vm_read32(row + 0x15c);
        vm_write32(row_text + 0x154, row);
        vm_write32(row + 0x158, i + 1 < sync_rate_index ? row + row_size : 0);
    }
    vm_write32(group + 0x15c, row_store);
    std::memcpy(vm_base + row_store + sync_rate_index * row_size, vm_base + volume, row_size);
    add_row(row_store, group, sync_rate_index, 0, handler);
    update_sync_rate_label();

    display_count = image_count = 0;
    for (const auto& option : video_options) {
        if (!supported(option.availability)) continue;
        available_video[display_count + image_count] = &option;
        if (option.availability == Availability::metal_post) ++image_count;
        else ++display_count;
    }
    if (display_count || image_count) {
        std::memcpy(vm_base + row_store + video_index * row_size, vm_base + volume, row_size);
        add_row(row_store, group, video_index, 1, handler);
        set_label(1, "Video / Display");
        for (const auto page : {Page::display, Page::image}) {
            if (!option_count(page)) continue;
            for (uint32_t i = 0; i <= back_row(page); ++i) {
                std::memcpy(vm_base + first_row(page) + i * row_size, vm_base + volume, row_size);
                add_row(first_row(page), group, i, text_slot(page, i), handler);
                if (i < option_count(page)) update_video_label(page, i);
            }
            if (has_image_link(page)) set_label(text_slot(page, display_count), "Image Quality");
            set_label(text_slot(page, back_row(page)),
                      page == Page::image && display_count ? "Back to Display" : "Back to Audio");
        }
        vm_write32(group + 0x15c, row_store);
        vm_write32(group + 0x168, video_index + 1);
    }
    if (verbose()) std::fprintf(stderr, "[settings/native] Audio rows installed, %u Video settings\n",
                                display_count + image_count);
}

void refresh_menu(ppu_context* ctx, uint32_t manager, Page page, uint32_t selected)
{
    // The native painter holds the active group's address. Replace its list
    // and layout together with the controller navigation grid.
    if (current_page == Page::audio) {
        for (size_t i = 0; i < group_fields.size(); ++i)
            audio_fields[i] = vm_read32(audio_group + group_fields[i]);
        if (audio_sidebar) {
            audio_sidebar_next = vm_read32(audio_sidebar + 0x158);
            for (uint32_t i = 0; i < audio_titles.size(); ++i)
                audio_titles[i] = vm_read32(audio_sidebar + 0x164 + i * 4);
        }
    }

    if (page == Page::audio) {
        for (size_t i = 0; i < group_fields.size(); ++i)
            vm_write32(audio_group + group_fields[i], audio_fields[i]);
        if (audio_sidebar) {
            vm_write32(audio_sidebar + 0x158, audio_sidebar_next);
            for (uint32_t i = 0; i < audio_titles.size(); ++i)
                vm_write32(audio_sidebar + 0x164 + i * 4, audio_titles[i]);
        }
    } else {
        // The game uses fixed vertical spacing for this group. At most seven
        // items fit between the heading and the controller hint.
        const std::array fields{0x44598000u, 0x43160000u, 0x44598000u, 0x43160000u,
                                0u, first_row(page), back_row(page) + 1};
        for (size_t i = 0; i < group_fields.size(); ++i)
            vm_write32(audio_group + group_fields[i], fields[i]);
        if (audio_sidebar) {
            // The known Audio background ends with the boombox image.
            if (audio_sidebar_next && vm_read32(audio_sidebar_next) == 7 &&
                vm_read32(audio_sidebar_next + 8) == 0x0d52c3de)
                vm_write32(audio_sidebar + 0x158, vm_read32(audio_sidebar_next + 0x158));
            auto* label = reinterpret_cast<char*>(vm_base + sidebar_label);
            std::snprintf(label, 16, "%s", page == Page::display ? "Display" : "Image");
            for (uint32_t i = 0; i < audio_titles.size(); ++i)
                vm_write32(audio_sidebar + 0x164 + i * 4, sidebar_label);
        }
    }
    current_page = page;
    ppu_context call = *ctx;
    call.gpr[3] = manager + 0x120;
    call.gpr[4] = audio_group;
    func_0024487C(&call);
    call = *ctx;
    call.gpr[3] = manager + 0x120;
    call.gpr[4] = selected;
    func_00241AF4(&call);
    call = *ctx;
    call.gpr[3] = manager;
    call.gpr[4] = 0;
    func_0024206C(&call);
}

bool select_added_row(ppu_context* ctx)
{
    if (!audio_screen || ctx->gpr[4] != audio_screen || ctx->gpr[5] < 0x118c) return false;
    const auto manager = static_cast<uint32_t>(ctx->gpr[5]) - 0x118c;
    const auto row = static_cast<uint32_t>(ctx->gpr[3]);
    const auto page = current_page;
    if (page == Page::audio && row == sync_rate_index) {
        const auto rate = std::find(rates.begin(), rates.end(), frame_cap());
        const auto next = (static_cast<size_t>(rate - rates.begin()) + 1) % rates.size();
        if (save_frame_cap(rates[next])) update_sync_rate_label();
        else std::fprintf(stderr, "[settings/native] could not save Sync Rate\n");
    } else if (page == Page::audio && (display_count || image_count) && row == video_index) {
        refresh_menu(ctx, manager, display_count ? Page::display : Page::image, 0);
    } else if (page != Page::audio && row == back_row(page)) {
        if (page == Page::image && display_count)
            refresh_menu(ctx, manager, Page::display, display_count);
        else
            refresh_menu(ctx, manager, Page::audio, video_index);
    } else if (has_image_link(page) && row == display_count) {
        refresh_menu(ctx, manager, Page::image, 0);
    } else if (page != Page::audio && row < option_count(page)) {
        const auto& option = page_option(page, row);
        const auto current = value(option.key);
        const auto choice = std::find(option.choices.begin(), option.choices.end(), current);
        const auto next = choice == option.choices.end() || choice + 1 == option.choices.end()
            ? option.choices.front() : *(choice + 1);
        if (save(option.key, std::string(next))) update_video_label(page, row);
        else std::fprintf(stderr, "[settings/native] could not save %s\n", option.key.data());
    } else {
        return false;
    }
    ctx->gpr[3] = 0;
    return true;
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
    if (audio_screen && ctx->gpr[5] == audio_screen && current_page != Page::audio) {
        const auto input = static_cast<uint32_t>(ctx->gpr[6]);
        const auto back = vm_read32(vm_read32(frontend_toc - 0x3758)) |
                          vm_read32(vm_read32(frontend_toc - 0x375c));
        if (input && (vm_read32(input + 0x1b8) & back)) {
            const auto manager = input - 0x118c;
            if (current_page == Page::image && display_count)
                refresh_menu(ctx, manager, Page::display, display_count);
            else
                refresh_menu(ctx, manager, Page::audio, video_index);
            vm_write32(input + 0x1b8, vm_read32(input + 0x1b8) & ~back);
            vm_write32(input + 0x1c0, vm_read32(input + 0x1c0) & ~back);
        }
        ctx->gpr[3] = 0;
        return;
    }
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
    if (select_added_row(ctx)) return;
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
    const bool selection = matches(0x00bf9114, 0x00146de0);
    if (selection) ppu_register_function(0x00146de0, debug_selected);
    if (selection && matches(0x00bf93d0, 0x00146fd0) &&
        vm_read32(frontend_state_slot) == 0x00f01630) {
        ppu_register_function(0x00146fd0, sync_rate_available);
        if (verbose()) std::fprintf(stderr, "[settings/native] Sync Rate binding installed\n");
    }
    if (selection && matches(0x00bf92b4, 0x001541b4) &&
        vm_read32(0x00bf9a54) == 0x00d88c00 &&
        vm_read32(0x00bf9d4c) == audio_profile_keys[2] &&
        vm_commit(row_store, 0x5000) == 0) {
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


// The loader's UID objects and the active menu instance are separate. Extend
// the instance immediately before the game materializes its navigation grid.
void func_0024487C(ppu_context* ctx)
{
    if (pain_settings::audio_hook_installed) {
        const auto manager = static_cast<uint32_t>(ctx->gpr[3]) - 0x120;
        const auto screen = vm_read32(manager + 0x1188);
        pain_settings::append_audio_settings(manager, screen, static_cast<uint32_t>(ctx->gpr[4]));
    }
    original_func_0024487C(ctx);
}

// The native screen activation and direction routines both pass through here.
// Report the game's actual selection for local verification.
void func_0024206C(ppu_context* ctx)
{
    const auto manager = static_cast<uint32_t>(ctx->gpr[3]);
    const auto previous = vm_read32(manager + 0x978);
    original_func_0024206C(ctx);
    if (!pain_settings::audio_hook_installed ||
        vm_read32(manager + 0x1188) != pain_settings::audio_screen) return;
    const auto selected = vm_read32(manager + 0x978);
    if (pain_settings::verbose() && selected != previous)
        std::fprintf(stderr, "[settings/native] %s selection %d (%u rows, item %08x)\n",
                     pain_settings::current_page == pain_settings::Page::audio ? "Audio" : "Video",
                     static_cast<int32_t>(selected), vm_read32(manager + 0x120),
                     vm_read32(manager + 0x980));
}
