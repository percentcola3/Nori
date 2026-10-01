#!/usr/bin/env python3
"""Offline Sparkle dependency and signing-policy regression checks."""

import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("fetch_sparkle", ROOT / "script/fetch_sparkle.py")
FETCH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FETCH)

EXECUTABLES = (
    "bin/generate_keys", "bin/sign_update", "bin/generate_appcast",
    "Sparkle.framework/Versions/B/Sparkle", "Sparkle.framework/Versions/B/Autoupdate",
    "Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater",
    "Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer",
    "Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader",
)


class DependencyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="nori-sparkle-test-")
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.archive = self.work / "source.tar.xz"
        with tarfile.open(self.archive, "w:xz") as archive:
            for name in EXECUTABLES + ("LICENSE",):
                item = tarfile.TarInfo(name)
                contents = ("fixture:" + name).encode()
                item.size = len(contents)
                item.mode = 0o755 if name in EXECUTABLES else 0o644
                archive.addfile(item, io.BytesIO(contents))
            link = tarfile.TarInfo("Sparkle.framework/Versions/Current")
            link.type = tarfile.SYMTYPE
            link.linkname = "B"
            archive.addfile(link)
            link = tarfile.TarInfo("Sparkle.framework/Sparkle")
            link.type = tarfile.SYMTYPE
            link.linkname = "Versions/Current/Sparkle"
            archive.addfile(link)
        self.lock = {
            "version": "2.10.0", "archive": "Sparkle-2.10.0.tar.xz",
            "url": "https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz",
            "sha256": FETCH.sha256(self.archive),
        }
        self.cache = self.work / "cache"
        self.download_calls = []

    def download(self, url, destination):
        self.download_calls.append(url)
        shutil.copyfile(self.archive, destination)

    def prepare(self, **kwargs):
        return FETCH.prepare(self.lock, self.cache, downloader=self.download, **kwargs)

    def test_official_lock(self):
        lock = FETCH.load_lock(ROOT / "vendor/sparkle/release.json")
        self.assertEqual(lock["sha256"], "c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c")
        self.assertEqual(lock["architectures"], ["arm64", "x86_64"])

    def test_complete_dependency_and_reuse(self):
        sdk = self.prepare()
        self.assertEqual(self.download_calls, [self.lock["url"]])
        self.assertTrue((sdk / "Sparkle.framework/Sparkle").is_symlink())
        for executable in EXECUTABLES:
            self.assertTrue(os.access(sdk / executable, os.X_OK))
        self.assertEqual(self.prepare(offline=True), sdk)
        self.assertEqual(len(self.download_calls), 1)

    def test_modified_extracted_framework_is_restored(self):
        sdk = self.prepare()
        library = sdk / "Sparkle.framework/Versions/B/Sparkle"
        original = library.read_bytes()
        library.write_bytes(b"modified")
        self.prepare(offline=True)
        self.assertEqual(library.read_bytes(), original)

    def test_corrupt_download_is_rejected(self):
        self.lock["sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "Downloaded.*SHA256"):
            self.prepare()
        self.assertFalse((self.cache / self.lock["version"]).exists())

    def test_corrupt_cached_archive_is_rejected(self):
        self.prepare()
        (self.cache / "downloads" / self.lock["archive"]).write_bytes(b"modified")
        with self.assertRaisesRegex(ValueError, "Cached.*SHA256"):
            self.prepare()
        self.assertEqual(len(self.download_calls), 1)

    def test_offline_missing_archive_does_not_download(self):
        with self.assertRaisesRegex(ValueError, "offline cache"):
            self.prepare(offline=True)
        self.assertEqual(self.download_calls, [])

    def test_archive_paths_and_links_cannot_escape(self):
        for name, target in (("../outside", None), ("/outside", None), ("safe/link", "../../outside")):
            with self.subTest(name=name):
                archive_path = self.work / "unsafe.tar.xz"
                with tarfile.open(archive_path, "w:xz") as archive:
                    item = tarfile.TarInfo(name)
                    if target:
                        item.type = tarfile.SYMTYPE
                        item.linkname = target
                    archive.addfile(item)
                with self.assertRaisesRegex(ValueError, "Unsafe"):
                    FETCH.validate_archive(archive_path)

    def test_lock_rejects_unversioned_or_unofficial_source(self):
        path = self.work / "lock.json"
        for key, value in (("url", "https://example.com/sparkle.tar.xz"), ("version", "../current")):
            with self.subTest(key=key):
                lock = dict(self.lock)
                lock[key] = value
                path.write_text(json.dumps(lock))
                with self.assertRaises(ValueError):
                    FETCH.load_lock(path)


class SigningPolicyTests(unittest.TestCase):
    def resolve(self, records, identity="", local_label="Nori Local Signing", adhoc="0"):
        environment = os.environ.copy()
        environment.update({"SM_TEST_SIGNING_IDENTITIES": records, "SM_BUILD_RESOLVE_ONLY": "1",
                            "SM_CODESIGN_IDENTITY": identity, "SM_LOCAL_SIGN_LABEL": local_label,
                            "SM_ALLOW_ADHOC": adhoc})
        result = subprocess.run(["/bin/bash", str(ROOT / "script/build.sh")], env=environment,
                                capture_output=True, text=True, check=True)
        return dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)

    def test_exception_contains_only_library_validation(self):
        actual = plistlib.loads((ROOT / "signing/sparkle-selfsigned.entitlements").read_bytes())
        self.assertEqual(actual, {"com.apple.security.cs.disable-library-validation": True})

    def test_public_and_local_selfsigned_hosts_receive_exception(self):
        for label in ("Nori Local Signing", "ForgeSweep Release Signing"):
            with self.subTest(label=label):
                records = '  1) ' + 'A' * 40 + ' "' + label + '"'
                result = self.resolve(records, identity='A' * 40, local_label=label)
                self.assertEqual(result["kind"], "local")
                self.assertEqual(result["identity"], 'A' * 40)
                self.assertEqual(result["host_entitlements"], str(ROOT / "signing/sparkle-selfsigned.entitlements"))

    def test_explicit_adhoc_host_receives_exception(self):
        result = self.resolve("", identity="-", adhoc="1")
        self.assertEqual(result["kind"], "adhoc")
        self.assertTrue(result["host_entitlements"].endswith("sparkle-selfsigned.entitlements"))

    def test_apple_hosts_keep_library_validation(self):
        for label, kind in (("Apple Development: Fixture (ABC123)", "development"),
                            ("Developer ID Application: Fixture (ABC123)", "developer-id")):
            with self.subTest(label=label):
                records = '  1) ' + 'B' * 40 + ' "' + label + '"'
                result = self.resolve(records, identity=label)
                self.assertEqual(result["kind"], kind)
                self.assertEqual(result["host_entitlements"], "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
