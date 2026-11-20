#include "ppu_recomp.h"

#ifdef PAIN_LEVELSCRIPT_DIR
#include "prx_loader.h"
#include "ps3emu/error_codes.h"

#include <algorithm>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <memory>
#include <mutex>
#include <span>
#include <string>
#include <string_view>

extern "C" void ppu_register_function(uint64_t addr, void (*fn)(ppu_context*));
extern "C" void ps3_hle_call(uint32_t nid, ppu_context* ctx);
extern "C" void ps3_hle_register_ctx(uint32_t nid, const char* name, void (*fn)(ppu_context*));
extern "C" int ppu_guest_call_ct_checked(uint32_t code, uint32_t toc,
    uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5,
    uint64_t a6, uint64_t a7, uint64_t* result);

namespace {
constexpr uint32_t unknown_module = 0x8001112e;
constexpr uint32_t already_started = 0x80011133;
constexpr uint32_t not_started = 0x80011134;
constexpr uint32_t already_stopped = 0x80011135;
constexpr uint32_t not_removable = 0x80011138;
constexpr uint32_t library_in_use = 0x8001113e;
constexpr uint32_t unsupported_prx = 0x80011148;

constexpr uint32_t eboot_slots = 0x00b97c6c;
constexpr std::array<uint32_t, 10> level_nids = {
    0x08bf4cb1, 0x403344ab, 0x4470b346, 0x4d918c6c, 0x4e7b35fc,
    0x63100756, 0x695df70d, 0x7f3e54d6, 0xac81efa7, 0xe644dc64,
};

struct ImportSlot {
    uint32_t slot;
    uint32_t thunk;
};

struct LevelModule {
    const char* stem;
    uint32_t base;
    uint32_t image_size;
    uint32_t toc;
    uint32_t start_opd;
    uint32_t stop_opd;
    uint32_t descriptors;
    const func_entry* funcs;
    const uint64_t* func_count;
    std::span<const prx_export> exports;
    std::span<const ImportSlot> imports;
};

struct LevelPath {
    std::string_view path;
    const LevelModule* module;
};
}  // namespace

#include "catalog.inc"

