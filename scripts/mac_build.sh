#!/bin/bash
# Build PainRecomp on bobby (Apple Silicon, Metal backend, SDL2 from ~/pain-ps3/prefix).
# Run ON bobby after scripts/push_bobby.sh.
set -e
cd ~/pain-ps3/pain-recomp
export PATH="$HOME/Library/Python/3.9/bin:$HOME/pain-ps3/prefix/bin:$PATH"
catalog="$PWD/prx/generated/full"
[[ -s "recompiled/ppu_hle_nids.cpp" && -s "$catalog/catalog.inc" ]] || {
    echo "Missing prepared build inputs. Run push_bobby.sh from the workstation." >&2
    exit 1
}
cmake -B build -G Ninja \
      -DPAIN_USE_PREPARED_PPU=ON -DPORT_SPU_INPUTS= \
      -DCMAKE_PREFIX_PATH="$HOME/pain-ps3/prefix" \
      -DPS3RECOMP_DIR="$HOME/pain-ps3/ps3recomp" \
      -DPAIN_LEVELSCRIPT_DIR="$catalog" \
      -DCMAKE_BUILD_TYPE=Release
cmake --build build -j 8
echo "=== built: $(ls build/PainRecomp)"
