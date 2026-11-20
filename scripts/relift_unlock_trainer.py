#!/usr/bin/env python3
"""Apply the 19 trainer guards to an existing BCES00548 lift."""

import argparse
from bisect import bisect_right
import hashlib
import json
from pathlib import Path
import re
import sys
from tempfile import NamedTemporaryFile

PORT = Path(__file__).resolve().parents[1]
EBOOT_SHA256 = "411d00aa3809706376bc8fe55e309844310e37e69152bdbb15627be5833fe40b"
GUARDED_LINE = re.compile(
    r"if \(g_pain_unlock_all\) \{ .*? \} else \{ (.*) \}  /\* insn patch .*? \*/"
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("eboot", type=Path, help="Decrypted BCES00548 EBOOT.elf")
    parser.add_argument("--toolkit", type=Path, default=PORT.parent / "ps3recomp")
    parser.add_argument("--recompiled", type=Path, default=PORT / "recompiled")
    args = parser.parse_args()
    sys.path.insert(0, str(args.toolkit.resolve() / "tools"))
    from elf_parser import ELFFile, vaddr_to_offset
    from ppu_lifter import PPULifter, disassemble_bytes, load_insn_patches

    if hashlib.sha256(args.eboot.read_bytes()).hexdigest() != EBOOT_SHA256:
        parser.error("EBOOT does not match the BCES00548 trainer")
    elf = ELFFile(str(args.eboot))
    elf.load()

    bounds = {int(str(f["start"]), 0): int(str(f["end"]), 0)
              for f in json.loads((PORT / "analysis/EBOOT.functions.json").read_text())}
    starts = sorted(bounds)
    lifter = PPULifter()
    lifter.function_entries = set(starts)
    lifter.code_lo = starts[0]
    lifter.code_hi = max(bounds.values())
    lifter.insn_patches = load_insn_patches(str(PORT / "patches/unlock-trainer.json"))
    functions = {}
    for start in sorted({starts[bisect_right(starts, addr) - 1] for addr in lifter.insn_patches}):
        end = bounds[start]
        offset = vaddr_to_offset(elf.program_headers, start)
        code = elf.raw_data[offset:offset + end - start]
        lifted = lifter.lift_function(disassemble_bytes(code, start, True), start, end)
        if lifted.fallthrough_to:
            parser.error(f"Unexpected continuation in {lifted.name}")
        signature = f"void {lifted.name}(ppu_context* ctx) {{"
        guarded = "\n".join(lifter._function_def_lines(lifted, {}, [], {})).rstrip()
        old, count = GUARDED_LINE.subn(r"\1", guarded[guarded.index(signature):])
        functions[signature] = (old, guarded, count)

    changes = {}
    remaining = set(functions)
    for path in sorted(args.recompiled.glob("ppu_recomp*.cpp")):
        text = original = path.read_text()
        for signature in sorted(remaining):
            old, guarded, _ = functions[signature]
            if guarded in text:
                remaining.remove(signature)
            elif old in text:
                text = text.replace(old, guarded, 1)
                remaining.remove(signature)
            elif signature in text:
                parser.error(f"{signature} does not match the verified stock or guarded lift in {path}")
        if text != original:
            changes[path] = text
        if not remaining:
            break

    count = sum(n for _, _, n in functions.values())
    if remaining or count != len(lifter.insn_patches):
        parser.error("Existing lift does not contain all trainer sites; relift from EBOOT.")

    for path, text in changes.items():
        with NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as output:
            output.write(text)
        Path(output.name).replace(path)
    print(f"Verified {count} trainer guards ({len(changes)} lift chunks updated)")


if __name__ == "__main__":
    main()
