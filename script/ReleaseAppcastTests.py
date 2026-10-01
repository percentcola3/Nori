#!/usr/bin/env python3
"""Behavioral checks for release feeds with real Ed25519 and Mach-O fixtures."""
import base64
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

root, verifier, signer = map(Path, sys.argv[1:])
checks = 0
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def expect(command, succeeds=True, message=None):
    global checks
    result = subprocess.run(command, capture_output=True, text=True)
    if (result.returncode == 0) != succeeds or (message and message not in result.stderr):
        raise AssertionError("unexpected command result: " + result.stdout + result.stderr)
    checks += 1
    return result


with tempfile.TemporaryDirectory(prefix="nori-appcast-fixture-") as temporary:
    work = Path(temporary)
    dist = work / "dist"
    dist.mkdir()
    key_file = work / "ephemeral-test-key"
    public_key = expect([str(signer), "fixture-key", str(key_file)]).stdout.strip()
    source_info = work / "Info.plist"
    public_config = work / "update.plist"
    public_config.write_bytes(plistlib.dumps({"PublicEDKey": public_key}))
    info = {"CFBundleIdentifier": "com.nori.app", "CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "7",
            "SUPublicEDKey": public_key, "LSMinimumSystemVersion": "13.0"}
    source_info.write_bytes(plistlib.dumps(info))
    notes = work / "notes.md"
    notes.write_text("# Nori 1.2.3\n\n修复 <脚本> & 更新。", encoding="utf-8")
    c_source = work / "fixture.c"
    c_source.write_text("int main(void) { return 0; }\n")
    for arch in ("arm64", "x86_64"):
        contents = dist / arch / "Nori.app" / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        expect(["clang", "-target", arch + "-apple-macos13.0", str(c_source), "-o", str(contents / "MacOS" / "Nori")])
        app_info = dict(info, SUFeedURL="https://github.com/percentcola3/sweep/releases/latest/download/appcast-" + arch + ".xml")
        (contents / "Info.plist").write_bytes(plistlib.dumps(app_info))
        (dist / ("Nori-" + arch + ".dmg")).write_bytes(b"archive fixture " + arch.encode() + b"\x00\xff" * 256)
    base = [sys.executable, str(root / "script/release_appcast.py")]
    common = ["--source-info", str(source_info), "--public-config", str(public_config), "--tag", "v1.2.3", "--dist-dir", str(dist),
              "--signature-verifier", str(verifier)]
    generate = base + ["generate"] + common + ["--sign-tool", str(signer), "--private-key-file", str(key_file), "--notes-file", str(notes)]
    verify = base + ["verify"] + common
    expect(generate)
    expect(verify)
    originals = {arch: (dist / ("appcast-" + arch + ".xml")).read_bytes() for arch in ("arm64", "x86_64")}
    arm_feed = dist / "appcast-arm64.xml"
    parsed = ET.fromstring(originals["arm64"])
    item = parsed.find("channel/item")
    assert item.find("description").text == "<pre># Nori 1.2.3\n\n修复 &lt;脚本&gt; &amp; 更新。</pre>"
    assert item.find("enclosure").get("url") == "https://github.com/percentcola3/sweep/releases/download/v1.2.3/Nori-arm64.dmg"
    checks += 2

    for attribute, value, reason in [
        ("url", "https://github.com/percentcola3/sweep/releases/latest/download/Nori-arm64.dmg", "immutable tagged asset"),
        ("url", "https://github.com/percentcola3/sweep/releases/download/v1.2.3/Nori-x86_64.dmg", "immutable tagged asset"),
        ("url", "https://attacker.example/Nori-arm64.dmg", "immutable tagged asset"),
        ("length", "1", "length does not match"),
        (SPARKLE + "edSignature", base64.b64encode(bytes(64)).decode(), "signature verification failed"),
        (SPARKLE + "edSignature", "not base64!", "signature encoding"),
    ]:
        tree = ET.fromstring(originals["arm64"])
        tree.find("channel/item/enclosure").set(attribute, value)
        arm_feed.write_bytes(ET.tostring(tree))
        expect(verify, False, reason)
    arm_feed.write_bytes(originals["arm64"])
    archive = dist / "Nori-arm64.dmg"
    archive_original = archive.read_bytes()
    archive.write_bytes(bytes([archive_original[0] ^ 1]) + archive_original[1:])
    expect(verify, False, "signature verification failed")
    archive.write_bytes(archive_original)

    for tag_name, value in [("version", "6"), ("shortVersionString", "1.2.2"), ("minimumSystemVersion", "12.0")]:
        tree = ET.fromstring(originals["arm64"])
        tree.find("channel/item/" + SPARKLE + tag_name).text = value
        arm_feed.write_bytes(ET.tostring(tree))
        expect(verify, False, "metadata mismatch")
    arm_feed.write_bytes(originals["arm64"])

    tree = ET.fromstring(originals["arm64"])
    tree.find("channel").append(ET.fromstring(ET.tostring(tree.find("channel/item"))))
    arm_feed.write_bytes(ET.tostring(tree))
    expect(verify, False, "exactly one release item")
    arm_feed.write_bytes(b'<!DOCTYPE rss [<!ENTITY bad "bad">]>' + originals["arm64"])
    expect(verify, False, "DTD or entity")
    arm_feed.write_bytes(originals["arm64"])

    arm_plist = dist / "arm64/Nori.app/Contents/Info.plist"
    arm_info = plistlib.loads(arm_plist.read_bytes())
    arm_plist.write_bytes(plistlib.dumps(dict(arm_info, CFBundleVersion="6")))
    expect(generate, False, "differs from source metadata")
    arm_plist.write_bytes(plistlib.dumps(dict(arm_info, SUPublicEDKey=base64.b64encode(bytes(32)).decode())))
    expect(generate, False, "public update key differs")
    arm_plist.write_bytes(plistlib.dumps(dict(arm_info, SUFeedURL="https://github.com/percentcola3/sweep/releases/latest/download/appcast-x86_64.xml")))
    expect(generate, False, "feed URL does not match")
    arm_plist.write_bytes(plistlib.dumps(arm_info))
    public_config.write_bytes(plistlib.dumps({"PublicEDKey": base64.b64encode(bytes(32)).decode()}))
    expect(generate, False, "source public update key differs from the pinned")
    public_config.write_bytes(plistlib.dumps({"PublicEDKey": public_key}))
    arm_binary = dist / "arm64/Nori.app/Contents/MacOS/Nori"
    arm_binary_original = arm_binary.read_bytes()
    arm_binary.write_bytes((dist / "x86_64/Nori.app/Contents/MacOS/Nori").read_bytes())
    expect(generate, False, "architecture does not match")
    arm_binary.write_bytes(arm_binary_original)

    other_key = work / "wrong-ephemeral-key"
    expect([str(signer), "fixture-key", str(other_key)])
    wrong_key_command = list(generate)
    wrong_key_command[wrong_key_command.index("--private-key-file") + 1] = str(other_key)
    expect(wrong_key_command, False, "signature verification failed")
    key_file.chmod(0o644)
    expect(generate, False, "must not be accessible")
    key_file.chmod(0o600)
    inside_key = dist / "must-never-publish-key"
    inside_key.write_bytes(key_file.read_bytes())
    inside_key.chmod(0o600)
    unsafe_command = list(generate)
    unsafe_command[unsafe_command.index("--private-key-file") + 1] = str(inside_key)
    expect(unsafe_command, False, "outside the release asset directory")
    inside_key.unlink()
    inside_key.symlink_to(key_file)
    expect(unsafe_command, False, "outside the release asset directory")
    inside_key.unlink()
    archive.unlink()
    archive.symlink_to(key_file)
    expect(generate, False, "nonempty regular file")
    archive.unlink()
    archive.write_bytes(archive_original)
    failing_signer = work / "failing-signer"
    failing_signer.write_text("#!/bin/sh\nprintf 'private-diagnostic-sentinel'\nprintf 'private-diagnostic-sentinel' >&2\nexit 1\n")
    failing_signer.chmod(0o700)
    failing_command = list(generate)
    failing_command[failing_command.index("--sign-tool") + 1] = str(failing_signer)
    failed = expect(failing_command, False, "Sparkle sign_update failed")
    assert "private-diagnostic-sentinel" not in failed.stdout + failed.stderr
    checks += 1

    manifest = work / "RELEASE-IDENTITY.txt"
    def write_previous(version, build, update_key=None):
        text = "Verified app version: " + version + " (build " + build + "), tag v" + version + "\n"
        if update_key:
            text += "Update public Ed25519 key: " + update_key + "\n"
        manifest.write_text(text)
    progression = base + ["check-version", "--source-info", str(source_info), "--public-config", str(public_config), "--previous-identity", str(manifest)]
    write_previous("1.2.2", "6")
    expect(progression)
    write_previous("1.2.2", "6", public_key)
    expect(progression)
    write_previous("1.2.3", "6")
    expect(progression, False, "must be newer")
    write_previous("1.10.0", "6")
    expect(progression, False, "must be newer")
    write_previous("1.2.2", "7")
    expect(progression, False, "build must increase")
    write_previous("1.2.2", "8")
    expect(progression, False, "build must increase")
    write_previous("1.2.2", "6", base64.b64encode(bytes(32)).decode())
    expect(progression, False, "public update key must remain unchanged")
    manifest.write_text("Verified app version: 1.2.2 (build 6)\nVerified app version: 1.2.1 (build 5)\n")
    expect(progression, False, "unambiguous app version")

    # A failure on Intel must leave BOTH previously validated feeds intact.
    intel_plist = dist / "x86_64/Nori.app/Contents/Info.plist"
    intel_info = plistlib.loads(intel_plist.read_bytes())
    intel_plist.write_bytes(plistlib.dumps(dict(intel_info, CFBundleVersion="6")))
    expect(generate, False, "differs from source metadata")
    for arch, data in originals.items():
        assert (dist / ("appcast-" + arch + ".xml")).read_bytes() == data
        checks += 1
    intel_plist.write_bytes(plistlib.dumps(intel_info))
    expect(verify)
    official_signer = os.environ.get("NORI_TEST_SPARKLE_SIGN_TOOL")
    if official_signer:
        # Optional offline interoperability check with the already fetched,
        # pinned official tool. Never reads the publisher's private key.
        official_command = list(generate)
        official_command[official_command.index("--sign-tool") + 1] = official_signer
        expect(official_command)
        expect(verify)

print("PASS: " + str(checks) + " appcast checks (real Ed25519 signatures, archive tampering, architecture, immutable URLs, metadata and version progression)")
