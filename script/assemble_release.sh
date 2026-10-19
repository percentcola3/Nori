#!/usr/bin/env bash
# Consume signed packages from this exact workflow run; never compile again.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $# -eq 3 ]] || { echo 'usage: assemble_release.sh INPUT_DIR SOURCE_COMMIT SOURCE_REF' >&2; exit 2; }
INPUT_DIR="$1"
SOURCE_COMMIT="$2"
SOURCE_REF="$3"
DIST_DIR="$ROOT_DIR/dist"
python3 "$ROOT_DIR/script/release_artifacts.py" --input-dir "$INPUT_DIR" \
    --source-commit "$SOURCE_COMMIT" --source-ref "$SOURCE_REF"
mkdir -p "$DIST_DIR"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/SimpleMole/Support/Info.plist")
TAG="v$VERSION"
{
    printf 'Source commit: %s\nSource ref: %s\n' "$SOURCE_COMMIT" "$SOURCE_REF"
    bash "$ROOT_DIR/script/verify_release_version.sh" "$TAG"
    printf 'Update public Ed25519 key: %s\n' "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$ROOT_DIR/SimpleMole/Support/Info.plist")"
} > "$DIST_DIR/RELEASE-IDENTITY.txt"
for arch in arm64 x86_64; do
    [[ ! -e "$DIST_DIR/$arch/Nori.app" ]] || { echo "error: refusing to replace an existing $arch build" >&2; exit 2; }
    mkdir -p "$DIST_DIR/$arch"
    /usr/bin/ditto -x -k "$INPUT_DIR/Nori-$arch.app.zip" "$DIST_DIR/$arch"
    cp "$INPUT_DIR/Nori-$arch.dmg" "$DIST_DIR/Nori-$arch.dmg"
    bash "$ROOT_DIR/script/verify_release.sh" "$DIST_DIR/$arch/Nori.app" >> "$DIST_DIR/RELEASE-IDENTITY.txt"
    bash "$ROOT_DIR/script/verify_release_version.sh" "$TAG" "$DIST_DIR/$arch/Nori.app/Contents/Info.plist"
done
echo 'Reused and verified both signed architecture builds without recompilation.'
