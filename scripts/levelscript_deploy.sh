# Sourced by the deploy scripts. Keep the catalogue preflight local.
prepare_deploy_catalog() {
    local port="$1" usrdir="$2"
    local catalog="$port/prx/generated/full"
    if [[ ! -e "$catalog" && -n "${RPCS3_BIN:-}" ]]; then
        python3 "$port/scripts/prepare_levelscripts.py" "$usrdir" --rpcs3 "$RPCS3_BIN" || return
    fi
    python3 "$port/scripts/prepare_levelscripts.py" "$usrdir" --check-full
}

# Ship the inputs the remote builds and the running game need. Decryption
# work files, probe logs and tutorial-only outputs stay at the source.
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
