#!/usr/bin/env python3
"""Publish one Sparkle item per architecture, with immutable GitHub asset URLs."""
import argparse
import base64
import datetime
import email.utils
import html
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
ARCHITECTURES = ("arm64", "x86_64")


def fail(message):
    raise ValueError(message)


def sparkle(name):
    return "{" + SPARKLE + "}" + name


def version_tuple(value):
    if not isinstance(value, str) or not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", value):
        fail("release version must use major.minor.patch")
    return tuple(map(int, value.split(".")))


def read_info(path):
    with open(path, "rb") as stream:
        info = plistlib.load(stream)
    version = info.get("CFBundleShortVersionString")
    version_tuple(version)
    build = info.get("CFBundleVersion")
    if not isinstance(build, str) or not re.fullmatch(r"[1-9][0-9]*", build):
        fail("release build must be a positive integer")
    if info.get("CFBundleIdentifier") != "com.nori.app":
        fail("unexpected app bundle identifier")
    return info


def check_tag(tag, info):
    if tag != "v" + info["CFBundleShortVersionString"]:
        fail("release tag does not match the app version")


def previous_version(path):
    text = Path(path).read_text(encoding="utf-8")
    versions = re.findall(r"^Verified app version: ([0-9]+\.[0-9]+\.[0-9]+) \(build ([1-9][0-9]*)\)(?:, tag v[0-9.]+)?$", text, re.MULTILINE)
    if len(set(versions)) != 1:
        fail("previous published identity must contain one unambiguous app version/build")
    version, build = versions[0]
    return version_tuple(version), int(build)


def check_version(info, previous):
    if previous:
        old_version, old_build = previous_version(previous)
        if version_tuple(info["CFBundleShortVersionString"]) <= old_version:
            fail("release version must be newer than the previous public release")
        if int(info["CFBundleVersion"]) <= old_build:
            fail("release build must increase beyond the previous public release")
        old_keys = set(re.findall(r"^Update public Ed25519 key: (.+)$", Path(previous).read_text(encoding="utf-8"), re.MULTILINE))
        if len(old_keys) > 1:
            fail("previous published identity contains conflicting update public keys")
        if old_keys and old_keys != {decode_key(info.get("SUPublicEDKey"))}:
            fail("public update key must remain unchanged; key rotation requires an explicit migration")


def repository_base(repository):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        fail("invalid GitHub owner/repository")
    return "https://github.com/" + repository


def decode_key(key):
    try:
        decoded = base64.b64decode(key, validate=True)
    except (ValueError, TypeError):
        fail("SUPublicEDKey must contain a valid public Ed25519 key")
    if len(decoded) != 32:
        fail("SUPublicEDKey must contain a 32-byte public Ed25519 key")
    return key


def signature_verify(verifier, key, signature, archive):
    try:
        raw = base64.b64decode(signature, validate=True)
    except (ValueError, TypeError):
        fail("invalid update archive Ed25519 signature encoding")
    if len(raw) != 64:
        fail("update archive Ed25519 signature must contain 64 bytes")
    result = subprocess.run([str(verifier), key, signature, str(archive)], capture_output=True)
    if result.returncode:
        fail("update archive Ed25519 signature verification failed")


