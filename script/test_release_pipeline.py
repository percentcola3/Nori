#!/usr/bin/env python3
"""Exercise shard coverage and the signed-build assembly protocol without keys."""
import collections
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import stat
import subprocess
import tempfile
import unittest
import warnings
import zipfile

import release_artifacts

ROOT = Path(__file__).resolve().parent.parent
COMMIT = "a" * 40
REF = "refs/heads/master"
INFO = {"CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "42", "SUPublicEDKey": "fixture-public-key"}


class RegressionCoverageTests(unittest.TestCase):
    def trace(self, group=None):
        # Replace only execution boundaries in a fixture copy. Bash still
        # evaluates the real argument parsing, conditionals and shard routing.
        source = (ROOT / "script/test.sh").read_text()
        definitions, dispatch = source.split("printf 'Nori local regression tests\\n'", 1)
        definitions = re.sub(r'^ROOT_DIR=.*$', "ROOT_DIR=" + shlex.quote(str(ROOT)), definitions, count=1, flags=re.M)
        functions = re.findall(r"^(test_[a-z_]+|stage_bridge_runtime)\(\)", definitions, re.M)
        stubs = [name + "() { printf 'TRACE function:" + name + "\\n'; }" for name in functions]
        stubs += [
            "bash() { local name=${1##*/}; shift; printf 'TRACE shell:%s' \"$name\"; "
            "if [[ $# -gt 0 ]]; then printf ' %s' \"$@\"; fi; printf '\\n'; }",
            "pipeline_python() { printf 'TRACE shell:%s\\n' \"${1##*/}\"; }",
            "pipeline_fetch_sparkle() { printf '/verified-public-sparkle\\n'; }",
        ]
        dispatch = dispatch.replace('/usr/bin/python3 "$ROOT_DIR/script/test_sparkle.py"',
                                    'pipeline_python "$ROOT_DIR/script/test_sparkle.py"')
        dispatch = dispatch.replace('$(/usr/bin/python3 "$ROOT_DIR/script/fetch_sparkle.py")',
                                    '$(pipeline_fetch_sparkle)')
        program = definitions + "\n" + "\n".join(stubs) + "\n" + dispatch
        arguments = [] if group is None else ["--group", group]
        result = subprocess.run(["bash", "-s", "--", *arguments], input=program, text=True,
                                capture_output=True, env={**os.environ, "SM_TEST_SKIP_SWIFT": "0", "SM_TEST_BUILD": "0"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return [line.removeprefix("TRACE ") for line in result.stdout.splitlines() if line.startswith("TRACE ")]

    def test_default_and_shards_cover_every_original_check_once(self):
        expected = json.loads((ROOT / "script/release_regression_suites.json").read_text())
        self.assertEqual(len(expected), len(set(expected)), "duplicate canonical regression entry")
        self.assertEqual(self.trace(), expected, "default regression changed or omitted a check")
        groups = {group: self.trace(group) for group in ("preflight", "native-a", "native-b", "native-c", "contracts")}
        self.assertEqual(groups["preflight"], expected[:2])
        for group in ("native-a", "native-b", "native-c"):
            self.assertEqual(sum(item.startswith("shell:") for item in groups[group]), 17)
        self.assertEqual(collections.Counter(item for items in groups.values() for item in items),
                         collections.Counter(expected), "shards omit or repeat regression checks")
        self.assertIn("function:test_agent_cleanup_selection_contract", groups["native-b"])
        self.assertIn("function:test_media_cleanup_selection_contract", groups["native-c"])

    def test_invalid_arguments_fail_before_any_test_runs(self):
        for args in (["--group", "typo"], ["--group"], ["--other", "native-a"], ["--group", "all", "extra"]):
            with self.subTest(args=args):
                result = subprocess.run(["bash", str(ROOT / "script/test.sh"), *args], capture_output=True, text=True)
                self.assertEqual(result.returncode, 2)
                self.assertNotIn("Nori local regression tests", result.stdout)

    def test_failed_suite_stops_its_group(self):
        source = (ROOT / "script/test.sh").read_text()
        functions = source[source.index("runs_group()"):source.index("assert_status()")]
        result = subprocess.run(["bash", "-c", "set -euo pipefail\nTEST_GROUP=native-a\n" + functions +
                                 "\nrun_suite native-a bash -c 'exit 23' || exit $?\necho unexpected-success\n"],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 23)
        self.assertNotIn("unexpected-success", result.stdout)

    def test_workflow_gates_and_cache_boundaries(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        jobs = dict(re.findall(r"^  ([a-z-]+):\n(.*?)(?=^  [a-z-]+:\n|\Z)", workflow.split("jobs:\n", 1)[1], re.M | re.S))
        self.assertEqual(set(jobs), {"preflight", "regression", "build", "assemble", "draft-release"})
        self.assertIn("needs: [preflight, regression, build]", jobs["assemble"])
        self.assertIn("group: [native-a, native-b, native-c, contracts]", jobs["regression"])
        self.assertIn("architecture: [arm64, x86_64]", jobs["build"])
        self.assertIn("needs: preflight", jobs["build"])
        self.assertIn("needs: preflight", jobs["regression"])
        self.assertNotIn("secrets.", jobs["preflight"] + jobs["regression"])
        self.assertIn("github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v')", jobs["draft-release"])
        self.assertIn("needs: assemble", jobs["draft-release"])
        self.assertIn("--verify-tag --draft", jobs["draft-release"])
        self.assertNotIn("gh release", jobs["build"] + jobs["assemble"])
        self.assertIn("pattern: Nori-package-*", jobs["assemble"])
        self.assertNotIn("run-id:", jobs["assemble"])
        self.assertNotIn("package_release.sh", jobs["assemble"])
        self.assertIn("group: release-${{ github.ref }}\n", workflow)
        self.assertEqual(workflow.count("architecture: native"), 3)
        prepare = (ROOT / ".github/actions/prepare-build/action.yml").read_text()
        save = (ROOT / ".github/actions/save-build-cache/action.yml").read_text()
        self.assertIn("github.event_name != 'pull_request'", prepare)
        self.assertIn("github.event_name != 'pull_request'", save)
        self.assertIn("run: python3 script/fetch_sparkle.py", prepare)
        self.assertIn("path: .build/dependencies/sparkle/downloads", prepare)
        self.assertIn("path: ${{ steps.sdk.outputs.cache-directory }}", prepare)
        ci = (ROOT / "script/ci_prepare.sh").read_text()
        self.assertIn(".build/ci-swift-modules/$ARCH", ci)
        self.assertNotRegex(prepare + save, r"path:.*(?:dist|keychain|signing|\*\*)")
        assemble = (ROOT / "script/assemble_release.sh").read_text()
        self.assertIn("release_artifacts.py", assemble)
        self.assertIn("verify_release.sh", assemble)
        self.assertNotRegex(assemble, r"(?:swiftc|build\.sh|package_release\.sh)")


class ArtifactProtocolTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="nori-pipeline-tests-")
        self.directory = Path(self.temporary.name)
        for arch in release_artifacts.ARCHITECTURES:
            (self.directory / f"Nori-{arch}.dmg").write_bytes(b"fixture-package")
            self.archive(arch)
            (self.directory / f"RELEASE-IDENTITY-{arch}.txt").write_text(
                f"Source commit: {COMMIT}\nSource ref: {REF}\n"
                "Verified app version: 1.2.3 (build 42)\nUpdate public Ed25519 key: fixture-public-key\n")
            self.manifest(arch)

    def tearDown(self):
        self.temporary.cleanup()

    def archive(self, arch="arm64", extra=(), info=True):
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(self.directory / f"Nori-{arch}.app.zip", "w") as archive:
                if info:
                    archive.writestr("Nori.app/Contents/Info.plist", plistlib.dumps(INFO))
                for name, data, kind in extra:
                    item = zipfile.ZipInfo(name)
                    item.create_system = 3
                    item.external_attr = (kind | 0o755) << 16
                    archive.writestr(item, data)

    def manifest(self, arch="arm64"):
        names = [f"Nori-{arch}.dmg", f"Nori-{arch}.app.zip", f"RELEASE-IDENTITY-{arch}.txt"]
        (self.directory / f"SHA256SUMS-{arch}").write_text("".join(
            hashlib.sha256((self.directory / name).read_bytes()).hexdigest() + "  " + name + "\n" for name in names))

    def verify(self):
        release_artifacts.verify_inputs(self.directory, COMMIT, REF, INFO)

    def test_valid_both_architectures_and_framework_symlinks(self):
        self.archive(extra=[("Nori.app/Contents/Frameworks/Foo.framework/Versions/Current", "B", stat.S_IFLNK),
                            ("Nori.app/Contents/Frameworks/Foo.framework/Versions/B/Foo", b"fixture", stat.S_IFREG),
                            ("__MACOSX/Nori.app/Contents/._Info.plist", b"metadata", stat.S_IFREG)])
        self.manifest()
        self.verify()

    def test_tamper_missing_architecture_unexpected_input_and_symlink(self):
        path = self.directory / "Nori-arm64.dmg"
        original = path.read_bytes()
        path.write_bytes(b"tampered")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            self.verify()
        path.write_bytes(original)
        path.unlink()
        path.symlink_to("Nori-x86_64.dmg")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            self.verify()
        path.unlink()
        path.write_bytes(original)
        extra = self.directory / "unexpected.txt"
        extra.touch()
        with self.assertRaisesRegex(ValueError, "unexpected files"):
            self.verify()
        extra.unlink()
        (self.directory / "SHA256SUMS-x86_64").unlink()
        with self.assertRaisesRegex(ValueError, "missing architecture"):
            self.verify()

    def test_manifest_rejects_missing_duplicate_and_escaping_names(self):
        path = self.directory / "SHA256SUMS-arm64"
        original = path.read_text()
        for content in (original.splitlines()[0] + "\n", original + original.splitlines()[0] + "\n",
                        original.replace("Nori-arm64.dmg", "../Nori-arm64.dmg")):
            with self.subTest(content=content):
                path.write_text(content)
                with self.assertRaises(ValueError):
                    self.verify()

    def test_identity_must_match_source_ref_commit_version_build_and_update_key(self):
        path = self.directory / "RELEASE-IDENTITY-arm64.txt"
        original = path.read_text()
        for old, new in ((COMMIT, "b" * 40), (REF, "refs/heads/other"), ("1.2.3", "1.2.4"),
                         ("build 42", "build 43"), ("fixture-public-key", "other-key")):
            with self.subTest(field=old):
                path.write_text(original.replace(old, new))
                self.manifest()
                with self.assertRaisesRegex(ValueError, "identity mismatch"):
                    self.verify()
        path.write_text(original + f"Source commit: {COMMIT}\n")
        self.manifest()
        with self.assertRaisesRegex(ValueError, "identity mismatch"):
            self.verify()

    def test_archive_rejects_path_traversal_duplicate_special_file_and_escaping_links(self):
        cases = [
            [("../escape", b"x", stat.S_IFREG)],
            [("/Nori.app/escape", b"x", stat.S_IFREG)],
            [("Nori.app/Contents//escape", b"x", stat.S_IFREG)],
            [("Nori.app/Contents/./escape", b"x", stat.S_IFREG)],
            [("Nori.app/Contents/Info.plist", b"duplicate", stat.S_IFREG)],
            [("Nori.app/pipe", b"x", stat.S_IFIFO)],
            [("__MACOSX/other", b"x", stat.S_IFREG)],
            [("Nori.app/link", "../../escape", stat.S_IFLNK)],
            [("Nori.app/link", "/tmp/escape", stat.S_IFLNK)],
            [("Nori.app/link", "Contents", stat.S_IFLNK), ("Nori.app/link/file", b"x", stat.S_IFREG)],
        ]
        for entries in cases:
            with self.subTest(entries=entries):
                self.archive(extra=entries)
                self.manifest()
                with self.assertRaises(ValueError):
                    self.verify()
        self.archive(info=False)
        self.manifest()
        with self.assertRaisesRegex(ValueError, "missing Info.plist"):
            self.verify()


class PreviousReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="nori-previous-release-tests-")
        self.root = Path(self.temporary.name)
        (self.root / "script").mkdir()
        (self.root / "bin").mkdir()
        shutil.copy(ROOT / "script/check_previous_release.sh", self.root / "script")
        self.log = self.root / "calls"
        (self.root / "script/verify_release_continuity.sh").write_text('echo continuity >> "$FIXTURE_LOG"\n')
        (self.root / "script/release_appcast.sh").write_text('printf "version %s\\n" "$*" >> "$FIXTURE_LOG"\n')
        gh = self.root / "bin/gh"
        gh.write_text('''#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  'api repos/fixture/repo/releases/latest')
    [[ "$FIXTURE_MODE" != lookup_error && "$FIXTURE_MODE" != bootstrap && "$FIXTURE_MODE" != offline ]] || exit 1
    echo v1.2.2 ;;
  'release list')
    [[ "$FIXTURE_MODE" != offline ]] || exit 1
    [[ "$FIXTURE_MODE" == bootstrap ]] || echo v1.2.2 ;;
  'release download')
    [[ "$FIXTURE_MODE" != download_error ]] || exit 1
    touch "${@: -1}/RELEASE-IDENTITY.txt" ;;
  *) exit 99 ;;
esac
''')
        gh.chmod(0o755)

    def tearDown(self):
        self.temporary.cleanup()

    def run_check(self, mode, tag=""):
        result = subprocess.run(["bash", str(self.root / "script/check_previous_release.sh"), tag,
                                 str(self.root / "previous")], text=True, capture_output=True,
                                env={**os.environ, "GH_REPO": "fixture/repo", "FIXTURE_MODE": mode,
                                     "FIXTURE_LOG": str(self.log), "PATH": str(self.root / "bin") + ":" + os.environ["PATH"]})
        calls = self.log.read_text() if self.log.exists() else ""
        return result, calls

    def test_manual_validation_preserves_continuity_without_advancing_version(self):
        result, calls = self.run_check("valid")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, "continuity\n")

    def test_tag_requires_version_progression(self):
        result, calls = self.run_check("valid", "v1.2.3")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--tag v1.2.3 --previous-identity", calls)

    def test_only_empty_stable_release_list_allows_bootstrap(self):
        result, calls = self.run_check("bootstrap", "v1.2.3")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, "")

    def test_lookup_network_and_identity_download_fail_closed(self):
        for mode in ("lookup_error", "offline", "download_error"):
            with self.subTest(mode=mode):
                result, calls = self.run_check(mode, "v1.2.3")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
