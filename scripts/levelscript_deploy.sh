# Shared workstation preflight and rsync inputs for both deploy scripts.
set_deploy_paths() {
    deploy_port="$1/pain-recomp"
    deploy_game="${GAME_DIR:-$1/game/Pain_BCES00548/Pain BCES00548/PS3_GAME}"
    deploy_hdd="${HDD0_ROOT:-$1/hdd0}"
    deploy_cache="$deploy_hdd/game/BCES00548/USRDIR"
    deploy_catalog="$deploy_port/prx/generated/full"
}

check_deploy_inputs() {
    local input chunk expected_hash actual_hash
    for input in "$deploy_game/PARAM.SFO" "$deploy_game/USRDIR/EBOOT.elf" \
        "$deploy_cache/CacheFlags/CacheDone.flg" "$deploy_catalog/catalog.inc" \
        "$deploy_port/recompiled/ppu_recomp.h" "$deploy_port/recompiled/ppu_hle_nids.cpp" \
        "$deploy_port/recompiled/prepared/wrapped_sources.txt" "$deploy_port/spu/pm_reg.c" \
        "$deploy_port/spu/jobmods_register.c"; do
        if [[ ! -s "$input" ]]; then
            printf 'Missing %s. Prepare the build inputs on the workstation first.\n' "$input" >&2
            return 1
        fi
    done
    while read -r chunk expected_hash; do
        if [[ ! -s "$deploy_port/recompiled/prepared/wrapped_$chunk" ]]; then
            printf 'Missing prepared PPU source for %s. Run prepare_deploy.sh on the workstation.\n' "$chunk" >&2
            return 1
        fi
        actual_hash="$(shasum -a 256 < "$deploy_port/recompiled/$chunk")" || return
        if [[ "${actual_hash%% *}" != "$expected_hash" ]]; then
            printf 'Stale prepared PPU source for %s. Run prepare_deploy.sh on the workstation.\n' "$chunk" >&2
            return 1
        fi
    done < "$deploy_port/recompiled/prepared/wrapped_sources.txt"
    "${PYTHON3:-python3}" "$deploy_port/scripts/extract_cache.py" \
        --verify "$deploy_game/USRDIR/CacheDesc.dat" "$deploy_hdd/game/BCES00548" || return
    "${PYTHON3:-python3}" "$deploy_port/scripts/prepare_levelscripts.py" \
        "$deploy_game/USRDIR" --check-full
}

# Copy only the build sources and runtime images. Work files and probe logs
# stay on the workstation.
deploy_catalog_filters=(
    --include=/catalog.inc
    --include=/lift/
    --include='/lift/*/'
    --include='/lift/*/*.cpp'
    --include='/lift/*/*.h'
    --include=/modules/
    --include='/modules/*/'
    --include='/modules/*/*_image.bin'
    --exclude='*'
)

deploy_port_filters=(
    --exclude=.git
    --exclude=__pycache__
    --exclude=/build/
    --exclude=/analysis/
    --exclude=/recompiled/
    --exclude=/screenshots/
    --exclude=/spu-images/
    --exclude=/spu-jobmods/
    --exclude=/spu-miss/
    --exclude=/gamedata/
    --exclude=/settings.ini
    --exclude='/run*.log'
    --exclude=/prx/generated/
)

copy_deploy_inputs() {
    local workspace="$1" destination="$2"
    deploy_rsync --delete --exclude=.git --exclude=.venv --exclude=build --exclude=__pycache__ \
        "$workspace/ps3recomp/" "$destination/ps3recomp/"
    deploy_rsync "${deploy_port_filters[@]}" "$deploy_port/" "$destination/pain-recomp/"
    deploy_rsync --delete "$deploy_port/recompiled/" "$destination/pain-recomp/recompiled/"
    deploy_rsync --delete "${deploy_catalog_filters[@]}" \
        "$deploy_catalog/" "$destination/pain-recomp/prx/generated/full/"
    deploy_rsync --exclude=/USRDIR "$deploy_game/" "$destination/game/PS3_GAME/"
    deploy_rsync "$deploy_game/USRDIR/" "$destination/game/PS3_GAME/USRDIR/"
    # Withdraw the target's marker before refreshing payloads, so an interrupted
    # repeat copy cannot leave the old marker in front of a partial cache.
    local empty
    empty="$(mktemp -d)" || return
    deploy_rsync --delete "$empty/" "$destination/hdd0/game/BCES00548/USRDIR/CacheFlags/"
    rmdir "$empty"
    deploy_rsync --exclude=/CacheFlags/CacheDone.flg "$deploy_cache/" "$destination/hdd0/game/BCES00548/USRDIR/"
    deploy_rsync "$deploy_cache/CacheFlags/CacheDone.flg" "$destination/hdd0/game/BCES00548/USRDIR/CacheFlags/"
    if [[ -f "$deploy_game/../PS3_DISC.SFB" ]]; then
        deploy_rsync "$deploy_game/../PS3_DISC.SFB" "$destination/game/"
    fi
}
