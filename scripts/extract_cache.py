#!/usr/bin/env python3
"""Pre-seed Pain's HDD game-data cache from the disc's CacheDesc.dat + CacheData.pak.

CacheDesc.dat layout (validated against the disassembly of Pain's installer,
0x001A9798..0x001A9C80): two big-endian u32 header words (entry count, total
payload bytes), then <count> records of 256 bytes: BE u32 file size + a
252-byte NUL-terminated relative path. Payloads are contiguous slices of
CacheData.pak in record order -- no compression, no padding; the manifest
total equals the pak size exactly.

Writes each file under <out_root>/USRDIR/<path> (out_root is the title's
game-data dir, e.g. <PS3_HDD0_ROOT>/game/BCES00548), and the completion
marker USRDIR/CacheFlags/CacheDone.flg ("Flag\0", 5 bytes) only after every
entry is extracted and the byte accounting balances.

A re-extraction removes the marker before it writes any payload, so an
interrupted run never leaves a complete-looking cache behind.

Usage: extract_cache.py <CacheDesc.dat> <CacheData.pak> <out_root>
       extract_cache.py --verify <CacheDesc.dat> <out_root>
           exits non-zero unless the marker and every manifest entry, at its
           manifest size, are present.
"""
import os
import struct
import sys


def read_manifest(desc_path):
    with open(desc_path, "rb") as f:
        desc = f.read()
    count, total = struct.unpack_from(">II", desc, 0)
    if (len(desc) - 8) // 256 != count:
        sys.exit(f"FATAL: manifest declares {count} records but holds {(len(desc) - 8) // 256}")
    entries = []
    for i in range(count):
        off = 8 + i * 256
        (size,) = struct.unpack_from(">I", desc, off)
        name = desc[off + 4:off + 256].split(b"\0")[0].decode("utf-8", "replace").lstrip("/")
        entries.append((name, size))
    return total, entries


def verify(desc_path, out_root):
    _, entries = read_manifest(desc_path)
    base = os.path.join(os.path.abspath(out_root), "USRDIR")
    marker = os.path.join(base, "CacheFlags", "CacheDone.flg")
    try:
        with open(marker, "rb") as f:
            if f.read() != b"Flag\0":
                return "marker has unexpected contents"
    except OSError:
        return "marker missing"
    for name, size in entries:
        dest = os.path.normpath(os.path.join(base, name))
        try:
            actual = os.path.getsize(dest)
        except OSError:
            return f"missing {name}"
        if actual != size:
            return f"{name} is {actual} bytes, manifest says {size}"
    return None


def main(desc_path, pak_path, out_root):
    with open(desc_path, "rb") as f:
        desc = f.read()
    count, total = struct.unpack_from(">II", desc, 0)
    pak_size = os.path.getsize(pak_path)
    if pak_size != total:
        sys.exit(f"FATAL: pak size {pak_size} != manifest total {total}")
    expected_records = (len(desc) - 8) // 256
    if expected_records != count:
        sys.exit(f"FATAL: manifest declares {count} records but holds {expected_records}")
    print(f"manifest: {count} entries, {total} payload bytes")

    base = os.path.join(os.path.abspath(out_root), "USRDIR")
    os.makedirs(base, exist_ok=True)
    try:
        os.remove(os.path.join(base, "CacheFlags", "CacheDone.flg"))
    except FileNotFoundError:
        pass

    offset = 0
    off = 8
    with open(pak_path, "rb") as pak:
        for i in range(count):
            (size,) = struct.unpack_from(">I", desc, off)
            raw = desc[off + 4:off + 256]
            name = raw.split(b"\0")[0].decode("utf-8", "replace").lstrip("/")
            off += 256
            if not name:
                sys.exit(f"FATAL: record {i} has an empty path")
            dest = os.path.normpath(os.path.join(base, name))
            if not (dest == base or dest.startswith(base + os.sep)):
                sys.exit(f"FATAL: path escapes root: {name!r}")
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            pak.seek(offset)
            data = pak.read(size)
            if len(data) != size:
                sys.exit(f"FATAL: short read at {name!r} ({len(data)} of {size})")
            with open(dest, "wb") as out:
                out.write(data)
            offset += size
            if (i + 1) % 500 == 0:
                print(f"  {i + 1}/{count} ({offset} bytes)")

    if offset != total:
        sys.exit(f"FATAL: consumed {offset} != manifest total {total}")
    flagdir = os.path.join(base, "CacheFlags")
    os.makedirs(flagdir, exist_ok=True)
    with open(os.path.join(flagdir, "CacheDone.flg"), "wb") as f:
        f.write(b"Flag\0")
    print(f"OK: {count} files extracted, {total} bytes, marker written")


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--verify":
        problem = verify(sys.argv[2], sys.argv[3])
        if problem:
            sys.exit(f"HDD cache incomplete: {problem}")
        print("HDD cache verified")
    elif len(sys.argv) == 4:
        main(sys.argv[1], sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)