namespace {
enum class State { loaded, started, stopped };
std::mutex lifecycle;
const LevelModule* active;
uint32_t module_id;
State state;
std::array<uint32_t, level_nids.size()> original_slots;

void result(ppu_context* ctx, uint32_t value)
{
    ctx->gpr[3] = static_cast<int64_t>(static_cast<int32_t>(value));
}

template<uint32_t Nid>
void call_existing_hle(ppu_context* ctx)
{
    ps3_hle_call(Nid, ctx);
}

void libc_puts(ppu_context* ctx)
{
    const uint32_t address = ctx->gpr[3];
    if (!address)
        return result(ctx, UINT32_MAX);
    const char* message = reinterpret_cast<const char*>(vm_base + address);
    const size_t limit = std::min<uint64_t>(4096, 0x100000000ull - address);
    const auto* end = static_cast<const char*>(std::memchr(message, '\0', limit));
    if (!end)
        return result(ctx, UINT32_MAX);
    result(ctx, std::fprintf(stderr, "[levelscript] %.*s\n",
                            static_cast<int>(end - message), message));
}

void thread_get_id(ppu_context* ctx)
{
    const uint32_t address = ctx->gpr[3];
    if (address < 0x10000 || address > UINT32_MAX - 7)
        return result(ctx, CELL_EFAULT);
    vm_write64(address, ctx->thread_id);
    result(ctx, CELL_OK);
}

void bind_exports(bool loaded)
{
    // Direct compiled import stubs go through the runtime NID registry.
    // Keep the PS3 descriptor table in sync for guest-side slot readers.
    for (size_t i = 0; i < level_nids.size(); ++i) {
        vm_write32(eboot_slots + 4 * i,
            loaded ? prx_resolve_export(level_nids[i]) : original_slots[i]);
    }
}

void unbind_exports()
{
    prx_unpublish_exports(active->base, active->exports.data(), active->exports.size());
    bind_exports(false);
}

std::string_view level_path(uint32_t addr)
{
    constexpr uint32_t max_path = 1024;
    if (addr < 0x10000 || addr > UINT32_MAX - max_path)
        return {};
    const char* path = reinterpret_cast<const char*>(vm_base + addr);
    const auto* end = static_cast<const char*>(std::memchr(path, '\0', max_path));
    if (!end)
        return {};
    std::string_view view(path, end - path);
    for (std::string_view prefix : {"/dev_bdvd/PS3_GAME/USRDIR/",
                                   "/dev_hdd0/game/BCES00548/USRDIR/"}) {
        if (view.starts_with(prefix))
            return view.substr(prefix.size());
    }
    return view;
}

void sys_prx_load_module(ppu_context* ctx)
{
    std::lock_guard guard(lifecycle);
    const auto path = level_path(ctx->gpr[3]);
    const LevelModule* module = nullptr;
    for (const auto& entry : level_paths) {
        if (entry.path == path) {
            module = entry.module;
            break;
        }
    }
    if (!module) {
        std::fprintf(stderr, "[levelscript] sys_prx_load_module: module absent from catalog: %.*s\n",
                     static_cast<int>(path.size()), path.empty() ? "" : path.data());
        return result(ctx, unknown_module);
    }
    if (active)
        return result(ctx, library_in_use);

    const char* directory = std::getenv("PAIN_LEVELSCRIPT_DIR");
    if (!directory || !*directory)
        directory = PAIN_LEVELSCRIPT_DIR;
    const std::string image_path = std::string(directory) + "/modules/" + module->stem
        + "/" + module->stem + "_image.bin";
    uint32_t image_size = 0;
    std::unique_ptr<uint8_t, decltype(&std::free)> image(
        prx_image_load_file(image_path.c_str(), &image_size), std::free);
    if (!image || image_size != module->image_size)
        return result(ctx, unsupported_prx);

    uint32_t descriptor = module->descriptors;
    for (const auto& import : module->imports) {
        vm_write32(descriptor, import.thunk);
        vm_write32(descriptor + 4, module->toc);
        const uint8_t pointer[] = {uint8_t(descriptor >> 24), uint8_t(descriptor >> 16),
                                   uint8_t(descriptor >> 8), uint8_t(descriptor)};
        std::memcpy(image.get() + import.slot - module->base, pointer, sizeof(pointer));
        descriptor += 8;
    }
    const prx_module description = {module->stem, module->base, image.get(), image_size,
        nullptr, 0, module->exports.data(), static_cast<uint32_t>(module->exports.size())};
    if (!prx_load_module(&description, nullptr).ok)
        return result(ctx, unsupported_prx);

    active = module;
    state = State::loaded;
    ++module_id;
    bind_exports(true);
    std::fprintf(stderr, "[levelscript] sys_prx_load_module id=%u %.*s, patched %zu imports\n",
                 module_id, static_cast<int>(path.size()), path.data(), module->imports.size());
    result(ctx, module_id);
}

void run_module_entry(ppu_context* ctx, bool start)
{
    std::lock_guard guard(lifecycle);
    if (!active || ctx->gpr[3] != module_id)
        return result(ctx, unknown_module);
    if (start && state != State::loaded)
        return result(ctx, already_started);
    if (!start && state != State::started)
        return result(ctx, state == State::stopped ? already_stopped : not_started);
    const uint32_t result_addr = ctx->gpr[6];
    if (result_addr < 0x10000 || result_addr > UINT32_MAX - 3)
        return result(ctx, CELL_EINVAL);

    const uint32_t opd = start ? active->start_opd : active->stop_opd;
    uint64_t entry_result = 0;
    const uint32_t code = opd ? vm_read32(opd) : 0;
    if (opd && !ppu_guest_call_ct_checked(code, vm_read32(opd + 4),
            ctx->gpr[4], ctx->gpr[5], 0, 0, 0, 0, 0, 0, &entry_result))
        return result(ctx, unsupported_prx);

    vm_write32(result_addr, static_cast<uint32_t>(entry_result));
    std::fprintf(stderr, "[levelscript] sys_prx_%s_module id=%u entry=0x%08x result=0x%08x\n",
                 start ? "start" : "stop", module_id, code, static_cast<uint32_t>(entry_result));
    if (entry_result == 0) {
        state = start ? State::started : State::stopped;
        if (!start)
            unbind_exports();
    } else if (start) {  // A non-resident start leaves no module linked.
        unbind_exports();
        active = nullptr;
    }
    result(ctx, CELL_OK);
}

void sys_prx_start_module(ppu_context* ctx) { run_module_entry(ctx, true); }
void sys_prx_stop_module(ppu_context* ctx) { run_module_entry(ctx, false); }

void sys_prx_unload_module(ppu_context* ctx)
{
    std::lock_guard guard(lifecycle);
    if (!active || ctx->gpr[3] != module_id)
        return result(ctx, unknown_module);
    if (state == State::started)
        return result(ctx, not_removable);
    if (state == State::loaded)
        unbind_exports();
    // Retain guest backing for a caller that already resolved the old export.
    // The game's next load of this image starts with pristine data and BSS.
    active = nullptr;
    result(ctx, CELL_OK);
}
}  // namespace
#endif

