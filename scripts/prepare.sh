#!/bin/bash
# Prepare an owned raw disc dump. Retail EBOOT.BIN and the two cache files
# are sufficient. This prepares data only. See prepare_deploy.sh for lifts.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
root="$(cd "$here/.." && pwd)"
game_dir="${GAME_DIR:-}"
if [[ -z "$game_dir" ]]; then
    for candidate in "$root/game/Pain_BCES00548/Pain BCES00548/PS3_GAME" "$root/game/PS3_GAME"; do
        if [[ -d "$candidate/USRDIR" ]]; then
            game_dir="$candidate"
            break
        fi
    done
fi
hdd_root="${HDD0_ROOT:-$root/hdd0}"
usrdir="$game_dir/USRDIR"
elf="$usrdir/EBOOT.elf"
[[ -n "$game_dir" && -d "$usrdir" ]] || {
    echo "No disc USRDIR found. Set GAME_DIR to the dump's PS3_GAME directory." >&2
    exit 1
}

is_elf() {
    [[ -s "$1" && "$(od -An -tx1 -N4 "$1" | tr -d '[:space:]')" == 7f454c46 ]]
}

if ! is_elf "$elf"; then
    [[ -s "$usrdir/EBOOT.BIN" ]] || {
        echo "No valid EBOOT.elf or raw EBOOT.BIN in $usrdir" >&2
        exit 1
    }
    rpcs3="${RPCS3_BIN:-}"
    if [[ -z "$rpcs3" ]]; then
        rpcs3="$(command -v rpcs3 || true)"
    fi
    if [[ -z "$rpcs3" ]]; then
        for candidate in "$HOME/Applications/rpcs3.app/Contents/MacOS/rpcs3" \
                         /Applications/rpcs3.app/Contents/MacOS/rpcs3; do
            if [[ -x "$candidate" ]]; then
                rpcs3="$candidate"
                break
            fi
        done
    fi
    if [[ -z "$rpcs3" ]] || ! command -v "$rpcs3" >/dev/null 2>&1; then
        printf 'Set RPCS3_BIN to an executable RPCS3 binary/AppImage, or run:\n  rpcs3 --decrypt "%s"\nThen run prepare.sh again.\n' "$usrdir/EBOOT.BIN" >&2
        exit 1
    fi
    scratch="$(mktemp -d "$usrdir/.decrypt.XXXXXX")"
    trap 'rm -rf "$scratch"' EXIT
    # RPCS3 writes beside its input. Publish the result only after checking it.
    cp "$usrdir/EBOOT.BIN" "$scratch/EBOOT.BIN"
    echo "Decrypting EBOOT.BIN with $rpcs3"
    QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}" \
        APPIMAGE_EXTRACT_AND_RUN="${APPIMAGE_EXTRACT_AND_RUN:-1}" \
        "$rpcs3" --decrypt "$scratch/EBOOT.BIN"
    is_elf "$scratch/EBOOT.elf" || {
        echo "RPCS3 did not produce a valid EBOOT.elf" >&2
        exit 1
    }
    mv "$scratch/EBOOT.elf" "$elf"
fi

install_root="$hdd_root/game/BCES00548"
marker="$install_root/USRDIR/CacheFlags/CacheDone.flg"
if [[ ! -s "$marker" ]]; then
    echo "Extracting the HDD cache from the disc"
    "${PYTHON3:-python3}" "$here/scripts/extract_cache.py" \
        "$usrdir/CacheDesc.dat" "$usrdir/CacheData.pak" "$install_root"
else
    echo "HDD cache present"
fi

printf 'PREPARE_OK\n  EBOOT:  %s\n  HDD0:   %s\n' "$elf" "$hdd_root"
