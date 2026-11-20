#!/usr/bin/env python3
"""Decode and lift PAIN's LevelScript modules from a local disc dump."""

import argparse
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys

PORT = Path(__file__).resolve().parents[1]
GENERATED = PORT / "prx" / "generated"
FIRST_BASE = 0x31000000
STRIDE = 0x100000
DESCRIPTOR_RESERVE = 0x1000
# The bank sits above managed SPU LS (0x30000000–0x301fffff) and below
# the game's mmapper allocations (0x40000000 family). Each lift keeps its EA.
BASE_LIMIT = 0x40000000
START = "0xBC9A0086"
STOP = "0xAB779874"


def u32(image, offset):
    return struct.unpack_from(">I", image, offset)[0]


def import_slot(image, base, thunk):
    """The lifter's import value names a glink thunk, not its writable slot."""
    _, high, load, save, entry, toc, ctr, branch = struct.unpack_from(
        ">8I", image, thunk - base
    )
    if (high >> 16, load >> 16, save, entry, toc, ctr, branch) != (
        0x658C, 0x818C, 0xF8410028, 0x800C0000, 0x804C0004, 0x7C0903A6, 0x4E800420
    ):
        raise ValueError(f"Unsupported import thunk at {thunk:#x}")
    slot = ((high & 0xFFFF) << 16) + struct.unpack(">h", struct.pack(">H", load & 0xFFFF))[0]
    if not base <= slot <= base + len(image) - 4 or u32(image, slot - base) != thunk:
        raise ValueError(f"Invalid import slot {slot:#x} for thunk {thunk:#x}")
    return slot


def lift_module(tools, out, index, source):
    stem = f"level_{index:03d}"
    base = FIRST_BASE + index * STRIDE
    data = out / "modules" / stem
    dest = out / "lift" / stem
    data.mkdir(parents=True, exist_ok=True)
    dest.mkdir(parents=True, exist_ok=True)
    prx = Path("decrypted") / f"{stem}.prx"
    image_path = data / f"{stem}_image.bin"
    seeds_path = data / f"{stem}_functions.json"
    exports_path = data / f"{stem}_exports.json"
    imports_path = data / f"{stem}_imports.json"
    with (data / "lift.log").open("w") as log:
        def run(tool, *args):
            subprocess.run([sys.executable, tools / tool, *args], check=True,
                           stdout=log, stderr=subprocess.STDOUT, cwd=out)

        try:
            run("lift_prx.py", prx, "--base", hex(base), "--output", data)
            image = image_path.read_bytes()
            metadata = json.loads(exports_path.read_text())
            if len(image) + DESCRIPTOR_RESERVE > STRIDE or metadata["module"] != "LEVEL_PRX":
                raise ValueError(f"Unexpected LevelScript image ({len(image):#x} bytes)")
            exports = metadata["exports"]
            entry = int(exports["!syslib"][START], 0)
            stop = int(exports["!syslib"].get(STOP, "0"), 0)
            toc = u32(image, entry - base + 4)

            # Use the actual exported descriptor's TOC. The module header's
            # unrelocated TOC field is relative to its data segment.
            raw = (out / prx).read_bytes()
            shoff, shentsize, shnum = (struct.unpack_from(">Q", raw, 0x28)[0],
                                       *struct.unpack_from(">HH", raw, 0x3A))
            sections = [struct.unpack_from(">IIQQQQ", raw, shoff + i * shentsize)
                        for i in range(shnum)]
            executable = [(base + va, base + va + size)
                          for _, kind, flags, va, _, size in sections
                          if kind == 1 and flags & 4 and size]
            code_end = max(end for _, end in executable)
            seeds = {start for start, _ in executable}
            seeds.update(int(f["start"], 0) for f in json.loads(seeds_path.read_text()))
            for offset in range(0, len(image) - 7, 4):
                if u32(image, offset + 4) == toc:
                    code = u32(image, offset)
                    if code % 4 == 0 and any(start <= code < end for start, end in executable):
                        seeds.add(code)
            for opd_text, code_text in metadata["opd_to_code"].items():
                opd, code = int(opd_text, 0), int(code_text, 0)
                if u32(image, opd - base + 4) != toc or not any(
                    start <= code < end for start, end in executable
                ):
                    raise ValueError(f"Invalid exported descriptor at {opd:#x}")
            seeds = sorted(seeds)
            lift_seeds = data / "functions_with_opds.json"
            lift_seeds.write_text(json.dumps([
                {"start": start, "end": end} for start, end in zip(seeds, seeds[1:] + [code_end])
            ]))

            hle_stubs = []
            slots = []
            for library, imports in json.loads(imports_path.read_text()).items():
                for nid, thunk_text in imports.items():
                    thunk = int(thunk_text, 0)
                    slots.append((import_slot(image, base, thunk), thunk))
                    hle_stubs.append({"library": library, "nid": nid, "stub": thunk_text})
            if len(slots) * 8 > DESCRIPTOR_RESERVE:
                raise ValueError("Import descriptors exceed the reserved page")
            stubs = data / "hle_stubs.json"
            stubs.write_text(json.dumps(hle_stubs, indent=2))
            run("ppu_lifter.py", image_path, "--raw", "--base", hex(base), "--toc", hex(toc),
                "--functions", lift_seeds, "--code-end", hex(code_end), "--hle-stubs", stubs,
                "--symbol-prefix", f"{stem}_", "--header-name", f"{stem}.h",
                "--source-name", f"{stem}.cpp", "--chunks", "3", "--jobs", "1", "--output", dest)
        except (subprocess.CalledProcessError, ValueError) as exc:
            raise RuntimeError(f"{source}: {exc}. See {log.name}") from exc

    export_rows = [(int(nid, 0), int(opd, 0) - base)
                   for nid, opd in exports["LevelScriptExport"].items()]
    return stem, base, len(image), toc, entry, stop, export_rows, slots


