#include "save_art.h"

#include "ppu_recomp.h"
#include "vm.h"

#include <cstdio>
#include <filesystem>
#include <fstream>

namespace pain_save_art {
namespace {
constexpr uint32_t profile_file_callback_opd = 0x00bc3060;
constexpr uint32_t profile_file_callback_code = 0x001aebec;
constexpr uint32_t file_type_offset = 0x08;
constexpr uint32_t file_offset = 0x20;
constexpr uint32_t size_offset = 0x24;
constexpr uint32_t buffer_size_offset = 0x28;
constexpr uint32_t buffer_offset = 0x2c;
constexpr uint32_t write_operation = 1;

// The port owns this space below mmapper, above the trainer and native menus.
constexpr uint32_t asset_capacity = 0x20000;
struct SaveArt {
    const char* name;
    uint32_t type;
    uint32_t address;
    uint32_t size = 0;
};
SaveArt assets[] = {
    {"ICON0.PNG", 2, 0x3ff40000},
    {"PIC1.PNG", 4, 0x3ff60000},
};
bool supported_profile;
} // namespace

void load(const char* disc_root)
{
    supported_profile = vm_read32(profile_file_callback_opd) == profile_file_callback_code;
    if (!supported_profile) return;

    const auto directory = std::filesystem::path(disc_root) / "PS3_GAME" / "USRDIR" / "Art" / "SaveDataIcons";
    for (auto& asset : assets) {
        std::ifstream file(directory / asset.name, std::ios::binary | std::ios::ate);
        const auto length = file.tellg();
        if (length <= 0 || length > asset_capacity ||
            vm_commit(asset.address, asset_capacity) != 0 ||
            !file.seekg(0).read(reinterpret_cast<char*>(vm_base + asset.address), length)) {
            std::fprintf(stderr, "[pain save] could not load disc save artwork %s\n", asset.name);
            continue;
        }
        asset.size = static_cast<uint32_t>(length);
    }
}

void supply_missing(uint32_t opd, uint32_t result, uint32_t file_set)
{
    if (!supported_profile || opd != profile_file_callback_opd || vm_read32(result) != 0 ||
        vm_read32(file_set) != write_operation || vm_read32(file_set + file_offset) ||
        vm_read32(file_set + size_offset) || vm_read32(file_set + buffer_size_offset) ||
        vm_read32(file_set + buffer_offset)) return;

    // The retail callback still requests artwork when its archive is absent.
    // Let SaveData execute that same operation with the disc's loose artwork.
    const auto type = vm_read32(file_set + file_type_offset);
    for (const auto& asset : assets) {
        if (asset.type != type || !asset.size) continue;
        vm_write32(file_set + size_offset, asset.size);
        vm_write32(file_set + buffer_size_offset, asset.size);
        vm_write32(file_set + buffer_offset, asset.address);
        std::fprintf(stderr, "[pain save] using disc %s (%u bytes)\n", asset.name, asset.size);
        return;
    }
}
} // namespace pain_save_art
