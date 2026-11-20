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

### Embedded SPU images (extract_spu_images.py)

| Image | Offset | Size | Guess |
|---|---|---|---|
| spu_0000 | 0x00B48980 | 2.8 KB | ? (tiny — maybe a stub/loader) |
| spu_0001 | 0x00C24400 | 145 KB | SPURS policy module or physics job |
| spu_0002 | 0x00C47B00 | 90.8 KB | second job module |

Expect more SPURS job modules streamed at runtime → collect with `SPU_DUMP_MISS=<dir>`,
lift with `tools/lift_jobmods.py`.

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

## Status

- [x] Dump acquired from Unraid, unzipped, retail structure verified (PARAM.SFO: PAIN, BCES00548, 01.00)
- [x] EBOOT decrypted (RPCS3 CLI)
- [x] Stage-1 PPU analysis: 25,475 functions / 418 imports / 31 libs
- [x] SPU images extracted (3)
- [ ] PPU lift → C++
- [ ] SPU lift + workload registration
- [ ] First link + CRT boot (null backend)
- [ ] First frames (Vulkan on beast / Metal on bobby)
- [ ] Menus → in-game bring-up loop
- [ ] macOS .app packaging (bobby)
- [ ] PS5 exploration (later; needs homebrew toolchain + jailbroken console)
