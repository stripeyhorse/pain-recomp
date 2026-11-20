# PainRecomp — Pain (PS3) as a native program

A native port of **Pain** (Idol Minds / SCEE, 2007; disc release **BCES00548**,
game version 1.00) built with [ps3recomp](https://github.com/sp00nznet/ps3recomp):
the game's PowerPC (PPU) and SPU code is statically recompiled to C++ and linked
against a clean-room reimplementation of the PS3's system libraries. It is the
game's own code running as a normal program — no emulator.

**Status:** boots, passes its first-boot cache gate, loads its frontend assets
and renders them with the game's own shaders. Verified running on **macOS
arm64 (Apple M2, Metal)** at a sustained ~23 fps present rate, and headless on
Linux x86-64 (null backend). Navigation/input bring-up is the current frontier.

This repository contains **no game code or data**. You build from your own
legally obtained dump; the pipeline regenerates everything.

## What is where

| Path | Contents |
|---|---|
| `main.cpp`, `stubs.cpp` | port glue: boot order, VFS, game-specific HLE overrides |
| `spu/pm_reg.c` | registers the SPURS policy module by content fingerprint |
| `scripts/extract_cache.py` | offline pre-seed: the 8,044-file HDD cache from the disc's own manifest |
| `scripts/push_bobby.sh`, `mac_build.sh`, `mac_shaders.sh`, `mac_run.sh` | deploy to an Apple Silicon Mac (sudo-free: pip cmake/ninja, source-built SDL2/glslang/SPIRV-Cross) |
| `scripts/first_run.sh` | local headless run |
| `patches/upstream/` | the five upstreamable ps3recomp fixes this port earned (with cover notes) |
| `NOTES.md` | the full bring-up log: every root cause and its evidence |

Frame captures (`PS3RECOMP_METAL_FRAME_DUMP`) are intentionally not distributed:
they contain the game's rendered output and stay on the machine that made them.

## Build from your own dump

```bash
# 0. decrypt (your own dump; rpcs3 --decrypt writes EBOOT.elf beside EBOOT.BIN)
QT_QPA_PLATFORM=offscreen <rpcs3> --decrypt <PS3_GAME/USRDIR/EBOOT.BIN>

# 1. analysis (stage 1)
python ps3recomp/tools/ppu_loader.py <EBOOT.elf> -o analysis/
python ps3recomp/tools/gen_imports.py <EBOOT.elf> -o analysis/imports_named.json
python ps3recomp/tools/extract_spu_images.py <EBOOT.elf> --output spu-images/

# 2. lift (chunk small enough to keep GCC's peak RAM per TU sane)
python ps3recomp/tools/ppu_lifter.py <EBOOT.elf> \
    --functions analysis/EBOOT.functions.json \
    --hle-stubs  analysis/EBOOT.imports.json \
    --insn-patches patches/unlock-trainer.json \
    --output recompiled --jobs 12 --chunk-lines 150000

# 3. SPURS policy module: carve 12,160 bytes at guest 0xB70B80 out of the
#    ELF, wrap at base 0xA00, lift, and build spu/pm_reg.c into the port
#    (see NOTES.md "Boot 2/3" for the exact recipe)

# 4. build
cmake -B build -G Ninja -DPS3RECOMP_DIR=<ps3recomp checkout>
cmake --build build -j 8

# 5. pre-seed the HDD cache the game's gate looks for, then run
python scripts/extract_cache.py <disc>/USRDIR/CacheDesc.dat <disc>/USRDIR/CacheData.pak hdd0/game/BCES00548
PS3_HDD0_ROOT=$PWD/../hdd0 ./build/PainRecomp <EBOOT.elf>
```

Sha256 of the decrypted EBOOT.elf this port was brought up against:
`411d00aa3809706376bc8fe55e309844310e37e69152bdbb15627be5833fe40b`.

### Unlock trainer

After lifting BCES00548 with `patches/unlock-trainer.json` and rebuilding,
launch with `PAIN_UNLOCK_ALL=1` to bypass the Crash Course requirement and
mark the local content catalogue available for this session. The trainer is
off by default. Unset the variable and restart to restore the original checks.
Use a separate `PS3_GAMEDATA_ROOT` for trainer sessions to keep campaign progress
earned while playing separate from your normal save.

## The four boot blockers, and their fixes

1. **TOC corruption** — the title's codegen restores r2 after *every* call;
   the lifter now emits the glink TOC save (50,988 sites; upstream patch 1).
2. **SPURS policy module not lifted** — a raw SPU image in the PPU data,
   lifted at base 0xA00 and registered by fingerprint (`spu/pm_reg.c`).
3. **The first-boot install gate** — `cellGame` answered with a placeholder
   title ID; the scaffold now initialises from the disc PARAM.SFO (upstream
   patch 4), and the 8,044-file cache is pre-seeded offline from the disc's
   own `CacheDesc.dat` manifest (byte-exact: 1,061,512,652 bytes).
4. **Blank frame** — guest-shader MSL translation wasn't built;
   `scripts/mac_shaders.sh` builds glslang + SPIRV-Cross from source.

Full evidence for each: `NOTES.md`.

## Targets

- **macOS arm64 (Metal)** — running (Apple M2 verified)
- **Linux x86-64 (Vulkan opt-in / null)** — headless verified
- **Windows (D3D12)** — expected to work; untested here
- **PlayStation 5** — feasibility investigation in progress

## Legal

This project is not affiliated with or endorsed by the game's rights holders.
It distributes none of the game's assets, code or data; it exists for
preservation, study and interoperability. All rights to the game belong to
their owners. You must provide your own legally obtained copy.

Port code is MIT; see `LICENSE`.
