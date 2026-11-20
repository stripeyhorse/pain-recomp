#!/bin/bash
# Primary deploy path. Copy workstation-prepared inputs to beast over SSH.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$root/pain-recomp/scripts/levelscript_deploy.sh"
set_deploy_paths "$root"
check_deploy_inputs

# A separate deploy directory keeps builds and probes independent.
target_dir="${PAIN_BEAST_DIR:-pain-ps3}"
if [[ ! "$target_dir" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
    echo "PAIN_BEAST_DIR must be a directory name beneath the beast home directory." >&2
    exit 1
fi

remote_rsync="$(ssh -o BatchMode=yes beast "bash -s -- $target_dir" <<'REMOTE'
set -euo pipefail
root="$HOME/$1"
shared_prefix="$HOME/pain-ps3/prefix"
if command -v rsync >/dev/null; then
    executable=rsync
elif [[ -x "$shared_prefix/usr/bin/rsync" ]]; then
    executable="$shared_prefix/usr/bin/rsync"
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

copy_deploy_inputs "$root" "beast:$target_dir"
