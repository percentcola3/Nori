#!/bin/bash
# App bridge: factory-reset the user's network configuration (administrator).
# Usage: app_net_reset.sh <uid>
# Removes everything that is not a macOS default, backing up modified files:
#   - turns off every proxy kind on every network service
#   - resets DNS servers to automatic on every network service
#   - forgets all saved Wi-Fi networks (the current connection stays up)
#   - removes every network location except "Automatic"
#   - restores /etc/hosts to the macOS default template (backup next to it)
#   - moves custom /etc/resolver entries into a backup directory
#   - flushes the DNS cache
# Output: one `step<TAB>ok|skip|fail<TAB>detail` line per step.
set -uo pipefail
export LC_ALL=C

report() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }

target_uid="${1:-}"
if [[ ! "$target_uid" =~ ^[0-9]+$ || "$target_uid" -eq 0 ]]; then
    echo "invalid user id" >&2
    exit 64
fi

if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
    for step in proxies dns wifi locations hosts resolver flush; do
        report "$step" skip "Skipped in test mode."
    done
    exit 0
fi
if [[ "$(/usr/bin/id -u)" -ne 0 ]]; then
    for step in proxies dns wifi locations hosts resolver flush; do
        report "$step" fail "Administrator access is required."
    done
    exit 77
fi
# 必须以目标用户的 networksetup 上下文执行。
if [[ "$(/usr/bin/id -u "$target_uid" 2>/dev/null)" != "$target_uid" ]]; then
    echo "unknown user id" >&2
    exit 64
fi

NETWORKSETUP=/usr/sbin/networksetup
STAMP="$(/bin/date +%Y%m%d-%H%M%S)"

# 1) 所有网络服务：关闭全部代理 + DNS 恢复自动。
services="$("$NETWORKSETUP" -listallnetworkservices 2>/dev/null | /usr/bin/tail -n +2 | /usr/bin/grep -v '^*')"
proxy_kinds=(webproxy securewebproxy socksfirewallproxy autoproxyurl ftpproxy gopherproxy)
proxies_done=0
dns_done=0
while IFS= read -r service; do
    [[ -z "$service" ]] && continue
    for kind in "${proxy_kinds[@]}"; do
        "$NETWORKSETUP" -set"${kind}"state "$service" off >/dev/null 2>&1 && proxies_done=$((proxies_done + 1))
    done
    "$NETWORKSETUP" -setdnsservers "$service" "Empty" >/dev/null 2>&1 && dns_done=$((dns_done + 1))
done <<< "$services"
report proxies ok "Turned off $proxies_done proxy setting(s)."
report dns ok "Reset DNS to automatic on $dns_done service(s)."

# 2) 忘记所有已保存的 Wi-Fi（当前连接不中断）。
wifi_forgot=0
wifi_service=""
while IFS= read -r service; do
    [[ -z "$service" ]] && continue
    if "$NETWORKSETUP" -listpreferredwirelessnetworks "$service" >/dev/null 2>&1; then
        wifi_service="$service"
        break
    fi
done <<< "$services"
if [[ -n "$wifi_service" ]]; then
    while IFS= read -r network; do
        network="${network//[$'\t\r']/}"
        network="${network#*: }"
        [[ -z "$network" ]] && continue
        "$NETWORKSETUP" -removepreferredwirelessnetwork "$wifi_service" "$network" >/dev/null 2>&1 \
            && wifi_forgot=$((wifi_forgot + 1))
    done < <("$NETWORKSETUP" -listpreferredwirelessnetworks "$wifi_service" 2>/dev/null | /usr/bin/tail -n +2)
    report wifi ok "Forgot $wifi_forgot saved Wi-Fi network(s)."
else
    report wifi skip "No Wi-Fi service found."
fi

# 3) 删除非“自动”的网络位置（当前活动位置无法删除，跳过并说明）。
active_location="$("$NETWORKSETUP" -getcurrentlocation 2>/dev/null)"
locations_removed=0
locations_skipped=0
while IFS= read -r location; do
    [[ -z "$location" ]] && continue
    if [[ "$location" == "Automatic" || "$location" == "$active_location" ]]; then
        locations_skipped=$((locations_skipped + 1))
        continue
    fi
    "$NETWORKSETUP" -removelocation "$location" >/dev/null 2>&1 && locations_removed=$((locations_removed + 1))
done < <("$NETWORKSETUP" -listlocations 2>/dev/null | /usr/bin/tail -n +1)
report locations ok "Removed $locations_removed location(s); kept Automatic and the active one ($locations_skipped)."

# 4) /etc/hosts 恢复系统默认模板（先备份）。
hosts_backup="/etc/hosts.nori-backup-$STAMP"
if /bin/cp /etc/hosts "$hosts_backup" 2>/dev/null; then
    /usr/bin/printf '%s\n' \
        '##' \
        '# Host Database' \
        '#' \
        '# localhost is used to configure the loopback interface' \
        '# when the system is booting.  Do not change this entry.' \
        '##' \
        '127.0.0.1	localhost' \
        '255.255.255.255	broadcasthost' \
        '::1             localhost' > /etc/hosts
    report hosts ok "Restored /etc/hosts (backup: $hosts_backup)."
else
    report hosts fail "Could not back up /etc/hosts; left unchanged."
fi

# 5) /etc/resolver 自定义解析移入备份目录（不删除）。
resolver_backup="/etc/resolver.nori-backup-$STAMP"
resolver_moved=0
if [[ -d /etc/resolver ]] && [[ -n "$(ls -A /etc/resolver 2>/dev/null)" ]]; then
    if /bin/mkdir -p "$resolver_backup"; then
        for entry in /etc/resolver/*; do
            [[ -e "$entry" ]] || continue
            /bin/mv "$entry" "$resolver_backup/" && resolver_moved=$((resolver_moved + 1))
        done
        report resolver ok "Moved $resolver_moved custom resolver file(s) to $resolver_backup."
    else
        report resolver fail "Could not create the resolver backup directory."
    fi
else
    report resolver skip "No custom resolver entries."
fi

# 6) 刷新 DNS 缓存。
/usr/bin/dscacheutil -flushcache >/dev/null 2>&1
/usr/bin/killall -HUP mDNSResponder >/dev/null 2>&1
report flush ok "Flushed the DNS cache."

exit 0
