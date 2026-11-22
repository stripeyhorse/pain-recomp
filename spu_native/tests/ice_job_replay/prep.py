"""prep.py <mesh spu_recomp.c> <pm spu_recomp.c> <spu_channels.c> <outdir>: the replay's mesh.c (exit hook at
the job's two exits), pm.c and smc.inc (the SDK's unlifted-code microstepper), as the 22 Nov build-verify-ice-job.sh."""
from pathlib import Path
import sys
mesh, pm, channels = (Path(a).read_text() for a in sys.argv[1:4])
out = Path(sys.argv[4]); out.mkdir(parents=True, exist_ok=True)
needle = "        ctx->int_enable = 0; SPU_RET(ctx);"
start = mesh.index("void jobmod_ca71f23d7b11_e11B00_spu_func_00015B00(spu_context* ctx) {")
end = mesh.index("typedef struct {", start)
job = mesh[start:end]
assert job.count(needle) == 2
job = job.replace(needle, "        pain_ice_replay_end(ctx);\n" + needle)
mesh = mesh[:start] + "extern void pain_ice_replay_end(spu_context*);\n" + job + mesh[end:]
for name, source in [("mesh", mesh), ("pm", pm)]:
    old = '../../runtime/spu/spu_helpers.h'
    assert source.count(old) <= 1
    (out / f"{name}.c").write_text(source.replace(old, "spu_helpers.h"))
start = channels.index("static int spu_smc_microstep(")
end = channels.index("\nvoid spu_indirect_branch(", start)
(out / "smc.inc").write_text(channels[start:end])
