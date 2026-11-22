#!/bin/bash
# Link a local (Linux, null renderer) PainRecomp for a toolkit worktree WITHOUT recompiling the lifted
# PPU and LevelScript translation units, which are most of a full build.
#
#   scripts/fx_local_link.sh <build-dir> [jobs]
#
# <build-dir> must already be configured by CMake against the worktree, for example
#   cmake -S <pain-recomp> -B <build-dir> -G Ninja -DPS3RECOMP_DIR=<worktree>/ps3recomp -DCMAKE_BUILD_TYPE=Release
# The script builds the runtime library and every non-lifted object in <build-dir> with ninja, then links
# <build-dir>/PainRecomp using the lifted PPU / LevelScript objects of the donor build
# (FX_DONOR, default: the main checkout's pain-recomp/build).
#
# Valid only while the worktree has not changed anything the lifted PPU code inlines: ps3recomp/include,
# runtime/ppu/*.h, runtime/memory, the generated recompiled/ sources or the PPU lifter. If you changed any
# of those, do a normal full build instead (and say so in your report).
#
# FX_OWN_LIFTED lists lifted objects (paths relative to <build-dir>, space separated) to compile in
# <build-dir> instead of taking them from the donor, for a worktree that changes one prepared chunk,
# for example FX_OWN_LIFTED=CMakeFiles/PainRecomp.dir/wrapped_ppu_recomp_001.cpp.o
set -euo pipefail
build="$(cd "${1:?build dir}" && pwd)"; jobs="${2:-4}"
here="$(cd "$(dirname "$0")/.." && pwd)"
donor="${FX_DONOR:-$here/build}"
ninja="$(grep -m1 '^CMAKE_MAKE_PROGRAM' "$build/CMakeCache.txt" | cut -d= -f2)"
[ -x "$ninja" ] || ninja="$(command -v ninja)"
link="$("$ninja" -C "$build" -t commands PainRecomp | tail -1)"
lifted='CMakeFiles/PainRecomp\.dir/(recompiled/|prx/|wrapped_ppu_recomp_)'
mapfile -t objs < <(tr ' ' '\n' <<<"$link" | grep -E '\.(o|a)$' | grep -v '^-' | sort -u)
own=(); missing=0
own_lifted=" ${FX_OWN_LIFTED:-} "
for o in "${objs[@]}"; do
    if [[ "$own_lifted" == *" $o "* ]]; then
        own+=("$o")
    elif [[ "$o" =~ $lifted ]]; then
        [ -s "$donor/$o" ] || { echo "donor object missing: $donor/$o" >&2; missing=1; }
    else
        own+=("$o")
    fi
done
[ "$missing" = 0 ] || { echo "The donor build is incomplete; do a full build." >&2; exit 1; }
nice -n 10 "$ninja" -C "$build" -j "$jobs" "${own[@]}"
# Point the lifted objects at the donor through a space-free symlink; everything else stays relative.
ln -sfn "$donor" "$build/.donor"
relinked="$(sed -E 's#(^| )(CMakeFiles/PainRecomp\.dir/(recompiled/|prx/|wrapped_ppu_recomp_)[^ ]*\.o)#\1.donor/\2#g' <<<"$link")"
for o in ${FX_OWN_LIFTED:-}; do relinked="${relinked// .donor\/$o / $o }"; done
( cd "$build" && nice -n 10 bash -c "$relinked" )
ls -la "$build/PainRecomp"
