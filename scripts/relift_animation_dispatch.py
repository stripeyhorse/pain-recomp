#!/usr/bin/env python3
"""Refresh PAIN BCES00548's animation decoder in an existing local EBOOT lift."""

import argparse
from pathlib import Path
import re
import struct
import sys
from tempfile import NamedTemporaryFile

PORT = Path(__file__).resolve().parents[1]
START, END = 0x0091F78C, 0x00920BBC
DISPATCH = 0x0091F920
TOC = 0x00C0D1F8
SIGNATURE = "void func_0091F78C(ppu_context* ctx) {"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("eboot", type=Path, help="Decrypted BCES00548 EBOOT.elf")
    parser.add_argument("--toolkit", type=Path, default=PORT.parent / "ps3recomp")
    parser.add_argument("--recompiled", type=Path, default=PORT / "recompiled")
    args = parser.parse_args()
    sys.path.insert(0, str(args.toolkit.resolve() / "tools"))
    from elf_parser import ELFFile, vaddr_to_offset
    from ppu_lifter import PPULifter, disassemble_bytes, discover_jump_tables

    elf = ELFFile(str(args.eboot))
    elf.load()

    def read_addr(address):
        offset = vaddr_to_offset(elf.program_headers, address)
        return None if offset is None else struct.unpack_from(">I", elf.raw_data, offset)[0]

    start_offset = vaddr_to_offset(elf.program_headers, START)
    if start_offset is None or read_addr(DISPATCH) != 0x4e800420:
        parser.error("EBOOT does not match the BCES00548 decoder")
    text = elf.raw_data[start_offset:start_offset + END - START]
    insns = disassemble_bytes(text, START, True)
    cases = discover_jump_tables(insns, read_addr, [TOC], START, END, [START]).get(DISPATCH, [])
    if len(cases) != 23 or 0x0091FC10 not in cases:
        parser.error("Toolchain did not recover all 23 case blocks. Apply the TOC spill fix.")

    lifter = PPULifter()
    lifter.jump_tables = {DISPATCH: cases}
    lifter.lift_function(insns, START, END)
    function, = lifter.functions
    if function.fallthrough_to:
        parser.error("Unexpected decoder fallthrough")
    body = "\n".join(lifter._function_def_lines(function, {START: function}, [START], {START: 0}))

    for path in sorted(args.recompiled.glob("ppu_recomp*.cpp")):
        original = path.read_text()
        begin = original.find(SIGNATURE)
        if begin == -1:
            continue
        finish = original.index("\n}\n", begin) + 3
        current = original[begin:finish]
        if all(f"case 0x{case:08X}u:" in current for case in cases):
            print(f"Animation dispatch already complete in {path}")
            return
        calls = re.compile(r"func_[A-F0-9]{8}")
        if set(calls.findall(body)) - set(calls.findall(current)):
            parser.error("Replacement would introduce a new lifted call target")
        with NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as output:
            output.write(original[:begin] + body.rstrip() + "\n" + original[finish:])
        Path(output.name).replace(path)
        print(f"Recovered 23 animation case blocks in {path}")
        return
    parser.error(f"Animation decoder was absent from {args.recompiled}")


if __name__ == "__main__":
    main()
