#include "unlock_trainer.h"

#include "ppu_recomp.h"
#include "vm.h"

#include <atomic>
#include <bit>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>

extern "C" {
int g_pain_unlock_all = 0;
void ppu_register_function(uint64_t address, void (*function)(ppu_context*));
}

void original_func_00132D24(ppu_context*);

namespace {
constexpr uint32_t profile_owner = 0x00d88c00;
constexpr uint32_t save_state = 0x01bec748;
constexpr uint32_t profile_capacity = 0x20000;
constexpr uint32_t stat_size = 20;
constexpr uint32_t stat_value = 16;
// Reserved just below the mmapper range, separate from the LevelScript bank.
constexpr uint32_t save_copy = 0x3ff00000;
constexpr char tutorial_key[] = "T_TUTORIAL";
constexpr uint32_t complete_value = std::bit_cast<uint32_t>(1.0f);

bool trainer_ready;
std::atomic_bool live_tutorial_complete;
std::mutex profile_mutex;
struct TutorialOverlay {
    uint32_t buffer = 0;
    uint32_t offset = 0;
    uint32_t original_value = 0;
    bool appended = false;
};
TutorialOverlay overlay;

uint32_t profile()
{
    return vm_read32(profile_owner + 0x4e4);
}

bool is_tutorial_key(uint32_t name)
{
    return name && std::memcmp(vm_base + name, tutorial_key, sizeof(tutorial_key)) == 0;
}

void set_live_tutorial()
{
    const auto stats = profile();
    const auto buffer = stats ? vm_read32(stats + 4) : 0;
    // The same buffer is the native load/save payload.
    if (!buffer || buffer != vm_read32(save_state + 0x30)) return;

    for (uint32_t offset = 0; offset + 2 * stat_size <= profile_capacity;
         offset += stat_size) {
        const auto record = buffer + offset;
        const bool empty = !vm_read8(record);
        if (!empty && !is_tutorial_key(record)) continue;

        const auto before = vm_read32(record + stat_value);
        if (!empty && std::bit_cast<float>(before) > 0.0f) {
            live_tutorial_complete.store(true);
            return;
        }
        if (empty) {
            const auto used = vm_read32(stats);
            // The native writer counts used bytes in units of 20 and warns
            // above 0xffff. Keep a zero terminator after the appended record.
            if (used > 0xffff - stat_size || vm_read8(record + stat_size)) return;
            std::memset(vm_base + record, 0, stat_size);
            std::memcpy(vm_base + record, tutorial_key, sizeof(tutorial_key));
            vm_write32(stats, used + stat_size);
        }
        vm_write32(record + stat_value, complete_value);
        overlay = {buffer, offset, before, empty};
        live_tutorial_complete.store(true);
        std::fprintf(stderr, "[pain trainer] live profile T_TUTORIAL=1 (session only)\n");
        return;
    }
}

void restore_stock_tutorial(uint32_t buffer)
{
    const auto destination = buffer + overlay.offset;
    if (!overlay.appended) {
        vm_write32(destination + stat_value, overlay.original_value);
        return;
    }

    uint32_t end = overlay.offset + stat_size;
    while (end + stat_size <= profile_capacity && vm_read8(buffer + end))
        end += stat_size;
    std::memmove(vm_base + destination, vm_base + destination + stat_size,
                 end - overlay.offset - stat_size);
    std::memset(vm_base + buffer + end - stat_size, 0, stat_size);
}

void save_file(ppu_context* ctx)
{
    // The native callback fills CellSaveDataFileSet. SYS-DATA is operation 1
    // and uses the full profile buffer. Give SaveData a filtered copy so the
    // guest continues to see consistent live state even during an autosave.
    const auto file_set = static_cast<uint32_t>(ctx->gpr[5]);
    func_001AEBEC(ctx);
    std::lock_guard lock(profile_mutex);
    if (!overlay.buffer || vm_read32(file_set) != 1 ||
        vm_read32(file_set + 0x28) != profile_capacity ||
        vm_read32(file_set + 0x2c) != overlay.buffer) return;

    const auto source = overlay.buffer + overlay.offset;
    if (!is_tutorial_key(source)) return;
    std::memcpy(vm_base + save_copy, vm_base + overlay.buffer, profile_capacity);
    restore_stock_tutorial(save_copy);
    vm_write32(file_set + 0x2c, save_copy);
    std::fprintf(stderr, "[pain trainer] excluded session T_TUTORIAL from SYS-DATA\n");
}
} // namespace

extern "C" bool pain_unlock_fallback()
{
    return g_pain_unlock_all && !live_tutorial_complete.load();
}

void pain_auto_load_profile(ppu_context* ctx)
{
    if (!trainer_ready) {
        func_00962344(ctx);
        return;
    }
    {
        std::lock_guard lock(profile_mutex);
        const auto stats = profile();
        if (overlay.buffer && stats && vm_read32(stats + 4) == overlay.buffer &&
            is_tutorial_key(overlay.buffer + overlay.offset)) {
            restore_stock_tutorial(overlay.buffer);
            if (overlay.appended && vm_read32(stats) >= stat_size)
                vm_write32(stats, vm_read32(stats) - stat_size);
        }
        overlay = {};
        live_tutorial_complete.store(false);
    }
    func_00962344(ctx);
    std::lock_guard lock(profile_mutex);
    set_live_tutorial();
    if (!live_tutorial_complete.load())
        std::fprintf(stderr, "[pain trainer] profile unavailable, using guarded lift fallback\n");
}

void func_00132D24(ppu_context* ctx)
{
    const bool real_tutorial_update = trainer_ready &&
        static_cast<uint32_t>(ctx->gpr[3]) == profile() &&
        is_tutorial_key(static_cast<uint32_t>(ctx->gpr[4]));
    const auto value = static_cast<float>(ctx->fpr[1]);
    if (!real_tutorial_update) {
        original_func_00132D24(ctx);
        return;
    }

    std::lock_guard lock(profile_mutex);
    original_func_00132D24(ctx);
    if (value > 0.0f) {
        // A native unlock (for example, completing Crash Course) can persist.
        overlay = {};
        live_tutorial_complete.store(true);
    } else if (overlay.buffer) {
        vm_write32(overlay.buffer + overlay.offset + stat_value, complete_value);
        overlay.original_value = std::bit_cast<uint32_t>(value);
    }
}

void install_unlock_trainer()
{
    const auto* requested = std::getenv("PAIN_UNLOCK_ALL");
    g_pain_unlock_all = requested && std::strcmp(requested, "1") == 0;
    if (!g_pain_unlock_all) return;
    // Guard the BCES00548 profile and save callback ABI before using it.
    if (vm_read32(0x00bf9a54) == profile_owner &&
        vm_read32(0x00bfc430) == save_state &&
        vm_read32(0x00bfc508) == 0x00bc3050 &&
        vm_read32(0x00bc3050) == 0x001ae4bc &&
        vm_read32(0x00bfc50c) == 0x00bc3060 &&
        vm_read32(0x00bc3060) == 0x001aebec &&
        is_tutorial_key(vm_read32(0x00bfa0f0)) &&
        vm_commit(save_copy, profile_capacity) == 0) {
        ppu_register_function(0x001aebec, save_file);
        trainer_ready = true;
        std::fprintf(stderr, "[pain trainer] PAIN_UNLOCK_ALL=1, profile hook installed\n");
    } else {
        std::fprintf(stderr, "[pain trainer] profile hook unavailable, using guarded lift fallback\n");
    }
}
