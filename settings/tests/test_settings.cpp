// Settings layer checks: frame_rate and its two advanced overrides, the INI >
// environment > default precedence, and fractional vblank_ms. Each case runs
// in a child process with a clean environment, because load() publishes
// environment variables and keeps process-wide state. POSIX only.
// Build and run: settings/tests/run.sh
#include "../settings.h"

#if defined(__APPLE__)
#include "rsx_metal_backend.h"
// save() forwards present options to the renderer; these cases never save.
extern "C" void rsx_metal_backend_set_present_options(const rsx_metal_present_options*) {}
#endif

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <initializer_list>
#include <string>
#include <utility>
#include <sys/wait.h>
#include <unistd.h>

namespace {
using Pairs = std::initializer_list<std::pair<const char*, const char*>>;

struct Case {
    const char* name;
    const char* ini;    // contents of settings.ini, nullptr for no file
    Pairs env;          // environment before load()
    Pairs expect;       // setting key -> resolved value
    Pairs published;    // environment variable -> value after load()
};

const char* const watched[] = {"PAIN_FRAME_RATE", "PAIN_VBLANK_MS", "PAIN_SIM_STEPS", "PS3_MUTE", "PS3_NO_AUDIO",
                               "PS3_SPURS_LANES_OF_2", "PAIN_TEST_PERF_CORES",
                               "PS3_PAD_DEADZONE", "PS3_PAD_RUMBLE", "PS3_PAD_QUIT"};

int run_case(const Case& test, const std::string& dir)
{
    for (const char* name : watched) unsetenv(name);
    const std::string path = dir + "/" + test.name + ".ini";
    std::remove(path.c_str());
    if (test.ini) std::ofstream(path) << test.ini;
    setenv("PAIN_SETTINGS_PATH", path.c_str(), 1);
    for (const auto& [name, value] : test.env) setenv(name, value, 1);
    if (!pain_settings::load()) {
        std::printf("FAIL %s: load() failed\n", test.name);
        return 1;
    }
    int failures = 0;
    for (const auto& [key, want] : test.expect) {
        const auto got = pain_settings::value(key);
        if (got != want) {
            std::printf("FAIL %s: %s = %s, expected %s\n", test.name, key, got.c_str(), want);
            ++failures;
        }
    }
    for (const auto& [name, want] : test.published) {
        const char* got = std::getenv(name);
        if (want ? !got || std::strcmp(got, want) != 0 : got != nullptr) {   // nullptr: must stay unset
            std::printf("FAIL %s: %s = %s, expected %s\n", test.name, name, got ? got : "<unset>",
                        want ? want : "<unset>");
            ++failures;
        }
    }
    // main.cpp parses the published period with strtod and paces in whole
    // microseconds: a fraction must survive the settings layer.
    if (const char* period = std::getenv("PAIN_VBLANK_MS")) {
        const auto us = static_cast<unsigned long long>(std::strtod(period, nullptr) * 1000.0 + 0.5);
        for (const auto& [key, want] : test.expect) {
            if (std::strcmp(key, "vblank_ms") != 0) continue;
            const auto want_us = static_cast<unsigned long long>(std::strtod(want, nullptr) * 1000.0 + 0.5);
            if (us != want_us) {
                std::printf("FAIL %s: vblank period %llu us, expected %llu\n", test.name, us, want_us);
                ++failures;
            }
        }
    }
    std::remove(path.c_str());
    if (!failures) std::printf("ok   %s\n", test.name);
    return failures ? 1 : 0;
}
} // namespace

