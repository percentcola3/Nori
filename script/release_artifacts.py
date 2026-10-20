#!/usr/bin/env python3
"""Verify the exact-source, architecture-scoped inputs of one workflow run."""
import argparse
import hashlib
from pathlib import Path, PurePosixPath
import plistlib
import posixpath
import re
import stat
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parent.parent
ARCHITECTURES = ("arm64", "x86_64")


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def validate_archive(path):
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if len(entries) > 20_000 or sum(item.file_size for item in entries) > 512 * 1024 * 1024:
            raise ValueError("unexpectedly large app archive")
        names = set()
        links = set()
        for item in entries:
            name = PurePosixPath(item.filename)
            parts = item.filename.rstrip("/").split("/")
            if (name.is_absolute() or any(part in {"", ".", ".."} for part in parts)
                    or "\\" in item.filename or not name.parts
                    or name.parts[0] not in {"Nori.app", "__MACOSX"}
                    or str(name) in names):
                raise ValueError("unsafe or duplicate app archive path")
            names.add(str(name))
            if name.parts[0] == "__MACOSX" and (len(name.parts) < 2 or name.parts[1] != "Nori.app"):
                raise ValueError("unexpected app archive metadata")
            kind = stat.S_IFMT(item.external_attr >> 16)
            if kind not in {0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK}:
                raise ValueError("unsupported app archive entry")
            if kind == stat.S_IFLNK:
                if name.parts[0] != "Nori.app" or item.file_size > 16_384:
                    raise ValueError("unsafe archive symlink")
                target = archive.read(item).decode("utf-8")
                resolved = posixpath.normpath(posixpath.join(posixpath.dirname(item.filename), target))
                if (not target or "\x00" in target or target.startswith("/")
                        or not (resolved == "Nori.app" or resolved.startswith("Nori.app/"))):
                    raise ValueError("app archive symlink escapes the bundle")
                links.add(str(name))
            if str(name) == "Nori.app/Contents/Info.plist" and kind not in {0, stat.S_IFREG}:
                raise ValueError("Info.plist must be a regular archive entry")
        for name in names:
            if any(str(parent) in links for parent in PurePosixPath(name).parents):
                raise ValueError("app archive entry traverses a symlink")
        if "Nori.app/Contents/Info.plist" not in names:
            raise ValueError("app archive is missing Info.plist")


def verify_inputs(directory, commit, source_ref, source_info):
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("expected a full source commit")
    if not re.fullmatch(r"refs/(heads|tags)/[^\r\n]+", source_ref):
        raise ValueError("invalid source ref")
    expected_names = set()
    version = source_info["CFBundleShortVersionString"]
    build = source_info["CFBundleVersion"]
    for arch in ARCHITECTURES:
        payloads = {f"Nori-{arch}.dmg", f"Nori-{arch}.app.zip", f"RELEASE-IDENTITY-{arch}.txt"}
        manifest = f"SHA256SUMS-{arch}"
        expected_names.update(payloads | {manifest})
        path = directory / manifest
        if path.is_symlink() or not path.is_file():
            raise ValueError("missing architecture manifest")
        checksums = {}
        for line in path.read_text().splitlines():
            match = re.fullmatch(r"([0-9a-f]{64}) [ *]([^/\\]+)", line)
            if not match or match[2] not in payloads or match[2] in checksums:
                raise ValueError("unexpected or duplicate architecture checksum")
            checksums[match[2]] = match[1]
        if set(checksums) != payloads:
            raise ValueError("incomplete architecture checksum manifest")
        for name, expected in checksums.items():
            path = directory / name
            if path.is_symlink() or not path.is_file() or digest(path) != expected:
                raise ValueError("architecture payload checksum mismatch: " + name)
        lines = (directory / f"RELEASE-IDENTITY-{arch}.txt").read_text().splitlines()
        for field, value in {"Source commit": commit, "Source ref": source_ref,
                             "Update public Ed25519 key": source_info["SUPublicEDKey"]}.items():
            matches = [line for line in lines if line.startswith(field + ":")]
            if matches != [field + ": " + value]:
                raise ValueError("architecture source identity mismatch: " + field)
        versions = [line for line in lines if line.startswith("Verified app version:")]
        expected_version = f"Verified app version: {version} (build {build})"
        if len(versions) != 1 or versions[0] not in {expected_version, expected_version + ", tag v" + version}:
            raise ValueError("architecture version identity mismatch")
        validate_archive(directory / f"Nori-{arch}.app.zip")
    if {item.name for item in directory.iterdir()} != expected_names:
        raise ValueError("unexpected files in release build inputs")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-dir", type=Path, required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--source-ref", required=True)
    args = parser.parse_args()
    head = subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True).strip()
    if head != args.source_commit:
        raise ValueError("workflow source does not match the checked-out commit")
    with (ROOT / "SimpleMole/Support/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    verify_inputs(args.input_dir, args.source_commit, args.source_ref, info)
    print("Verified both architecture payloads from source " + head)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, zipfile.BadZipFile, UnicodeError) as error:
        raise SystemExit("error: " + str(error))
