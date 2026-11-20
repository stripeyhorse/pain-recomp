#!/bin/bash
# (Re)launch PainRecomp on bobby with the Metal backend and the pre-seeded
# HDD cache. Runs ON bobby. Kills any previous instance first.
pkill -x PainRecomp 2>/dev/null && sleep 1
cd "$HOME/pain-ps3/pain-recomp"
export PS3_HDD0_ROOT="$HOME/pain-ps3/hdd0"
nohup ./build/PainRecomp "$HOME/pain-ps3/game/PS3_GAME/USRDIR/EBOOT.elf" \
      > "$HOME/pain-ps3/run_mac.log" 2>&1 &
echo "launched pid $!"
sleep 15
grep -aE "VFS root|content root|Activating|blu-ray files|RSX metal|pipeline" \
     "$HOME/pain-ps3/run_mac.log" | head -12
