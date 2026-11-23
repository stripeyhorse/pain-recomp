#!/bin/bash
# Test only: build the launcher sources with the render harness in place of
# main.swift, then render the main window and Settings sheet to PNG in
# OUTPUT_DIR and check the sheet's behaviour. The launcher's state goes to a
# temporary directory through PAIN_PREVIEW_DATA_DIR.
set -euo pipefail
[[ $# == 1 ]] || { echo "Usage: $0 OUTPUT_DIR" >&2; exit 2; }
here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$1"
output="$(cd "$1" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
xcrun swiftc -swift-version 5 -target arm64-apple-macos27.0 -warnings-as-errors \
    "$here/render/main.swift" "$here/../Launcher.swift" "$here/../SettingsSheet.swift" \
    "$here/../SettingsFile.swift" -o "$work/render"
mkdir "$work/state"
PAIN_PREVIEW_DATA_DIR="$work/state" "$work/render" "$output"
