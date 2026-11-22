#!/bin/bash
# CORPUS=<dir> pair.sh <rounds> <repeat> <variant>...: (variants are build.sh output dirs) alternate the variants' replay checkers, rotating the
# order each round; every repeat of every job is checked exactly. Waits out PainRecomp before
# each run so a benchmark is never shared. A variant is <dir> or <dir>:VAR=VAL,VAR=VAL. Prints round, variant, sum of the 64 job means (ns).
rounds=$1 repeat=$2; shift 2; vs=("$@"); n=${#vs[@]}
C=${CORPUS:?directory of job-*.bin captures}
for ((r = 1; r <= rounds; r++)); do
  for ((k = 0; k < n; k++)); do
    v=${vs[$(( (k + r - 1) % n ))]}
    bin=${v%%:*}; envs=(); [ "$bin" != "$v" ] && IFS=, read -ra envs <<<"${v#*:}"
    while pgrep -x PainRecomp >/dev/null; do sleep 3; done
    out=$(env ${envs[@]+"${envs[@]}"} REPEAT=$repeat "$bin/check" "$C"/job-*.bin 2>/dev/null)
    pass=$(echo "$out" | sed -n 's/^Job replays: \([0-9]*\/[0-9]*\).*/\1/p')
    ns=$(echo "$out" | sed -n 's/^sum_of_case_means_ns=//p')
    printf "%d\t%s\t%s\t%s\n" $r $v "$pass" "$ns"
  done
done
