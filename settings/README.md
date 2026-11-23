# PAIN settings

PainRecomp reads `settings.ini` from its working directory. Set
`PAIN_SETTINGS_PATH` to use a different file. Copy `settings.example.ini`
or add your own `[settings]` section. Valid INI values override environment
values, then the defaults. Set `PAIN_SETTINGS_VERBOSE=1` for the resolved
values and native-menu diagnostics.

`frame_rate` is the one pacing setting a player needs. `vblank_ms` and
`sim_steps` are advanced overrides: when either is set, in the INI or the
environment, it replaces the value `frame_rate` chose for it, and the
other keeps the `frame_rate` value.

The Mac launcher's **Settings…** sheet edits this file. It covers
`res_scale`, `frame_rate`, `vsync`, `fullscreen`, `aspect`, `aa`, `upscale`,
`anisotropic`, `language` and `audio`, and writes only the keys the player
changes, in place, as the game's own menu does. Changing the frame rate
there also comments out active `vblank_ms` and `sim_steps` lines.

PAIN's Audio and Controller screens live under **Extras** and in the pause
menu. PAIN handles its audio sliders and profile itself. On BCES00548,
**Sync Rate** follows Volume in Audio. Highlight it and press Cross to cycle
60 FPS, 30 FPS, 20 FPS and Variable. Each selection applies at once and
updates the INI.

