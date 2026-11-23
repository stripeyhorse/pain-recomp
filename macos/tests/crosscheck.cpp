// Cross-check: settings.cpp's own load() must resolve, from each INI file the
// Swift test wrote, the values the launcher's model read from it.
// Usage: crosscheck DIR NAME... (reads DIR/NAME.ini and DIR/NAME.expect,
// writes load()'s PAIN_SETTINGS_VERBOSE trace to DIR/NAME.verbose).
// Run it with an empty environment so no inherited variable takes part.
#include "../../settings/settings.h"

#if defined(__APPLE__)
#include "rsx_metal_backend.h"
// save() forwards present options to the renderer; this check never saves.
extern "C" void rsx_metal_backend_set_present_options(const rsx_metal_present_options*) {}
#endif

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <sys/wait.h>
#include <unistd.h>

static int check(const std::string& base)
{
    setenv("PAIN_SETTINGS_PATH", (base + ".ini").c_str(), 1);
    setenv("PAIN_SETTINGS_VERBOSE", "1", 1);
    if (!std::freopen((base + ".verbose").c_str(), "w", stderr)) return 2;
    if (!pain_settings::load()) {
        std::printf("FAIL %s: load() failed\n", base.c_str());
        return 1;
    }
    std::ifstream expect(base + ".expect");
    std::string line;
    int failures = 0, keys = 0;
    while (std::getline(expect, line)) {
        const auto equals = line.find('=');
        const auto key = line.substr(0, equals), want = line.substr(equals + 1);
        const auto got = pain_settings::value(key);
        ++keys;
        if (got != want) {
            std::printf("FAIL %s: %s = %s in settings.cpp, %s in Swift\n", base.c_str(), key.c_str(),
                        got.c_str(), want.c_str());
            ++failures;
        }
    }
    if (!keys) return 2;
    if (!failures) std::printf("ok   %s (%d keys agree)\n", base.c_str(), keys);
    return failures ? 1 : 0;
}

int main(int argc, char** argv)
{
    if (argc < 3) return 2;
    int failed = 0;
    for (int i = 2; i < argc; ++i) {
        std::fflush(stdout);
        // load() publishes environment variables; give each file a fresh process.
        const pid_t child = fork();
        if (child < 0) return 2;
        if (child == 0) {
            const int result = check(std::string(argv[1]) + "/" + argv[i]);
            std::fflush(stdout);
            std::fflush(stderr);
            std::_Exit(result);
        }
        int status = 0;
        waitpid(child, &status, 0);
        if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) ++failed;
    }
    std::printf("%d of %d cross-check files disagree\n", failed, argc - 2);
    return failed ? 1 : 0;
}
