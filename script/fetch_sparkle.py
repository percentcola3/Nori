#!/usr/bin/env python3
"""Fetch and verify the pinned official Sparkle framework and release tools."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import re
import stat
import subprocess
import sys
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parent.parent
SCOPES = ("Sparkle.framework", "bin", "LICENSE")
MANIFEST = ".nori-sparkle-manifest.json"


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_lock(path):
    lock = json.loads(path.read_text())
    version = lock["version"]
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("Sparkle lock contains an invalid version")
    archive = "Sparkle-" + version + ".tar.xz"
    expected_url = "https://github.com/sparkle-project/Sparkle/releases/download/" + version + "/" + archive
    if lock["archive"] != archive or lock["url"] != expected_url:
        raise ValueError("Sparkle lock must reference the official versioned release archive")
    if not re.fullmatch(r"[0-9a-f]{64}", lock["sha256"]):
        raise ValueError("Sparkle lock contains an invalid SHA256")
    return lock


def inventory(directory):
    records = {}
    for scope in SCOPES:
        base = directory / scope
        if not base.exists():
            raise ValueError("Sparkle archive is missing " + scope)
        paths = [base] + (sorted(base.rglob("*")) if base.is_dir() else [])
        for path in paths:
            relative = path.relative_to(directory).as_posix()
            if path.is_symlink():
                records[relative] = {"link": os.readlink(path)}
            elif path.is_file():
                records[relative] = {"sha256": sha256(path), "mode": stat.S_IMODE(path.stat().st_mode)}
            elif not path.is_dir():
                raise ValueError("Unsupported Sparkle dependency entry: " + relative)
    return records


def validate_archive(archive):
    # The digest is checked first. Also reject paths or links that escape the
    # extraction directory, so cache replacement remains strictly scoped.
    with tarfile.open(archive, "r:xz") as stream:
        for member in stream.getmembers():
            path = PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts:
                raise ValueError("Unsafe path in Sparkle archive: " + member.name)
            if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
                raise ValueError("Unsupported entry in Sparkle archive: " + member.name)
            if member.issym() or member.islnk():
                target = member.linkname
                start = posixpath.dirname(member.name) if member.issym() else ""
                resolved = posixpath.normpath(posixpath.join(start, target))
                if target.startswith("/") or resolved == ".." or resolved.startswith("../"):
                    raise ValueError("Unsafe link in Sparkle archive: " + member.name)


def download(url, destination):
    subprocess.run([
        "/usr/bin/curl", "--fail", "--silent", "--show-error", "--location",
        "--proto", "=https", "--proto-redir", "=https", "--tlsv1.2",
        "--connect-timeout", "20", "--max-time", "180", "--retry", "2",
        "--output", str(destination), url,
    ], check=True)


def prepare(lock, cache, offline=False, downloader=download):
    cache.mkdir(parents=True, exist_ok=True)
    # Build and release jobs may share a local SDK cache. Serialize cold
    # preparation so one job cannot replace the directory another just prepared.
    with (cache / ".prepare.lock").open("a") as preparation_lock:
        fcntl.flock(preparation_lock.fileno(), fcntl.LOCK_EX)
        return prepare_locked(lock, cache, offline, downloader)


def prepare_locked(lock, cache, offline, downloader):
    archive = cache / "downloads" / lock["archive"]
    archive.parent.mkdir(exist_ok=True)
    if not archive.exists():
        if offline:
            raise ValueError("Pinned Sparkle archive is unavailable in the offline cache")
        with tempfile.TemporaryDirectory(prefix=".download-", dir=cache) as temporary:
            candidate = Path(temporary) / lock["archive"]
            print("==> Downloading Sparkle " + lock["version"], file=sys.stderr)
            downloader(lock["url"], candidate)
            if sha256(candidate) != lock["sha256"]:
                raise ValueError("Downloaded Sparkle archive failed its pinned SHA256 check")
            os.replace(candidate, archive)
    if not archive.is_file() or sha256(archive) != lock["sha256"]:
        raise ValueError("Cached Sparkle archive failed its pinned SHA256 check; remove that archive and retry")

    destination = cache / lock["version"]
    if destination.is_dir():
        try:
            manifest = json.loads((destination / MANIFEST).read_text())
            if manifest["archive_sha256"] == lock["sha256"] and manifest["files"] == inventory(destination):
                return destination
        except (OSError, ValueError, KeyError):
            pass

    validate_archive(archive)
    with tempfile.TemporaryDirectory(prefix=".extract-", dir=cache) as temporary:
        staged = Path(temporary) / "sdk"
        staged.mkdir()
        # bsdtar retains the versioned framework's symlinks and executable modes.
        subprocess.run(["/usr/bin/tar", "-xJf", str(archive), "-C", str(staged)], check=True)
        for required in ("bin/generate_keys", "bin/sign_update", "bin/generate_appcast",
                         "Sparkle.framework/Versions/B/Sparkle", "Sparkle.framework/Versions/B/Autoupdate",
                         "Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater",
                         "Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer",
                         "Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"):
            if not os.access(staged / required, os.X_OK):
                raise ValueError("Sparkle archive is missing executable " + required)
        manifest = {"archive_sha256": lock["sha256"], "files": inventory(staged)}
        (staged / MANIFEST).write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
        if destination.exists():
            os.replace(destination, Path(temporary) / "previous-sdk")
        os.replace(staged, destination)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache-dir", type=Path, default=ROOT / ".build/dependencies/sparkle")
    parser.add_argument("--offline", action="store_true", help="require a checksum-verified cached archive")
    arguments = parser.parse_args()
    try:
        lock = load_lock(ROOT / "vendor/sparkle/release.json")
        print(prepare(lock, arguments.cache_dir.resolve(), arguments.offline))
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError, tarfile.TarError) as error:
        print("error: " + str(error), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
