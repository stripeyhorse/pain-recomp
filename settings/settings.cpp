#include "settings.h"

#if defined(__APPLE__)
#include "rsx_metal_backend.h"
#include <sys/sysctl.h>
#endif

#include <array>
#include <atomic>
#include <chrono>
#include <charconv>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <string>
#include <string_view>

namespace pain_settings {
namespace {
using namespace std::literals;

enum class Kind { toggle, presence, inverted_toggle, number, integer, post_scale, cap, frame_rate, language, size, aa, aniso, aspect, upscale, lanes, pad_button, pacing };

struct Option {
    std::string_view key;
    const char* env;
    std::string_view fallback;
    Kind kind;
    double minimum = 0;
    double maximum = 0;
};

constexpr std::array options{
    Option{"vsync", "PS3RECOMP_VSYNC", "on", Kind::toggle},
    Option{"frame_cap", "PAIN_FRAME_CAP", "0", Kind::cap},
    Option{"fullscreen", "PS3RECOMP_FULLSCREEN", "off", Kind::toggle},
    Option{"fullscreen_size", "PS3RECOMP_FULLSCREEN_SIZE", "auto", Kind::size},
    Option{"window_size", "PS3RECOMP_WINDOW_SIZE", "auto", Kind::size},
    Option{"aspect", "PS3RECOMP_ASPECT", "fit", Kind::aspect},
    Option{"post_scale", "PS3_POST_SCALE", "100", Kind::post_scale},
    Option{"aa", "PS3_AA", "off", Kind::aa},
    Option{"vibrance", "PS3_VIBRANCE", "0", Kind::number, -1, 1},
    Option{"contrast", "PS3_CONTRAST", "1", Kind::number, .5, 1.5},
    Option{"sharpen", "PS3_SHARPEN", "0", Kind::number, 0, 1},
    Option{"anisotropic", "PS3_ANISO", "0", Kind::aniso},
    Option{"res_scale", "PS3_RES_SCALE", "1", Kind::number, .5, 3},
    Option{"upscale", "PS3_UPSCALE", "off", Kind::upscale},
    Option{"language", "PS3_LANG", "auto", Kind::language},
    Option{"audio", "PS3_MUTE", "on", Kind::presence},
    Option{"stick_deadzone", "PS3_PAD_DEADZONE", "10", Kind::integer, 0, 50},
    Option{"vibration", "PS3_PAD_RUMBLE", "100", Kind::integer, 0, 100},
    Option{"controller_quit", "PS3_PAD_QUIT", "on", Kind::toggle},
    Option{"motion", "PS3_PAD_MOTION", "on", Kind::toggle},
    Option{"shake_button", "PS3_PAD_SHAKE_BUTTON", "off", Kind::pad_button},
    Option{"metal_headless", "PS3RECOMP_METAL_HEADLESS", "off", Kind::toggle},
    Option{"metal_guest_programs", "PS3RECOMP_METAL_FIXED_FUNCTION", "on", Kind::inverted_toggle},
    Option{"vulkan_window", "PS3RECOMP_VK_WINDOW", "off", Kind::toggle},
    Option{"vulkan_guest_programs", "PS3RECOMP_VK_GUEST_PROGRAMS", "off", Kind::toggle},
    Option{"unlock_trainer", "PAIN_UNLOCK_ALL", "off", Kind::toggle},
    Option{"pin_pose_at_kick", "PAIN_PIN_POSE_AT_KICK", "on", Kind::toggle},
    Option{"creator_first", "PS3_CREATOR_FIRST", "on", Kind::toggle},
    Option{"fifo_park_grace_ms", "GCM_PARK_GRACE_MS", "2000", Kind::number, 0, 60000},
    // frame_rate sets the defaults of the two advanced settings after it:
    // 30 is sim_steps 2 with a 16.667 ms vblank, 60 is sim_steps 1 with 8.333.
    // An explicit vblank_ms or sim_steps (INI or environment) still wins.
    Option{"frame_rate", "PAIN_FRAME_RATE", "30", Kind::frame_rate},
    Option{"vblank_ms", "PAIN_VBLANK_MS", "16.667", Kind::number, 4, 33},
    Option{"sim_steps", "PAIN_SIM_STEPS", "2", Kind::number, 1, 2},
    // frame_pacing = on shows each frame at a screen refresh of its own, one
    // guest frame after the last, and keeps the vblank clock in step with
    // the screen (PS3RECOMP_PRESENT_INTERVAL_MS = 1000 / frame_rate). A value
    // already in the environment is kept as it is, unless the INI names
    // frame_pacing.
    Option{"frame_pacing", "PS3RECOMP_PRESENT_INTERVAL_MS", "on", Kind::pacing},
    Option{"thread_qos", "PS3_THREAD_QOS", "on", Kind::toggle},
#if defined(__APPLE__)
    Option{"spu_mfc_lookup_cache", "SPU_MFC_LOOKUP_CACHE", "off", Kind::toggle},
#endif
    Option{"mesh_lanes", "PS3_SPURS_LANES_OF_2", "auto", Kind::lanes, 1, 6},
};

std::mutex settings_mutex;
std::array<std::string, options.size()> values;
std::atomic<int> cap;
bool trace;
std::filesystem::path settings_path;

// The default of a setting that frame_rate implies, given the frame_rate
// already resolved (it comes earlier in the table).
std::string_view fallback(const Option& option, std::string_view frame_rate)
{
    const bool sixty = frame_rate == "60";
    if (option.key == "vblank_ms") return sixty ? "8.333"sv : "16.667"sv;
    if (option.key == "sim_steps") return sixty ? "1"sv : "2"sv;
    return option.fallback;
}

std::string_view trim(std::string_view text)
{
    const auto first = text.find_first_not_of(" \t\r");
    return first == text.npos ? ""sv : text.substr(first, text.find_last_not_of(" \t\r") - first + 1);
}

template<class T>
bool parse_number(std::string_view text, T& number)
{
    if (text.empty()) return false;
    const auto result = std::from_chars(text.data(), text.data() + text.size(), number);
    return result.ec == std::errc{} && result.ptr == text.data() + text.size();
}

std::string lower(std::string_view text)
{
    std::string result(text);
    for (auto& c : result)
        if (c >= 'A' && c <= 'Z') c = static_cast<char>(c + 'a' - 'A');
    return result;
}

bool normalize(const Option& option, std::string& value)
{
    value = lower(trim(value));
    int integer{};
    switch (option.kind) {
    case Kind::toggle:
    case Kind::presence:
    case Kind::inverted_toggle:
    case Kind::pacing:
        if (value == "yes" || value == "true" || value == "1") value = "on";
        if (value == "no" || value == "false" || value == "0") value = "off";
        return value == "on" || value == "off";
    case Kind::lanes:
        if (value == "auto") return true;
        [[fallthrough]];
    case Kind::number: {
        char* end{};
        const double real = std::strtod(value.c_str(), &end);
        return end != value.c_str() && *end == '\0' && real >= option.minimum && real <= option.maximum;
    }
    case Kind::integer:
        return parse_number(value, integer) && integer >= option.minimum && integer <= option.maximum;
    case Kind::post_scale:
        return parse_number(value, integer) && integer >= 50 && integer <= 200;
    case Kind::cap:
        return parse_number(value, integer) && (integer == 0 || integer == 20 || integer == 30 || integer == 60);
    case Kind::frame_rate:
        return value == "30" || value == "60";
    case Kind::aniso:
        return parse_number(value, integer) && (integer == 0 || (integer >= 2 && integer <= 16));
    case Kind::size: {
        if (value == "auto") return true;
        unsigned width{}, height{};
        const auto separator = value.find('x');
        const std::string_view size = value;
        return separator != size.npos && parse_number(size.substr(0, separator), width) &&
            parse_number(size.substr(separator + 1), height) &&
            width >= 160 && height >= 90 && width <= 16384 && height <= 16384;
    }
    case Kind::language:
        return value == "auto" || (parse_number(value, integer) && integer >= 0 && integer <= 19) ||
            (" ja en en-us fr es de it nl pt pt-pt ru ko zh-t zh-s fi sv da no pl pt-br en-gb tr "sv)
                .find(" " + value + " ") != std::string_view::npos;
    case Kind::aa:
        if (value == "0") value = "off";
        return value == "off" || value == "fxaa" || value == "smaa";
    case Kind::aspect:
        return value == "fit" || value == "stretch";
    case Kind::upscale:
        if (value == "0") value = "off";
        return value == "off" || value == "metalfx";
    case Kind::pad_button:
        return value == "off" || value == "l3" || value == "r3" || value == "touchpad";
    }
    return false;
}

// mesh_lanes = auto: 3 lanes on a Mac with six or more performance cores
// (M4 Pro: 49 FPS on 2 lanes, 59.6 on 3), else 2 (M2: 3 gained nothing).
// PAIN_TEST_PERF_CORES stands in for the core count, for tests and bench runs.
int performance_cores()
{
    int cores = 0;
    if (const char* forced = std::getenv("PAIN_TEST_PERF_CORES"); forced && parse_number(std::string_view(forced), cores))
        return cores;
#if defined(__APPLE__)
    size_t size = sizeof cores;
    if (sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nullptr, 0) == 0) return cores;
#endif
    return 0;
}

const char* inherited(const Option& option)
{
    if (const auto* value = std::getenv(option.env)) return value;
    if (option.key == "window_size") return std::getenv("PS3RECOMP_METAL_WINDOW");
    if (option.key == "fullscreen") return std::getenv("PS3RECOMP_VK_FULLSCREEN");
#ifdef _WIN32
    if (option.key == "vsync") return std::getenv("D3D12_VSYNC");
#endif
    return nullptr;
}

bool publish(const char* name, const char* value)
{
#ifdef _WIN32
    return _putenv_s(name, value ? value : "") == 0;
#else
    return (value ? setenv(name, value, 1) : unsetenv(name)) == 0;
#endif
}

// The present interval frame_pacing = on asks for, from the resolved frame_rate.
const char* pacing_interval(std::string_view frame_rate)
{
    return frame_rate == "60" ? "16.667" : "33.333";
}

// An inherited PS3RECOMP_PRESENT_INTERVAL_MS is an interval, not on/off: it
// reads as on when the toolkit would pace with it (a number above 0).
std::string pacing_from_env(const char* env)
{
    char* end{};
    const double ms = std::strtod(env, &end);
    return end != env && *end == '\0' && ms > 0 && ms <= 1000 ? "on" : "off";
}

bool apply_option(const Option& option, const std::string& value)
{
    if (option.key == "fullscreen" && !publish("PS3RECOMP_VK_FULLSCREEN", nullptr)) return false;
    if (option.key == "window_size" && !publish("PS3RECOMP_METAL_WINDOW", nullptr)) return false;
    if (option.kind == Kind::toggle) return publish(option.env, value == "on" ? "1" : "0");
    if (option.kind == Kind::presence || option.kind == Kind::inverted_toggle)
        return publish(option.env, value == "on" ? nullptr : "1");
    return publish(option.env, value == "auto" ? nullptr : value.c_str());
}

} // namespace

