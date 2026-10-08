#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    printf 'not ok - %s\n' "$1" >&2
    exit 1
}

pass() {
    printf 'ok - %s\n' "$1"
}

[[ -x /usr/bin/perl ]] || fail "Perl fallback is unavailable"

# Force the exact fallback used on a stock macOS installation without
# coreutils. Do not let a developer-installed gtimeout hide regressions.
export MO_TIMEOUT_INITIALIZED=1
export MO_TIMEOUT_BIN=""
export MO_TIMEOUT_PERL_BIN=/usr/bin/perl
# shellcheck disable=SC1091
source "$ROOT_DIR/vendor/mole/lib/core/timeout.sh"

set +e
run_with_timeout 2 /bin/sh -c 'exit 23'
status=$?
set -e
[[ "$status" -eq 23 ]] || fail "Perl fallback did not preserve child exit status"
pass "Perl fallback preserves child exit status"

# Calibrate Perl startup and fork/exec costs on this host with a blocking reap.
# These costs vary substantially on virtualized runners and are not polling.
start=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f", time')
for _ in {1..20}; do
    /usr/bin/perl -e '
        use strict;
        use warnings;
        use POSIX qw(:sys_wait_h setpgid tcgetpgrp tcsetpgrp);
        use Time::HiRes qw(time sleep);
        my $pid = fork();
        defined $pid or exit 125;
        if ($pid == 0) { setpgid(0, 0); exec "/usr/bin/true"; exit 127; }
        setpgid($pid, $pid);
        waitpid($pid, 0) == $pid or exit 125;
        exit(WIFEXITED($?) ? WEXITSTATUS($?) : 125);
    ' || fail "short-command startup baseline failed"
done
finish=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f", time')
baseline_elapsed=$(/usr/bin/awk -v start="$start" -v finish="$finish" \
    'BEGIN { printf "%.3f", finish - start }')

start=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f", time')
for _ in {1..20}; do
    run_with_timeout 2 /usr/bin/true || fail "short command failed"
done
finish=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f", time')
elapsed=$(/usr/bin/awk -v start="$start" -v finish="$finish" \
    'BEGIN { printf "%.3f", finish - start }')
# The former fixed 100ms poll adds about two seconds to this batch, beyond
# startup costs. Keep the same 1.5s polling allowance after calibration.
/usr/bin/awk -v elapsed="$elapsed" -v baseline="$baseline_elapsed" \
    'BEGIN { exit !(elapsed - baseline < 1.5) }' ||
    fail "short-command polling regressed (${elapsed}s for 20 commands; startup baseline ${baseline_elapsed}s)"
pass "Perl fallback reaps short commands promptly (${elapsed}s for 20 commands; startup baseline ${baseline_elapsed}s)"

start=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f", time')
set +e
run_with_timeout 0.15 /bin/sleep 5
status=$?
set -e
finish=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f", time')
elapsed=$(/usr/bin/awk -v start="$start" -v finish="$finish" \
    'BEGIN { printf "%.3f", finish - start }')
[[ "$status" -eq 124 ]] || fail "Perl fallback did not return timeout status 124"
/usr/bin/awk -v elapsed="$elapsed" 'BEGIN { exit !(elapsed < 1.5) }' ||
    fail "Perl fallback timeout was not enforced promptly (${elapsed}s)"
pass "Perl fallback preserves timeout status and deadline (${elapsed}s)"

fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/nori-timeout-tests.XXXXXX") ||
    fail "could not create timeout fixture"
case "$fixture_root" in
    "${TMPDIR:-/tmp}"/nori-timeout-tests.*) ;;
    *) fail "unsafe timeout fixture path" ;;
