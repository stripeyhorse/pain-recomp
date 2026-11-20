#!/bin/bash
# Build PainRecomp on bobby (Apple Silicon, Metal backend, SDL2 from ~/pain-ps3/prefix).
# Run ON bobby after scripts/push_bobby.sh.
set -e
cd ~/pain-ps3/pain-recomp
export PATH="$HOME/Library/Python/3.9/bin:$PATH"
cmake -B build -G Ninja \
      -DCMAKE_PREFIX_PATH="$HOME/pain-ps3/prefix" \
      -DPS3RECOMP_DIR="$HOME/pain-ps3/ps3recomp" \
      -DCMAKE_BUILD_TYPE=Release
cmake --build build -j 8
echo "=== built: $(ls build/PainRecomp)"
