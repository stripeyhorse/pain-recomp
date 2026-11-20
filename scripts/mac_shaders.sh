#!/bin/bash
# Build glslang + SPIRV-Cross (guest-shader translation deps for the Metal
# backend) into ~/pain-ps3/prefix, then reconfigure + rebuild PainRecomp with
# MSL translation ON. Runs ON bobby. No sudo needed.
set -e
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
cd "$HOME/pain-ps3/pain-recomp"
cmake -B build -G Ninja \
      -DCMAKE_PREFIX_PATH="$P" \
      -DCMAKE_MAKE_PROGRAM="$(command -v ninja || echo "$P/bin/ninja")" \
      -DPS3RECOMP_DIR="$HOME/pain-ps3/ps3recomp" \
      -DCMAKE_BUILD_TYPE=Release 2>&1 | grep -iE "translation|glslang|spirv|metal" || true
cmake --build build -j 8 2>&1 | tail -1
echo "SHADERS_DONE"
