# PS5 RADV adapter plan

The toolkit has a loader and window-system integration interface in
`libs/video/rsx_vulkan_platform.h`. Linux builds select
`rsx_vulkan_platform_sdl.c`. The Prospero payload still uses the null RSX
backend. The adapter below is an implementation stub for the console phase.

## Seam map

| Boundary | Linux implementation | Shared Vulkan backend |
| --- | --- | --- |
| Procedure lookup | `rsx_vk_platform_load` opens `libvulkan.so.1`, falls back to `libvulkan.so`, and resolves `vkGetInstanceProcAddr` | `vk_load_global_functions` resolves global and later instance/device entry points. Shutdown releases the loader after destroying the instance. |
| Native output | `rsx_vk_platform_output_open` creates the SDL window and reports instance extensions. The adapter supplies drawable size, visibility, event pumping and elapsed time. | `vk_init_all` creates the instance, calls the surface hook and selects a graphics queue that can present. It makes one surface before device selection for SDL and can create one per physical-device candidate for display WSI. |
| Presentation | `rsx_vk_platform_create_surface` calls `SDL_Vulkan_CreateSurface`. `rsx_vk_platform_present` calls the resolved `vkQueuePresentKHR`. | `vk_create_swapchain` negotiates usage, format, extent and present mode. `vk_present_window` acquires an image, blits the offscreen frame and submits with the existing semaphores and fences. `vk_queue_present` keeps the queue locked. Resize and swapchain loss remain in the shared backend. |

## Adapter stub

Select a dedicated `rsx_vulkan_platform_ps5.c` at build time instead of the
SDL adapter. Link target-built RADV and the corresponding SDK platform
libraries with the pinned template's archive ordering and link options.
Resolve target Vulkan headers and glslang from the cross-build prefix.
Keep SDL2 available for pad and audio.

1. **Load.** Return the static RADV `vk_icdGetInstanceProcAddr` from
   `rsx_vk_platform_load`. It implements the
   `PFN_vkGetInstanceProcAddr` signature. The template passes that symbol
   to Volk. The RSX backend already owns its own dispatch table, so resolve
   and verify `vkCreateInstance`, then instance and device commands through
   that table. The static adapter's unload hook has no dynamic library to close.
   [Template dispatch and link stack](https://github.com/mihawk-99/PS5_VulkanTemplate/blob/91179df760df1e6c6f2d4d172bc435319d79ff3c/ps5/README.md)
2. **Open output.** When presentation is requested, report
   `VK_KHR_surface` and `VK_KHR_display` as instance extensions and set
   `surface_per_device = 1`. Confirm extension availability with the
   pinned driver. An offscreen build can decline output and still use RADV.
3. **Create surface.** Resolve the display commands with the instance proc
   resolver. Enumerate the candidate device's displays, modes and planes.
   Choose a mode from the reported list and a plane that supports that
   display. Check the plane's extent, transform and alpha capabilities.
   Call `vkCreateDisplayPlaneSurfaceKHR` with the chosen mode, plane index,
   stack index and extent. Report failures with their `VkResult`. The shared
   backend destroys unused candidate surfaces and keeps the one paired with
   the selected graphics/present queue. If the surface reports a variable
   extent, return the chosen mode's extent for that physical device.
   [Template display surface](https://github.com/mihawk-99/PS5_VulkanTemplate/blob/91179df760df1e6c6f2d4d172bc435319d79ff3c/base/VulkanSwapChain.cpp#L535-L663)
4. **Present and close.** Forward `vkQueuePresentKHR` to RADV under the
   shared queue lock. Start with FIFO. Verify the swapchain format can be
   a blit destination, the surface supports `VK_IMAGE_USAGE_TRANSFER_DST_BIT`,
   and the advertised image count fits the backend. Track the actual display
   extent independently of the emulated render size. Use the foreground
   title's lifecycle events for exit and mode changes, and its monotonic
   clock for the optional hold. Free native state after the shared backend
   has idled the queue and destroyed its swapchain and surface.
   [RADV VideoOut path](https://github.com/mihawk-99/PS5_Vulkan)

## Console acceptance

1. Qualify the unchanged textured template on the user's provisioned PS5.
   Record the template, SDK and RADV revisions, console launch context, mode
   and frame cadence. Require visible HDMI output and a clean restart.
2. Bring up the shared backend offscreen on that stack. Assert clear and
   readback pixels, depth and stencil, indexed textured draws, and copy/blit.
   First use synthetic commands. Then repeat with the target-built
   glslang translator enabled.
3. Enable `VK_KHR_display` output. Check the chosen queue, swapchain usage
   and format, repeated acquire/present, visible HDMI frames and clean
   shutdown/restart. Verify that a requested display run actually creates
   a swapchain, since a failure may fall back to offscreen rendering.
4. Use the same frontend settings and capture points as the desktop
   baseline. Require repeatable recognisable frontend and in-level frames
   with real guest shaders and record flip rates against host vblank.