def emit_catalog(out, results, aliases):
    lines = ["// Generated locally by prepare_levelscripts.py."]
    for stem, base, size, toc, entry, stop, exports, slots in results:
        lines += [
            f"extern const func_entry {stem}_function_table[];",
            f"extern const uint64_t {stem}_function_table_count;",
            f"static const prx_export {stem}_exports[] = {{",
            *(f"    {{{nid:#x}, {offset:#x}}}," for nid, offset in exports),
            "};",
            f"static const ImportSlot {stem}_imports[] = {{",
            *(f"    {{{slot:#x}, {thunk:#x}}}," for slot, thunk in slots),
            "};",
            f"static const LevelModule {stem} = {{",
            f'    "{stem}", {base:#x}, {size:#x}, {toc:#x}, {entry:#x}, {stop:#x},',
            f"    {base + STRIDE - DESCRIPTOR_RESERVE:#x},",
            f"    {stem}_function_table, &{stem}_function_table_count,",
            f"    {stem}_exports, {stem}_imports",
            "};",
        ]
    lines.append("static const LevelModule* const level_modules[] = {")
    lines.extend(f"    &{row[0]}," for row in results)
    lines.extend(("};", "static const LevelPath level_paths[] = {"))
    lines.extend(f"    {{{json.dumps(path)}, &{stem}}}," for path, stem in sorted(aliases))
    lines.append("};")
    (out / "catalog.inc").write_text("\n".join(lines) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("usrdir", type=Path, help="Local PS3_GAME/USRDIR")
    parser.add_argument("--rpcs3", type=Path, required=True, help="RPCS3 executable or AppImage")
    parser.add_argument("--toolkit", type=Path, default=PORT.parent / "ps3recomp")
    parser.add_argument("--output", type=Path, default=GENERATED / "full",
                        help="A new directory under prx/generated")
    parser.add_argument("--only", help="Only build modules matching this USRDIR-relative glob")
    parser.add_argument("--jobs", type=int, default=min(4, os.cpu_count() or 1))
    args = parser.parse_args()
    usrdir = args.usrdir.resolve()
    out = args.output.resolve()
    if GENERATED not in out.parents or out.exists():
        parser.error("--output must be a new directory under prx/generated")
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    rpcs3 = args.rpcs3.resolve(strict=True)
    tools = args.toolkit.resolve() / "tools"
    groups = defaultdict(list)
    for path in sorted(usrdir.glob("Themes/*/Levels/**/Scripts/PS3_PPU_Release/LevelScript.sprx")):
        groups[hashlib.sha256(path.read_bytes()).digest()].append(path)
    if not groups or FIRST_BASE + len(groups) * STRIDE > BASE_LIMIT:
        parser.error(f"Unexpected number of unique modules: {len(groups)}")

    selected = [(index, paths) for index, paths in enumerate(groups.values())
                if args.only is None or any(fnmatch.fnmatchcase(p.relative_to(usrdir).as_posix(), args.only)
                                            for p in paths)]
    if not selected:
        parser.error(f"No LevelScript matches {args.only!r}")
    decrypted = out / "decrypted"
    decrypted.mkdir(parents=True)
    inputs = []
    aliases = []
    for index, paths in selected:
        stem = f"level_{index:03d}"
        sprx = decrypted / f"{stem}.sprx"
        shutil.copyfile(paths[0], sprx)
        inputs.append(sprx)
        aliases.extend((p.relative_to(usrdir).as_posix(), stem) for p in paths)
    print(f"Preparing {len(selected)} distinct PRXs for {len(aliases)} guest paths", flush=True)
    env = dict(os.environ, QT_QPA_PLATFORM="offscreen", APPIMAGE_EXTRACT_AND_RUN="1")
    for kind in ("CACHE", "CONFIG", "DATA", "STATE"):
        env[f"XDG_{kind}_HOME"] = str(out / "rpcs3" / kind.lower())
    decrypt_args = [arg for path in inputs for arg in ("--decrypt", path)]
    with (out / "decrypt.log").open("w") as log:
        subprocess.run([rpcs3, *decrypt_args], check=True, env=env, cwd=out,
                       stdout=log, stderr=subprocess.STDOUT)
    for sprx in inputs:
        if not sprx.with_suffix(".prx").is_file():
            raise RuntimeError(f"RPCS3 did not decrypt {sprx.name}. See {out / 'decrypt.log'}")
    with ThreadPoolExecutor(max_workers=args.jobs) as executor:
        results = list(executor.map(lambda item: lift_module(tools, out, item[0], item[1][0]),
                                    selected))
    emit_catalog(out, results, aliases)
    print(f"LevelScript catalog ready: {out}")


if __name__ == "__main__":
    main()
