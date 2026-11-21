# PAIN settings

PainRecomp reads `settings.ini` from its working directory. Set
`PAIN_SETTINGS_PATH` to use a different file. Copy `settings.example.ini`
or add your own `[settings]` section. Valid INI values override environment
values, then the defaults. Set `PAIN_SETTINGS_VERBOSE=1` for the resolved
values and native-menu diagnostics.

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
| `audio` | on, off | Starts with normal audio or reports audio unavailable to PAIN. |
| `metal_headless`, `metal_guest_programs` | on, off | Select Metal output and guest shader use. Shader translation needs the toolkit dependencies. |
| `vulkan_window`, `vulkan_guest_programs` | on, off | Select Vulkan window output and guest shader use. Shader translation needs the toolkit dependencies. |
| `unlock_trainer` | on, off | Sets `PAIN_UNLOCK_ALL` for the optional guarded lift. |
| `pin_pose_at_kick` | on, off | Sets `PAIN_PIN_POSE_AT_KICK`. Pins the actor pose at the list kick for the prepass and material jobs, which keeps the player character textured in flight. Defaults to on. |
| `creator_first` | on, off | Sets `PS3_CREATOR_FIRST`. A new PPU thread at the creator's priority or lower starts after the creator's next blocking call, so the boot's GameContent and SysCacheCreate handshakes keep their completion flag unless the creator stalls past the toolkit's cap (`PS3_CREATOR_FIRST_MS`, 2000 ms). Needs toolkit `d4b41e8` or later. Defaults to on. |
| `fifo_park_grace_ms` | 0 to 60000 | Sets `GCM_PARK_GRACE_MS`. How long the RSX FIFO waits at a parked jump for the game to patch it before following `put`. The toolkit default of 50 ms can skip a fence when the host is busy and stall the game at a ring wrap. Defaults to 2000. |
| `vblank_ms` | 4 to 33 | Sets `PAIN_VBLANK_MS`. The synthesized vblank period. PAIN waits two vblanks per frame, so 8 targets 60 FPS and 16 is the console's 30 FPS. Launch-to-airborne time measured the same at both. Defaults to 8. |
| `thread_qos` | on, off | Sets `PS3_THREAD_QOS`. macOS only: runs the SPURS lanes, the RSX thread and the game's main thread at user-interactive QoS so they stay on performance cores. No measured difference on a 4P+4E M2; unmeasured on machines with more efficiency cores. Defaults to on. |
| `spu_mfc_lookup_cache` | on, off | Sets `SPU_MFC_LOOKUP_CACHE` on macOS. Reuses the SPU worker's last memory-flow controller lookup. Defaults to off. |

INI edits apply at startup. The window presentation settings require the
toolkit change for Metal and Vulkan. The null backend has no graphics output.
Internal render scale and the full retail graphics menu are future work.
