#!/bin/bash
# launch-check.sh APP STATE [RUNS] [PLAY_SECONDS]
#
# A packaged PAIN.app, started the way a player starts it, on a real screen: does the game's window
# open in front, does the launcher leave the Dock while it is open, does the game keep running, and
# does the launcher come back (window in front, Dock icon) when the game quits. Run before a release.
#
#   APP    the packaged PAIN.app
#   STATE  a folder holding selection.json for game data already imported on this Mac
#          (the launcher's own data folder, or a copy: ~/Library/Application Support/PainRecomp)
#
# It needs a logged-in, unlocked desktop. From SSH the launcher cannot reach the screen, so the whole
# check runs inside the desktop session: this script writes a .command file and opens it in Terminal
# (which must already be allowed to read the disk the app is on), then waits for the result. Nothing
# is clicked or typed and no screenshot is taken. The game runs with sound off for PLAY_SECONDS
# (default 20), is asked to quit (SIGTERM, the clean quit) and the launcher is watched for six more.
#
# This catches what a locked screen or an off-screen test cannot: 0.2.21 passed every other check
# and closed the game a second after its window opened, on a Mac whose window manager utility sends
# a quit to apps left without a window.
#
# Exit status 0 when every run passed. The samples of every run are kept in WORK (printed at the end).
set -uo pipefail
if [[ $# -lt 2 ]]; then sed -n '2,20p' "$0" >&2; exit 2; fi
app="$(cd "$1" && pwd -P)"; state="$(cd "$2" && pwd -P)"; runs="${3:-3}"; play="${4:-20}"
[[ -x "$app/Contents/MacOS/PAIN" && -f "$state/selection.json" ]] || { echo "need APP/Contents/MacOS/PAIN and STATE/selection.json" >&2; exit 2; }
if pgrep -x PAIN >/dev/null || pgrep -x PainRecomp >/dev/null; then echo "PAIN is already running" >&2; exit 2; fi
work="${WORK:-$(dirname "$app")/launch-check-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$work"

cat > "$work/windows.js" <<'JS'
ObjC.import("CoreGraphics"); ObjC.import("Foundation");
function run() {   // on-screen windows of normal level, front to back: "<position> <pid> <width>x<height>"
  var l = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo(1, 0))), out = [], pos = 0;
  for (var i = 0; i < l.length; i++) { var w = l[i]; if (w.kCGWindowLayer != 0) continue;
    pos++; out.push(pos + " " + w.kCGWindowOwnerPID + " " + w.kCGWindowBounds.Width + "x" + w.kCGWindowBounds.Height); }
  return out.join("\n");
}
JS

