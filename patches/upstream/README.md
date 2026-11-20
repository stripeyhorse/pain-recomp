# Upstream patch series for sp00nznet/ps3recomp

Five commits earned during the bring-up of a retail disc title (Pain, BCES00548),
each independently justified and game-agnostic. Order matters only in that
0004's template change is what 0005's guide text refers to.

Apply on a fresh clone of `sp00nznet/ps3recomp` master:

```bash
git am pain-recomp/patches/upstream/00*.patch
```

| # | Commit | Why upstream cares |
|---|---|---|
| 1 | `ppu_lifter: emit the glink TOC save before direct bl calls` | **Correctness, load-bearing.** Toolchains that emit `ld r2,40(r1)` after every call get a zeroed/stale TOC from every unsaved reload; observed as 50,988 restore sites and a null-page cascade 314 constructors deep. The emitted store is exactly the glink stub's own save into the ABI-reserved slot. |
| 2 | `spu_dispatch_mt: build on GCC` | Build fix: the TU is described as clang-built but the template's SPU glob compiles it under GCC too, where unguarded `musttail` is a hard error. |
| 3 | `ppu_loader: POSIX diagnostics` | The single most useful diagnostic for bug #1 is *which TOC* was live at a null-page access; adds r2 to both null-page reporters and the `[CALL]` trace, and un-guards `PPU_TOCWATCH` (its capture API was already shimmed on POSIX). |
| 4 | `templates/project: initialise cellGame from the disc PARAM.SFO` | Every new port inherits the placeholder-title-ID trap: SKU selection, game-data paths and install gates read identity through cellGame. The scaffold now wires `cellGame_init_from_paramsfo` over the standard SFO layouts before guest boot. |
| 5 | `GAME_PORTING_GUIDE: two recipes` | Documentation of the two boot-blocker classes the above fixes came from: raw SPURS policy modules (the `PM NOT LIFTED` loop, wrap-at-0xA00, fingerprint registration) and mandatory first-boot installs (find the one-probe gate, pre-seed the manifest cache). |

## Not included (port-specific, kept in this repo)

- `patches/ps3recomp-local.patch` — superseded by this series; the vendored
  checkout in `../ps3recomp` already carries these commits.
- Game-specific glue (`main.cpp` extras, `spu/pm_reg.c`, stubs) belongs to the
  per-game port, not the toolkit.
