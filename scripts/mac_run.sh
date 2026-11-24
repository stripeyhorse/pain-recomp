#!/bin/bash
# (Re)launch the prepared Metal build on bobby.
set -euo pipefail
root="$HOME/pain-ps3"
cd "$root/pain-recomp"
elf="$root/game/PS3_GAME/USRDIR/EBOOT.elf"
export PS3_HDD0_ROOT="$root/hdd0"
if [[ ! -x ./build/PainRecomp || ! -s "$elf" ||
      ! -s "$PS3_HDD0_ROOT/game/BCES00548/USRDIR/CacheFlags/CacheDone.flg" ]]; then
    echo "Missing build or prepared disc/cache files. Run push_bobby.sh on the workstation and mac_build.sh on bobby." >&2
    exit 1
fi
# SIGTERM quits the way the window's close button does: up to 3 s, more for a save.
if killall PainRecomp 2>/dev/null; then
    for _ in $(seq 40); do pgrep -x PainRecomp >/dev/null || break; sleep 0.2; done
fi
nohup ./build/PainRecomp "$elf" > "$root/run_mac.log" 2>&1 &
echo "launched pid $!"
