#!/bin/bash
# (Re)launch PainRecomp on bobby with the Metal backend and the pre-seeded
# HDD cache. Runs ON bobby. Kills any previous instance first.
# (pkill -x does not reliably match on macOS; killall -9 by name does.)
killall -9 PainRecomp 2>/dev/null && sleep 1
cd "$HOME/pain-ps3/pain-recomp"
export PS3_HDD0_ROOT="$HOME/pain-ps3/hdd0"
export PS3RECOMP_METAL_FRAME_DUMP="$HOME/pain-ps3/frame.ppm"   # every 120th present
nohup ./build/PainRecomp "$HOME/pain-ps3/game/PS3_GAME/USRDIR/EBOOT.elf" \
      > "$HOME/pain-ps3/run_mac.log" 2>&1 &
echo "launched pid $!"
sleep 15
grep -aE "VFS root|content root|Activating|blu-ray files|RSX metal|pipeline|captured" \
     "$HOME/pain-ps3/run_mac.log" | head -12
