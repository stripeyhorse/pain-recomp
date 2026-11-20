#pragma once

namespace pain_settings {
bool load();
int frame_cap();
bool save_frame_cap(int value);
bool verbose();
void install_native_hooks();
}
