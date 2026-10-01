#!/usr/bin/env bash
# A release tag must describe the version embedded in its app, not just its notes.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT_DIR/script/release_signing_common.sh"
[[ $# -le 2 ]] || release_signing_error 'usage: script/verify_release_version.sh [TAG [INFO_PLIST]]'
TAG="${1:-}"
INFO_PLIST="${2:-$ROOT_DIR/SimpleMole/Support/Info.plist}"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null) || \
    release_signing_error "missing CFBundleShortVersionString: $INFO_PLIST"
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST" 2>/dev/null) || \
    release_signing_error "missing CFBundleVersion: $INFO_PLIST"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || release_signing_error 'release version must use major.minor.patch'
[[ "$BUILD" =~ ^[1-9][0-9]*$ ]] || release_signing_error 'release build must be a positive integer'
[[ -z "$TAG" || "$TAG" == "v$VERSION" ]] || \
    release_signing_error "release tag $TAG does not match the app version v$VERSION"
printf 'Verified app version: %s (build %s)%s\n' "$VERSION" "$BUILD" "${TAG:+, tag $TAG}"
