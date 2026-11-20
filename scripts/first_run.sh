#!/bin/bash
# Local headless run with a bounded process lifetime. A timeout means the game
# was still running. The caller can distinguish that from an early exit.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
root="$(cd "$here/.." && pwd)"
source "$here/scripts/levelscript_deploy.sh"
set_deploy_paths "$root"
GAME_DIR="$deploy_game" HDD0_ROOT="$deploy_hdd" "$here/scripts/prepare.sh"
export PS3_HDD0_ROOT="$deploy_hdd"
cd "$here"
timeout "${1:-60}" "${PAIN_BINARY:-./build/PainRecomp}" "$deploy_game/USRDIR/EBOOT.elf" 2>&1 | tee "$here/run.log"
