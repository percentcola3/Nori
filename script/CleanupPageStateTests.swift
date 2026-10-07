import Foundation

private enum NoriMood: Equatable { case idle, success, attention }

private final class PageTestL10n {
    func t(_ key: String) -> String { key }
    func tf(_ key: String, _ arguments: CVarArg...) -> String {
        key + ":" + (arguments.first.map(String.init(describing:)) ?? "")
    }
}

private final class PageTestCache {
    func clear() {}
}

private final class PageTestPermissions {
    var granted = false
    var liveChecks = 0
    var clearedErrors = 0

    func refresh() -> Bool { granted }
    func clearDiskAuthorizationError() { clearedErrors += 1 }
    func scheduleLiveCheck(force: Bool) {
        precondition(force)
        liveChecks += 1
    }
}

/// Production page methods are inserted by test_cleanup_page_state.sh.
/// The fixture replaces windows, scans and deletion with observable effects.
private final class CleanupRuntimeState {
    var retryAction: (() -> Void)?
}

private final class PageStateFixture {
    struct Attempt {
        let categories: [CleanupCategory]
        let priorResult: CleanupExecutionResult
        let maintenanceIDs: [String]
    }

    var categories: [CleanupCategory] = []
    var cleanupOutcomeMood: NoriMood?
    var cleanupOutcomeDetails: [String] = []
    var cleanupTaskProgress: String? = "verifying"
    var cleanupCompletedCount = 0
    var cleanupReclaimedBytes: UInt64 = 0
    var cleanupFailureApplications: [String] = []
    var cleanupCelebrating = false
    var cleanupFeedbackID = 0
    var cleanupRetryAvailable = false
    let cleanupRuntime = CleanupRuntimeState()
    var cleanupQueued = false
    var isApplying = true
    var isBusyExcludingUninstall: Bool { isApplying }
    var headerMood: NoriMood?
    var popupCount = 0
    var statusText = ""
    var attempts: [Attempt] = []

    let l10n = PageTestL10n()
    let analyzeCache = PageTestCache()
    let permissionCenter = PageTestPermissions()
    var showPermissionCenter = false
    var hasPendingPermissionAction = false
    var authorizationResumptions = 0
    var diskServiceActivations = 0

    func noteHeaderReaction(_ mood: NoriMood?) { headerMood = mood }
    func localizedCleanupDetail(_ detail: String) -> String { "localized:" + detail }
    func resampleAfterMutation() {}
    func log(_ text: String) {}
    func activateProtectedDiskServices() { diskServiceActivations += 1 }
    func resumePendingAuthorizedOperation() {
        authorizationResumptions += 1
        hasPendingPermissionAction = false
        showPermissionCenter = false
    }
    func presentTaskFailure(message: String = "", details: [String] = [],
                            detailsAreLocalized: Bool = false) { popupCount += 1 }
    static func blockingApplicationNames(_ owners: [String]) -> [String] { owners.sorted() }

    func performApply(categories: [CleanupCategory], family: CleanupFamily,
                      mode: CleanupExecutionMode, installers: CleanupCategory? = nil,
                      maintenanceIDs: [String] = [], priorResult: CleanupExecutionResult = .init()) {
        precondition(!cleanupRetryAvailable && cleanupRuntime.retryAction == nil,
                     "The retry must be consumed before dispatching another task")
        attempts.append(Attempt(categories: categories, priorResult: priorResult,
                                maintenanceIDs: maintenanceIDs))
    }

    // APPSTATE_CLEANUP_PAGE_METHODS
}

@main
struct CleanupPageStateTests {
    static func main() {
        testPartialSuccessAndRetry()
        testCompleteFailure()
        testActualByteAggregation()
        testUnverifiedInventoryRetainsRetry()
        testStartupPermissions()
        print("Cleanup page state: partial success, actual bytes, inline failure, remaining retries and startup permissions passed")
    }

    private static func category(_ paths: [String]) -> CleanupCategory {
        CleanupCategory(name: "Fixture garbage", paths: paths,
            bytes: UInt64(paths.count) * 4096,
            pathBytes: Dictionary(uniqueKeysWithValues: paths.map { ($0, UInt64(4096)) }),
            pathIdentities: Dictionary(uniqueKeysWithValues: paths.map { ($0, "original:" + $0) }),
            source: .core, risk: .safe, disposal: .permanentDelete,
            applyRoute: .genericTrash, activityGuard: .openFile)
    }

