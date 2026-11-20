#include "pose_pin.h"
#include "settings/settings.h"

#include <cstdio>

#if __has_include("ps3emu/runtime_hooks.h")
#include "ps3emu/runtime_hooks.h"
#include "spu_context.h"

#include <array>
#include <cstdint>
#include <cstring>
#include <mutex>
extern "C" uint8_t* vm_base;

namespace {
// These addresses and WWS local-store offsets are for BCES00548 01.00.
constexpr uint32_t second_spurs = 0x00f28d80;
constexpr uint32_t first_list = 0x018a8a80;
constexpr uint32_t second_list = 0x018b8a80;
constexpr uint32_t pose_ea = 0x00ecac70;
constexpr uint32_t pose_size = 0x1e00;
constexpr uint32_t matrix_get_pc = 0x2080;
constexpr uint32_t spurs_ls_offset = 0x1c4;
constexpr uint32_t list_ls_offset = 0x13f0;

struct PoseSnapshot {
    std::array<uint8_t, pose_size> bytes{};
    bool valid = false;
};

std::mutex pose_mutex;
PoseSnapshot snapshots[2];

uint32_t read_ls_word(const uint8_t* p)
{
    return (uint32_t{p[0]} << 24) | (uint32_t{p[1]} << 16) |
           (uint32_t{p[2]} << 8) | p[3];
}

void capture_pose(uint32_t spurs_ea, uint32_t wid, uint32_t, uint64_t list)
{
    if (spurs_ea != second_spurs || wid != 0 || (list != first_list && list != second_list))
        return;

    std::lock_guard lock(pose_mutex);
    auto& snapshot = snapshots[list == second_list];
    std::memcpy(snapshot.bytes.data(), vm_base + pose_ea, pose_size);
    snapshot.valid = true;
}

void read_pinned_pose(const spu_context* spu, uint32_t ea, uint32_t size, uint8_t* dst)
{
    if (!spu->policy_mode || spu->pc != matrix_get_pc ||
        ea < pose_ea || ea >= pose_ea + pose_size || size > pose_ea + pose_size - ea)
        return;

    if (read_ls_word(spu->ls + spurs_ls_offset) != second_spurs)
        return;

    const auto list = read_ls_word(spu->ls + list_ls_offset);
    if (list != first_list && list != second_list)
        return;

    std::lock_guard lock(pose_mutex);
    const auto& snapshot = snapshots[list == second_list];
    if (snapshot.valid)
        std::memcpy(dst, snapshot.bytes.data() + (ea - pose_ea), size);
}
} // namespace
#endif

bool install_pose_pin()
{
    if (pain_settings::value("pin_pose_at_kick") != "on")
        return true;

#if __has_include("ps3emu/runtime_hooks.h")
    g_spurs_ready_count_store_hook = capture_pose;
    g_spu_dma_get_hook = read_pinned_pose;
    std::fprintf(stderr, "[pose-pin] Enabled BCES00548 kick-time pose snapshots\n");
    return true;
#else
    std::fprintf(stderr, "[pose-pin] The ps3recomp pose-pin runtime hooks are required. See README.md.\n");
    return false;
#endif
}
