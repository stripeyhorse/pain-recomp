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
| `language` | auto, PS3 language code or ID | System language reported to PAIN. Available translations depend on the disc. |
| `audio` | on, off | Starts with normal audio or reports audio unavailable to PAIN. |
| `metal_headless`, `metal_guest_programs` | on, off | Select Metal output and guest shader use. Shader translation needs the toolkit dependencies. |
| `vulkan_window`, `vulkan_guest_programs` | on, off | Select Vulkan window output and guest shader use. Shader translation needs the toolkit dependencies. |
| `unlock_trainer` | on, off | Sets `PAIN_UNLOCK_ALL` for the optional guarded lift. |
| `pin_pose_at_kick` | on, off | Sets `PAIN_PIN_POSE_AT_KICK`. Pins the actor pose at the list kick for the prepass and material jobs, which keeps the player character textured in flight. Defaults to on. |
| `creator_first` | on, off | Sets `PS3_CREATOR_FIRST`. A new PPU thread at the creator's priority or lower starts after the creator's next blocking call, so the boot's GameContent and SysCacheCreate handshakes keep their completion flag unless the creator stalls past the toolkit's cap (`PS3_CREATOR_FIRST_MS`, 2000 ms). Needs toolkit `d4b41e8` or later. Defaults to on. |
| `fifo_park_grace_ms` | 0 to 60000 | Sets `GCM_PARK_GRACE_MS`. How long the RSX FIFO waits at a parked jump for the game to patch it before following `put`. The toolkit default of 50 ms can skip a fence when the host is busy and stall the game at a ring wrap. Defaults to 2000. |

INI edits apply at startup. The window presentation settings require the
toolkit change for Metal and Vulkan. The null backend has no graphics output.
Internal render scale and the full retail graphics menu are future work.
