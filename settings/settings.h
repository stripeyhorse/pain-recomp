#pragma once

#include <string>
#include <string_view>

namespace pain_settings {
bool load();
std::string value(std::string_view key);
bool save(std::string_view key, std::string value);
int frame_cap();
bool save_frame_cap(int value);
bool verbose();
void install_native_hooks();
}
