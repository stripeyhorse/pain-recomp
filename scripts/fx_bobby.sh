#!/bin/bash
# Sync the tracked sources of a ps3recomp and a pain-recomp checkout to bobby and build there.
#   scripts/fx_bobby.sh sync  [ps3recomp-dir] [pain-recomp-dir]   rsync tracked files (checksum compare)
#   scripts/fx_bobby.sh build                                     incremental ninja build on bobby
#   scripts/fx_bobby.sh bench <tag> [VAR=VAL ...]                 held 1080p Crash Course city replay
# Every ssh/rsync shares one ControlMaster connection (bobby rate-limits fresh connections).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
SSH=(ssh -o ControlMaster=auto -o "ControlPath=/tmp/cm-%r@%h:%p" -o ControlPersist=2h)
cmd="${1:?sync|build|bench}"; shift
case "$cmd" in
sync)
    toolkit="${1:-$here/../ps3recomp}"; port="${2:-$here}"
    for pair in "$toolkit:ps3recomp" "$port:pain-recomp"; do
        src="${pair%%:*}"; dst="${pair##*:}"
        git -C "$src" ls-files -z | rsync -e "${SSH[*]}" -c -i -r -0 --files-from=- "$src/" "bobby:pain-ps3/$dst/" \
            | grep -v '^\.[fd]' || true
    done ;;
build)
    "${SSH[@]}" bobby 'cd ~/pain-ps3/pain-recomp && export PATH="$HOME/Library/Python/3.9/bin:$HOME/pain-ps3/prefix/bin:$PATH" && cmake --build build -j 8 2>&1 | grep -v -E "warning:|^\s+[0-9]+ \||^\s+\||~|\^|note:|warnings? generated" | tail -${FX_TAIL:-25} && shasum -a 256 build/PainRecomp | cut -c1-16' ;;
bench)
    tag="${1:?tag}"; shift
    "${SSH[@]}" bobby "cd ~/pain-ps3/fx && ${FX_ENV:-} ./run.sh '$tag' \"\${FX_EXE:-\$HOME/pain-ps3/pain-recomp/build/PainRecomp}\" $* 2>&1 | tail -6" ;;
*) echo "unknown command $cmd" >&2; exit 2 ;;
esac