bool load()
{
    const char* verbosity = std::getenv("PAIN_SETTINGS_VERBOSE");
    trace = verbosity && *verbosity && *verbosity != '0';
    const char* named_path = std::getenv("PAIN_SETTINGS_PATH");
    settings_path = named_path && *named_path ? named_path : "settings.ini";
    std::error_code error;
    settings_path = std::filesystem::absolute(settings_path, error);
    if (error) {
        std::fprintf(stderr, "[settings] could not resolve settings path: %s\n", error.message().c_str());
        return false;
    }
    const auto& path = settings_path;
    std::array<std::string, options.size()> ini;
    const bool exists = std::filesystem::exists(path, error);
    if (error) {
        std::fprintf(stderr, "[settings] %s: %s\n", path.string().c_str(), error.message().c_str());
        return false;
    }
    if (exists) {
        std::ifstream input(path);
        std::string line;
        bool settings_section = true;
        unsigned line_number = 0;
        while (std::getline(input, line)) {
            auto text = trim(std::string_view(line).substr(0, line.find_first_of(";#")));
            ++line_number;
            if (text.empty()) continue;
            if (text.starts_with('[') && text.ends_with(']')) {
                settings_section = lower(trim(text.substr(1, text.size() - 2))) == "settings";
                continue;
            }
            if (!settings_section) continue;
            const auto equals = text.find('=');
            if (equals == text.npos) continue;
            const auto key = lower(trim(text.substr(0, equals)));
            for (size_t i = 0; i < options.size(); ++i) {
                if (key != options[i].key) continue;
                std::string value(text.substr(equals + 1));
                if (normalize(options[i], value)) ini[i] = value;
                else std::fprintf(stderr, "[settings] line %u: invalid %s\n", line_number, key.c_str());
                break;
            }
        }
        if (!input.eof() || input.bad()) {
            std::fprintf(stderr, "[settings] could not read %s\n", path.string().c_str());
            return false;
        }
    }
    if (trace) std::fprintf(stderr, "[settings] %s (%s)\n", path.string().c_str(), exists ? "loaded" : "absent");
    std::string frame_rate;
    for (size_t i = 0; i < options.size(); ++i) {
        const auto& option = options[i];
        std::string value = ini[i];
        const char* source = "ini";
        if (value.empty()) {
            source = "default";
            if (const auto* env = inherited(option); env && option.kind == Kind::pacing) {
                value = pacing_from_env(env);
                source = "env";
            } else if (env) {
                value = env;
                if (option.kind == Kind::presence) value = "off";
                if (option.kind == Kind::inverted_toggle) value = *env && *env != '0' ? "off" : "on";
                if (option.kind == Kind::toggle && !*env) value = "off";
                if (option.kind == Kind::language && !*env) value = "auto";
                if (normalize(option, value)) source = "env";
                else {
                    std::fprintf(stderr, "[settings] invalid environment value for %s\n", option.env);
                    value.clear();
                }
            }
            if (value.empty()) {
                value = fallback(option, frame_rate);
                if (option.key == "vblank_ms" || option.key == "sim_steps") source = "frame_rate";
            }
        }
        if (option.key == "frame_rate") frame_rate = value;
        std::string resolved_from;
        if (option.kind == Kind::lanes && value == "auto") {
            const int cores = performance_cores();
            value = cores >= 6 ? "3" : "2";
            resolved_from = std::string(source) + " auto, " +
                (cores > 0 ? std::to_string(cores) + " performance cores" : "performance cores unknown"s);
            source = resolved_from.c_str();
        }
        bool applied;
        if (option.kind == Kind::pacing)   // an inherited interval stays as it is
            applied = source == "env"sv || publish(option.env, value == "on" ? pacing_interval(frame_rate) : nullptr);
        else
            applied = apply_option(option, value);
        if (!applied) {
            std::fprintf(stderr, "[settings] could not publish %s\n", option.env);
            return false;
        }
        if (option.kind == Kind::cap) {
            int parsed = 0;
            parse_number(value, parsed);
            cap.store(parsed, std::memory_order_relaxed);
        }
        values[i] = value;
        if (trace) {
            const auto* applied = std::getenv(option.env);
            std::fprintf(stderr, "[settings] %s=%s (%s) -> %s=%s\n", option.key.data(), value.c_str(),
                         source, option.env, applied ? applied : "<unset>");
        }
    }
#if defined(__APPLE__)
    if (!publish("PS3RECOMP_WINDOW_PIXELS", "1")) return false;
#endif
    return true;
}

