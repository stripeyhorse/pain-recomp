#!/bin/bash
# First-run harness on this box (null backend, headless): boot the recompiled
# Pain with a timeout, capture the log for bring-up triage.
# Usage: scripts/first_run.sh [seconds]
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ELF="$HERE/../game/Pain_BCES00548/Pain BCES00548/PS3_GAME/USRDIR/EBOOT.elf"
T="${1:-60}"
cd "$HERE"
timeout "$T" ./build/PainRecomp "$ELF" 2>&1 | tee "$HERE/run.log"
echo "--- exit: $? (124 = still running at timeout)"
