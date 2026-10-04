#!/bin/bash
# Disable a single registered proxy kind on one existing network service.
# The GUI invokes this from its verified privileged bundle staging area.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C
unset ENV BASH_ENV CDPATH
[[ $# -eq 2 ]] || exit 64
svc="$1"; kind="$2"
[[ -n "$svc" && "$svc" != -* && ${#svc} -le 256 && ! "$svc" =~ [[:cntrl:]] ]] || exit 64
case "$kind" in
    http) flag=-setwebproxystate ;;
    https) flag=-setsecurewebproxystate ;;
    socks) flag=-setsocksfirewallproxystate ;;
    pac) flag=-setautoproxystate ;;
    *) exit 64 ;;
esac
if [[ "${MOLE_TEST_MODE:-0}" == 1 || "${MOLE_TEST_NO_AUTH:-0}" == 1 ]]; then
    printf 'proxy\tskipped\n'; exit 0
fi
[[ "$(/usr/bin/id -u)" -eq 0 ]] || exit 77
found=0
while IFS= read -r listed; do
    [[ "$listed" == "$svc" || "$listed" == "*$svc" ]] && found=1
done < <(/usr/sbin/networksetup -listallnetworkservices)
[[ "$found" -eq 1 ]] || exit 64
/usr/sbin/networksetup "$flag" "$svc" off
printf 'proxy\tdisabled\t%s\n' "$kind"
