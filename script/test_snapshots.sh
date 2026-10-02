#!/usr/bin/env bash
# Owner-command contract only: never thin the user's actual Time Machine backups.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nori-snapshot-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/tmutil" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$NORI_SNAPSHOT_CALLS"
case "$1" in
    thinlocalsnapshots) exit "${NORI_SNAPSHOT_THIN_STATUS:-0}" ;;
    listlocalsnapshots)
        printf 'Snapshots for volume group containing disk /:\ncom.apple.TimeMachine.2026-09-01-010203.local\nother.invalid.snapshot\n'
        ;;
    *) exit 91 ;;
esac
STUB
cat > "$WORK/diskutil" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$NORI_SNAPSHOT_DISK_CALLS"
cat <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>Purgeable</key><integer>4096</integer></dict></plist>
PLIST
STUB
chmod +x "$WORK/tmutil" "$WORK/diskutil"
export PATH="$WORK:/usr/bin:/bin:/usr/sbin:/sbin"
export NORI_SNAPSHOT_CALLS="$WORK/tmutil.log" NORI_SNAPSHOT_DISK_CALLS="$WORK/diskutil.log"
output=$(bash "$ROOT_DIR/bridge/app_snapshots_scan.sh")
[[ "$output" == $'purgeable\t4096\nsnapshot\t2026-09-01-010203' ]]
[[ "$(cat "$NORI_SNAPSHOT_CALLS")" == 'listlocalsnapshots /' ]]
[[ "$(cat "$NORI_SNAPSHOT_DISK_CALLS")" == 'info -plist /' ]]
: > "$NORI_SNAPSHOT_CALLS"
output=$(bash "$ROOT_DIR/bridge/app_snapshots_thin.sh")
[[ "$output" == '2026-09-01-010203' ]]
[[ "$(cat "$NORI_SNAPSHOT_CALLS")" == $'thinlocalsnapshots / 999999999999999 4\nlistlocalsnapshots /' ]]
: > "$NORI_SNAPSHOT_CALLS"
if NORI_SNAPSHOT_THIN_STATUS=73 bash "$ROOT_DIR/bridge/app_snapshots_thin.sh" >/dev/null; then
    echo 'FAIL: snapshot thinning failure reported success' >&2; exit 1
fi
[[ "$(cat "$NORI_SNAPSHOT_CALLS")" == 'thinlocalsnapshots / 999999999999999 4' ]]
printf 'PASS: read-only snapshot inventory, exact owner-command thinning arguments, output filtering, failure stops refresh; all system commands stubbed\n'
