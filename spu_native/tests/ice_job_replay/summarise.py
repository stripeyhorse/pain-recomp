"""summarise.py <ref-variant> < pair.sh output: per-round change of each variant against ref."""
import sys, collections
ref = sys.argv[1]
rows = [l.split("\t") for l in sys.stdin.read().splitlines() if l.count("\t") == 3]
by = collections.defaultdict(dict)
for r, v, p, ns in rows:
    if p.split("/")[0] != p.split("/")[-1]: print("FAILED", r, v, p)
    by[int(r)][v] = float(ns) if ns else float("nan")
vs = sorted({v for r in by for v in by[r]})
for v in vs:
    ch = [100 * (by[r][v] / by[r][ref] - 1) for r in sorted(by) if v in by[r] and ref in by[r]]
    us = [by[r][v] / 64 / 1000 for r in sorted(by) if v in by[r]]
    print(f"{v:14s} mean job {min(us):6.2f}-{max(us):6.2f} us   vs {ref}: " + ", ".join(f"{c:+.2f}%" for c in ch))
