#!/bin/bash
# App bridge: administrator-only optimize tasks (Mole `mo optimize` parity).
# Runs privileged via the GUI's osascript wrapper, once per optimize run.
# Usage: app_optimize_admin.sh <uid> <task>...
# Output: one `task<TAB>state<TAB>message` line per requested task, where
# state is applied | unchanged | unavailable | failed.
set -uo pipefail
export LC_ALL=C

report() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }

target_uid="${1:-}"
shift || true
if [[ ! "$target_uid" =~ ^[0-9]+$ || "$target_uid" -eq 0 ]]; then
    echo "invalid user id" >&2
    exit 64
fi

if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
    for task in "$@"; do report "$task" unavailable "Skipped in test mode."; done
    exit 0
fi
if [[ "$(/usr/bin/id -u)" -ne 0 ]]; then
    for task in "$@"; do report "$task" unavailable "Administrator access is required."; done
    exit 77
fi

# Run a command with a wall-clock limit; returns 124 on timeout.
run_bounded() {
    local limit="$1"
    shift
    "$@" > /dev/null 2>&1 &
    local pid=$!
    local waited=0
    while /bin/kill -0 "$pid" 2> /dev/null; do
        if ((waited >= limit * 5)); then
            /bin/kill -TERM "$pid" 2> /dev/null || true
            /bin/sleep 2
            /bin/kill -KILL "$pid" 2> /dev/null || true
            wait "$pid" 2> /dev/null || true
            return 124
        fi
        /bin/sleep 0.2
        waited=$((waited + 1))
    done
    wait "$pid"
}

for task in "$@"; do
    case "$task" in
        dns)
            if run_bounded 15 /usr/bin/dscacheutil -flushcache &&
                run_bounded 15 /usr/bin/killall -HUP mDNSResponder; then
                report dns applied "DNS cache flushed and mDNSResponder restarted."
            else
                report dns failed "Could not flush the DNS cache."
            fi
            ;;
        network-stack)
            ok=0
            run_bounded 15 /sbin/route -n flush && ok=$((ok + 1))
            run_bounded 15 /usr/sbin/arp -a -d && ok=$((ok + 1))
            case "$ok" in
                2) report network-stack applied "Routing table refreshed and ARP cache cleared." ;;
                1) report network-stack failed "Network stack refresh was incomplete." ;;
                *) report network-stack failed "Could not refresh the network stack." ;;
            esac
            ;;
        periodic)
            if [[ ! -x /usr/sbin/periodic ]]; then
                report periodic unavailable "periodic is not available on this macOS version."
            elif run_bounded 900 /usr/sbin/periodic daily weekly monthly; then
                report periodic applied "Daily, weekly and monthly maintenance ran."
            else
                report periodic failed "Periodic maintenance failed or timed out."
            fi
            ;;
        permissions)
            if run_bounded 900 /usr/sbin/diskutil resetUserPermissions / "$target_uid"; then
                report permissions applied "Home directory permissions reset."
            else
                report permissions failed "Could not reset home directory permissions."
            fi
            ;;
        spotlight)
            if run_bounded 60 /usr/bin/mdutil -E /; then
                report spotlight applied "Spotlight rebuild started; indexing continues in the background."
            else
                report spotlight failed "Could not start the Spotlight rebuild."
            fi
            ;;
        disk-verify)
            verify_log=$(/usr/bin/mktemp /private/var/tmp/nori-verify.XXXXXX)
            run_bounded 600 /bin/sh -c '/usr/sbin/diskutil verifyVolume / > "$1" 2>&1' sh "$verify_log"
            status=$?
            if [[ $status -eq 124 ]]; then
                report disk-verify failed "Disk verification timed out."
            elif /usr/bin/grep -qi "appears to be OK" "$verify_log"; then
                report disk-verify unchanged "The startup volume appears to be OK."
            elif [[ $status -ne 0 ]] || /usr/bin/grep -qiE "error|corrupt|invalid" "$verify_log"; then
                report disk-verify failed "Problems found; run Disk Utility First Aid on the startup volume."
            else
                report disk-verify failed "The verification result was not recognized."
            fi
            /bin/rm -f "$verify_log" # SAFE: mktemp scratch file created above.
            ;;
        *)
            report "$task" failed "Unknown administrator task."
            ;;
    esac
done
exit 0
