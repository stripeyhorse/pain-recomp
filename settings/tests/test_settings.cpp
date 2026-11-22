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

const char* const watched[] = {"PAIN_FRAME_RATE", "PAIN_VBLANK_MS", "PAIN_SIM_STEPS"};

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
        if (!got || std::strcmp(got, want) != 0) {
            std::printf("FAIL %s: %s = %s, expected %s\n", test.name, name, got ? got : "<unset>", want);
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
