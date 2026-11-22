#!/bin/bash
# build.sh <out-dir> [variant cflags...]: build the ICE job replay checker <out-dir>/check.
#   SDK=<ps3recomp> SPU=<lifted spu dir> [NATIVE=1] build.sh out -DSPU_FLOAT_RZ_ONLY ...
# The mesh and policy images are compiled with the variant flags (as the game would be with
# the matching CMake options); NATIVE=1 compiles the mesh image with spu_native attached
# (PAIN_SPU_NATIVE then selects the path at run time). HDR=<dir> puts another spu_helpers.h /
# spu_context.h first on the include path, to time an older SDK header against a newer one.
# Then: REPEAT=150 <out-dir>/check <corpus>/job-*.bin   or   pair.sh (alternating rounds).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); port=$(cd "$here/../../.." && pwd)
out=$1; shift; mkdir -p "$out/src"
sdk=${SDK:?ps3recomp checkout}; spu=${SPU:?lifted spu dir}
mesh_img=jobmod_ca71f23d7b11_e11B00
mesh_src="$spu/$mesh_img/spu_recomp.c"
if [ "${NATIVE:-0}" = 1 ]; then
  python3 "$port/scripts/spu_native_patch.py" "$mesh_img" "$mesh_src" "$out/src/mesh-native.c"
  mesh_src="$out/src/mesh-native.c"
fi
python3 "$here/prep.py" "$mesh_src" "$spu/pm_b70b80/spu_recomp.c" "$sdk/runtime/spu/spu_channels.c" "$out/src"
common=(${HDR:+-I$HDR} -std=gnu11 -O2 -fno-strict-aliasing -fwrapv -w -I"$sdk/runtime/spu" -I"$sdk/tests"
        -I"$sdk/include" -I"$out/src" -I"$port/spu_native")
cc=${CC:-clang}
$cc "${common[@]}" -c "$sdk/runtime/spu/spu_drain.c" -o "$out/drain.o"
$cc "${common[@]}" -c "$sdk/runtime/spu/spu_interp.c" -o "$out/interp.o"
$cc "${common[@]}" "$@" -I"$spu/$mesh_img" -c "$out/src/mesh.c" -o "$out/mesh.o" &
$cc "${common[@]}" "$@" -I"$spu/pm_b70b80" -c "$out/src/pm.c" -o "$out/pm.o" &
$cc "${common[@]}" -c "$here/ice_job_replay.c" -o "$out/check.o"
wait
if [ "$(uname)" = Darwin ]; then strip=-Wl,-dead_strip; else strip=-Wl,--gc-sections; fi
$cc $strip "$out"/{check,mesh,pm,drain,interp}.o -lm -o "$out/check"
