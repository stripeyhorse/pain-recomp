#!/usr/bin/env python3
"""Build a metadata-only Metal preparation map from private PAIN captures."""

import argparse
import mmap
from pathlib import Path
import struct


def vertex_words(program):
    # The capture contains the native RSX vertex store's little-endian words.
    return ((0, b"".join(program[i:i + 4][::-1] for i in range(0, len(program), 4))),)


def fragment_instructions(program):
    # Buffered inline constants may change during play. Match the instructions
    # using the same slot rule as rsx_fp_structural_hash.
    blocks = []
    offset = 0
    while offset + 16 <= len(program):
        instruction = program[offset:offset + 16]
        blocks.append((offset, instruction))
        words = struct.unpack(">4I", instruction)
        words = [((word << 16) | (word >> 16)) & 0xffffffff for word in words]
        offset += 32 if any(word & 3 == 2 for word in words[1:]) else 16
        if words[0] & 1 and offset == len(program):
            return tuple(blocks)
    raise ValueError("Invalid captured fragment program")


def locate(asset, blocks, size):
    origin, anchor = max(blocks, key=lambda block: len(block[1]))
    position = asset.find(anchor)
    while position != -1:
        offset = position - origin
        if 0 <= offset <= len(asset) - size and all(
            asset[offset + start:offset + start + len(data)] == data for start, data in blocks
        ):
            return offset
        position = asset.find(anchor, position + 1)
    return None


def shader_inputs(captures):
    recipes = {}
    metadata_size = None
    for path in sorted(captures.glob("*.capture")):
        data = path.read_bytes()
        key, vs_hash, ps_hash, _, vs_size, ps_size = struct.unpack_from("<4Q2I", data)
        size = len(data) - vs_size - ps_size
        if (not key or not vs_hash or not ps_hash or not 40 <= size <= 2048 or
                not 0 < vs_size <= 65536 or not 0 < ps_size <= 65536 or
                vs_size % 16 or ps_size % 16 or key in recipes):
            raise ValueError(f"Invalid capture: {path.name}")
        if metadata_size is not None and metadata_size != size:
            raise ValueError("Captures from different shader recipe versions")
        metadata_size = size
        vp = (vs_size, vertex_words(data[size:size + vs_size]))
        fp = (ps_size, fragment_instructions(data[size + vs_size:]))
        recipes[key] = (data[:size], vp, fp)
    if not recipes:
        raise ValueError("No shader captures found")
    return metadata_size, recipes


def find_sources(root, shaders):
    missing = set(shaders)
    found = {}
    candidates = sorted(path for path in root.rglob("*") if path.is_file() and
                        path.suffix.lower() in {".bin", ".rsx", ".vbin", ".fbin"})
    for path in candidates:
        if not missing:
            break
        if not path.stat().st_size:
            continue
        identifier = path.relative_to(root).as_posix().encode("utf-8")
        if not 0 < len(identifier) < 480:
            continue
        with path.open("rb") as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as asset:
            for size, blocks in tuple(missing):
                offset = locate(asset, blocks, size)
                if offset is not None:
                    found[size, blocks] = (offset, identifier)
                    missing.remove((size, blocks))
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("captures", type=Path)
    parser.add_argument("installed_usrdir", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    size, recipes = shader_inputs(args.captures)
    shaders = {shader for _, vp, fp in recipes.values() for shader in (vp, fp)}
    inputs = find_sources(args.installed_usrdir, shaders)
    records = []
    for recipe, vp, fp in recipes.values():
        if vp not in inputs or fp not in inputs:
            continue
        vo, vn = inputs[vp]
        fo, fn = inputs[fp]
        records.append(recipe + struct.pack("<QQII", vo, fo, len(vn), len(fn)) + vn + fn)

    if not 0 < len(records) <= 2048:
        raise ValueError("No usable shader recipes, or recipe map exceeds its record limit")
    # Only render parameters, hashes, offsets and relative paths are emitted.
    args.output.write_bytes(struct.pack("<8sII", b"PRSMAP1", size, len(records)) + b"".join(records))
    print(f"Matched {len(records)} of {len(recipes)} captured pipelines to installed game files.")


if __name__ == "__main__":
    main()
