#!/bin/bash
# run_fixture.sh <SPU_DIR> <PS3RECOMP_DIR> <out-dir> [cc] [extra cflags...]
# Builds and runs spu_native_fixture.c: optimised, then with ASan and UBSan, each also
# with -DSPU_FLOAT_RZ_ONLY (the arm64 default build of the lifted modules).
set -euo pipefail
spu=$1 sdk=$2 out=$3 cc=${4:-cc}; shift $(( $# < 4 ? $# : 4 ))
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
mkdir -p "$out"
python3 "$root/scripts/spu_native_patch.py" jobmod_ca71f23d7b11_e11B00 "$spu/jobmod_ca71f23d7b11_e11B00/spu_recomp.c" "$out/table_fixture.c" --fixture
python3 "$root/scripts/spu_native_patch.py" jobmod_fee160dc063c_e0F78 "$spu/jobmod_fee160dc063c_e0F78/spu_recomp.c" "$out/cull_fixture.c" --fixture
inc=(-I"$out" -I"$root/spu_native" -I"$sdk/runtime/spu" -I"$sdk/include")
base=(-std=gnu11 -fno-strict-aliasing -fwrapv -Wall -Wno-unused-function -Wno-unused-label -Wno-unused-variable "$@")
rc=0
for v in "opt:-O2" "san:-O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all" "rzopt:-O2 -DSPU_FLOAT_RZ_ONLY" "rzsan:-O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all -DSPU_FLOAT_RZ_ONLY"; do
  name=${v%%:*}; flags=${v#*:}
  $cc "${base[@]}" $flags "${inc[@]}" "$here/spu_native_fixture.c" -lm -o "$out/fixture-$name"
  echo "== $name"; "$out/fixture-$name" ${FIXTURE_TIMINGS:+t} || rc=1
  $cc "${base[@]}" $flags -I"$root/spu_native" -I"$sdk/runtime/spu" -I"$sdk/include" "$here/word_clear_test.c" -lm -o "$out/word-clear-$name"
  "$out/word-clear-$name" || rc=1
done
exit $rc
