#!/usr/bin/env python3
"""Headless Crash Course frame-rate check (Linux, null renderer).

  scripts/headless_course_fps.py EXE STAGE_DIR [--min-fps N] [--from S] [--to S] [--root DIR]

Boots EXE against the disc in <root>/game and the hdd0 in <root>/hdd0, drives the
menus into Crash Course with PAD_FILE presses on a timer (the null renderer prints
no capture lines to react to), and counts guest flips from S seconds after the
level module starts (sys_prx_start_module) to T seconds after (default 40..80, past
the launch sequence, which is CPU-bound and slow headless in every build).
Prints one line and exits 0 if the rate is at least --min-fps (default 5), 1 if it
is lower or the level never started, 2 on a usage error. The log is
STAGE_DIR/game.log; STAGE_DIR must not exist.

A crawl in the level does not stop flips altogether, so "still flipping" is not a
pass: before PS3_NULLSW_LAZY_TEX, Crash Course ran at 3-5 FPS headless here
(every texture bind decoded on the FIFO walker) and the older driver's
verdict=ok hid it. From +40 to +80 s on this box (Debian, 12 cores, two runs at
once): 14-21 FPS with the lazy decode, 0-0.5 without; 16-19 with PS3_NULLSW_RASTER=0.

The input schedule is the havok-stall package's course_linux.py.
"""
import argparse, os, pathlib, re, selectors, subprocess, sys, time

ap = argparse.ArgumentParser()
ap.add_argument("exe"); ap.add_argument("stage")
ap.add_argument("--min-fps", type=float, default=5.0)
ap.add_argument("--from", dest="t_from", type=float, default=40.0)
ap.add_argument("--to", dest="t_to", type=float, default=80.0)
ap.add_argument("--root", default=str(pathlib.Path(__file__).resolve().parents[2]))
ap.add_argument("--boot-timeout", type=float, default=150.0)
a = ap.parse_args()
if a.t_to <= a.t_from:
    print("--to must be after --from", file=sys.stderr); sys.exit(2)

root = pathlib.Path(a.root)
game = root / "game/Pain_BCES00548/Pain BCES00548/PS3_GAME"
if not (game / "USRDIR/EBOOT.elf").exists():
    print(f"no disc at {game} (use --root)", file=sys.stderr); sys.exit(2)
# Absolute: the game runs with cwd=stage and gets these paths in its environment.
exe = pathlib.Path(a.exe).resolve()
stage = pathlib.Path(a.stage).resolve(); stage.mkdir(parents=True, exist_ok=False)
pad = stage / "pad"; pad.write_text(""); (stage / "hdd1").mkdir()
env = dict(os.environ,
           PS3_HDD0_ROOT=str(root / "hdd0"), PS3_HDD1_ROOT=str(stage / "hdd1"),
           PS3_GAMEDATA_ROOT=str(stage / "gamedata"), PAIN_SETTINGS_PATH=str(stage / "settings.ini"),
           PAD_FILE=str(pad), PAD_SCRIPT="33:0x4000,42:0x0008,53:0x4000,70:0x4000",
           GCM_FLIPCOUNT="1", PS3_VERBOSE="0")
proc = subprocess.Popen([str(exe), str(game / "USRDIR/EBOOT.elf")], cwd=stage, env=env,
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
sel = selectors.DefaultSelector(); sel.register(proc.stdout, selectors.EVENT_READ)

def press(mask, reports=1):
    tmp = stage / "next-pad"; tmp.write_text(f"{mask} {reports}\n"); tmp.replace(pad)

flip_re = re.compile(r"^\[flip\] (\d+) at")
t0 = time.monotonic(); buf = b""
course_t = prx_t = None; course_steps = 0; next_input = 0.0; continued = False
flips = []                      # (t, flip number); GCM_FLIPCOUNT logs every 10th after 400
with (stage / "game.log").open("w") as log:
    try:
        while proc.poll() is None:
            now = time.monotonic() - t0
            if prx_t is None and now > a.boot_timeout: break
            if prx_t is not None and now > prx_t + a.t_to + 1: break
            if course_t is not None and not pad.stat().st_size and now >= next_input:
                if course_steps < 5:
                    press("0x0040" if course_steps < 4 else "0x4000")
                    course_steps += 1; next_input = now + .52
                elif prx_t is None and now - course_t > 85:
                    press("0x4000"); next_input = now + 15
            if prx_t is not None and now - prx_t > 7 and not continued and not pad.stat().st_size:
                press("0x4000", 4); continued = True; next_input = now + 6
            if continued and now >= next_input and not pad.stat().st_size:
                press("0x4000", 4); next_input = now + 3
            for key, _ in sel.select(.1):
                chunk = os.read(key.fd, 65536)
                if not chunk: break
                buf += chunk
                rows = buf.split(b"\n"); buf = rows.pop()
                for b in rows:
                    line = b.decode(errors="replace")
                    log.write(f"{now:7.2f} {line}\n")
                    m = flip_re.match(line)
                    if m: flips.append((now, int(m.group(1))))
                    if "PAD_SCRIPT t=70.0s" in line and course_t is None:
                        course_t = now + 5; next_input = course_t
                    if "sys_prx_start_module" in line and prx_t is None:
                        prx_t = now
    finally:
        if proc.poll() is None: proc.kill()
        proc.wait()

if prx_t is None:
    print(f"FAIL level never started (flips={flips[-1][1] if flips else 0}) log={stage}/game.log")
    sys.exit(1)
lo, hi = prx_t + a.t_from, prx_t + a.t_to
before = [n for t, n in flips if t < lo]; inside = [n for t, n in flips if lo <= t < hi]
n = (inside[-1] - (before[-1] if before else 0)) if inside else 0
fps = n / (a.t_to - a.t_from)
ok = fps >= a.min_fps
print(f"{'PASS' if ok else 'FAIL'} fps={fps:.2f} (flips {n} from +{a.t_from:.0f} to +{a.t_to:.0f} s "
      f"after the level start at {prx_t:.1f} s; min {a.min_fps}) log={stage}/game.log")
sys.exit(0 if ok else 1)