extern "C" void ps3_load_prx_modules()
{
#ifdef PAIN_LEVELSCRIPT_DIR
    // All lifts have disjoint addresses. Install their immutable host dispatch
    // targets before the guest can start threads reading the function table.
    for (const auto* module : level_modules) {
        for (uint64_t i = 0; i < *module->func_count; ++i) {
            const auto& fn = module->funcs[i];
            ppu_register_function(fn.addr, fn.func);
        }
    }
    for (size_t i = 0; i < level_nids.size(); ++i)
        original_slots[i] = vm_read32(eboot_slots + 4 * i);
    ps3_hle_register_ctx(0x26090058, "sys_prx_load_module", sys_prx_load_module);
    ps3_hle_register_ctx(0x9f18429d, "sys_prx_start_module", sys_prx_start_module);
    ps3_hle_register_ctx(0x80fb0c19, "sys_prx_stop_module", sys_prx_stop_module);
    ps3_hle_register_ctx(0xf0aece0d, "sys_prx_unload_module", sys_prx_unload_module);
    // These PRXs import the unsuffixed sys_libc symbols. The runtime already
    // implements the PS3 ABI under the sysPrxForUser spellings.
    ps3_hle_register_ctx(0xe3cc73f3, "puts", libc_puts);
    ps3_hle_register_ctx(0x04a183fc, "strcpy", call_existing_hle<0x99c88692>);
    ps3_hle_register_ctx(0x273b9711, "sprintf", call_existing_hle<0xa1f9eafe>);
    ps3_hle_register_ctx(0x2f45d39c, "strlen", call_existing_hle<0x2d36462b>);
    ps3_hle_register_ctx(0x3d85d6f8, "strcmp", call_existing_hle<0x459b4393>);
    ps3_hle_register_ctx(0x5909e3c4, "memset", call_existing_hle<0x68b9b011>);
    ps3_hle_register_ctx(0x759e0635, "malloc", call_existing_hle<0xbdb18f83>);
    ps3_hle_register_ctx(0x77a602dd, "free", call_existing_hle<0xf7f7fb20>);
    ps3_hle_register_ctx(0x831d70a5, "memcpy", call_existing_hle<0x6bf66ea7>);
    ps3_hle_register_ctx(0xd84b3689, "_ZdlPv", call_existing_hle<0xf7f7fb20>);
    ps3_hle_register_ctx(0x350d454e, "sys_ppu_thread_get_id", thread_get_id);
    std::fprintf(stderr, "[levelscript] catalog ready (%zu guest paths)\n", std::size(level_paths));
#endif
}
