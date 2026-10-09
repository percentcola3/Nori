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
    struct Progress {}
    struct MaintenanceRow { let id: String }
    struct QueueFixture { var activeJob: String? }
    struct Attempt {
        let categories: [CleanupCategory]
        let priorResult: CleanupExecutionResult
        let maintenanceIDs: [String]
        let installers: CleanupCategory?
        let retryScope: [CleanupCategory]?
        let pendingMaintenanceIDs: [String]
    }

    var categories: [CleanupCategory] = []
    var cleanupOutcomeMood: NoriMood?
    var cleanupOutcomeDetails: [String] = []
    var cleanupTaskProgress: Progress? = .init()
    var cleanupCompletedCount = 0
    var cleanupReclaimedBytes: UInt64 = 0
    var cleanupFailureApplications: [String] = []
    var cleanupCelebrating = false
    var cleanupFeedbackID = 0
    var cleanupRetryAvailable = false
    let cleanupRuntime = CleanupRuntimeState()
    var cleanupQueued = false
    var isApplying = true
    var isCleanupTaskBusy: Bool { isApplying || cleanupQueued }
    var agentApplying = false
    var agentProgramBusyID: String?
    var commandLineToolBusyID: String?
    var softwareUpdatingID: String?
    var uninstallQueue = QueueFixture()
    var pendingCleanup: (() -> Void)?
    var family: CleanupFamily = .clean
    var cleanupScanComplete = true
    var installerCandidates: CleanupCategory?
    var systemMaintenanceRows: [MaintenanceRow] = []
    var systemMaintenanceSelection: Set<String> = []
    var selectedCount: Int { categories.compactMap(\.selectedSubset).reduce(0) { $0 + $1.paths.count } }
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

    // APPSTATE_CLEANUP_PAGE_METHODS
}

@main
struct CleanupPageStateTests {
    static func main() async throws {
        let selection = category(["/fixture/first", "/fixture/second"])
        precondition(selection.selectingPath(at: 1) == selection.selectingPaths(["/fixture/second"]),
                     "Indexed selection changed the captured category or selected item")
        precondition(!selection.selectingPath(at: -1).selected && !selection.selectingPath(at: 2).selected,
                     "Indexed selection accepted a path outside the captured inventory")
        var protectedSelection = selection
        protectedSelection.risk = .protected
        precondition(!protectedSelection.selectingPath(at: 0).selected,
                     "Indexed selection bypassed protected-category restrictions")
        testPartialSuccessAndRetry()
        testCompleteFailure()
        testActualByteAggregation()
        testUnverifiedInventoryRetainsRetry()
        testStartupPermissions()
        testGarbageTotal()
        try await testMutationBoundaries()
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

    private static func testMutationBoundaries() async throws {
        let captured = category(["/fixture/captured"])
        for gate in ["agent-data", "agent-program", "cli-uninstall", "software-update"] {
            let page = PageStateFixture()
            page.isApplying = false
            page.categories = [captured]
            page.configureCleanupRetry([captured], family: .clean, mode: .manual,
                installers: nil, maintenanceIDs: [], result: .init(), verified: true)
            if gate == "agent-data" { page.agentApplying = true }
            if gate == "agent-program" { page.agentProgramBusyID = "other-agent" }
            if gate == "cli-uninstall" { page.commandLineToolBusyID = "other-cli" }
            if gate == "software-update" { page.softwareUpdatingID = "other-update" }
            page.applyCleanup()
            page.retryFailedCleanup()
            precondition(page.attempts.isEmpty && !page.isApplying && page.cleanupRetryAvailable
                         && page.cleanupRuntime.retryAction != nil,
                         "Shared mutation consumed the captured cleanup retry")
            page.agentApplying = false
            page.agentProgramBusyID = nil
            page.commandLineToolBusyID = nil
            page.softwareUpdatingID = nil
            page.categories = [category(["/fixture/new-selection"])]
            page.retryFailedCleanup()
            precondition(page.attempts.count == 1 && page.attempts[0].categories == [captured],
                         "Cleanup retry expanded to a later selection")
        }

        let racing = PageStateFixture()
        racing.isApplying = true
        racing.agentProgramBusyID = "other-agent"
        let installers = category(["/fixture/installer"])
        let originalScope = [category(["/fixture/completed", "/fixture/captured"])]
        racing.performApply(categories: [captured], family: .clean, mode: .manual,
            installers: installers, maintenanceIDs: ["maintenance"],
            priorResult: .init(removed: 1, reclaimedBytes: 23), retryScope: originalScope,
            pendingMaintenanceIDs: ["pending-maintenance"])
        precondition(!racing.isApplying && racing.cleanupTaskProgress == nil
                     && racing.cleanupRetryAvailable && racing.attempts.isEmpty)
        racing.agentProgramBusyID = nil
        racing.retryFailedCleanup()
        let resumed = racing.attempts[0]
        precondition(resumed.categories == [captured] && resumed.installers == installers
                     && resumed.maintenanceIDs == ["maintenance"] && resumed.priorResult.reclaimedBytes == 23
                     && resumed.retryScope == originalScope && resumed.pendingMaintenanceIDs == ["pending-maintenance"],
                     "A blocked execution boundary lost its frozen request arguments")

        let queued = PageStateFixture()
        queued.isApplying = false
        queued.categories = [captured]
        queued.uninstallQueue.activeJob = "active-app"
        queued.applyCleanup()
        let deadline = Date().addingTimeInterval(3)
        while queued.pendingCleanup == nil {
            precondition(Date() < deadline)
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        precondition(queued.cleanupQueued && !queued.isApplying && queued.attempts.isEmpty,
                     "Ordinary cleanup no longer waits behind active app uninstall")
        queued.categories = [category(["/fixture/later-selection"])]
        queued.uninstallQueue.activeJob = nil
        let pending = queued.pendingCleanup!
        queued.pendingCleanup = nil
        queued.cleanupQueued = false
        pending()
        precondition(queued.attempts.count == 1 && queued.attempts[0].categories == [captured],
                     "Uninstall queue resume changed the cleanup selection")
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

    private static func testGarbageTotal() {
        let page = PageStateFixture()
        var safe = category(["/fixture/cache", "/fixture/other"])
        safe.bytes = 102_400 // The getter must use individual measured paths.
        safe = safe.selectingPaths([])
        var warning = category(["/fixture/history"])
        warning.risk = .warning
        var protected = category(["/fixture/credentials"])
        protected.risk = .protected
        var preserved = category(["/fixture/current-installation"])
        preserved.disposal = .none
        page.categories = [safe, warning, protected, preserved]
        precondition(page.totalBytes == 8192,
                     "Garbage totals include eligible cache paths, independently of selection")
        let parent = category(["/fixture/cache-root"])
        let nested = category(["/fixture/cache-root/child"])
        let neighbor = category(["/fixture/cache-root-neighbor"])
        page.categories = [nested, parent, neighbor, parent]
        precondition(page.totalBytes == 8192,
                     "A selected parent covers its child once; a same-prefix neighbor remains distinct")
        page.categories = [warning, protected, preserved]
        precondition(page.totalBytes == 0,
                     "History, protected resources and retained installations cannot become garbage")
        page.categories = []
        precondition(page.totalBytes == 0)
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