    private static func testPartialSuccessAndRetry() {
        let completed = "/fixture/gone"
        let pending = "/fixture/pending"
        let requested = category([completed, pending])
        let partial = CleanupExecutionResult(removed: 1, skipped: 1, failed: 1,
            messages: ["Permission denied"], executionFailed: true,
            removedPaths: [completed], reclaimedBytes: 4096)
        let page = PageStateFixture()
        page.categories = [category([pending])]
        page.configureCleanupRetry([requested], family: .clean, mode: .manual,
            installers: nil, maintenanceIDs: [], result: partial, verified: true)
        page.reportCleanupResult(partial, permanently: true,
            verified: false, waitingApplications: ["Browser"])
        page.recordRemainingCleanup([category([pending])], owners: ["Browser"])

        precondition(page.cleanupOutcomeMood == .success && page.headerMood == .success,
                     "Partial deletion must display successful cleanup")
        precondition(page.cleanupReclaimedBytes == 4096
            && page.statusText == "cleanup.task.reclaimed:" + ByteFormat.format(4096),
            "Cleanup displayed an estimate rather than the executor's released bytes")
        precondition(page.cleanupOutcomeDetails.isEmpty && page.popupCount == 0,
                     "Partial success still displays failure diagnostics or a popup")
        precondition(page.cleanupRetryAvailable && page.cleanupRuntime.retryAction != nil,
                     "Success feedback discarded the remaining cleanup action")
        precondition(page.isApplying && page.cleanupTaskProgress == nil && page.cleanupCelebrating,
                     "Reporting released the busy state before the caller completes verification")

        page.retryFailedCleanup()
        precondition(page.attempts.isEmpty, "A busy task allowed another cleanup")
        page.isApplying = false
        page.retryFailedCleanup()
        precondition(page.attempts.count == 1 && page.attempts[0].categories.count == 1)
        let attempt = page.attempts[0]
        precondition(attempt.categories[0].paths == [pending]
            && attempt.categories[0].pathIdentities[pending] == requested.pathIdentities[pending],
            "Retry resubmitted completed paths or lost the original pending identity")
        precondition(attempt.priorResult.removed == 0 && attempt.priorResult.reclaimedBytes == 0,
                     "Another explicit cleanup counted the previous attempt's released bytes again")

        let finished = CleanupExecutionResult(removed: 1, removedPaths: [pending], reclaimedBytes: 2048)
        page.categories = []
        page.configureCleanupRetry(attempt.categories, family: .clean, mode: .manual,
            installers: nil, maintenanceIDs: [], result: finished, verified: true)
        page.reportCleanupResult(finished, permanently: true)
        precondition(page.cleanupReclaimedBytes == 2048 && page.cleanupCompletedCount == 1,
                     "The second result accumulated the first attempt's deletion again")
        precondition(!page.cleanupRetryAvailable && page.cleanupRuntime.retryAction == nil,
                     "A completed plan left a stale retry action")
        page.retryFailedCleanup()
        precondition(page.attempts.count == 1, "A consumed plan dispatched another cleanup")
    }

    private static func testCompleteFailure() {
        let page = PageStateFixture()
        page.reportCleanupResult(.init(failed: 2, messages: ["Permission denied"], executionFailed: true),
            permanently: true, verified: false, waitingApplications: ["Browser"])
        precondition(page.cleanupOutcomeMood == .attention && page.popupCount == 0,
                     "Complete failure escaped inline feedback")
        precondition(page.cleanupOutcomeDetails.contains("localized:Permission denied")
            && page.cleanupOutcomeDetails.contains("cleanup.execution.verificationIncomplete")
            && page.cleanupOutcomeDetails.contains("Browser"), "Inline failure reasons were lost")
        precondition(page.cleanupReclaimedBytes == 0 && page.isApplying,
                     "Failure invented released bytes or ended the caller's busy state")
    }

    private static func testActualByteAggregation() {
        let page = PageStateFixture()
        page.reportCleanupResult(.init(removed: 1, reclaimedBytes: 512), permanently: true,
            maintenance: .init(removed: 1, reclaimedBytes: 1024))
        precondition(page.cleanupReclaimedBytes == 1536 && page.cleanupCompletedCount == 2,
                     "Maintenance and deletion results lost their released byte totals")
    }

    private static func testUnverifiedInventoryRetainsRetry() {
        let pending = "/fixture/unverified"
        let page = PageStateFixture()
        page.categories = []
        page.configureCleanupRetry([category([pending])], family: .clean, mode: .manual,
            installers: nil, maintenanceIDs: ["maintenance-pending"],
            result: .init(failed: 1), verified: false)
        page.isApplying = false
        page.retryFailedCleanup()
        precondition(page.attempts.first?.categories.first?.paths == [pending]
            && page.attempts.first?.maintenanceIDs == ["maintenance-pending"],
            "Incomplete verification discarded the frozen pending plan")
    }

    private static func testStartupPermissions() {
        let missing = PageStateFixture()
        missing.prepareStartupPermissions()
        precondition(missing.showPermissionCenter && missing.permissionCenter.liveChecks == 1
            && missing.diskServiceActivations == 0 && missing.authorizationResumptions == 0,
            "Missing startup permission did not guide the user before protected work")
        missing.showPermissionCenter = false
        missing.refreshAuthorizationAndResume()
        precondition(!missing.showPermissionCenter,
                     "A dismissed startup guide reopened without a pending user action")

        let granted = PageStateFixture()
        granted.permissionCenter.granted = true
        granted.prepareStartupPermissions()
        precondition(!granted.showPermissionCenter && granted.diskServiceActivations == 1
            && granted.authorizationResumptions == 0,
            "Permission availability was treated as a new protected-operation request")
        granted.hasPendingPermissionAction = true
        granted.prepareStartupPermissions()
        granted.refreshAuthorizationAndResume()
        precondition(granted.authorizationResumptions == 1,
                     "An explicit pending operation resumed more than once")
    }
}
