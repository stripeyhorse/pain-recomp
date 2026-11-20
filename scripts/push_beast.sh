#!/bin/bash
# Copy the existing lift, toolkit and disc files to beast over SSH.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$root/pain-recomp/scripts/levelscript_deploy.sh"
set_deploy_paths "$root"
check_deploy_inputs

remote_rsync="$(ssh -o BatchMode=yes beast 'bash -s' <<'REMOTE'
set -euo pipefail
root="$HOME/pain-ps3"
if command -v rsync >/dev/null; then
    executable=rsync
elif [[ -x "$root/prefix/usr/bin/rsync" ]]; then
    executable="$root/prefix/usr/bin/rsync"
else
    printf 'Install rsync on beast or place it under ~/pain-ps3/prefix/usr/bin.\n' >&2
    exit 1
fi
mkdir -p "$root"/{ps3recomp,pain-recomp,game/PS3_GAME/USRDIR,pain-recomp/prx/generated/full,hdd0/game/BCES00548/USRDIR}
printf '%q\n' "$executable"
REMOTE
)"

deploy_rsync() {
    rsync -a --partial --info=stats1 -e 'ssh -o BatchMode=yes' \
        --rsync-path="$remote_rsync" \
        "$@"
}

copy_deploy_inputs "$root" beast:pain-ps3
