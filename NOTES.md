# Pain (PS3, BCES00548) — native port log

Target: **Pain** (Idol Minds / SCEE, 2007–2010, disc release **BCES00548**, game version **01.00**, SDK-era ~2.60).
Approach: static recompilation with [ps3recomp](https://github.com/sp00nznet/ps3recomp) — same method as
[inFAMOUSreborn](https://github.com/whompay/inFAMOUSreborn). Platforms: **macOS (Apple Silicon, Metal)** first,
PS5 later. This repo contains no game data; everything generated is rebuilt from the owner's own dump.

## Machine fleet

| Machine | Role | Notes |
|---|---|---|
| `debian` (local) | analysis, lifting, builds | 12 cores, GCC 14.2, Python 3.15, null backend |
| `beast` (ssh `beast`, 192.168.1.54) | heavy builds, RPCS3 reference, Vulkan backend | Debian 13, 20 cores, 31 GB, GTX 1080 Ti (driver 550) |
| `bobby` (ssh `bobby`, 192.168.1.117) | final target platform | Apple Silicon Mac (Metal backend, arm64) |
| `unraid` (ssh `unraid`, root@192.168.1.10) | game source | `Pain_BCES00548.zip` in `/mnt/user/ROMS/` |

## Ground truth: the decrypted ELF

- `EBOOT.elf`: ELF 64-bit MSB, PPC64, Cell LV2, statically linked, stripped. 14,142,368 bytes.
- sha256 `411d00aa3809706376bc8fe55e309844310e37e69152bdbb15627be5833fe40b`
- entry OPD 0xbb7a20 → code 0x10230, entry TOC 0xbfd2c8; module TOC (r2) 0xc0d1f8
- 2 load segments: code 0x10000 (11.4 MB), data+bss 0xb80000 (bss 14.2 MB)
- Decrypted from the retail `EBOOT.BIN` with `rpcs3 --decrypt` (v0.0.43 AppImage, works headless with
  `QT_QPA_PLATFORM=offscreen`; no firmware needed for the decrypt utility).

## PPU analysis (ppu_loader.py)

- OPD descriptors: 31,511 → **25,475 unique functions**
- Firmware imports: **418 across 31 libraries** (369 named, 88%)
- Biggest: cellSysutil 39, sceNp 38, cellGcmSys 36, sysPrxForUser 33

### Embedded SPU images (extract_spu_images.py) — identified via strings

All three link `libspurs` → they are **SPURS job modules**, and the big two are **Havok**:

| Image | Offset | Size | Identity |
|---|---|---|---|
| spu_0000 | 0x00B48980 | 2.8 KB | tiny Idol Minds helper task (dev path `/home/kanee/svnwork/ps3-svn/`, `.SpuGUID`) |
| spu_0001 | 0x00C24400 | 145 KB | **`hkspurscollide_spu_gcc_release`** — Havok collision narrow-phase (TtNarrowPhase, LtBvTree3) |
| spu_0002 | 0x00C47B00 | 90.8 KB | **`hkspursintegrate_spu_gcc_release`** — Havok integrator/solver (StIntegrate, TtIntVel/TtSolve/TtExport) |

Lifted to `spu/` via `tools/build_spu_workloads.py`: 898 functions, 102 call targets,
3 fingerprint-registered images (constructor `spu_register_all`); 42 `.word` data-in-code
fallbacks go through the interpreter. If the game streams different copies (e.g. from
CacheData.pak), the fingerprint misses and the interpreter catches them — collect with
`SPU_DUMP_MISS=<dir>` and lift then.

### Module risk read (vs ps3recomp MODULE_STATUS)

- ✅ Solid: cellGcmSys, cellSpurs, cellAudio, cellFont, cellResc, sys_fs, sys_net, sys_io,
  cellRtc, cellSync, sceNp(+Commerce2), cellGame, cellNetCtl, cellOskExtUtility, cellHttp(Ssl),
  cellSysmodule, cellFontFT, cellVideoExportUtility, cellVideoUpload.
- ⚠️ cellSail (26) — full Player + Graphics/Sound Adapter set; likely the attract-movie path
  (`USRDIR/Movies/PAIN_ATTRACT_MOVIE.mp4`, plain H.264 MP4). ps3recomp cellSail lifecycle is
  complete but playback is "immediate finish" → intro skips, doesn't crash. Real playback later
  via the runtime FFmpeg loader (cellVdec/cellDmux/cellAdec route).
- ⚠️ Dead online-era features to stub offline: cellVoice (17, mic chat), cellRec (5, video
  recording), cellMusicUtility (8) + cellSearchUtility (9, in-game custom soundtracks).
- ❓ `LevelScriptExport` (10 imports, **all NIDs unknown** to ps3recomp and public NID DBs) —
  unknown library, possibly the game's own cross-PRX scripting API (dev-kit leftover?) or
  resolved by a runtime-loaded module. Pain runs in RPCS3 without it being known, so likely
  never called; the recomp's missing-NID log will tell us. Watch at first boot.
- Unnamed NIDs to resolve later: 49 across cellSysutil(11), cellVoice(4), sys_net(4),
  cellSearchUtility(3), cellOskExtUtility(5), cellVideoExportUtility(3), cellMusicUtility(2),
  cellHttp(5), LevelScriptExport(10), cellRtc(1), cellVideoUpload(1).

### Game-side quirks

- `USRDIR/Config.txt`: `EnableAdServer` + `EnableNP` lines — the game phones home for its
  in-game dynamic advertising (famous Pain feature) and NP login. Offline-first port: ads →
  "no ads", NP → offline answers (sceNp HLE already does this), or psnr later.
- `USRDIR/edats/`: 16–20 byte NPDRM entitlement stubs (`AsianSchoolGirl.EDAT`,
  `BrockLee.EDAT`, `Bowling_2P.EDAT`, `Area51FreePlay*.EDAT` …) = on-disc DLC unlock tokens
  → answer "owned" via the entitlement HLE, no crypto needed.
- `USRDIR/CacheData.pak` (1.01 GB) + `CacheDesc.dat`: the bulk of game assets.
- RPCS3 rates Pain **Playable**; known RPCS3 bug: freeze after ~15 min (emulator issue #12996,
  not a game bug). RPCS3 remains the behavioural reference.
- EBOOT has NO .sprx files in USRDIR → LevelScriptExport, if real, comes from somewhere else.

## Pipeline (reproducible)

```bash
# 0. decrypt (once, from your own dump)
QT_QPA_PLATFORM=offscreen <rpcs3> --decrypt <PS3_GAME/USRDIR/EBOOT.BIN>   # writes EBOOT.elf beside it

# 1. stage-1 analysis
python tools/ppu_loader.py <EBOOT.elf> -o ../pain-recomp/analysis/
python tools/gen_imports.py <EBOOT.elf> -o ../pain-recomp/analysis/imports_named.json
python tools/extract_spu_images.py <EBOOT.elf> --output ../pain-recomp/spu-images/

# 2. lift (the long one; --jobs = cores)
python tools/ppu_lifter.py <EBOOT.elf> \
    --functions ../pain-recomp/analysis/EBOOT.functions.json \
    --hle-stubs  ../pain-recomp/analysis/EBOOT.imports.json \
    --output ../pain-recomp/recompiled --jobs 12

# 3. HLE handler table
python tools/gen_hle_nids.py --all --out ../pain-recomp/recompiled/ppu_hle_nids.cpp

# 4. build
cd ../pain-recomp && cmake -B build -G Ninja -DPS3RECOMP_DIR=<ps3recomp> && cmake --build build

# 5. run (null backend first on this box; Metal on bobby; Vulkan on beast)
PS3_VFS_ROOT=<dir-with-game-files> ./build/PainRecomp <EBOOT.elf>
```

## Bring-up log

### Boot 1 (first link): clean CRT → engine init → r2=0 cascade → `sys_process_exit(1)`

The game boots: CRT, TLS, argv (`/dev_bdvd/PS3_GAME/USRDIR/EBOOT.BIN`), RSX null
backend init at 1280x720, then a static-ctor walker (`0xC7F60`, 548-entry list at
`0xB80894`) correctly dispatches ~313 module-registrar ctors with r2=0xC0D1F8.
Deep in ctor #314's subtree (`0x4A9640`, a module-block init gate using
`sys_ppu_thread_get_id` + `sys_lwmutex_lock`), r2 silently becomes 0 and every
TOC-relative load cascades into null-page accesses until the game bails.

**Root cause (found via PPU_TOCWATCH/PS3_CALLTRACE instrumentation added locally):
the title's toolchain emits the ELFv1 TOC restore `ld r2, 40(r1)` after EVERY `bl`**
(50,988 sites in the lifted code). On hardware the callee's glink/PLT stub saves
the caller's r2 into the ABI-reserved slot at sp+0x28 before jumping; the lifted
direct call bypasses that stub, so each restore reads stale stack garbage —
stack roulette that 313 ctors won and #314 lost.

**Fix:** `ppu_lifter.py` now emits `vm_write64(ctx->gpr[1]+0x28, ctx->gpr[2])`
before every direct `bl` call — exactly the glink save (patch in
`patches/ps3recomp-local.patch`, applied to the vendored toolkit).

Also observed, not yet fixed: one indirect call through a game import-table slot
landed on an HLE-inject OPD (`0x20000028`, opd[0]=0) and was dropped by the
null-call handler — symptom of the poisoned chain; revisit if it survives the TOC fix.

Local runtime diagnostics added (all upstreamable): r2 in null-page reports,
`PPU_TOCWATCH` on POSIX, r2 in the `[CALL]` indirect-call trace.

### Boot 3 (title-ID fix + pre-seed): INSTALL GATE PASSED — game runsRoot cause of the whole install saga (sol 6.2 xhigh report): our port's cellGame
reported the placeholder title ID `BLES00000` because `main.cpp` never called
`cellGame_init_from_paramsfo` — so Pain never activated its disc SKU
(`EP9000-BCES00548_00`), took a wrong game-data path, and fell into the
installer, whose SPURS-side consumer never acked (writer never opened an HDD
file; the 4x8MB pak reads = the producer's ring filling).

The real gate is a plain `cellFsStat` on `<USRDIR>/CacheFlags/CacheDone.flg`
(existence only; the installed tree it certifies is 8,044 LOOSE files — the
loader has no archive fallback, so flag-only bypass would break menus).

**Fix (both parts applied):**
1. `main.cpp` now calls `cellGame_init_from_paramsfo(<disc>/PS3_GAME/PARAM.SFO)`
   after deriving the VFS root.
2. `scripts/extract_cache.py` pre-seeds the cache offline: CacheDesc.dat is a
   manifest of 8,044 records (BE u32 size + 252-byte path), payloads are
   contiguous uncompressed slices of CacheData.pak; extracted into
   `$PS3_HDD0_ROOT/game/BCES00548/USRDIR/` + the 5-byte `Flag\0` marker.
   1,061,512,652 bytes extracted, byte-exact against the pak.

**Evidence it works (local, run9):** `Activating SKU EP9000-BCES00548_00`,
`All blu-ray files are cached`, then HDD opens of real assets — ICON0/PIC1,
`Image/bin/shaders/*.vbin/.fbin` (the game's GPU shader programs), UI/Effects
shaders — and a steady multi-thread idle (audio mixer cadence).

**bobby (Apple M2, Metal):** pre-seed extracted locally (byte-exact), port
rebuilt, **running**: `[RSX metal] windowed on Apple M2 (1280x720)`, SKU
activated, gate passed, register-file draw engine executing the game's draw
commands at ~125% CPU. Last mile: every draw was dropped with `guest shaders
off (translator not built)` — `scripts/mac_shaders.sh` builds glslang +
SPIRV-Cross from source into `~/pain-ps3/prefix` (no sudo) and rebuilds with
MSL translation on.

Firmware (for the optional RPCS3 reference): PS3 4.91 PUP fetched from
archive.org's preservation mirror (sha1 6c5e520b64cd39d28edc19e0f1a5c3e04d0c3d8a,
206,187,676 bytes) — Sony's own update CDN domain no longer resolves from any
of the local machines or the VPSes.

### Boot 4 (guest shaders on): PAIN RUNS AND DRAWS ON BOBBY

`scripts/mac_shaders.sh` built glslang 16.6.0 (ENABLE_OPT=0) + SPIRV-Cross
from source into `~/pain-ps3/prefix` (sudo-free) and reconfigured the build:
`Shaders: guest programs translated to MSL`. Relaunch via `scripts/mac_run.sh`:

```
[RSX metal] windowed on Apple M2 (1280x720), guest shaders on
All blu-ray files are cached
[rsx engine] pipeline ... guest vp 6, fp 27, ... -> ok   (7 compiled, 0 drops)
ps: PainRecomp at ~135% CPU, sustained live loop
```

The title's own vertex/fragment programs compile and draw every frame on the
M2's GPU through the register-file draw engine (880 draws per frame across 3
surfaces by frame 15,120, ~23 presents per second).

### Visual verification (independent vision agent, frame 15120)

A vision-capable agent read the captured frame and confirmed, high confidence:
a **correctly rendered PSN "SUPPLEMENTAL TERMS" consent screen** — muted
background, left-aligned bold condensed text (verbatim legible: "PlayStation®Network
Europe Limited wants your on-line gaming experience..."), a thin scrollbar with a
yellow handle, ✕-Accept (bottom left, pale-blue cross icon) and ○-Decline
(bottom right, coral-red circle icon). No corruption, no missing textures.

So the ~23fps render loop was never stuck: **the game is waiting on the first-boot
PSN EULA consent — a user input, by design.** Press ✕ (cross, or the X key via the
cellPad keyboard fallback) to Accept and the game advances to its main menu.
Render pipeline proven end to end: RSX → register-file draw engine → Metal →
the title's own guest shaders → readable styled UI text.

### Boot 2 (TOC fix): full boot → install flow → SPURS consumer stall

Zero null-page events after the lifter fix. Boot: cellGame ContentPermit ✓,
mount ✓, cellPad ✓, GCM reports ✓, all 548 ctor-walker entries ✓, SPURS
workloads churn with the embedded policy module.

**The game reaches its mandatory first-boot HDD install** ("Pain will install
game data to the HDD", 1.01 GB CacheData.pak → cache). It read exactly 4×8 MB
pak chunks (~32 MB, matching its frozen "ReadWait 34188" counter) and then
stalled: the pak reader is a producer whose consumer never acks — no
/dev_hdd0 file was ever opened by the writer thread. SPURS PM (wid 0/1)
resolves and runs (image 201) but the install jobs never progress. One
flaky assert in the game's own jobapi: joblist.cpp(157): 0 == ret (after
WaitForWorkloadShutdown; did not reproduce under tracing).

Failed opens are all EXPECTED misses: 14 hashed ad-asset files + 2 ad-spaces
under `USRDIR/Ads/defaultDirectory/01/` (Pain's dynamic in-game ad system;
content only ever existed on the dead ad server) and optional
`autorun.txt`/`RunConfig.txt`. The ad writer's open-for-write onto the disc
path is also tolerated by the game.

**Open investigation (sol 6.2 xhigh)**: skip the install check via a title
hack vs pre-seed the installed state (reference from an RPCS3 run — blocked
on firmware PUP: Sony's CDN unreachable from this network; need the user's
PS3UPDAT.PUP).

The SPURS policy module (guest 0xB70B80, 12,160 B, FNV 0xAB4C8373E9204A03)
is lifted at base 0xA00 (its first 4 words are executable `ila` magic no-ops;
real prologue at +0x10) and registered by fingerprint in `spu/pm_reg.c`
(image 201) — cellSpurs resolves it: `wid=0 PM resolved`.

- [x] Dump acquired from Unraid, unzipped, retail structure verified (PARAM.SFO: PAIN, BCES00548, 01.00)
- [x] EBOOT decrypted (RPCS3 CLI)
- [x] Stage-1 PPU analysis: 25,475 functions / 418 imports / 31 libs
- [x] SPU images extracted (3) and identified (Havok SPURS collide+integrate) + lifted (898 funcs)
- [x] PPU lift → C++ (37,534 functions, 110 chunks, 1.3 GB)
- [x] First link + CRT boot (null backend) — boots, then r2=0 cascade (root cause found + fixed: glink TOC save; rebuild in flight)
- [ ] Re-lift + boot past the ctor list into game init
- [ ] First frames (Vulkan on beast / Metal on bobby)
- [ ] Menus → in-game bring-up loop
- [ ] LevelScript.sprx pipeline: decrypt + lift the 91 level PRXs, bind LevelScriptExport
- [ ] macOS .app packaging (bobby)
- [ ] PS5 exploration (later; needs homebrew toolchain + jailbroken console)

## Status
