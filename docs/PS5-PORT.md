# PS5 port plan (preserved from the feasibility investigation)

Source: the sol 6.2 feasibility report (2026-11-20), whose `/tmp` staging was
later lost to a tmpfs cleanup. Preserved here from the orchestrator's full
read so the plan survives; citations were to `ps5-payload-dev/sdk` v0.50,
`mihawk-99/PS5_Vulkan` (RADV) and `ps5-payload-dev/SDL` `release-2.30.x-ps5`.

## Verdict

**PS5 target: feasible with an already provisioned native-homebrew console,
a Prospero runtime port, and integration of the community RADV Vulkan
stack.** Native Vulkan already runs in homebrew titles (vkQuake, RetroArch
cores, PSFlycast). The SDK, PS5 GPU driver and SDL2 port all exist. The
biggest unknowns: the 4 GiB guest arena in the intended process, Vulkan
shader/render-target parity, and title-launch/service permissions on the
actual console.

## Console and firmware

- BD-J userland execution, kernel access and launching a native foreground
  title are distinct capabilities; an entry point alone says nothing about
  VideoOut, controller/audio services or memory budget.
- **Firmware rule:** keep the EXISTING firmware of a dedicated, already
  provisioned console IF it passes both a plain SDK ELF and an unchanged
  RADV native-title sample. Record the hardware model, full firmware, loader
  build, foreground launcher, SDK and driver revisions of that run. For a
  stock console there is no supported firmware target today.
- Loaders: `ps5-payload-dev/elfldr` v0.28 and the SDK's Websrv are the
  established examples; FTP is transport only.

## SDK / CPU / memory

- Baseline: `ps5-payload-dev/sdk` v0.50 (`prospero-clang++`, CMake toolchain
  `PS5`/`PROSPERO`, libc++ included, imports into `libkernel_web.sprx` /
  `libSceLibcInternal.sprx`). The C++20 sample and an ABI probe
  (pthread create/join, mmap/mprotect/munmap, getcontext/makecontext/
  swapcontext) were cross-built and readelf-verified during feasibility.
- ISA: x86-64 **Zen 2** — the port's SSE4.1/AVX2 SPU helper paths apply
  directly (verify CPUID/YMM state on hardware). ARM64 paths exist for
  completeness (the M2 build exercises them).
- Pages: **16 KiB host** vs the guest's 4 KiB model — audit the page-rounding
  guard paths.
- **Two cross-build blockers (both identified by actual compilation):**
  1. `MAP_NORESERVE` is absent from the Prospero headers (the guest-VM
     reservation in `vm.h` + the port's arena) — needs a portable guard.
  2. The thread-park signal in `runtime/platform/win32_compat.c` is
     Linux-only at :63 but the park implementation at :807 builds for every
     non-Apple POSIX target — needs a correct or gated park/resume contract.
- Guest arena: the port maps 4 GiB + 64 KiB lazily-backed; verify an
  anonymous `PROT_NONE` reservation with host-page-rounded protections and
  a measured working set; fall back to `sceKernelReserveVirtualRange` /
  flexible-memory APIs if plain reserve fails. Keep CPU guest memory and
  GPU-visible allocations separate. A segmented arena would break the
  generated code's addressing contract — stop and re-estimate if forced.

## Graphics paths (ranked)

1. **Share the RSX Vulkan backend with PS5 RADV** (community Mesa/RADV,
   statically linked, AGC submission + VideoOut via `VK_KHR_display`).
   Replace only the loader/WSI seams; share the draw engine and SPIR-V
   translation. Cross-build glslang; `PS3RECOMP_VK_GUEST_PROGRAMS=1`.
2. Alternate community driver (`mpereiraesaa/ps5-vulkan`, Vulkan 1.3) as a
   fallback if RADV hits a reproducible blocker.
3. PS5 OpenGL/EGL (BlackBearReloaded, experimental GL 4.6) — would need a
   new renderer; lower value.
4. New low-level AGC/GPUM renderer — a research project; avoid.
Bring-up: headless CPU null backend first (FIFO + synthetic pixel checks).

## Pad and audio

`ps5-payload-dev/SDL` `release-2.30.x-ps5` is a real SDL2 port
(`scePadInit/Open/ReadState`, vibration; `sceAudioOutInit/Open/Output`),
cross-built during feasibility and accepted by the port's CMake. Direct C
adapters around the same calls are the fallback.

## Phased plan (effort for one developer with a qualified console)

- **A · Host CPU + Prospero cross-build · 2-4 days.** Cross-configure the
  port against the toolchain + cross-built SDL2, `PS3RECOMP_RSX_VULKAN=OFF`,
  `PS3RECOMP_FFMPEG_RUNTIME=OFF`; fix the two blockers as portable toolkit
  commits; keep target dependency resolution isolated from host SDL.
  **PASS:** the Pain null ELF links with the expected target imports; the
  Linux build still reaches its baseline boot; host fiber/sync/SPU helper
  tests pass.
- **B · Real-console headless ELF · 3-7 days.** readelf first; launch via
  the configured loader; capture stdout over the isolated test LAN. Extend
  the ABI probe to the exact Pain arena, alignment, raw-SPU windows and
  page protections; log returns/elapsed/peak during progressively touched
  ranges. Supply guest EBOOT path, disc root and a writable HDD0 root via
  loader arguments or a manifest; stage the 8,044-file cache + disc tree
  with size/digest checks (never embedded). **PASS:** repeated vblank/flip
  and FIFO progress past the install gate, expected SPURS dispatch, stable
  memory, across THREE cold runs, compared against the Linux reference;
  pixel proof is a known clear-colour/test-triangle centre-pixel diagnostic
  over the LAN (a real screen capture belongs to C).
- **C · Native Vulkan graphics · 2-5 weeks.** Prove the unmodified RADV
  template (textured draw, HDMI presentation) on the same console BEFORE
  touching the RSX code; in parallel replay the frontend on desktop Vulkan
  (`PS3RECOMP_RSX_VULKAN=ON`, guest programs, `PS3RECOMP_VK_WINDOW=1`) and
  compare frames/draw counters against the Metal reference. Then adapt only
  the loader/WSI seams; prove offscreen clear/readback, depth+stencil,
  indexed textured draws, copy/blit; then VideoOut presentation; then the
  first guest-shader frontend frame. **PASS:** recognisable repeatable
  frontend + in-level frames with real guest shaders, reliable
  shutdown/restart; measured flip rates vs host vblank.
- **D · DualSense and audio · 3-7 days.** Wire the PS5 SDL2 port
  (`scePad`/`sceAudioOut`); first playable control + audible effects.

## Risks

Homebrew on your own console; firmware-update risk on a provisioned machine;
BD-J is not a path to a foreground title. Alternatives if blocked: PS4
targets (OpenOrbis patterns) or waiting on scene progress.