int frame_cap() { return cap.load(std::memory_order_relaxed); }

static std::string_view resolved_value(std::string_view key)
{
    for (size_t i = 0; i < options.size(); ++i)
        if (key == options[i].key) return values[i];
    return {};
}

std::string value(std::string_view key)
{
    std::lock_guard lock(settings_mutex);
    return std::string(resolved_value(key));
}

bool save(std::string_view key, std::string setting)
{
    std::lock_guard lock(settings_mutex);
    size_t index = 0;
    while (index < options.size() && key != options[index].key) ++index;
    if (index == options.size() || !normalize(options[index], setting)) return false;

    std::string contents;
    std::error_code error;
    if (std::filesystem::exists(settings_path, error)) {
        if (!std::filesystem::is_regular_file(settings_path, error)) return false;
        std::ifstream existing(settings_path, std::ios::binary);
        if (!existing) return false;
        try {
            contents.assign(std::istreambuf_iterator<char>(existing), {});
        } catch (const std::ios_base::failure&) {
            return false;
        }
    }
    if (error) return false;

    // Replace the last matching key while preserving the rest of the file.
    size_t value_offset = std::string::npos;
    size_t value_size = 0;
    size_t insert_offset = 0;
    const std::string_view original = contents;
    bool settings_section = true;
    for (size_t start = 0; start < original.size();) {
        const auto next = original.find('\n', start);
        const auto line = original.substr(start, next == original.npos ? next : next - start);
        const auto text = trim(line.substr(0, line.find_first_of(";#")));
        const auto equals = text.find('=');
        if (text.starts_with('[') && text.ends_with(']')) {
            settings_section = lower(trim(text.substr(1, text.size() - 2))) == "settings";
        } else if (settings_section && equals != text.npos &&
                   lower(trim(text.substr(0, equals))) == key) {
            const auto tail = text.substr(equals + 1);
            const auto existing_value = trim(tail);
            value_offset = static_cast<size_t>((existing_value.empty() ? tail.data() : existing_value.data()) -
                                               original.data());
            value_size = existing_value.size();
        }
        start = next == original.npos ? original.size() : next + 1;
        if (settings_section) insert_offset = start;
    }

    if (value_offset != original.npos) {
        contents.replace(value_offset, value_size, setting);
    } else {
        std::string line;
        if (insert_offset && contents[insert_offset - 1] != '\n') line += '\n';
        if (!insert_offset) line += "[settings]\n";
        line += std::string(key) + " = " + setting + '\n';
        contents.insert(insert_offset, line);
    }

    auto temporary = settings_path;
    temporary += ".tmp." + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count());