esac
owner_pid=""
child_pid=""
unrelated_pid=""
cleanup() {
    [[ "$owner_pid" =~ ^[0-9]+$ ]] && /bin/kill -KILL "$owner_pid" 2>/dev/null || true
    [[ "$child_pid" =~ ^[0-9]+$ ]] && /bin/kill -KILL "$child_pid" 2>/dev/null || true
    [[ "$unrelated_pid" =~ ^[0-9]+$ ]] && /bin/kill -KILL "$unrelated_pid" 2>/dev/null || true
    /bin/rm -rf -- "$fixture_root"
}
trap cleanup EXIT

# Killing the shell that owns the timeout helper must not orphan its command.
# This exercises the existing getppid owner-death path without changing its
# TERM/KILL or process-group behavior.
(
    run_with_timeout 30 /bin/sh -c '
        printf "%s\n" "$$" > "$1"
        while :; do /bin/sleep 1; done
    ' timeout-child "$fixture_root/child.pid"
) &
owner_pid=$!

for _ in {1..100}; do
    [[ -s "$fixture_root/child.pid" ]] && break
    /bin/sleep 0.01
done
[[ -s "$fixture_root/child.pid" ]] || fail "timed child did not start"
child_pid=$(<"$fixture_root/child.pid")
[[ "$child_pid" =~ ^[0-9]+$ ]] || fail "timed child PID is invalid"

/bin/kill -KILL "$owner_pid" 2>/dev/null || fail "could not terminate timeout owner"
wait "$owner_pid" 2>/dev/null || true
owner_pid=""
for _ in {1..100}; do
    if ! /bin/kill -0 "$child_pid" 2>/dev/null; then
        child_pid=""
        break
    fi
    /bin/sleep 0.02
done
[[ -z "$child_pid" ]] || fail "Perl fallback orphaned a child after owner death"
pass "Perl fallback preserves owner-death cleanup"

# A timeout must also stop descendants in the dedicated group while an
# unrelated fixture process stays alive. Signal targets all originate here.
run_with_timeout 0.5 /bin/sh -c '
    /bin/sleep 30 &
    printf "%s\n" "$!" > "$1"
    wait
' timeout-grandchild "$fixture_root/grandchild.pid" &
owner_pid=$!
/bin/sleep 30 &
unrelated_pid=$!
set +e
wait "$owner_pid"
status=$?
set -e
owner_pid=""
[[ "$status" -eq 124 ]] || fail "descendant fixture did not return timeout status 124"
child_pid=$(<"$fixture_root/grandchild.pid")
[[ "$child_pid" =~ ^[0-9]+$ ]] || fail "descendant fixture PID is invalid"
for _ in {1..100}; do
    if ! /bin/kill -0 "$child_pid" 2>/dev/null; then child_pid=""; break; fi
    /bin/sleep 0.02
done
[[ -z "$child_pid" ]] || fail "Perl timeout left a descendant alive"
/bin/kill -0 "$unrelated_pid" 2>/dev/null || fail "Perl timeout signalled an unrelated fixture process"
/bin/kill -TERM "$unrelated_pid" 2>/dev/null || true
wait "$unrelated_pid" 2>/dev/null || true
unrelated_pid=""
pass "Perl fallback preserves descendant cleanup and unrelated process isolation"

set +e
run_with_timeout 2 /bin/sh -c 'kill -TERM $$'
status=$?
set -e
[[ "$status" -eq 143 ]] || fail "Perl fallback lost child signal status 143"
pass "Perl fallback preserves child signal status"

trap - EXIT
cleanup

# Exercise macOS timer coalescing explicitly, rather than depending on the
# runner inheriting background scheduling. The same assertions and allowances
# run again; a regression cannot hide behind an ordinary foreground run.
if [[ "${1:-}" != --background-policy && -x /usr/sbin/taskpolicy ]]; then
    /usr/sbin/taskpolicy -b /bin/bash "$ROOT_DIR/script/TimeoutFallbackTests.sh" --background-policy ||
        fail "Perl fallback failed under macOS background timer policy"
    pass "Perl fallback wakes promptly under macOS background timer policy"
fi
