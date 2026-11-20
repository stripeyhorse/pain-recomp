#!/bin/bash
# Push the toolkit, the port and the game files to bobby (the Apple Silicon Mac).
# Run from this box. Idempotent; rsync only sends what changed.
set -e
HERE="$(cd "$(dirname "$0")/../.." && pwd)"     # .../Pain PS3
GAME="$HERE/game/Pain_BCES00548/Pain BCES00548"

rsync -a --delete --exclude .git --exclude .venv --exclude build \
      "$HERE/ps3recomp/" bobby:pain-ps3/ps3recomp/

rsync -a --exclude .git --exclude build \
      "$HERE/pain-recomp/" bobby:pain-ps3/pain-recomp/

# game files (disc content; ~1.1 GB, mostly CacheData.pak)
rsync -a "$GAME/PS3_GAME/USRDIR/" bobby:pain-ps3/game/PS3_GAME/USRDIR/
rsync -a "$GAME/PS3_GAME/PARAM.SFO" "$GAME/PS3_GAME/ICON0.PNG" bobby:pain-ps3/game/PS3_GAME/ 2>/dev/null || true
rsync -a "$GAME/PS3_DISC.SFB" bobby:pain-ps3/game/ 2>/dev/null || true
echo "push done"
