#!/bin/bash
# Copy the existing lift, toolkit and disc files to beast over SSH.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
disc="$root/game/Pain_BCES00548/Pain BCES00548"

remote_rsync="$(ssh -o BatchMode=yes beast 'bash -s' <<'REMOTE'
set -euo pipefail
root="$HOME/pain-ps3"
mkdir -p "$root"/{ps3recomp,pain-recomp,game/PS3_GAME/USRDIR,prefix,src,logs}
if command -v rsync >/dev/null; then
    printf '%s\n' rsync
    exit
fi
if [[ ! -x "$root/prefix/usr/bin/rsync" ]]; then
    download="$(mktemp -d "$root/src/rsync.XXXXXX")"
    cd "$download"
    apt-get download rsync >&2
    dpkg-deb -x rsync_*.deb "$root/prefix"
fi
printf '%q\n' "$root/prefix/usr/bin/rsync"
REMOTE
)"

rsync_from_here() {
    rsync -a --partial --info=stats1 -e 'ssh -o BatchMode=yes' \
        --rsync-path="$remote_rsync" \
        "$@"
}

rsync_from_here --exclude=.git --exclude=.venv --exclude=build \
    "$root/ps3recomp/" beast:pain-ps3/ps3recomp/
rsync_from_here --exclude=.git --exclude=build --exclude='/run*.log' \
    "$root/pain-recomp/" beast:pain-ps3/pain-recomp/
rsync_from_here "$disc/PS3_GAME/USRDIR/" beast:pain-ps3/game/PS3_GAME/USRDIR/
rsync_from_here "$disc/PS3_GAME/PARAM.SFO" "$disc/PS3_GAME/ICON0.PNG" \
    beast:pain-ps3/game/PS3_GAME/
rsync_from_here "$disc/PS3_DISC.SFB" beast:pain-ps3/game/
