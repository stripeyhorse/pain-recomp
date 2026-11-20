#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace {
int unlock_all_requested()
{
    const char* value = std::getenv("PAIN_UNLOCK_ALL");
    if (value == nullptr || std::strcmp(value, "1") != 0) {
        return 0;
    }

    std::fprintf(stderr, "[pain trainer] PAIN_UNLOCK_ALL=1 requested (requires the guarded unlock lift)\n");
    return 1;
}
}

// Read once before guest threads run. The lifted patches all share this guard.
extern "C" {
int g_pain_unlock_all = unlock_all_requested();
}
