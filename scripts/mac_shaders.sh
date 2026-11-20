#!/bin/bash
# Build glslang + SPIRV-Cross (guest-shader translation deps for the Metal
# backend) into ~/pain-ps3/prefix, then reconfigure + rebuild PainRecomp with
# MSL translation ON. Runs ON bobby. No sudo needed.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
export PATH="$HOME/Library/Python/3.9/bin:$PATH"
P="$HOME/pain-ps3/prefix"
SRC="$HOME/pain-ps3/src"
mkdir -p "$P" "$SRC"
cd "$SRC"

echo "== glslang"
[ -d glslang ] || git clone --depth 1 https://github.com/KhronosGroup/glslang
cmake -S glslang -B glslang/build -G Ninja -DCMAKE_INSTALL_PREFIX="$P" \
      -DCMAKE_BUILD_TYPE=Release -DENABLE_GLSLANG_BINARIES=OFF -DENABLE_OPT=0 >/dev/null
cmake --build glslang/build -j 8 >/dev/null
cmake --install glslang/build >/dev/null

echo "== SPIRV-Cross"
[ -d SPIRV-Cross ] || git clone --depth 1 https://github.com/KhronosGroup/SPIRV-Cross
cmake -S SPIRV-Cross -B SPIRV-Cross/build -G Ninja -DCMAKE_INSTALL_PREFIX="$P" \
      -DCMAKE_BUILD_TYPE=Release -DSPIRV_CROSS_ENABLE_TESTS=OFF \
      -DSPIRV_CROSS_ENABLE_EXAMPLES=OFF -DSPIRV_CROSS_SHARED=ON >/dev/null
cmake --build SPIRV-Cross/build -j 8 >/dev/null
cmake --install SPIRV-Cross/build >/dev/null

echo "== reconfigure + rebuild PainRecomp with the prefix"
exec "$here/mac_build.sh"
