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

Usage: extract_cache.py <CacheDesc.dat> <CacheData.pak> <out_root>
"""
import os
import struct
import sys


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
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2], sys.argv[3])
