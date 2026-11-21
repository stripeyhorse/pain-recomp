#!/usr/bin/env python3
"""Validate and prepare a local BCES00548 disc for the precompiled Mac runner."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from zipfile import BadZipFile, ZipFile

BOOT = "USRDIR/EBOOT.BIN"
CACHE_DESC = "USRDIR/CacheDesc.dat"
CACHE_PAK = "USRDIR/CacheData.pak"
CACHE_MARKER = "game/BCES00548/USRDIR/CacheFlags/CacheDone.flg"
BUFFER_SIZE = 1024 * 1024


class GameDataError(Exception):
    pass


def file_hash(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def build_manifest(disc, catalog, output):
    files = {}
    for path in sorted(disc.rglob("*")):
        relative = path.relative_to(disc)
        if path.is_file() and not any(part.startswith(".") for part in relative.parts):
            if relative.as_posix() != "USRDIR/EBOOT.elf":
                files[relative.as_posix()] = [path.stat().st_size, file_hash(path)]
    for required in ("PARAM.SFO", BOOT, CACHE_DESC, CACHE_PAK):
        if required not in files:
            raise GameDataError(f"Build input is missing {required}.")

    levels = {}
    rows = catalog.joinpath("catalog.inc").read_text()
    aliases = re.findall(r'^    \{(".*"), &(level_\d{3})\},$', rows, re.MULTILINE)
    for encoded_path, stem in aliases:
        relative = "USRDIR/" + json.loads(encoded_path)
        if relative not in files:
            raise GameDataError(f"Build input is missing {relative}.")
        levels.setdefault(stem, relative)
    if len(levels) != 90 or len(aliases) != 91:
        raise GameDataError("The Mac build requires the full LevelScript catalogue.")
    modules = {
        stem: [path, file_hash(catalog / "modules" / stem / f"{stem}_image.bin")]
        for stem, path in sorted(levels.items())
    }
    output.write_text(json.dumps({
        "files": files,
        "elf": file_hash(disc / "USRDIR/EBOOT.elf"),
        "modules": modules,
    }, indent=2) + "\n")


def report(message):
    print(message, flush=True)


def check_file(data, path, expected, destination=None):
    size, sha256 = expected
    digest = hashlib.sha256()
    read = 0
    while block := data.read(BUFFER_SIZE):
        read += len(block)
        if read > size:
            break
        digest.update(block)
        if destination is not None:
            destination.write(block)
    if read != size or digest.hexdigest() != sha256:
        raise GameDataError(f"{path} does not match the supported BCES00548 disc (version 01.00).")


def find_disc(source):
    if source.name == "PS3_GAME":
        return source
    direct = source / "PS3_GAME"
    if direct.is_dir():
        return direct
    choices = [path for path in source.glob("*/*/PS3_GAME") if path.is_dir()]
    choices.extend(path for path in source.glob("*/PS3_GAME") if path.is_dir())
    if len(choices) != 1:
        raise GameDataError("Choose the PAIN ZIP, its extracted folder, or its PS3_GAME folder.")
    return choices[0]


def validate_folder(source, manifest):
    disc = find_disc(source)
    for name, expected in manifest["files"].items():
        item = disc / name
        if not item.is_file():
            raise GameDataError(f"The selected folder is missing PS3_GAME/{name}.")
        with item.open("rb") as payload:
            check_file(payload, name, expected)
    return disc


def validate_archive(source, manifest, destination):
    with ZipFile(source) as archive:
        index = {}
        roots = set()
        for entry in archive.infolist():
            name = PurePosixPath(entry.filename)
            if entry.is_dir() or name.is_absolute() or ".." in name.parts or "\\" in entry.filename:
                continue
            if name.parts[-2:] == ("PS3_GAME", "PARAM.SFO"):
                roots.add(name.parent)
            if name in index:
                raise GameDataError(f"The ZIP contains duplicate entries for {name}.")
            index[name] = entry
        if len(roots) != 1:
            raise GameDataError("The ZIP must contain one PAIN PS3_GAME folder.")
        prefix = roots.pop()
        for name, expected in manifest["files"].items():
            entry = index.get(prefix / name)
            if entry is None:
                raise GameDataError(f"The ZIP is missing PS3_GAME/{name}.")
            if entry.flag_bits & 1:
                raise GameDataError("Use an unencrypted ZIP or extract it before choosing the folder.")
            if stat.S_ISLNK(entry.external_attr >> 16) or entry.file_size != expected[0]:
                raise GameDataError(f"The ZIP entry PS3_GAME/{name} has an unexpected type or size.")
            target = destination / name
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(entry) as payload, target.open("wb") as output:
                check_file(payload, name, expected, output)


def prepare_data(disc, manifest, scratch, rpcs3, log_dir):
    from extract_cache import main as extract_cache
    from lift_prx import Prx

    prepared = scratch / "prepared"
    prepared.mkdir()
    decryption = scratch / "decrypt"
    decryption.mkdir()
    home = scratch / "rpcs3"
    home.mkdir()

    stem = decryption / "EBOOT.BIN"
    shutil.copyfile(disc / BOOT, stem)
    inputs = [stem]
    for name, (relative, _) in manifest["modules"].items():
        encrypted = decryption / f"{name}.sprx"
        shutil.copyfile(disc / relative, encrypted)
        inputs.append(encrypted)

    report("Preparing game executables…")
    env = dict(os.environ, QT_QPA_PLATFORM="offscreen", HOME=str(home), CFFIXED_USER_HOME=str(home))
    for kind in ("CACHE", "CONFIG", "DATA", "STATE"):
        env[f"XDG_{kind}_HOME"] = str(home / kind.lower())
    env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    args = [str(rpcs3), *(arg for path in inputs for arg in ("--decrypt", str(path)))]
    with (log_dir / "decrypt.log").open("w") as log:
        result = subprocess.run(args, env=env, cwd=home, stdout=log, stderr=subprocess.STDOUT)
    executable = stem.with_suffix(".elf")
    if result.returncode or not executable.is_file() or file_hash(executable) != manifest["elf"]:
        raise GameDataError("The game executable could not be prepared. See decrypt.log.")
    executable.rename(prepared / "EBOOT.elf")

    for name, (_, expected) in manifest["modules"].items():
        decrypted = decryption / f"{name}.prx"
        if not decrypted.is_file():
            raise GameDataError(f"A LevelScript could not be decrypted ({name}). See decrypt.log.")
        base = 0x31000000 + int(name.removeprefix("level_")) * 0x100000
        image, _ = Prx(decrypted).build_image(base)
        if hashlib.sha256(image).hexdigest() != expected:
            raise GameDataError(f"A prepared LevelScript did not match this build ({name}).")
        out = prepared / "levels" / "modules" / name
        out.mkdir(parents=True)
        (out / f"{name}_image.bin").write_bytes(image)

    report("Building the local game cache…")
    extract_cache(disc / CACHE_DESC, disc / CACHE_PAK, prepared / "hdd0/game/BCES00548")
    return prepared


def prepared_ok(prepared, manifest):
    return (
        (prepared / "EBOOT.elf").is_file()
        and (prepared / "hdd0" / CACHE_MARKER).is_file()
        and all((prepared / "levels" / "modules" / name / f"{name}_image.bin").is_file()
                for name in manifest["modules"])
    )


def import_game(source, state, manifest_path, rpcs3):
    source = source.resolve(strict=True)
    manifest_bytes = manifest_path.read_bytes()
    manifest = json.loads(manifest_bytes)
    key = hashlib.sha256(manifest_bytes).hexdigest()[:16]
    library = state / "library"
    logs = state / "logs"
    library.mkdir(parents=True, exist_ok=True)
    logs.mkdir(parents=True, exist_ok=True)
    with (library / "import.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with tempfile.TemporaryDirectory(prefix="import-", dir=library) as temp:
            scratch = Path(temp)
            report("Checking PAIN disc files…")
            if source.is_file() and source.suffix.lower() == ".zip":
                disc = scratch / "PS3_GAME"
                validate_archive(source, manifest, disc)
            elif source.is_dir():
                disc = validate_folder(source, manifest)
            else:
                raise GameDataError("Choose your PAIN disc ZIP or extracted folder.")

            prepared = library / f"prepared-{key}"
            if not prepared_ok(prepared, manifest):
                new_data = prepare_data(disc, manifest, scratch, rpcs3, logs)
                if prepared.exists():
                    temp_name = scratch.name
                    prepared = library / f"prepared-{key}-{temp_name}"
                new_data.rename(prepared)

            if disc == scratch / "PS3_GAME":
                imported = library / f"disc-{key}"
                if imported.exists():
                    try:
                        disc = validate_folder(imported, manifest)
                    except GameDataError:
                        imported = library / f"disc-{key}-{scratch.name}"
                if disc == scratch / "PS3_GAME":
                    new_disc = scratch / "disc"
                    new_disc.mkdir()
                    disc.rename(new_disc / "PS3_GAME")
                    new_disc.rename(imported)
                    disc = imported / "PS3_GAME"

            selection = {
                "source": str(source), "disc": str(disc), "prepared": str(prepared),
            }
            candidate = scratch / "selection.json"
            candidate.write_text(json.dumps(selection) + "\n")
            candidate.replace(state / "selection.json")
    report("PAIN disc verified and ready to play.")


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    manifest = commands.add_parser("manifest")
    for name in ("disc", "catalog", "output"):
        manifest.add_argument(name, type=Path)
    install = commands.add_parser("import")
    for name in ("source", "state", "manifest", "rpcs3"):
        install.add_argument(name, type=Path)
    args = parser.parse_args()
    try:
        if args.command == "manifest":
            build_manifest(args.disc, args.catalog, args.output)
        else:
            import_game(args.source, args.state, args.manifest, args.rpcs3)
    except (GameDataError, OSError, BadZipFile) as exc:
        report(f"Error: {exc}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
