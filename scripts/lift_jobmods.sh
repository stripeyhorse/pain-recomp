#!/bin/bash
# Lift the WWS SPU job modules embedded in the player's EBOOT.elf into spu/.
#
# PAIN streams 11 job modules (audio mix, animation, Havok) from fixed
# addresses in its own ELF into the job code buffer at LS 0x4000. Without
# their lifts every job runs in the SPU interpreter: about 21M interpreted
# steps a second at the menu, 62% silent audio blocks and 2-4 FPS in play.
# spu/ is generated output and is never committed; run this after
# extract/lift of the three SPU ELF images and before the build.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
elf="${1:-$root/game/Pain_BCES00548/Pain BCES00548/PS3_GAME/USRDIR/EBOOT.elf}"
out="$root/pain-recomp/spu"
python3 "$root/ps3recomp/tools/lift_jobmods.py" --engine-elf "$elf" --out "$out" --merge-chunks
# The job modules take image ids 200..210. The policy module must sit outside
# that range or its functions are registered under a job module's id.
grep -q 'spu_begin_image(199);' "$out/pm_reg.c" || {
    echo "spu/pm_reg.c must register the policy module as image 199." >&2
    exit 1
}
