# PAIN settings

PainRecomp reads `settings.ini` from its working directory. Set
`PAIN_SETTINGS_PATH` to use a different file. Copy `settings.example.ini`
or add your own `[settings]` section. Valid INI values override environment
values, then the defaults. Set `PAIN_SETTINGS_VERBOSE=1` for the resolved
values and native-menu diagnostics.

PAIN's Audio and Controller screens live under **Extras** and in the pause
menu. PAIN handles its audio sliders and profile itself. The existing
**Sync Rate** control in PAIN's debug menu applies a live frame cap when the
game exposes that screen. Selecting a value saves it to the INI. Access from
the retail pause menu still needs verification.

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

INI edits apply at startup. The window presentation settings require the
toolkit change for Metal and Vulkan. The null backend has no graphics output.
Internal render scale and the full retail graphics menu are future work.
