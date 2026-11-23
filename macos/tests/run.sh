#!/bin/bash
# Build and run the launcher's settings.ini checks on macOS: the Swift model
# cases, then a cross-check of the files it writes against settings.cpp's own
# load(). settings.cpp includes the toolkit's Metal backend header:
# PS3RECOMP_DIR, default ../ps3recomp beside the port.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
port="$here/../.."
toolkit="${PS3RECOMP_DIR:-$port/../ps3recomp}"
out="${KEEP_DIR:-$(mktemp -d)}"
[[ -n "${KEEP_DIR:-}" ]] || trap 'rm -rf "$out"' EXIT
mkdir -p "$out/files"

xcrun swiftc -swift-version 5 -warnings-as-errors \
    "$here/../SettingsFile.swift" "$here/main.swift" -o "$out/settings-file-test"
"$out/settings-file-test" --crosscheck "$out/files" "$port/settings/settings.example.ini"

"${CXX:-c++}" -std=c++20 -Wall -Wextra -O1 \
    -I "$toolkit/libs/video" -I "$toolkit/include" \
    "$port/settings/settings.cpp" "$here/crosscheck.cpp" -o "$out/crosscheck"
names=()
for file in "$out/files"/*.ini; do names+=("$(basename "$file" .ini)"); done
env -i PATH=/usr/bin:/bin "$out/crosscheck" "$out/files" "${names[@]}"
