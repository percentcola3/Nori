#!/usr/bin/env bash
# Public compiler/SDK caches only. Signing material and build outputs never
# belong in these directories or in GitHub Actions caches.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="${1:-native}"
[[ "$ARCH" != native ]] || ARCH="$(uname -m)"
case "$ARCH" in arm64|x86_64) ;; *) echo 'error: unsupported CI architecture' >&2; exit 2 ;; esac
source "$ROOT_DIR/script/test_developer_toolchain.sh"
for tool in swiftc clang python3 git codesign ditto hdiutil shasum perl; do
    command -v "$tool" >/dev/null || { echo "error: missing CI dependency: $tool" >&2; exit 2; }
done
SDK_FINGERPRINT=$( {
    swiftc --version
    printf '%s\n' "$SDKROOT"
    if [[ -f "$SDKROOT/SDKSettings.json" ]]; then cat "$SDKROOT/SDKSettings.json"; fi
} | shasum -a 256 | /usr/bin/cut -c 1-24)
CACHE_PREFIX="nori-sdk-v1-$SDK_FINGERPRINT-$ARCH"
CACHE_DIRECTORY="$ROOT_DIR/.build/ci-swift-modules/$ARCH"
mkdir -p "$CACHE_DIRECTORY"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'cache-prefix=%s\ncache-directory=%s\n' "$CACHE_PREFIX" "$CACHE_DIRECTORY" >> "$GITHUB_OUTPUT"
fi
if [[ -n "${GITHUB_ENV:-}" ]]; then
    printf 'SDKROOT=%s\nNORI_SWIFT_MODULE_CACHE=%s\n' "$SDKROOT" "$CACHE_DIRECTORY" >> "$GITHUB_ENV"
fi
printf 'Prepared %s SDK module cache: %s\n' "$ARCH" "$CACHE_PREFIX"
