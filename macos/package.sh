#!/bin/bash
# Assemble an Apple Silicon preview from an existing Metal build and local development inputs.
set -euo pipefail
umask 077

if [[ $# != 5 ]]; then
    echo "Usage: $0 STAGE VERIFIED_MAC_BUILD SDK_PREFIX PS3_GAME GENERATED_CATALOG" >&2
    exit 2
fi

here="$(cd "$(dirname "$0")" && pwd -P)"
port="$(cd "$here/.." && pwd -P)"
toolkit="$(cd "$port/../ps3recomp" && pwd -P)"
stage="$(cd "$1" && pwd -P)"
runner="$2"
prefix="$3"
disc="$4"
catalog="$5"
deps="$stage/deps"
app="$stage/PAIN.app"
bundle="$app/Contents"
resources="$bundle/Resources"
frameworks="$bundle/Frameworks"
helpers="$bundle/Helpers"
archive="$stage/PAIN-MacBook-Launcher-arm64.zip"

[[ ! -e "$app" && ! -e "$archive" ]]
mkdir -p "$bundle/MacOS" "$resources/Licences" "$frameworks" "$helpers"
xcrun swiftc -swift-version 5 -target arm64-apple-macos27.0 -O \
    "$here/Launcher.swift" -o "$bundle/MacOS/PAIN"
install -m 755 "$runner" "$helpers/PainRecomp"
install_name_tool -rpath "$prefix/lib" '@executable_path/../Frameworks' "$helpers/PainRecomp"
for library in libSDL2-2.0.0.dylib libspirv-cross-c-shared.0.dylib; do
    install -m 755 "$prefix/lib/$library" "$frameworks/$library"
done

ditto --norsrc --noextattr "$deps/python" "$resources/Python"
ditto --norsrc --noextattr "$deps/RPCS3.app" "$helpers/RPCS3.app"
codesign --verify --deep --strict "$helpers/RPCS3.app"
install -m 644 "$here/game_data.py" "$port/scripts/extract_cache.py" \
    "$toolkit/tools/lift_prx.py" "$resources/"
"$resources/Python/bin/python3" -B "$resources/game_data.py" manifest "$disc" "$catalog" "$resources/disc.json"

install -m 644 "$port/LICENSE" "$resources/Licences/pain-recomp.txt"
install -m 644 "$toolkit/LICENSE" "$resources/Licences/ps3recomp.txt"
install -m 644 "$deps/RPCS3-LICENSE.txt" "$resources/Licences/RPCS3.txt"
install -m 644 "$deps/SDL2-LICENSE.txt" "$resources/Licences/SDL2.txt"
install -m 644 "$deps/glslang-LICENSE.txt" "$resources/Licences/glslang.txt"
ditto --norsrc --noextattr "$deps/SPIRV-Cross-LICENSES" "$resources/Licences/SPIRV-Cross"
cat > "$resources/Licences/Sources.txt" <<'EOF'
RPCS3 arm64 for macOS is used only during import.
Source: https://github.com/RPCS3/rpcs3/tree/c05ef180e787fa162ff0506231bafb5f69d53748
Binary release: https://github.com/RPCS3/rpcs3-binaries-mac-arm64/releases/tag/build-c05ef180e787fa162ff0506231bafb5f69d53748
Python 3.12.16: https://www.python.org/downloads/release/python-31216/
Portable distribution: https://github.com/astral-sh/python-build-standalone/releases/tag/20261110
See Python/lib/python3.12/LICENSE.txt and Python/share for Python and its dependencies.
EOF

cat > "$bundle/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleDisplayName</key><string>PAIN</string>
    <key>CFBundleExecutable</key><string>PAIN</string>
    <key>CFBundleIdentifier</key><string>com.stripeyhorse.painrecomp.launcher</string>
    <key>CFBundleName</key><string>PAIN</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>20261121.2</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
    <key>LSMinimumSystemVersion</key><string>27.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$bundle/Info.plist"
for binary in "$helpers/PainRecomp" "$frameworks/"*.dylib; do
    codesign --force --sign - "$binary"
done
codesign --force --sign - "$app"
codesign --verify --deep --strict --verbose=2 "$app"
ditto -c -k --norsrc --keepParent "$app" "$archive"
(cd "$stage" && shasum -a 256 "${archive##*/}")
