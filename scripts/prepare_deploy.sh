#!/bin/bash
# Prepare deploy inputs on the workstation after lifting the EBOOT and SPU code.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$root/pain-recomp/scripts/levelscript_deploy.sh"
set_deploy_paths "$root"

GAME_DIR="$deploy_game" HDD0_ROOT="$deploy_hdd" "$deploy_port/scripts/prepare.sh"
if [[ ! -e "$deploy_catalog" ]]; then
    : "${RPCS3_BIN:?Set RPCS3_BIN to generate the workstation LevelScript catalogue}"
    "${PYTHON3:-python3}" "$deploy_port/scripts/prepare_levelscripts.py" \
        "$deploy_game/USRDIR" --rpcs3 "$RPCS3_BIN"
fi
"${PYTHON3:-python3}" "$deploy_port/scripts/relift_animation_dispatch.py" \
    "$deploy_game/USRDIR/EBOOT.elf"
"${PYTHON3:-python3}" "$deploy_port/scripts/relift_unlock_trainer.py" \
    "$deploy_game/USRDIR/EBOOT.elf"

nid_table="$deploy_port/recompiled/ppu_hle_nids.cpp"
tmp="$(mktemp "$nid_table.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
"${PYTHON3:-python3}" "$root/ps3recomp/tools/gen_hle_nids.py" --all --out "$tmp"
if ! cmp -s "$tmp" "$nid_table"; then
    mv "$tmp" "$nid_table"
fi
cmake -DRECOMP_DIR="$deploy_port/recompiled" \
    -DPREPARED_PPU_DIR="$deploy_port/recompiled/prepared" \
    -P "$deploy_port/scripts/prepare_ppu.cmake"
check_deploy_inputs
