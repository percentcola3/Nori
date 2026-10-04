#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOSTS_BACKUP_TEST_TMP=$(mktemp -d /private/var/tmp/nori-hosts-backups.XXXXXXXX)
trap 'rm -rf "$HOSTS_BACKUP_TEST_TMP"' EXIT
source "$ROOT_DIR/bridge/app_dev_backup_guard.sh"
for number in 1 2 3 4 5 6; do
 name=$(printf 'hosts.nori-backup.%08d' "$number")
 printf 'fixture' > "$HOSTS_BACKUP_TEST_TMP/$name"
 chmod 600 "$HOSTS_BACKUP_TEST_TMP/$name"
 touch -t "20260101000$number" "$HOSTS_BACKUP_TEST_TMP/$name"
done
printf 'outside' > "$HOSTS_BACKUP_TEST_TMP/outside"
ln -s "$HOSTS_BACKUP_TEST_TMP/outside" "$HOSTS_BACKUP_TEST_TMP/hosts.nori-backup.symlink1"
ln "$HOSTS_BACKUP_TEST_TMP/outside" "$HOSTS_BACKUP_TEST_TMP/hosts.nori-backup.hardlink"
printf 'keep' > "$HOSTS_BACKUP_TEST_TMP/hosts.nori-backup.widefile"
chmod 644 "$HOSTS_BACKUP_TEST_TMP/hosts.nori-backup.widefile"
printf 'keep' > "$HOSTS_BACKUP_TEST_TMP/hosts.nori-backup.admin-20260101"
nori_rotate_hosts_backups "$HOSTS_BACKUP_TEST_TMP" "$HOSTS_BACKUP_TEST_TMP/hosts.nori-backup.00000006" "$(id -u)"
[[ ! -e "$HOSTS_BACKUP_TEST_TMP/hosts.nori-backup.00000001" ]] || exit 1
for name in 00000002 00000003 00000004 00000005 00000006 symlink1 hardlink widefile admin-20260101; do
 [[ -e "$HOSTS_BACKUP_TEST_TMP/hosts.nori-backup.$name" || -L "$HOSTS_BACKUP_TEST_TMP/hosts.nori-backup.$name" ]] || exit 1
done
[[ "$(cat "$HOSTS_BACKUP_TEST_TMP/outside")" == outside ]] || exit 1
printf 'Hosts backups: five retained; links, broad permissions and foreign names preserved\n'