int main()
{
    char dir_template[] = "/tmp/pain-settings-test.XXXXXX";
    const char* dir = mkdtemp(dir_template);
    if (!dir) return 2;

    const Case cases[] = {
        {"default_is_30", nullptr, {},
         {{"frame_rate", "30"}, {"vblank_ms", "16.667"}, {"sim_steps", "2"}},
         {{"PAIN_FRAME_RATE", "30"}, {"PAIN_VBLANK_MS", "16.667"}, {"PAIN_SIM_STEPS", "2"}}},
        {"empty_ini_is_30", "[settings]\n", {},
         {{"frame_rate", "30"}, {"vblank_ms", "16.667"}, {"sim_steps", "2"}}, {}},
        {"ini_60", "[settings]\nframe_rate = 60\n", {},
         {{"frame_rate", "60"}, {"vblank_ms", "8.333"}, {"sim_steps", "1"}},
         {{"PAIN_VBLANK_MS", "8.333"}, {"PAIN_SIM_STEPS", "1"}}},
        {"env_60", nullptr, {{"PAIN_FRAME_RATE", "60"}},
         {{"frame_rate", "60"}, {"vblank_ms", "8.333"}, {"sim_steps", "1"}}, {}},
        {"ini_frame_rate_beats_env", "[settings]\nframe_rate = 30\n", {{"PAIN_FRAME_RATE", "60"}},
         {{"frame_rate", "30"}, {"vblank_ms", "16.667"}, {"sim_steps", "2"}}, {}},
        {"ini_vblank_overrides_60", "[settings]\nframe_rate = 60\nvblank_ms = 10\n", {},
         {{"frame_rate", "60"}, {"vblank_ms", "10"}, {"sim_steps", "1"}}, {}},
        {"env_sim_steps_overrides_60", "[settings]\nframe_rate = 60\n", {{"PAIN_SIM_STEPS", "2"}},
         {{"frame_rate", "60"}, {"vblank_ms", "8.333"}, {"sim_steps", "2"}},
         {{"PAIN_SIM_STEPS", "2"}}},
        {"env_vblank_overrides_30", nullptr, {{"PAIN_VBLANK_MS", "8"}},
         {{"frame_rate", "30"}, {"vblank_ms", "8"}, {"sim_steps", "2"}},
         {{"PAIN_VBLANK_MS", "8"}}},
        {"ini_vblank_beats_env_vblank", "[settings]\nvblank_ms = 12.5\n", {{"PAIN_VBLANK_MS", "8.333"}},
         {{"vblank_ms", "12.5"}, {"sim_steps", "2"}}, {{"PAIN_VBLANK_MS", "12.5"}}},
        {"fractional_env_vblank_kept", nullptr, {{"PAIN_VBLANK_MS", "16.6667"}},
         {{"vblank_ms", "16.6667"}}, {{"PAIN_VBLANK_MS", "16.6667"}}},
        {"invalid_frame_rate_ini_falls_back", "[settings]\nframe_rate = 45\n", {},
         {{"frame_rate", "30"}, {"vblank_ms", "16.667"}, {"sim_steps", "2"}}, {}},
        {"invalid_frame_rate_ini_uses_env", "[settings]\nframe_rate = 45\n", {{"PAIN_FRAME_RATE", "60"}},
         {{"frame_rate", "60"}, {"vblank_ms", "8.333"}, {"sim_steps", "1"}}, {}},
        {"invalid_env_frame_rate_is_30", nullptr, {{"PAIN_FRAME_RATE", "120"}},
         {{"frame_rate", "30"}, {"vblank_ms", "16.667"}, {"sim_steps", "2"}}, {}},
        {"out_of_range_vblank_uses_frame_rate", "[settings]\nframe_rate = 60\nvblank_ms = 3.5\n", {},
         {{"vblank_ms", "8.333"}, {"sim_steps", "1"}}, {}},
        // audio = off mutes the device; it must not send PAIN down its
        // no-audio path (PS3_NO_AUDIO), which crashes it.
        {"ini_audio_off_mutes", "[settings]\naudio = off\n", {},
         {{"audio", "off"}}, {{"PS3_MUTE", "1"}, {"PS3_NO_AUDIO", nullptr}}},
        {"ini_audio_on_unmutes", "[settings]\naudio = on\n", {{"PS3_MUTE", "1"}},
         {{"audio", "on"}}, {{"PS3_MUTE", nullptr}}},
        {"env_mute_is_audio_off", nullptr, {{"PS3_MUTE", "1"}},
         {{"audio", "off"}}, {{"PS3_MUTE", "1"}}},
        // mesh_lanes = auto (the default): 3 lanes with 6+ performance cores, else 2.
        {"auto_lanes_4_cores_is_2", nullptr, {{"PAIN_TEST_PERF_CORES", "4"}},
         {{"mesh_lanes", "2"}}, {{"PS3_SPURS_LANES_OF_2", "2"}}},
        {"auto_lanes_8_cores_is_3", nullptr, {{"PAIN_TEST_PERF_CORES", "8"}},
         {{"mesh_lanes", "3"}}, {{"PS3_SPURS_LANES_OF_2", "3"}}},
        {"ini_auto_lanes_8_cores_is_3", "[settings]\nmesh_lanes = auto\n", {{"PAIN_TEST_PERF_CORES", "8"}},
         {{"mesh_lanes", "3"}}, {{"PS3_SPURS_LANES_OF_2", "3"}}},
        {"ini_lanes_2_beats_8_cores", "[settings]\nmesh_lanes = 2\n", {{"PAIN_TEST_PERF_CORES", "8"}},
         {{"mesh_lanes", "2"}}, {{"PS3_SPURS_LANES_OF_2", "2"}}},
        {"env_lanes_4_beats_auto", nullptr, {{"PS3_SPURS_LANES_OF_2", "4"}, {"PAIN_TEST_PERF_CORES", "8"}},
         {{"mesh_lanes", "4"}}, {{"PS3_SPURS_LANES_OF_2", "4"}}},
        {"ini_lanes_beats_env_lanes", "[settings]\nmesh_lanes = 1\n", {{"PS3_SPURS_LANES_OF_2", "4"}},
         {{"mesh_lanes", "1"}}, {{"PS3_SPURS_LANES_OF_2", "1"}}},
        {"invalid_ini_lanes_falls_back_to_auto", "[settings]\nmesh_lanes = 7\n", {{"PAIN_TEST_PERF_CORES", "8"}},
         {{"mesh_lanes", "3"}}, {{"PS3_SPURS_LANES_OF_2", "3"}}},
        {"invalid_ini_lanes_uses_env", "[settings]\nmesh_lanes = lots\n", {{"PS3_SPURS_LANES_OF_2", "4"}},
         {{"mesh_lanes", "4"}}, {{"PS3_SPURS_LANES_OF_2", "4"}}},
        {"invalid_env_lanes_falls_back_to_auto", nullptr, {{"PS3_SPURS_LANES_OF_2", "0"}, {"PAIN_TEST_PERF_CORES", "4"}},
         {{"mesh_lanes", "2"}}, {{"PS3_SPURS_LANES_OF_2", "2"}}},
        // Controller: stick_deadzone (0-50), vibration (0-100, numbers only),
        // controller_quit (on/off).
        {"controller_defaults", nullptr, {},
         {{"stick_deadzone", "10"}, {"vibration", "100"}, {"controller_quit", "on"}},
         {{"PS3_PAD_DEADZONE", "10"}, {"PS3_PAD_RUMBLE", "100"}, {"PS3_PAD_QUIT", "1"}}},
        {"controller_ini", "[settings]\nstick_deadzone = 25\nvibration = 0\ncontroller_quit = off\n", {},
         {{"stick_deadzone", "25"}, {"vibration", "0"}, {"controller_quit", "off"}},
         {{"PS3_PAD_DEADZONE", "25"}, {"PS3_PAD_RUMBLE", "0"}, {"PS3_PAD_QUIT", "0"}}},
        {"controller_ini_limits", "[settings]\nstick_deadzone = 0\nvibration = 100\ncontroller_quit = yes\n", {},
         {{"stick_deadzone", "0"}, {"vibration", "100"}, {"controller_quit", "on"}},
         {{"PS3_PAD_DEADZONE", "0"}, {"PS3_PAD_RUMBLE", "100"}, {"PS3_PAD_QUIT", "1"}}},
        {"controller_ini_out_of_range_falls_back",
         "[settings]\nstick_deadzone = 51\nvibration = 101\ncontroller_quit = maybe\n", {},
         {{"stick_deadzone", "10"}, {"vibration", "100"}, {"controller_quit", "on"}},
         {{"PS3_PAD_DEADZONE", "10"}, {"PS3_PAD_RUMBLE", "100"}, {"PS3_PAD_QUIT", "1"}}},
        {"controller_ini_not_whole_numbers_fall_back",
         "[settings]\nstick_deadzone = 7.5\nvibration = off\n", {},
         {{"stick_deadzone", "10"}, {"vibration", "100"}}, {{"PS3_PAD_RUMBLE", "100"}}},
        {"controller_ini_negative_falls_back", "[settings]\nstick_deadzone = -1\nvibration = -10\n", {},
         {{"stick_deadzone", "10"}, {"vibration", "100"}}, {}},
        {"controller_env", nullptr,
         {{"PS3_PAD_DEADZONE", "30"}, {"PS3_PAD_RUMBLE", "40"}, {"PS3_PAD_QUIT", "0"}},
         {{"stick_deadzone", "30"}, {"vibration", "40"}, {"controller_quit", "off"}},
         {{"PS3_PAD_DEADZONE", "30"}, {"PS3_PAD_RUMBLE", "40"}, {"PS3_PAD_QUIT", "0"}}},
        {"controller_ini_beats_env", "[settings]\nstick_deadzone = 5\nvibration = 70\ncontroller_quit = on\n",
         {{"PS3_PAD_DEADZONE", "30"}, {"PS3_PAD_RUMBLE", "40"}, {"PS3_PAD_QUIT", "0"}},
         {{"stick_deadzone", "5"}, {"vibration", "70"}, {"controller_quit", "on"}},
         {{"PS3_PAD_DEADZONE", "5"}, {"PS3_PAD_RUMBLE", "70"}, {"PS3_PAD_QUIT", "1"}}},
        {"controller_invalid_ini_uses_env", "[settings]\nstick_deadzone = 99\n", {{"PS3_PAD_DEADZONE", "20"}},
         {{"stick_deadzone", "20"}}, {{"PS3_PAD_DEADZONE", "20"}}},
        {"controller_invalid_env_is_default", nullptr,
         {{"PS3_PAD_DEADZONE", "60"}, {"PS3_PAD_RUMBLE", "loud"}, {"PS3_PAD_QUIT", "sometimes"}},
         {{"stick_deadzone", "10"}, {"vibration", "100"}, {"controller_quit", "on"}},
         {{"PS3_PAD_DEADZONE", "10"}, {"PS3_PAD_RUMBLE", "100"}, {"PS3_PAD_QUIT", "1"}}},
        {"controller_env_quit_off_word", nullptr, {{"PS3_PAD_QUIT", "off"}},
         {{"controller_quit", "off"}}, {{"PS3_PAD_QUIT", "0"}}},
    };

    int failed = 0;
    for (const auto& test : cases) {
        std::fflush(stdout);
        const pid_t child = fork();
        if (child < 0) return 2;
        if (child == 0) {
            // Settings diagnostics go to stderr; keep the report readable.
            if (!std::getenv("PAIN_SETTINGS_TEST_VERBOSE")) std::freopen("/dev/null", "w", stderr);
            const int result = run_case(test, dir);
            std::fflush(stdout);
            std::_Exit(result);
        }
        int status = 0;
        waitpid(child, &status, 0);
        if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) ++failed;
    }
    rmdir(dir);
    std::printf("%d of %zu settings cases failed\n", failed, sizeof cases / sizeof cases[0]);
    return failed ? 1 : 0;
}
