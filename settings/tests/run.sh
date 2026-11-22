#!/bin/bash
# Build and run the settings-layer checks (POSIX). On macOS, settings.cpp
# includes the toolkit's Metal backend header: PS3RECOMP_DIR, default
# ../ps3recomp beside the port.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
toolkit="${PS3RECOMP_DIR:-$here/../../../ps3recomp}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
"${CXX:-c++}" -std=c++20 -Wall -Wextra -O1 -g ${SANITIZE:+-fsanitize=$SANITIZE} \
    -I "$toolkit/libs/video" -I "$toolkit/include" \
    "$here/../settings.cpp" "$here/test_settings.cpp" -o "$out/test_settings"
"$out/test_settings"
