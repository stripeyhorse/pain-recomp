# PainRecomp

PainRecomp runs the European **PAIN BCES00548 01.00** disc release as a
native program. The port statically recompiles PowerPC and SPU code with
[ps3recomp](https://github.com/stripeyhorse/ps3recomp) and uses its
reimplementation of the PS3 system libraries. You supply your own legally
obtained disc dump. Decrypted executables, lifted sources, game files and
frame captures stay local.

## Status

- **Playable offline on macOS arm64 with Metal and Linux x86-64 with
  Vulkan.** Verified on an Apple M2 and GTX 1080 Ti. The port passes the
  cache and first-run consent screens. On Metal, Downtown FreePlay loaded
  with a DLC character, and a scripted Crash Course launch advanced the
  lesson after a hit. The LevelScript catalogue covers 90 distinct modules
  at 91 disc paths.
- **Native Audio and Video controls.** Sync Rate is a selectable Audio row
  in Extras and the pause menu. It offers Variable, 20, 30 and 60 FPS and
  persists in the INI. Video/Display offers window and fullscreen output
  presets through 4K. Metal's Image Quality page controls post-processing.
  Post-process Scale changes the scanout effects buffer. The game still
  renders its geometry and scene targets at the original 720p. An
  airborne character silhouette defect remains in the Metal verification.
- **Profile saves.** The port supplies missing save artwork from the disc
  and lets the native autosave write ICON0, PIC1 and SYS-DATA. A fresh
  profile completed the save and reloaded on both Linux null and headless
  Vulkan. See [NOTES.md](NOTES.md) for the test results.
- **Offline trainer.** Set `PAIN_UNLOCK_ALL=1` or `unlock_trainer = on`
  in `settings.ini` for the session. It sets the live Crash Course
  completion stat and filters that temporary change out of the profile
  write. DLC assets must be present on the disc.
- **Online stays locked.** The native menu checks network readiness in
  addition to progression. Online requires compatible PSN and PAIN
  Medius services. The toolkit's optional psnr client provides parts of PSN
  emulation. PAIN's end-to-end service path is unverified.

- **PS5 Phase A: cross-builds as a Prospero ELF (null backend).**
  Real-console headless verification is Phase B.

Linux null-backend runs provide a headless boot and profile check. Windows
has no acceptance result. See [NOTES.md](NOTES.md) for backend and gameplay
evidence.

## Workstation preparation

The public branch mirrors documentation, preparation scripts and the
toolkit series. The current build and deployment procedures below use the
full working port checkout. Use a sibling checkout of the toolkit fork at
the revision listed in [the 12-patch series](patches/upstream/README.md).

```sh
# Run from the full pain-recomp checkout.
# GAME_DIR is the PS3_GAME directory in your dump.
export GAME_DIR="/path/to/your dump/PS3_GAME"
export RPCS3_BIN="/path/to/rpcs3"
./scripts/prepare.sh
elf="$GAME_DIR/USRDIR/EBOOT.elf"

python3 ../ps3recomp/tools/ppu_loader.py "$elf" -o analysis/
python3 ../ps3recomp/tools/gen_imports.py "$elf" -o analysis/imports_named.json
python3 ../ps3recomp/tools/ppu_lifter.py "$elf" \
    --functions analysis/EBOOT.functions.json \
    --hle-stubs analysis/EBOOT.imports.json \
    --insn-patches patches/unlock-trainer.json \
    --output recompiled --jobs 12 --chunk-lines 150000

# Prepare the SPU workload sources and register the raw policy module.
# See the SPU and policy-module sections in NOTES.md.
./scripts/prepare_deploy.sh
```

`prepare.sh` accepts a raw `EBOOT.BIN` and the two disc cache files
`CacheDesc.dat` and `CacheData.pak`. It decrypts the executable with RPCS3
and extracts the HDD cache under the workspace's `hdd0`. Override that
destination with `HDD0_ROOT`. Repeating preparation reuses the valid ELF
and completed cache.

`prepare_deploy.sh` refreshes an existing PPU lift's trainer guards and
animation dispatch, generates the HLE import table and wrapped PPU sources,
and prepares the full LevelScript catalogue. It needs `RPCS3_BIN` when
generating the catalogue for the first time.

## Build and run

```sh
cmake -S . -B build -G Ninja -DPS3RECOMP_DIR=../ps3recomp
cmake --build build --parallel 8
./scripts/first_run.sh 180
```

Use `PS3_GAMEDATA_ROOT` to keep the player profile separate from the
installed cache. The native bootstrap may show an offline network message
before the main menu. The first run can ask for consent before it continues.

### Crash Course pose workaround

`pin_pose_at_kick` is on by default. Set `pin_pose_at_kick = off` in
`settings.ini`, or `PAIN_PIN_POSE_AT_KICK=0`, for the unpinned behaviour. It
is read at startup. It gives the two same-list pose consumers, depth prepass
and material, the completed pose from the list kick. The prepass uses a pose
one list generation behind the unpinned material pass. The sling band and
some pedestrians can still turn grey.

The option requires a toolkit with the pose-pin runtime hooks. If your
toolkit checkout lacks `include/ps3emu/runtime_hooks.h`, apply the supplied
[toolkit patch](patches/pose-pin-runtime-hooks.patch) before building.

```sh
git -C ../ps3recomp apply ../pain-recomp/patches/pose-pin-runtime-hooks.patch
```

### Cross-build for PS5

Use ps5-payload-sdk v0.50 with host LLVM 19 and a Prospero build of SDL2
from [ps5-payload-dev/SDL](https://github.com/ps5-payload-dev/SDL/tree/release-2.30.x-ps5).
Install SDL2 and its target dependencies, including libsamplerate for
the PS5 audio build, under `PS5_SDL2_PREFIX`. Use the toolkit checkout
through `9df357a` for the PS5 portability fixes. Prepare the local PPU, SPU
and PRX lifts as above.

```sh
cmake -S . -B build/ps5 -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$PS5_PAYLOAD_SDK/toolchain/prospero.cmake" \
    -DPS3RECOMP_DIR=../ps3recomp \
    -DSDL2_DIR="$PS5_SDL2_PREFIX/lib/cmake/SDL2" \
    -DCMAKE_EXE_LINKER_FLAGS="-L\"$PS5_SDL2_PREFIX/lib\"" \
    -DPS3RECOMP_RSX_VULKAN=OFF -DPS3RECOMP_FFMPEG_RUNTIME=OFF \
    -DPAIN_USE_PREPARED_PPU=ON \
    -DCMAKE_BUILD_TYPE=Debug -DCMAKE_CXX_FLAGS_DEBUG=-O0 -DCMAKE_C_FLAGS_DEBUG=-O1
cmake --build build/ps5 --parallel 3 --target PainRecomp
readelf -h -l -d build/ps5/PainRecomp.elf
```

This configuration reduces build time for the lifted PPU and LevelScript
sources. Add `-DPAIN_LIFTED_PPU_O2=ON` in a separate build directory to
benchmark those sources at `-O2` with the same runtime flags. Use a bounded
job count for the large generated translation units.

The payload takes the guest EBOOT as its first argument and uses
`PS3_VFS_ROOT` for the disc root and `PS3_HDD0_ROOT` for the writable cache
root. See the [PS5 port plan](docs/PS5-PORT.md) for console acceptance criteria.

### Deploy to Beast

Run `./scripts/push_beast.sh` on the workstation after preparation. Its
default destination is `~/pain-ps3` on Beast. Set `PAIN_BEAST_DIR` to a
different directory name for a parallel build. The script copies the source
trees, disc files and completed cache. On Beast, run `beast_build.sh deps` once
and `beast_build.sh port` for subsequent Vulkan builds. An isolated checkout can
reuse the shared dependencies with `PAIN_BEAST_DEPS_ROOT="$HOME/pain-ps3"`.

```sh
# Run in the Beast deploy root.
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json
export PS3RECOMP_VK_GUEST_PROGRAMS=1
export PS3_HDD0_ROOT="$PWD/hdd0"
./pain-recomp/build/PainRecomp "$PWD/game/PS3_GAME/USRDIR/EBOOT.elf"
```

For manual raw-disc preparation on Linux, set `GAME_DIR`, `HDD0_ROOT` and
`RPCS3_BIN` on the target and run `scripts/prepare.sh` explicitly. Target builds
still consume the workstation-generated PPU, SPU and PRX sources. The Metal
helpers remain available for a separately provisioned macOS target.

## Licence

The port is MIT licensed and exists for preservation and interoperability.
It is unaffiliated with the rights holders. The game and its assets remain
the property of their respective owners.