cat > "$work/session.command" <<SESSION
#!/bin/bash
# Written by launch-check.sh; runs inside the desktop session.
work='$work'; app='$app'; state='$state'; runs=$runs; play=$play
SESSION
cat >> "$work/session.command" <<'SESSION'
failed=0
for run in $(seq 1 "$runs"); do
  profile="$work/profile-$run"; out="$work/run-$run.txt"
  rm -rf "$profile"; mkdir -p "$profile"; cp "$state/selection.json" "$profile/"
  printf '[settings]\naudio = off\n' > "$profile/settings.ini"
  PAIN_PREVIEW_DATA_DIR="$profile" "$app/Contents/MacOS/PAIN" --play > "$work/launcher-$run.out" 2>&1 &
  fronted=0; opened=""; quit=""; gone=""; t0=$(date +%s)
  seen=0; game_front=0; launcher_hidden=0; survived=0; back=0
  for i in $(seq 1 240); do
    now=$(( $(date +%s) - t0 ))
    lp=$(pgrep -x PAIN | head -1); gp=$(pgrep -x PainRecomp | head -1)
    fpid=$(lsappinfo info -only pid "$(lsappinfo front)" | sed -n 's/.*pid = \([0-9]*\).*/\1/p')
    ltype=""; [ -n "$lp" ] && ltype=$(lsappinfo info -only ApplicationType "$(lsappinfo find pid=$lp | sed 's/-".*//')" | sed -n 's/.*type="\([^"]*\)".*/\1/p')
    wins=$(osascript -l JavaScript "$work/windows.js" 2>/dev/null | awk -v lp="${lp:-x}" -v gp="${gp:-x}" '
       $2==lp { printf "launcher#%d(%s) ", $1, $3 } $2==gp { printf "game#%d(%s) ", $1, $3 }')
    last=$(grep -a -E "shader-prep|Metal backend init|RSX FPS|\[quit\]|exited with code" "$profile/logs/game.log" 2>/dev/null | tail -1 | cut -c1-100)
    echo "t=${now}s front=${fpid:-?} launcher=${lp:-none}/${ltype:-} game=${gp:-none} windows: ${wins:-none} | $last" >> "$out"
    # The player's double-click brings the launcher forward; a launcher started from a script is not in front.
    if [ $fronted = 0 ] && [ -n "$lp" ] && echo "$wins" | grep -q launcher; then open -a "$app"; fronted=1; fi
    if [ -z "$opened" ] && grep -a -q "Metal backend init OK -- window open" "$profile/logs/game.log" 2>/dev/null; then opened=$now; echo "   -> game window open at ${now}s" >> "$out"; fi
    # Scored from two seconds after the window opened until the quit.
    if [ -n "$opened" ] && [ -z "$quit" ] && [ $((now - opened)) -ge 2 ]; then
      seen=$((seen+1))
      [ -n "$gp" ] && [ "$fpid" = "$gp" ] && game_front=$((game_front+1))
      [ -n "$lp" ] && [ "$ltype" != Foreground ] && launcher_hidden=$((launcher_hidden+1))
    fi
    if [ -n "$opened" ] && [ -z "$quit" ] && [ $((now - opened)) -ge "$play" ]; then
      [ -n "$gp" ] && survived=1 && kill -TERM "$gp"
      quit=$now; echo "   -> game asked to quit at ${now}s" >> "$out"
    fi
    if [ -n "$quit" ] && [ -z "$gp" ] && [ -z "$gone" ]; then gone=$now; echo "   -> game gone at ${now}s" >> "$out"; fi
    if [ -n "$gone" ] && [ $((now - gone)) -ge 6 ]; then
      [ -n "$lp" ] && [ "$ltype" = Foreground ] && [ "$fpid" = "$lp" ] && echo "$wins" | grep -q launcher && back=1
      break
    fi
    if [ -z "$lp" ] && [ "$now" -ge 20 ]; then echo "   -> launcher not running" >> "$out"; break; fi
    sleep 1
  done
  clean=0; grep -a -q "exited with code 0" "$profile/logs/game.log" 2>/dev/null && clean=1
  verdict=PASS
  [ -n "$opened" ] && [ $survived = 1 ] && [ $back = 1 ] && [ $clean = 1 ] && [ $seen -gt 0 ] \
    && [ $game_front = $seen ] && [ $launcher_hidden = $seen ] || { verdict=FAIL; failed=$((failed+1)); }
  if [ -n "$opened" ]; then window="opened at ${opened}s"; else window="never opened"; fi
  echo "run $run: $verdict  window $window; game in front $game_front of $seen s; launcher out of the Dock $launcher_hidden of $seen s; game ran the $play s: $survived; clean exit: $clean; launcher back in front with its Dock icon: $back" | tee -a "$work/result.txt"
  if [ -f "$profile/logs/launcher.log" ]; then sed 's/^/   launcher.log: /' "$profile/logs/launcher.log" >> "$work/result.txt"; fi
  lp=$(pgrep -x PAIN | head -1); [ -n "$lp" ] && kill -TERM "$lp"
  gp=$(pgrep -x PainRecomp | head -1); [ -n "$gp" ] && kill -TERM "$gp"
  sleep 3
done
echo "failed=$failed of $runs" >> "$work/result.txt"
touch "$work/done"
exit 0
SESSION
chmod +x "$work/session.command"
rm -f "$work/done" "$work/result.txt"
open -g -a Terminal "$work/session.command" || { echo "could not open Terminal" >&2; exit 2; }
limit=$(( runs * (play + 150) )); waited=0
until [ -e "$work/done" ] || [ $waited -ge $limit ]; do sleep 2; waited=$((waited+2)); done
[ -e "$work/done" ] || { echo "no result after ${limit}s: is the screen unlocked, and may Terminal read $app?" >&2; exit 2; }
cat "$work/result.txt"
echo "samples: $work/run-*.txt"
grep -q '^failed=0 ' "$work/result.txt"
