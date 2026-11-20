#pragma once

#include <cstdint>

namespace pain_save_art {
void load(const char* disc_root);
void supply_missing(uint32_t opd, uint32_t result, uint32_t file_set);
}
