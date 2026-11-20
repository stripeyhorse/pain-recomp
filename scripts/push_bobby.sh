#!/bin/bash
# Copy prepared workstation inputs to bobby. Build separately with mac_build.sh.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$root/pain-recomp/scripts/levelscript_deploy.sh"
set_deploy_paths "$root"
check_deploy_inputs

# One shared SSH master: the hosts rate-limit fresh connections.
ssh_opts=(-o ControlMaster=auto -o ControlPath=/tmp/cm-%r@%h:%p -o ControlPersist=2h)
ssh "${ssh_opts[@]}" bobby 'mkdir -p ~/pain-ps3/ps3recomp ~/pain-ps3/pain-recomp/prx/generated/full ~/pain-ps3/game/PS3_GAME/USRDIR ~/pain-ps3/hdd0/game/BCES00548/USRDIR'
deploy_rsync() {
    rsync -a -e "ssh ${ssh_opts[*]}" "$@"
}
copy_deploy_inputs "$root" bobby:pain-ps3