| Key | Values | Effect |
| --- | --- | --- |
| `frame_cap` | 0, 20, 30, 60 | Maximum guest-frame submissions per second. 0 is Variable. |
| `vsync` | on, off | Metal native window display sync or Vulkan window present mode. Vulkan uses FIFO when IMMEDIATE is unavailable. |
| `fullscreen` | on, off | Initial fullscreen state on Metal or windowed Vulkan. |
| `window_size` | auto, WIDTHxHEIGHT | Initial Metal or Vulkan window content size. |
| `aspect` | fit, stretch | Fit preserves the source aspect. Stretch fills the window. |
| `aa` | off, fxaa, smaa | Metal register-file renderer. |
| `vibrance`, `contrast` | −1 to 1, 0.5 to 1.5 | Metal present pass. |
| `sharpen`, `anisotropic` | 0 to 1, 0 or 2 to 16 | Metal present sharpening and eligible guest samplers. |
| `res_scale` | 0.5 to 3 | Sets `PS3_RES_SCALE`. Metal register-file renderer: internal resolution as a multiple of the guest's, for colour and depth targets. 1 is the guest's own size. Startup only. |
| `upscale` | off, metalfx | Sets `PS3_UPSCALE`. Metal windowed present through the MetalFX spatial scaler instead of the bilinear sample; falls back with one log line if unavailable. Startup only. |
| `language` | auto, PS3 language code or ID | System language reported to PAIN. Available translations depend on the disc. |
| `audio` | on, off | Sets `PS3_MUTE`. Off silences the output device; PAIN's audio still runs and paces as normal. |
| `metal_headless`, `metal_guest_programs` | on, off | Select Metal output and guest shader use. Shader translation needs the toolkit dependencies. |
| `vulkan_window`, `vulkan_guest_programs` | on, off | Select Vulkan window output and guest shader use. Shader translation needs the toolkit dependencies. |
| `unlock_trainer` | on, off | Sets `PAIN_UNLOCK_ALL` for the optional guarded lift. |
| `pin_pose_at_kick` | on, off | Sets `PAIN_PIN_POSE_AT_KICK`. Pins the actor pose at the list kick for the prepass and material jobs, which keeps the player character textured in flight. Defaults to on. |
| `creator_first` | on, off | Sets `PS3_CREATOR_FIRST`. A new PPU thread at the creator's priority or lower starts after the creator's next blocking call, so the boot's GameContent and SysCacheCreate handshakes keep their completion flag unless the creator stalls past the toolkit's cap (`PS3_CREATOR_FIRST_MS`, 2000 ms). Needs toolkit `d4b41e8` or later. Defaults to on. |
| `fifo_park_grace_ms` | 0 to 60000 | Sets `GCM_PARK_GRACE_MS`. How long the RSX FIFO waits at a parked jump for the game to patch it before following `put`. The toolkit default of 50 ms can skip a fence when the host is busy and stall the game at a ring wrap. Defaults to 2000. |
| `frame_rate` | 30, 60 | Sets `PAIN_FRAME_RATE`. The frame rate the game is paced for. PAIN advances its world by two fixed 1/60 s steps per rendered frame, so its speed depends on the frame rate it runs at. 30 is the console's pacing (`sim_steps = 2`, `vblank_ms = 16.667`): the game plays at correct speed whenever the machine sustains 30 FPS, and is capped there. 60 is one step per frame (`sim_steps = 1`, `vblank_ms = 8.333`): it plays at correct speed **only on a machine that sustains 60 FPS**; anywhere slower it plays in slow motion, in proportion (36 FPS plays at 0.6× speed). An Apple M2 renders about 36 FPS at 1920×1080, so use 30 there. Startup only. Defaults to 30. |
| `vblank_ms` | 4 to 33 | Advanced; overrides the period `frame_rate` sets. Sets `PAIN_VBLANK_MS`. The synthesized vblank period in milliseconds; fractions are honoured. PAIN waits two vblanks per frame, so 16.667 is the console's 30 FPS, 8.333 caps at 60 FPS and 8 at 62.5 FPS. With `sim_steps = 2`, any period below 16.667 lets a fast machine run the game too fast (at 35 FPS, 1.17× speed). Defaults to the `frame_rate` value: 16.667 for 30, 8.333 for 60. |
| `sim_steps` | 1, 2 | Advanced; overrides the step count `frame_rate` sets. Sets `PAIN_SIM_STEPS`. Simulation steps per rendered frame. PAIN advances its world by two fixed 1/60 s steps every frame, so it plays at normal speed at 30 FPS and twice as fast at 60. 2 runs the game's own frame driver unchanged. 1 runs a copy of it in which each per-step update (game clock, physics, world and logic, and the other per-step calls) runs once per frame, so the game plays at normal speed at 60 FPS with about half the simulation work per frame; `frame_rate = 60` pairs it with `vblank_ms = 8.333`. With 1 the game is half speed at 30 FPS. Startup only. Defaults to the `frame_rate` value: 2 for 30, 1 for 60. The environment variable `PAIN_SIM_STATS=1` prints a `[sim-steps]` line every 5 s: frames, flips, per-step call rates and the frame driver's wall and CPU time per frame (with 2 it runs a counting copy of the same driver). With 1, the game runs slower than real time whenever the frame rate is below 60, menus included, so a wall-clock `PAD_SCRIPT` drifts out of step with the screens; use `PAD_CLOCK=flips` with times in flips (one flip per step with 1, two steps per flip with 2). With 1 a self-check runs every frame: each per-step call the game's driver would have made ran once, and a clock tick advanced the clock. It prints one line per newly seen driver path (the menus have no clock tick in the game's driver either) and falls back to 2 with a `self-check FAILED` line on a violation. sim_steps=1 also refuses to start if the one-step copy and the linked game driver come from different lifts. |
| `thread_qos` | on, off | Sets `PS3_THREAD_QOS`. macOS only: runs the SPURS lanes, the RSX thread and the game's main thread at user-interactive QoS so they stay on performance cores. No measured difference on a 4P+4E M2; unmeasured on machines with more efficiency cores. Defaults to on. |
| `spu_mfc_lookup_cache` | on, off | Sets `SPU_MFC_LOOKUP_CACHE` on macOS. Reuses the SPU worker's last memory-flow controller lookup. Defaults to off. |
| `mesh_lanes` | 1 to 6 | Sets `PS3_SPURS_LANES_OF_2`. Host threads serving the game's two-SPU SPURS instance, which runs the ICE Mesh geometry jobs. 2 is what the game asked for. 3 or 4 share the same job lists between more threads; on a 4P+4E M2 three threads all took work and the frame did not change, because the performance cores were already full. Defaults to 2. |

INI edits apply at startup. The window presentation settings require the
toolkit change for Metal and Vulkan. The null backend has no graphics output.
Internal render scale and the full retail graphics menu are future work.
