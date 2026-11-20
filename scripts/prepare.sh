#!/bin/bash
# prepare.sh -- make a RAW game dump runnable. Idempotent; run before launching.
# Works from the raw retail files: the encrypted EBOOT.BIN and the disc's
# CacheDesc.dat + CacheData.pak. No pre-processed artifacts are required.
#
# Env overrides:
#   GAME_DIR   path to the dump's PS3_GAME (default: derived, ../game/.../PS3_GAME)
#   HDD0_ROOT  writable cache root (default: <workspace>/hdd0)
#   RPCS3_BIN  path to an rpcs3 binary/AppImage used only for EBOOT decryption
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

GAME_DIR="${GAME_DIR:-}"
if [ -z "$GAME_DIR" ]; then
    U="$(find "$ROOT/game" -maxdepth 4 -type d -name USRDIR 2>/dev/null | head -1)"
    [ -n "$U" ] && GAME_DIR="$(dirname "$U")"
fi
HDD0_ROOT="${HDD0_ROOT:-$ROOT/hdd0}"
USRDIR="$GAME_DIR/USRDIR"
TITLE_ID="BCES00548"

[ -d "$USRDIR" ] || { echo "FATAL: no game USRDIR at $USRDIR"; exit 1; }

# --- 1. the executable: raw EBOOT.BIN -> EBOOT.elf ---------------------------
if [ ! -f "$USRDIR/EBOOT.elf" ]; then
    if [ ! -f "$USRDIR/EBOOT.BIN" ]; then
        echo "FATAL: neither EBOOT.elf nor EBOOT.BIN in $USRDIR"
        exit 1
    fi
    RPCS3="${RPCS3_BIN:-}"
    if [ -z "$RPCS3" ]; then
        for c in /tmp/opencode/squashfs-root/AppRun /tmp/opencode/rpcs3.AppImage \
                 "$HOME/Applications/rpcs3.app/Contents/MacOS/rpcs3" \
                 /Applications/rpcs3.app/Contents/MacOS/rpcs3; do
            [ -x "$c" ] && RPCS3="$c" && break
        done
    fi
    if [ -n "$RPCS3" ]; then
        echo "== decrypting EBOOT.BIN with $RPCS3 (writes EBOOT.elf beside it)"
        QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}" "$RPCS3" --decrypt "$USRDIR/EBOOT.BIN" || exit 1
    else
        echo "FATAL: raw EBOOT.BIN present but no EBOOT.elf and no rpcs3 found."
        echo "  Decrypt your own dump once (rpcs3 --decrypt <EBOOT.BIN>) and rerun,"
        echo "  or point RPCS3_BIN at an rpcs3 binary/AppImage."
        exit 1
    fi
fi
[ -f "$USRDIR/EBOOT.elf" ] || { echo "FATAL: decryption did not produce EBOOT.elf"; exit 1; }

# --- 2. the HDD cache: raw CacheDesc.dat + CacheData.pak -> 8,044 loose files --
MARKER="$HDD0_ROOT/game/$TITLE_ID/USRDIR/CacheFlags/CacheDone.flg"
if [ ! -f "$MARKER" ]; then
    echo "== pre-seeding the game-data cache from the raw pak (idempotent)"
    python3 "$HERE/scripts/extract_cache.py" \
        "$USRDIR/CacheDesc.dat" "$USRDIR/CacheData.pak" \
        "$HDD0_ROOT/game/$TITLE_ID" || exit 1
else
    echo "== HDD cache present ($(find "$HDD0_ROOT/game/$TITLE_ID/USRDIR" -type f | wc -l | tr -d ' ') files)"
fi

echo "PREPARE_OK"
echo "  EBOOT:  $USRDIR/EBOOT.elf"
echo "  HDD0:   $HDD0_ROOT"