#ifdef _WIN32
    auto* file = _wfopen(temporary.c_str(), L"wbx");
#else
    auto* file = std::fopen(temporary.c_str(), "wbx");
#endif
    if (!file) return false;
    const bool written = std::fwrite(contents.data(), 1, contents.size(), file) == contents.size();
    if (std::fclose(file) == 0 && written) std::filesystem::rename(temporary, settings_path, error);
    else error = std::make_error_code(std::errc::io_error);
    if (error) {
        std::error_code ignored;
        std::filesystem::remove(temporary, ignored);
        return false;
    }
    values[index] = setting;
    if (options[index].kind == Kind::cap) {
        int parsed{};
        parse_number(setting, parsed);
        cap.store(parsed, std::memory_order_relaxed);
    }
#if defined(__APPLE__)
    if (key == "aa" || key == "sharpen" || key == "vibrance" || key == "contrast" ||
        key == "aspect" || key == "post_scale" || key == "vsync") {
        const auto aa = resolved_value("aa");
        const auto real = [](auto option) { return std::strtof(resolved_value(option).data(), nullptr); };
        unsigned scale{};
        parse_number(resolved_value("post_scale"), scale);
        const rsx_metal_present_options post{
            aa == "smaa" ? RSX_METAL_AA_SMAA : aa == "fxaa" ? RSX_METAL_AA_FXAA : RSX_METAL_AA_OFF,
            real("sharpen"), real("vibrance"), real("contrast"), scale, resolved_value("aspect") == "stretch",
            resolved_value("vsync") == "on",
        };
        rsx_metal_backend_set_present_options(&post);
    }
#endif
    std::fprintf(stderr, "[settings/native] saved %.*s=%s\n", static_cast<int>(key.size()),
                 key.data(), setting.c_str());
    return true;
}
bool save_frame_cap(int value) { return save("frame_cap", std::to_string(value)); }
bool verbose() { return trace; }
} // namespace pain_settings
