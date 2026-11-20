# ps3recomp patch series

The 12 patches apply in order to upstream ps3recomp at
`de4f090328ea08bef6b2f15caec0b85e343a7ece`. The published toolkit fork
includes the full series through `fb551632fd0ff3952bc534e43d3f563f7a3cdd51`. The patches contain toolkit
source, tests and documentation. [Toolkit fork](https://github.com/stripeyhorse/ps3recomp)

```sh
git clone https://github.com/sp00nznet/ps3recomp.git
git -C ps3recomp switch --detach de4f090328ea08bef6b2f15caec0b85e343a7ece
git -C ps3recomp am "$PWD"/pain-recomp/patches/upstream/00*.patch
```

| Patch | Fork commit | Change |
| --- | --- | --- |
| 01 | `fbc8a47` | Save the caller TOC in the ABI linkage slot before lifted direct calls. |
| 02 | `afec200` | Guard Clang's `musttail` in the SPU dispatcher so GCC builds. |
| 03 | `f9e14fb` | Include the current TOC in PPU diagnostics and enable TOC watch on POSIX. |
| 04 | `8aada63` | Initialise the template's cellGame title metadata from PARAM.SFO. |
| 05 | `c29989f` | Document raw SPURS policy modules and mandatory-install cache pre-seeding. |
| 06 | `98ec9ba` | Apply PRX REL64 relative to the relocation place. |
| 07 | `7f57024` | Unpublish a dynamic module's exports while preserving a newer owner's entries. |
| 08 | `eb676aa` | Set startup window geometry, aspect and display sync on Metal and Vulkan. |
| 09 | `bd27627` | Recover a jump-table base loaded through the TOC and spilled to the stack. |
| 10 | `8f74319` | Quiesce SPURS workloads and wait for their active lanes before removal. |
| 11 | `76a586f` | Select fullscreen output size and apply live Metal presentation controls. |
| 12 | `fb55163` | Preserve separate front and back stencil masks and references. |
