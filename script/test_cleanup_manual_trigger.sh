#!/usr/bin/env bash
# Source-level lifecycle regression: do not launch the app or scan the real home.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_STATE="$ROOT_DIR/SimpleMole/AppState.swift"
APP_DELEGATE="$ROOT_DIR/SimpleMole/AppDelegate.swift"
CLEANUP_VIEW="$ROOT_DIR/SimpleMole/Views/CleanupTabView.swift"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

if /usr/bin/grep -Eq 'scheduleCleanupWarmup|prewarmCleanupCacheIfNeeded|cleanupWarmup' \
    "$APP_STATE" "$APP_DELEGATE"; then
    fail "cleanup lifecycle still schedules automatic scans or retries"
fi

activation=$(/usr/bin/awk '
    /^    func refreshAuthorizationAndResume\(/ { capture = 1 }
    capture { print }
    capture && /^    }/ { exit }
' "$APP_STATE")
[[ -n "$activation" ]] || fail "authorization activation hook is missing"
if /usr/bin/grep -Eq 'scanCleanup\(|unifiedCleanupScan\(|quickOptimize\(' <<< "$activation"; then
    fail "activation starts a cleanup scan without a user request"
fi
/usr/bin/grep -Fq 'guard hasPendingPermissionAction else { return }' <<< "$activation" || \
    fail "activation does not gate resumption on an explicit pending action"
/usr/bin/grep -Fq 'resumePendingAuthorizedOperation()' <<< "$activation" || \
    fail "user-requested scan cannot resume after authorization"

startup_permissions=$(/usr/bin/awk '
    /^    private func prepareStartupPermissions\(/ { capture = 1 }
    capture { print }
    capture && /^    }/ { exit }
' "$APP_STATE")
/usr/bin/grep -Fq 'showPermissionCenter = true' <<< "$startup_permissions" || \
    fail "startup does not guide the user before a protected scan needs permission"
/usr/bin/grep -Fq 'permissionCenter.scheduleLiveCheck(force: true)' <<< "$startup_permissions" || \
    fail "startup permission guidance does not recheck the current signed process"
if /usr/bin/grep -Eq 'scanCleanup\(|unifiedCleanupScan\(|runPrivilegedBridge\(|applyCleanup\(' \
    <<< "$startup_permissions"; then
    fail "startup permission guidance starts cleanup or administrator work"
fi
/usr/bin/grep -A6 -F 'appState.$showPermissionCenter' "$APP_DELEGATE" \
    | /usr/bin/grep -Fq '.filter { $0 }' || fail "startup permission guidance has no visibility gate"
/usr/bin/grep -A6 -F 'appState.$showPermissionCenter' "$APP_DELEGATE" \
    | /usr/bin/grep -Fq 'self?.showMainWindow()' || \
    fail "startup permission guidance remains hidden in a menu-bar-only launch"

cleanup_feedback=$(/usr/bin/awk '
    /^    private func reportCleanupResult\(/ { capture = 1 }
    capture { print }
    capture && /^    }/ { exit }
' "$APP_STATE")
remaining_feedback=$(/usr/bin/awk '
    /^    private func recordRemainingCleanup\(/ { capture = 1 }
    capture { print }
    capture && /^    }/ { exit }
' "$APP_STATE")
if /usr/bin/grep -Eq 'presentTaskFailure\(|presentTaskNotice\(|confirmation[[:space:]]*=' \
    <<< "$cleanup_feedback$remaining_feedback"; then
    fail "cleanup feedback still presents a popup"
fi
/usr/bin/grep -Fq 'cleanupOutcomeMood = combined.removed > 0 ? .success : .attention' \
    <<< "$cleanup_feedback" || fail "partial deletion does not show successful cleanup"
/usr/bin/grep -Fq 'cleanupReclaimedBytes = combined.reclaimedBytes' \
    <<< "$cleanup_feedback" || fail "cleanup result does not use actual reclaimed bytes"
if /usr/bin/grep -Fq 'cleanupRetryAvailable = false' <<< "$cleanup_feedback"; then
    fail "successful cleanup discards its remaining cleanup action"
fi

cleanup_tab=$(/usr/bin/awk '
    /switch pages\[tab\]/ { capture = 1 }
    capture && /case \.cleanup:/ { cleanup = 1; next }
    cleanup && /case / { exit }
    cleanup && !/^[[:space:]]*\/\// && /[^[:space:]]/ { print $1 }
' "$APP_STATE")
[[ "$cleanup_tab" == "break" ]] || fail "cleanup tab activation mutates results or starts work"

/usr/bin/grep -Fq 'state.requestScanAccess(.quickOptimize)' "$CLEANUP_VIEW" || \
    fail "the unified scan button is missing"
if /usr/bin/grep -Fq 'state.requestScanAccess(.deepCleanupScan)' "$CLEANUP_VIEW"; then
    fail "cleanup tab still exposes a separate deep-scan entry"
fi
/usr/bin/grep -Fq 'scanCleanup(force: true, mode: .quick, deepFollowUp: true)' "$APP_STATE" || \
    fail "the unified entry does not run a fresh quick scan with deep follow-up"
/usr/bin/grep -Fq 'if deepFollowUp, mode == .quick, !scan.cancelled, !scan.deferredPaths.isEmpty' \
    "$APP_STATE" || fail "quick scans with unfinished directories no longer escalate to deep"
/usr/bin/grep -Fq 'if mode == .quick && scan.cacheable { CleanupCache.save(scan.categories) }' \
    "$APP_STATE" || fail "successful manual scans are no longer cached"
/usr/bin/grep -Fq 'NativeCore.shared.preflightCleanupCategories(cached.categories, control: control,' \
    "$APP_STATE" || fail "cached cleanup paths are displayed without fresh deletion eligibility"
/usr/bin/grep -Fq 'categories = finalizedCleanupCategories(' "$APP_STATE" \
    && /usr/bin/grep -Fq 'appendNoriManagedPaths(to: preflight.categories), running: snapshot' \
    "$APP_STATE" || fail "cached cleanup display bypasses native eligibility or runtime filtering"
/usr/bin/grep -Fq 'cleanupScanComplete = preflight.succeeded && !control.isCancelled' \
    "$APP_STATE" || fail "unverified cached cleanup enables execution"
[[ $(/usr/bin/grep -Fc 'includingAdministratorRequired: true' "$APP_STATE") -ge 2 ]] || \
    fail "fresh or cached manual scans hide eligible items requiring administrator access"

unified_scan=$(/usr/bin/awk '
    /^    private func unifiedCleanupScan\(/ { capture = 1 }
    capture { print }
    capture && /^    }/ { exit }
' "$APP_STATE")
/usr/bin/grep -Fq 'CleanupCategory.safeCleanupCandidates(from: coreScan.categories)' \
    <<< "$unified_scan" || fail "ordinary cleanup publishes unconfirmed Warning data roots"
if /usr/bin/grep -Fq 'app_installer_scan.sh' <<< "$unified_scan"; then
    fail "ordinary cleanup recommends installer files that may be the only copy"
fi

printf 'PASS: manual cleanup preserves lifecycle and revalidates fresh/cached display eligibility\n'