def app_metadata(args, arch):
    app = args.dist_dir / arch / "Nori.app" / "Contents"
    info = read_info(app / "Info.plist")
    if (info["CFBundleShortVersionString"], info["CFBundleVersion"]) != (
            args.source_info["CFBundleShortVersionString"], args.source_info["CFBundleVersion"]):
        fail("built app version/build differs from source metadata")
    result = subprocess.run(["/usr/bin/lipo", "-archs", str(app / "MacOS" / "Nori")], capture_output=True, text=True)
    if result.returncode or result.stdout.strip() != arch:
        fail("built app architecture does not match " + arch)
    key = decode_key(info.get("SUPublicEDKey"))
    source_key = decode_key(args.source_info.get("SUPublicEDKey"))
    if key != source_key:
        fail("built app public update key differs from source metadata")
    if key != args.public_key:
        fail("built app public update key differs from the pinned signing/update.plist key")
    expected_feed = args.base + "/releases/latest/download/appcast-" + arch + ".xml"
    if info.get("SUFeedURL") != expected_feed:
        fail("built app feed URL does not match its architecture")
    minimum_system = info.get("LSMinimumSystemVersion")
    if not isinstance(minimum_system, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", minimum_system):
        fail("built app minimum system version is invalid")
    return key, minimum_system


def archive_path(args, arch):
    path = args.dist_dir / ("Nori-" + arch + ".dmg")
    if path.is_symlink() or not path.is_file() or path.stat().st_size <= 0:
        fail("update archive must be a nonempty regular file for " + arch)
    return path


def sign_archive(args, archive, public_key):
    # Never log the tool's output/error: a malformed credential must not turn
    # sign_update diagnostics into a private-key disclosure in CI.
    result = subprocess.run([str(args.sign_tool), "--ed-key-file", str(args.private_key_file), "-p", str(archive)], capture_output=True)
    if result.returncode:
        fail("Sparkle sign_update failed; check the signing tool and private-key file")
    try:
        signature = result.stdout.decode("ascii").strip()
    except UnicodeDecodeError:
        fail("Sparkle sign_update returned an invalid signature encoding")
    signature_verify(args.signature_verifier, public_key, signature, archive)
    return signature


def validate_feed(args, arch, feed, key, minimum_system):
    # Avoid entity/DTD surprises in downloaded or edited feeds.
    if b"<!DOCTYPE" in feed.upper() or b"<!ENTITY" in feed.upper():
        fail("appcast must not contain a DTD or entity declaration")
    root = ET.fromstring(feed)
    channels = root.findall("channel")
    if root.tag != "rss" or root.get("version") != "2.0" or len(channels) != 1:
        fail("appcast must contain one RSS 2.0 channel")
    items = channels[0].findall("item")
    if len(items) != 1:
        fail("architecture appcast must contain exactly one release item")
    item = items[0]
    expected = {sparkle("version"): args.source_info["CFBundleVersion"],
                sparkle("shortVersionString"): args.source_info["CFBundleShortVersionString"],
                sparkle("minimumSystemVersion"): minimum_system}
    for name, value in expected.items():
        elements = item.findall(name)
        if len(elements) != 1 or elements[0].text != value:
            fail("appcast version/build/minimum system metadata mismatch")
    enclosures = item.findall("enclosure")
    if len(enclosures) != 1:
        fail("appcast must contain one architecture-specific enclosure")
    enclosure = enclosures[0]
    expected_url = args.base + "/releases/download/" + args.tag + "/Nori-" + arch + ".dmg"
    if enclosure.get("url") != expected_url:
        fail("appcast enclosure must use the immutable tagged asset URL for its architecture")
    archive = archive_path(args, arch)
    if enclosure.get("length") != str(archive.stat().st_size):
        fail("appcast enclosure length does not match the update archive")
    if enclosure.get("type") != "application/octet-stream":
        fail("appcast enclosure has an unexpected archive type")
    signature_verify(args.signature_verifier, key, enclosure.get(sparkle("edSignature")), archive)


def make_feed(args, arch, key, minimum_system):
    archive = archive_path(args, arch)
    signature = sign_archive(args, archive, key)
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "Nori " + arch + " updates"
    ET.SubElement(channel, "link").text = args.base + "/releases"
    ET.SubElement(channel, "description").text = "Published stable Nori releases for " + arch
    ET.SubElement(channel, "language").text = "en"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = "Nori " + args.source_info["CFBundleShortVersionString"]
    ET.SubElement(item, "link").text = args.base + "/releases/tag/" + args.tag
    ET.SubElement(item, "pubDate").text = email.utils.format_datetime(datetime.datetime.now(datetime.timezone.utc), usegmt=True)
    ET.SubElement(item, sparkle("version")).text = args.source_info["CFBundleVersion"]
    ET.SubElement(item, sparkle("shortVersionString")).text = args.source_info["CFBundleShortVersionString"]
    ET.SubElement(item, sparkle("minimumSystemVersion")).text = minimum_system
    if args.notes_file:
        notes = args.notes_file.read_text(encoding="utf-8")
        if len(notes.encode("utf-8")) > 262144:
            fail("release notes exceed 256 KiB")
        ET.SubElement(item, "description").text = "<pre>" + html.escape(notes) + "</pre>"
    ET.SubElement(item, "enclosure", {
        "url": args.base + "/releases/download/" + args.tag + "/Nori-" + arch + ".dmg",
        "length": str(archive.stat().st_size), "type": "application/octet-stream",
        sparkle("edSignature"): signature,
    })
    ET.indent(root, space="  ")
    feed = ET.tostring(root, encoding="utf-8", xml_declaration=True) + b"\n"
    validate_feed(args, arch, feed, key, minimum_system)
    return feed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("generate", "verify", "check-version"))
    parser.add_argument("--source-info", type=Path, required=True)
    parser.add_argument("--public-config", type=Path, default=Path(__file__).resolve().parent.parent / "signing/update.plist")
    parser.add_argument("--tag")
    parser.add_argument("--previous-identity", type=Path)
    parser.add_argument("--repository", default="percentcola3/Nori")
    parser.add_argument("--dist-dir", type=Path)
    parser.add_argument("--archs", nargs="+", choices=ARCHITECTURES, default=list(ARCHITECTURES))
    parser.add_argument("--notes-file", type=Path)
    parser.add_argument("--sign-tool", type=Path)
    parser.add_argument("--private-key-file", type=Path)
    parser.add_argument("--signature-verifier", type=Path)
    args = parser.parse_args()
    args.source_info = read_info(args.source_info)
    with args.public_config.open("rb") as stream:
        public_config = plistlib.load(stream)
    args.public_key = decode_key(public_config.get("PublicEDKey"))
    if decode_key(args.source_info.get("SUPublicEDKey")) != args.public_key:
        fail("source public update key differs from the pinned signing/update.plist key")
    if not args.tag:
        args.tag = "v" + args.source_info["CFBundleShortVersionString"]
    check_tag(args.tag, args.source_info)
    check_version(args.source_info, args.previous_identity)
    if args.command == "check-version":
        print("Verified release version/build progression.")
        return
    if args.dist_dir is None or args.signature_verifier is None:
        fail("dist-dir and signature-verifier are required")
    args.base = repository_base(args.repository)
    if len(args.archs) != len(set(args.archs)):
        fail("duplicate release architecture")
    if args.command == "generate":
        if args.sign_tool is None or not args.sign_tool.is_file() or args.private_key_file is None or not args.private_key_file.is_file():
            fail("sign-tool and an existing private-key-file are required")
        if stat.S_IMODE(args.private_key_file.stat().st_mode) & 0o077:
            fail("private-key file must not be accessible to group or other users")
        if (args.dist_dir.resolve() in args.private_key_file.resolve().parents
                or args.dist_dir.absolute() in args.private_key_file.absolute().parents):
            fail("private-key file must remain outside the release asset directory")
    prepared = []
    for arch in args.archs:
        key, minimum_system = app_metadata(args, arch)
        destination = args.dist_dir / ("appcast-" + arch + ".xml")
        if args.command == "generate":
            prepared.append((destination, make_feed(args, arch, key, minimum_system)))
        else:
            validate_feed(args, arch, destination.read_bytes(), key, minimum_system)
    # Both architectures must pass validation before either feed is replaced.
    for destination, feed in prepared:
        with tempfile.NamedTemporaryFile(dir=args.dist_dir, prefix=".appcast-", delete=False) as stream:
            temporary = Path(stream.name)
            try:
                stream.write(feed)
                stream.flush()
                os.fchmod(stream.fileno(), 0o644)
                os.replace(temporary, destination)
            finally:
                temporary.unlink(missing_ok=True)
    print("Verified " + ", ".join(args.archs) + " appcasts and archive signatures.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, plistlib.InvalidFileException, ET.ParseError) as error:
        print("error: " + str(error), file=sys.stderr)
        sys.exit(2)
