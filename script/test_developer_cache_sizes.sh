#!/usr/bin/env bash
# Isolated executable fixtures; never runs installed package managers.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_SIZE_TEST_TMP=$(mktemp -d /private/var/tmp/nori-cache-sizes.XXXXXXXX)
trap 'rm -rf "$CACHE_SIZE_TEST_TMP"' EXIT
mkdir -p "$CACHE_SIZE_TEST_TMP/stage/bin" "$CACHE_SIZE_TEST_TMP/stage/lib/core" "$CACHE_SIZE_TEST_TMP/commands" "$CACHE_SIZE_TEST_TMP/home/custom-cache" "$CACHE_SIZE_TEST_TMP/home/Documents/private-cache"
cp "$ROOT_DIR/bridge/app_gc_scan.sh" "$ROOT_DIR/bridge/app_scan_access.sh" "$CACHE_SIZE_TEST_TMP/stage/bin/"
cat > "$CACHE_SIZE_TEST_TMP/stage/lib/core/common.sh" <<'EOF'
run_with_timeout() { shift; "$@"; }
EOF
cat > "$CACHE_SIZE_TEST_TMP/commands/npm" <<'EOF'
#!/bin/bash
printf '%s\n' "$HOME/custom-cache"
EOF
cat > "$CACHE_SIZE_TEST_TMP/commands/pip" <<'EOF'
#!/bin/bash
printf '%s\n' "$HOME/empty-cache"
EOF
cat > "$CACHE_SIZE_TEST_TMP/commands/pnpm" <<'EOF'
#!/bin/bash
printf '%s\n' 'invalid path output'
EOF
cat > "$CACHE_SIZE_TEST_TMP/commands/go" <<'EOF'
#!/bin/bash
case "${2:-}" in
 GOCACHE) printf '%s\n' "$HOME/custom-cache" ;;
 GOMODCACHE) printf '%s\n' "$HOME/Documents/private-cache" ;;
esac
EOF
cat > "$CACHE_SIZE_TEST_TMP/commands/brew" <<'EOF'
#!/bin/bash
printf '%s\n' "$HOME/custom-cache"
EOF
cat > "$CACHE_SIZE_TEST_TMP/commands/xcrun" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$CACHE_SIZE_TEST_TMP/commands/"*
dd if=/dev/zero of="$CACHE_SIZE_TEST_TMP/home/custom-cache/data" bs=1024 count=16 >/dev/null 2>&1
CACHE_SIZE_TEST_OUTPUT=$(HOME="$CACHE_SIZE_TEST_TMP/home" PATH="$CACHE_SIZE_TEST_TMP/commands:/usr/bin:/bin" FORGESWEEP_FULL_DISK_AUTHORIZED=0 /bin/bash "$CACHE_SIZE_TEST_TMP/stage/bin/app_gc_scan.sh")
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
for entry in npm brew go-build; do
 size=$(printf '%s\n' "$CACHE_SIZE_TEST_OUTPUT" | awk -F '\t' -v id="$entry" '$1==id {print $3}')
 [[ "$size" =~ ^[0-9]+$ && "$size" -gt 0 ]] || fail "official custom cache path not sized for $entry"
done
[[ "$(printf '%s\n' "$CACHE_SIZE_TEST_OUTPUT" | awk -F '\t' '$1=="pip" {print $3}')" == 0 ]] || fail 'known empty cache confused with unknown'
for entry in pnpm go-mod gem; do
 [[ "$(printf '%s\n' "$CACHE_SIZE_TEST_OUTPUT" | awk -F '\t' -v id="$entry" '$1==id {print $3}')" == unknown ]] || fail "unknown/protected cache scope mislabeled for $entry"
done
printf 'Cache sizing: official custom paths, known empty, failed queries and protected roots passed\n'
