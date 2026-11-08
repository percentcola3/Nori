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
    var taskGeneration = UUID()
    var traceRequestID: UUID?
    var confirmationToken: UUID?
    var reviewedSelection: ReviewedSelection?

    struct ReviewedSelection {
        let categories: [CleanupCategory]
        let installers: CleanupCategory?
        let maintenanceIDs: [String]
        let family: CleanupFamily
        let generation: UUID
        let selectedCount: Int
    }
}

/// Records both MainActor and detached preparation events without touching
/// CleanupTrace's real HOME/log destination or invoking an application service.
private enum CleanupTrace {
    struct Entry: Sendable {
        let sequence: Int
        let event: String
        let requestID: UUID?
        let fields: [String: String]
    }
    final class MemorySink: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [Entry] = []
        func record(_ event: String, requestID: UUID?, fields: [String: String]) {
            lock.lock(); defer { lock.unlock() }
            entries.append(.init(sequence: entries.count + 1, event: event, requestID: requestID, fields: fields))
        }
        func snapshot() -> [Entry] { lock.lock(); defer { lock.unlock() }; return entries }
        func reset() { lock.lock(); defer { lock.unlock() }; entries.removeAll() }
    }
    static let mockTrace = MemorySink()
    static func record(_ event: String, requestID: UUID? = nil, fields: [String: String] = [:]) {
        mockTrace.record(event, requestID: requestID, fields: fields)
    }
}

private enum CleanupSelectionPresentation {
    static func selectedCount(_ category: CleanupCategory?) -> Int {
        guard let category, category.canSelect else { return 0 }
        return category.selectedPathCount
    }
}
private enum L10nLocalizationAuditTables {
    static func categoryName(_ name: String, isAppLeftover: Bool = false) -> String { name }
}

private enum CleanupScanMode { case deep }
private enum AdministratorCleanupPlan {
    static var proposed: [DeletionPlan.Item] = []
    static func confirmationItems(_ categories: [CleanupCategory], administratorRequiredPaths: Set<String>) -> [DeletionPlan.Item] {
        proposed
    }
}
private enum CleanupScanProcess {
    struct Scan {
        var categories: [CleanupCategory] = []
        var succeeded = true
        var administratorRequiredPaths = Set<String>()
        var diagnostics = ""
    }
    static var reply = Scan()
    static var inputs: [[CleanupCategory]] = []
    static func scanCleanup(mode: CleanupScanMode, includingAdministratorRequired: Bool,
                            cachedCategories: [CleanupCategory]?) async -> Scan {
        precondition(includingAdministratorRequired && cachedCategories != nil)
        inputs.append(cachedCategories!)
        return reply
    }
}

@MainActor
private final class PageStateFixture {
    struct Progress {}
    struct MaintenanceRow { let id: String }
    struct QueueFixture { var activeJob: String? }
    struct Confirmation {
        let id = UUID()
        let title: String
        let message: String
        let confirmLabel: String
        let onConfirm: () -> Void
    }
    struct Attempt {
        let categories: [CleanupCategory]
        let family: CleanupFamily
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
    var isScanning = false
    var isAutoCleanupScanning = false
    var isSystemMaintenanceRunning = false
    var confirmation: Confirmation?
    var isDispatchingConfirmation = false
    var queueResumeCount = 0
    var showAutoCleanupSheet = false
    var showWhitelistSheet = false
    var agentApplying = false
    var agentProgramBusyID: String?
    var uninstallDataReview: UUID?
    var commandLineToolBusyID: String?
    var softwareUpdatingID: String?
    var uninstallQueue = QueueFixture()
    var pendingCleanup: (() -> Void)?
    var family: CleanupFamily = .clean
    var cleanupScanComplete = true
    var installerCandidates: CleanupCategory?
    var systemMaintenanceRows: [MaintenanceRow] = []
    var systemMaintenanceSelection: Set<String> = []
    var selectedCount: Int { categories.reduce(0) { $0 + CleanupSelectionPresentation.selectedCount($1) } }
    var headerMood: NoriMood?
    var popupCount = 0
    var logPublicationCount = 0
    var logLines: [String] = [] { didSet { logPublicationCount += 1 } }
    var taskNotice: TaskFeedbackNotice?
    var statusText = ""
    var attempts: [Attempt] = []
    struct RouteAttempt {
        let route: CleanupApplyRoute
        let categories: [CleanupCategory]
        let mode: CleanupExecutionMode
        let permanently: Bool
    }
    var routeAttempts: [RouteAttempt] = []
    var routeReplies: [CleanupExecutionResult] = []
    var onRouteAttempt: ((Int) -> Void)?

    /// The real retry wrapper is extracted below; every destructive/native
    /// attempt is replaced by this deterministic in-memory result sequence.
    func executeCleanupRouteAttempt(_ route: CleanupApplyRoute, categories: [CleanupCategory],
                                    mode: CleanupExecutionMode, permanently: Bool = false,
                                    onProgress: ((Int, Int, String) -> Void)? = nil) async -> CleanupExecutionResult {
        let index = routeAttempts.count
        routeAttempts.append(.init(route: route, categories: categories, mode: mode, permanently: permanently))
        onRouteAttempt?(index + 1)
        let count = categories.reduce(0) { $0 + $1.paths.count }
        onProgress?(count, count, "")
        return index < routeReplies.count ? routeReplies[index] : .init(failed: count)
    }

    let l10n = PageTestL10n()
    let analyzeCache = PageTestCache()
    let permissionCenter = PageTestPermissions()
    var showPermissionCenter = false
    var hasPendingPermissionAction = false
    var authorizationResumptions = 0
    var diskServiceActivations = 0

    func startNextUninstallIfPossible() { queueResumeCount += 1 }
    func noteHeaderReaction(_ mood: NoriMood?) { headerMood = mood }
    func localizedCleanupDetail(_ detail: String) -> String { "localized:" + detail }
    func resampleAfterMutation() {}
    func log(_ text: String) { logLines = Array((logLines + text.components(separatedBy: .newlines)).suffix(400)) }
    func activateProtectedDiskServices() { diskServiceActivations += 1 }
    func resumePendingAuthorizedOperation() {
        authorizationResumptions += 1
        hasPendingPermissionAction = false
        showPermissionCenter = false
    }
    func presentTaskFailure(message: String = "", details: [String] = [],
                            detailsAreLocalized: Bool = false) { popupCount += 1 }
    func presentTaskNotice(_ notice: TaskFeedbackNotice) {
        popupCount += 1
        taskNotice = notice
    }
    static func blockingApplicationNames(_ owners: [String]) -> [String] { owners.sorted() }

    // APPSTATE_CLEANUP_PAGE_METHODS
}

@main
@MainActor
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
        try await testAutomaticRouteRetryBudget()
        await testUnevenSharedRouteBudget()
        try await testAutomaticRouteRetryScope()
        await testAutomaticRouteRetryGuards()
        testTraceMemorySink()
        try await testConfirmationFrozenSnapshot()
        try await testConfirmationCancellationAndStaleCallbacks()
        try await testConfirmationGenerationGuards()
        try await testNoWarningAndSelectionOnlyRoutes()
        try await testInflightClickTraceCorrelation()
        testCleanupGateReasons()
        await testPartialSuccessAndRetry()
        await testCompleteFailure()
        await testActualByteAggregation()
        await testUnverifiedInventoryRetainsRetry()
        await testQuietRetainedFeedback()
        await testFreshAdministratorPreview()
        await testBoundedDiagnostics()
        testStartupPermissions()
        testGarbageTotal()
        try await testMutationBoundaries()
        try await testReviewedLeftoversDispatch()
        print("Cleanup page state: reviewed leftovers dispatch, frozen selection, partial success, actual bytes, modal failure, remaining retries and startup permissions passed")
    }

    private static func testAutomaticRouteRetryBudget() async throws {
        var target = category(["/fixture/retry-target"])
        target.retention = 7 * 86400
        precondition(CleanupRiskPolicy.usesFileActivityGuard(target))
        let transient = CleanupExecutionResult(failed: 1, messages: ["Transient native refusal"])
        for recovers in [true, false] {
            let page = PageStateFixture()
            page.cleanupRuntime.traceRequestID = UUID()
            let budget = CleanupRetryPolicy.Budget()
            page.routeReplies = [transient, transient, recovers
                ? .init(removed: 1, removedPaths: Set(target.paths), reclaimedBytes: 4096) : transient]
            let result = await page.executeCleanupRoute(.genericTrash, categories: [target], mode: .manual,
                permanently: true, retryBudget: budget)
            precondition(page.routeAttempts.count == 3 && page.routeAttempts.allSatisfy {
                $0.categories.first?.pathIdentities == target.pathIdentities && $0.permanently
            }, "Native recovery must use at most three attempts with the originally reviewed identities")
            precondition(result.removed == (recovers ? 1 : 0) && result.failed == (recovers ? 0 : 1)
                && result.reclaimedBytes == (recovers ? 4096 : 0),
                "Recovered failures or exhausted attempts inflated terminal failures/actual released bytes")
            if !recovers {
                _ = await page.executeCleanupRoute(.installerTrash, categories: [target], mode: .manual, retryBudget: budget)
                var replaced = target
                replaced.pathIdentities[target.paths[0]] = "replacement-object"
                _ = await page.executeCleanupRoute(.developerCacheTrash, categories: [replaced], mode: .manual, retryBudget: budget)
                precondition(page.routeAttempts.count == 3, "Another route or changed identity reset the logical request's shared budget")
            }
            await page.reportCleanupResult(result, permanently: true, verified: recovers)
            precondition(page.popupCount == 0 && page.taskNotice == nil && page.cleanupRuntime.retryAction == nil
                && !page.cleanupRetryAvailable && page.cleanupOutcomeDetails.isEmpty,
                "Automatic retry exhaustion exposed a manual retry or failure dialog")
        }
    }

    private static func testUnevenSharedRouteBudget() async {
        let first = "/fixture/uneven-budget-A", second = "/fixture/uneven-budget-B"
        let scope = category([first, second])
        let firstOnly = scope.selectingPaths([first]).selectedSubset!
        for firstAlreadyExhausted in [false, true] {
            let budget = CleanupRetryPolicy.Budget()
            for _ in 0..<(firstAlreadyExhausted ? 3 : 2) {
                precondition(budget.claim(categories: [firstOnly]).count == 1)
            }
            let page = PageStateFixture()
            page.cleanupRuntime.traceRequestID = UUID()
            page.routeReplies = firstAlreadyExhausted
                ? [.init(failed: 1), .init(failed: 1), .init(removed: 1, removedPaths: [second], reclaimedBytes: 2048)]
                : [.init(failed: 2), .init(removed: 1, removedPaths: [second], reclaimedBytes: 2048)]
            let result = await page.executeCleanupRoute(.genericTrash, categories: [scope], mode: .manual,
                permanently: true, retryBudget: budget)
            if firstAlreadyExhausted {
                precondition(page.routeAttempts.count == 3 && page.routeAttempts.allSatisfy {
                    $0.categories.first?.paths == [second]
                        && $0.categories.first?.pathIdentities == [second: scope.pathIdentities[second]!]
                }, "A first-pass exhausted target ran again or changed the new target's original identity")
                precondition(result.removed == 1 && result.removedPaths == [second]
                    && result.failed == 0 && result.skipped == 1 && result.reclaimedBytes == 2048,
                    "First-claim budget exclusions must count once across all later passes")
            } else {
                precondition(page.routeAttempts.count == 1 && page.routeAttempts[0].categories.first?.paths == scope.paths
                    && result.failed == 2 && result.removed == 0 && result.skipped == 0 && result.reclaimedBytes == 0,
                    "A B-only partial second pass erased A's terminal failure or invented a deletion")
                precondition(trace(page.cleanupRuntime.traceRequestID).contains {
                    $0.event == "route.retry.stopped" && $0.fields["reason"] == "partial_budget_exhausted"
                }, "Uneven later claims did not stop before execution")
            }
        }
    }

    private static func testAutomaticRouteRetryScope() async throws {
        let removed = "/fixture/already-removed", retained = "/fixture/quiet-retained", pending = "/fixture/retry-pending"
        let source = warning([removed, retained, pending, "/fixture/unselected"])
            .selectingPaths([removed, retained, pending]).selectedSubset!
        let receipt = DeletionPlan.RetainedTarget(record: retained, identity: source.pathIdentities[retained]!, reason: .protectedFlags, count: 1)
        let page = PageStateFixture()
        page.routeReplies = [.init(removed: 1, skipped: 1, failed: 1, removedPaths: [removed], reclaimedBytes: 256, retainedTargets: [receipt]),
                             .init(removed: 1, removedPaths: [pending], reclaimedBytes: 512)]
        page.onRouteAttempt = { index in
            if index == 1 { page.categories = [category(["/fixture/later-selection"])] }
        }
        let result = await page.executeCleanupRoute(.genericTrash, categories: [source], mode: .manual, permanently: true)
        precondition(page.routeAttempts.count == 2 && page.routeAttempts[0].categories.first?.paths == source.paths
            && page.routeAttempts[1].categories.first?.paths == [pending]
            && page.routeAttempts[1].categories.first?.pathIdentities == [pending: source.pathIdentities[pending]!]
            && page.routeAttempts[1].categories.first?.uninstallDataOwner == source.uninstallDataOwner,
            "Automatic retry replayed removed/quiet/unselected work, rebound identity or lost the original data owner")
        precondition(result.removed == 2 && result.removedPaths == [removed, pending]
            && result.failed == 0 && result.reclaimedBytes == 768 && result.quietSkipped == 1,
            "Partial automatic recovery double-counted deletion/retention or kept an obsolete failure")
    }

    private static func testAutomaticRouteRetryGuards() async {
        let target = category(["/fixture/guarded-retry"])
        for route in [CleanupApplyRoute.toolCommand, .none, .genericTrash] {
            let page = PageStateFixture()
            page.routeReplies = [.init(failed: 1, executionFailed: route == .genericTrash),
                                 .init(removed: 1, removedPaths: Set(target.paths), reclaimedBytes: 99)]
            _ = await page.executeCleanupRoute(route, categories: [target], mode: .manual)
            precondition(page.routeAttempts.count == 1, "A tool/unknown transport outcome was replayed automatically")
        }
        for mode in [CleanupExecutionMode.automatic, .quickClean, .manual] {
            CleanupTrace.mockTrace.reset()
            let page = PageStateFixture()
            page.cleanupRuntime.traceRequestID = UUID()
            var ageBound = target
            if case .manual = mode { ageBound = warning(["/fixture/age-bound-review"]) }
            ageBound.retention = 7 * 86400
            page.routeReplies = [.init(failed: 1), .init(removed: 1)]
            _ = await page.executeCleanupRoute(.genericTrash, categories: [ageBound], mode: mode)
            precondition(page.routeAttempts.count == 1 && trace(page.cleanupRuntime.traceRequestID).contains {
                $0.event == "route.retry.stopped" && $0.fields["reason"] == "fresh_age_review_required"
            }, "An age-bound automatic/quick/review-data attempt reused its first age proof")
        }
        for condition in ["generation", "mutation", "not-applying", "cancelled"] {
            let page = PageStateFixture()
            page.routeReplies = [.init(failed: 1), .init(removed: 1, removedPaths: Set(target.paths))]
            var task: Task<CleanupExecutionResult, Never>?
            page.onRouteAttempt = { _ in
                switch condition {
                case "generation": page.cleanupRuntime.taskGeneration = UUID()
                case "mutation": page.agentApplying = true
                case "not-applying": page.isApplying = false
                default: task?.cancel()
                }
            }
            task = Task { await page.executeCleanupRoute(.genericTrash, categories: [target], mode: .manual) }
            _ = await task!.value
            precondition(page.routeAttempts.count == 1, "Epoch/cancellation/shared mutation continued a stale retry: \(condition)")
            if condition == "generation" { precondition(page.isApplying, "An old retry cleared a newer generation's busy state") }
        }
        for initiallyBlocked in [false, true] {
            let page = PageStateFixture()
            page.agentApplying = initiallyBlocked
            page.isApplying = initiallyBlocked
            _ = await page.executeCleanupRoute(.genericTrash, categories: [target], mode: .manual)
            precondition(page.routeAttempts.isEmpty, "A blocked/inactive route started a destructive attempt")
        }
    }

    private static func readyPage(_ categories: [CleanupCategory]) -> PageStateFixture {
        let page = PageStateFixture()
        page.isApplying = false
        page.categories = categories
        return page
    }

    private static func warning(_ paths: [String]) -> CleanupCategory {
        var value = category(paths)
        value.name = "Fixture reviewed app data"
        value.source = .core
        value.risk = .warning
        value.activityGuard = .appData
        value.reasonKey = "cleanup.risk.appDataReview"
        value.uninstallDataOwner = .init(kind: .application, name: "Fixture reviewed owner", bundleID: "test.nori.review")
        return value
    }

    private static func trace(_ requestID: UUID?) -> [CleanupTrace.Entry] {
        CleanupTrace.mockTrace.snapshot().filter { $0.requestID == requestID }
    }

    private static func assertEvents(_ expected: [String], requestID: UUID?) {
        let entries = trace(requestID)
        var remaining = ArraySlice(expected)
        for entry in entries where entry.event == remaining.first { remaining = remaining.dropFirst() }
        precondition(remaining.isEmpty, "Missing or reordered click trace: \(expected); actual=\(entries.map(\.event))")
        precondition(entries.allSatisfy { $0.requestID != nil }, "A clicked operation lost its trace request identity")
    }

    private static func waitUntil(_ message: String, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate() {
            precondition(Date() < deadline, message)
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private static func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private static func testTraceMemorySink() {
        CleanupTrace.mockTrace.reset()
        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            CleanupTrace.record("fixture.concurrent", requestID: UUID(), fields: ["index": String(index)])
        }
        let entries = CleanupTrace.mockTrace.snapshot()
        precondition(entries.count == 1_000 && Set(entries.map { $0.fields["index"]! }).count == 1_000
            && entries.map(\.sequence) == Array(1...1_000), "The in-memory trace sink lost or raced detached events")
        CleanupTrace.mockTrace.reset()
    }

    private static func testConfirmationFrozenSnapshot() async throws {
        CleanupTrace.mockTrace.reset()
        let reviewed = warning(["/fixture/reviewed", "/fixture/not-reviewed"]).selectingPaths(["/fixture/reviewed"])
        var installer = category(["/fixture/installer-selected", "/fixture/installer-unselected"])
        installer.source = .installer
        installer.applyRoute = .installerTrash
        installer = installer.selectingPaths(["/fixture/installer-selected"])
        let page = readyPage([reviewed])
        page.installerCandidates = installer
        page.systemMaintenanceRows = [.init(id: "first"), .init(id: "second"), .init(id: "unselected")]
        page.systemMaintenanceSelection = ["first", "second"]
        page.requestCleanupFromPage()
        let requestID = page.cleanupRuntime.traceRequestID
        precondition(requestID != nil && page.confirmation != nil && page.cleanupRuntime.confirmationToken != nil
            && !page.isApplying && page.attempts.isEmpty, "A warning click did not request stable-window confirmation")
        let accepted = page.confirmation!
        page.categories = [category((0..<5).map { "/fixture/later-\($0)" })]
        page.installerCandidates = category(["/fixture/later-installer", "/fixture/later-installer-2"])
        page.systemMaintenanceRows = [.init(id: "later-maintenance")]
        page.systemMaintenanceSelection = ["later-maintenance"]
        page.family = .tools
        page.runConfirmation(accepted)
        precondition(page.confirmation == nil && page.isDispatchingConfirmation,
                     "Window confirmation must close before dispatching its accepted action")
        try await waitUntil("Confirmed click never reached the execution boundary") { page.attempts.count == 1 }
        let attempt = page.attempts[0]
        precondition(attempt.family == .clean && attempt.categories.count == 1
            && attempt.categories[0].id == reviewed.id && attempt.categories[0].paths == ["/fixture/reviewed"]
            && attempt.categories[0].risk == .warning && attempt.categories[0].uninstallDataOwner == reviewed.uninstallDataOwner
            && attempt.categories[0].pathIdentities == ["/fixture/reviewed": reviewed.pathIdentities["/fixture/reviewed"]!]
            && attempt.installers?.id == installer.id && attempt.installers?.paths == ["/fixture/installer-selected"]
            && attempt.maintenanceIDs == ["first", "second"] && page.statusText == "status.processing:4",
            "Confirmation expanded into later selection, lost reviewed metadata, changed family, or recounted later work")
        precondition(page.cleanupRuntime.confirmationToken == nil && page.cleanupRuntime.reviewedSelection == nil,
                     "Accepted confirmation did not consume its token and frozen review")
        assertEvents(["button.clicked", "confirmation.requested", "window.confirmation.action", "confirmation.accepted",
            "submission.entered", "submission.preparing", "selection.prepare.started", "selection.prepare.finished",
            "submission.prepared", "execution.entered"], requestID: requestID)
        precondition(trace(requestID).first?.fields["selectedCount"] == "1"
            && trace(requestID).first(where: { $0.event == "selection.prepare.finished" })?.fields["paths"] == "1")
        page.runConfirmation(accepted)
        await drainMainQueue()
        precondition(page.attempts.count == 1 && trace(requestID).filter { $0.event == "confirmation.accepted" }.count == 1,
                     "A duplicate confirmation callback dispatched reviewed work twice")
        precondition(trace(requestID).contains { $0.event == "confirmation.stale_callback" })
    }

    private static func testConfirmationCancellationAndStaleCallbacks() async throws {
        for cancelAfterWindowDispatch in [false, true] {
            CleanupTrace.mockTrace.reset()
            let page = readyPage([warning(["/fixture/cancelled-review"])])
            page.requestCleanupFromPage()
            let accepted = page.confirmation!
            let requestID = page.cleanupRuntime.traceRequestID
            if cancelAfterWindowDispatch { page.runConfirmation(accepted) }
            page.cancelCleanupConfirmation()
            if !cancelAfterWindowDispatch { accepted.onConfirm() }
            await drainMainQueue()
            precondition(page.attempts.isEmpty && !page.isApplying && page.confirmation == nil
                && page.cleanupRuntime.confirmationToken == nil && page.cleanupRuntime.reviewedSelection == nil,
                "Cancel or a late accepted callback dispatched a cancelled review")
            assertEvents(["button.clicked", "confirmation.requested", "confirmation.cancelled", "confirmation.stale_callback"], requestID: requestID)
            precondition(!trace(requestID).contains { $0.event == "submission.preparing" })
        }
        let page = readyPage([warning(["/fixture/old-review"])])
        page.requestCleanupFromPage()
        let old = page.confirmation!
        page.cancelCleanupConfirmation()
        page.categories = [warning(["/fixture/new-review"])]
        page.requestCleanupFromPage()
        let current = page.confirmation!
        let token = page.cleanupRuntime.confirmationToken
        old.onConfirm()
        precondition(page.attempts.isEmpty && page.cleanupRuntime.confirmationToken == token && page.confirmation?.id == current.id,
                     "A stale callback consumed or replaced the newer confirmation")
        page.runConfirmation(current)
        try await waitUntil("Replacement confirmation never dispatched") { page.attempts.count == 1 }
        precondition(page.attempts[0].categories.flatMap(\.paths) == ["/fixture/new-review"])
    }

    private static func testConfirmationGenerationGuards() async throws {
        CleanupTrace.mockTrace.reset()
        let page = readyPage([warning(["/fixture/stale-generation"])])
        page.requestCleanupFromPage()
        let accepted = page.confirmation!
        let requestID = page.cleanupRuntime.traceRequestID
        page.cleanupRuntime.taskGeneration = UUID()
        page.runConfirmation(accepted)
        await drainMainQueue()
        precondition(page.attempts.isEmpty && !page.isApplying && page.cleanupRuntime.reviewedSelection == nil,
                     "A confirmation from an old scan generation dispatched")
        precondition(trace(requestID).contains { $0.event == "submission.rejected" && $0.fields["reason"] == "review_generation_changed" })

        let preparing = readyPage([warning(["/fixture/old-preparation"])])
        preparing.requestCleanupFromPage()
        let callback = preparing.confirmation!
        preparing.confirmation = nil
        callback.onConfirm()
        precondition(preparing.isApplying, "Accepted selection never entered preparation")
        let preparingID = preparing.cleanupRuntime.traceRequestID
        preparing.cleanupRuntime.taskGeneration = UUID()
        try await waitUntil("Old preparation did not report abandonment") {
            trace(preparingID).contains { $0.event == "selection.prepare.abandoned" }
        }
        precondition(preparing.attempts.isEmpty && preparing.isApplying,
                     "An old asynchronous preparation dispatched or cleared the newer generation's busy state")
    }

    private static func testNoWarningAndSelectionOnlyRoutes() async throws {
        for mode in ["safe", "installer", "maintenance"] {
            CleanupTrace.mockTrace.reset()
            let page = readyPage(mode == "safe" ? [category(["/fixture/safe"])] : [])
            if mode == "installer" { page.installerCandidates = category(["/fixture/installer-only"]) }
            if mode == "maintenance" {
                page.systemMaintenanceRows = [.init(id: "maintenance-only")]
                page.systemMaintenanceSelection = ["maintenance-only"]
            }
            page.requestCleanupFromPage()
            let requestID = page.cleanupRuntime.traceRequestID
            precondition(page.confirmation == nil && page.cleanupRuntime.confirmationToken == nil && page.isApplying,
                         "No-warning selection waited for a confirmation or silently failed to prepare: \(mode)")
            try await waitUntil("No-warning selection did not dispatch: \(mode)") { page.attempts.count == 1 }
            assertEvents(["button.clicked", "confirmation.not_required", "submission.entered", "submission.preparing",
                "selection.prepare.started", "selection.prepare.finished", "execution.entered"], requestID: requestID)
            precondition(trace(requestID).filter { $0.event == "submission.preparing" }.count == 1
                && !trace(requestID).contains { $0.event == "confirmation.requested" })
        }
    }

    private static func testInflightClickTraceCorrelation() async throws {
        for awaitingConfirmation in [false, true] {
            CleanupTrace.mockTrace.reset()
            let page = readyPage([awaitingConfirmation
                ? warning(["/fixture/inflight-review"]) : category(["/fixture/inflight-safe"])])
            page.requestCleanupFromPage()
            let activeID = page.cleanupRuntime.traceRequestID!
            page.requestCleanupFromPage()
            let rejectedID = CleanupTrace.mockTrace.snapshot().last(where: { $0.event == "button.clicked" })!.requestID!
            precondition(rejectedID != activeID && page.cleanupRuntime.traceRequestID == activeID,
                         "A blocked second click replaced the active cleanup request identity")
            precondition(trace(rejectedID).map(\.event) == ["button.clicked", "submission.rejected"]
                && trace(rejectedID).last?.fields["reason"] == (awaitingConfirmation ? "modal_active" : "applying"),
                "A blocked click lost its own correlated rejection reason")
            if awaitingConfirmation { page.runConfirmation(page.confirmation!) }
            try await waitUntil("Active cleanup did not dispatch after a blocked second click") { page.attempts.count == 1 }
            assertEvents(["button.clicked"] + (awaitingConfirmation
                ? ["confirmation.requested", "confirmation.accepted"] : ["confirmation.not_required"])
                + ["submission.entered", "submission.preparing", "selection.prepare.started",
                   "selection.prepare.finished", "submission.prepared", "execution.entered"], requestID: activeID)
            precondition(trace(rejectedID).count == 2 && !trace(activeID).contains { $0.event == "submission.rejected" },
                         "Preparation or execution events leaked into the rejected click's trace")
        }
    }

    private static func testCleanupGateReasons() {
        let gates = ["applying", "scanning", "queued", "automatic_scan", "maintenance", "shared_mutation",
                     "scan_incomplete", "no_selection", "confirmation", "notice", "permissions", "auto_sheet", "whitelist"]
        for gate in gates {
            CleanupTrace.mockTrace.reset()
            let page = readyPage([category(["/fixture/blocked"])])
            let readySignature = page.cleanupGateSignature
            switch gate {
            case "applying": page.isApplying = true
            case "scanning": page.isScanning = true
            case "queued": page.cleanupQueued = true
            case "automatic_scan": page.isAutoCleanupScanning = true
            case "maintenance": page.isSystemMaintenanceRunning = true
            case "shared_mutation": page.agentApplying = true
            case "scan_incomplete": page.cleanupScanComplete = false
            case "no_selection": page.categories = []
            case "confirmation": page.confirmation = .init(title: "fixture", message: "fixture", confirmLabel: "fixture", onConfirm: {})
            case "notice": page.taskNotice = .init(message: "fixture")
            case "permissions": page.showPermissionCenter = true
            case "auto_sheet": page.showAutoCleanupSheet = true
            case "whitelist": page.showWhitelistSheet = true
            default: preconditionFailure("Unknown gate fixture")
            }
            let expected = ["confirmation", "notice", "permissions", "auto_sheet", "whitelist"].contains(gate) ? "modal_active" : gate
            precondition(page.cleanupButtonBlockReason == expected && page.cleanupGateSignature != readySignature,
                         "Footer and submission disagree on a scalar gate: \(gate)")
            page.requestCleanupFromPage()
            let requestID = CleanupTrace.mockTrace.snapshot().last?.requestID
            precondition(page.cleanupRuntime.traceRequestID == nil,
                         "A rejected click became the active cleanup operation")
            assertEvents(["button.clicked", "submission.rejected"], requestID: requestID)
            precondition(page.attempts.isEmpty && page.cleanupRuntime.confirmationToken == nil
                && trace(requestID).last?.fields["reason"] == expected
                && trace(requestID).last?.fields["gate"] == expected && !page.statusText.isEmpty,
                "A blocked click failed silently or lost its reason: \(gate)")
        }
    }

    private static func testReviewedLeftoversDispatch() async throws {
        let paths = ["/fixture/Library/Application Support/Retired App", "/fixture/Library/Preferences/retired.plist"]
        var reviewed = CleanupCategory(name: "Fixture uninstalled app", paths: paths,
            bytes: 8192, pathBytes: Dictionary(uniqueKeysWithValues: paths.map { ($0, UInt64(4096)) }),
            pathIdentities: Dictionary(uniqueKeysWithValues: paths.map { ($0, "reviewed:" + $0) }),
            selected: false, source: .appLeftover, risk: .warning, disposal: .permanentDelete,
            applyRoute: .genericTrash, activityGuard: .appData, reasonKey: "cleanup.risk.uninstallLeftover")
        reviewed.uninstallDataOwner = UninstallDataOwner(kind: .application, name: "Fixture uninstalled app",
            bundleID: "test.nori.retired-app")
        reviewed = reviewed.selectingPaths([paths[0]])
        precondition(reviewed.isAppDataReview && reviewed.selected && !reviewed.allSelected)

        for includeSafe in [false, true] {
            CleanupTrace.mockTrace.reset()
            let safe = category(["/fixture/selected-safe.cache"])
            let unselected = category(["/fixture/unselected.cache"]).clearingSelection()
            let page = readyPage([unselected, reviewed] + (includeSafe ? [safe] : []))
            page.requestCleanupFromPage()
            let requestID = page.cleanupRuntime.traceRequestID
            precondition(page.isApplying && page.attempts.isEmpty && page.confirmation == nil
                && page.cleanupRuntime.confirmationToken == nil,
                "A leftover-only or mixed safe/leftover click must prepare immediately without a confirmation")
            assertEvents(["button.clicked", "confirmation.not_required", "submission.entered", "submission.preparing"], requestID: requestID)
            page.categories = [category(["/fixture/later-selection"])]
            try await waitUntil("Reviewed leftovers never reached execution dispatch") { page.attempts.count == 1 }
            let dispatched = page.attempts[0].categories
            let leftover = dispatched.first { $0.id == reviewed.id }
            precondition(page.attempts.count == 1 && dispatched.count == (includeSafe ? 2 : 1)
                && Set(dispatched.flatMap(\.paths)) == Set([paths[0]] + (includeSafe ? safe.paths : []))
                && leftover?.paths == [paths[0]] && leftover?.source == .appLeftover
                && leftover?.risk == .warning && leftover?.isAppDataReview == true
                && leftover?.uninstallDataOwner == reviewed.uninstallDataOwner
                && leftover?.pathIdentities == [paths[0]: reviewed.pathIdentities[paths[0]]!],
                "Direct leftover dispatch dropped partial selection, owner/identity metadata, safe work, or widened the frozen scope")
            precondition(!trace(requestID).contains { $0.event == "confirmation.requested" || $0.event == "confirmation.accepted" },
                         "Uninstalled leftovers unexpectedly requested or waited for a confirmation")
            assertEvents(["selection.prepare.started", "selection.prepare.finished", "execution.entered"], requestID: requestID)
        }

        let incomplete = readyPage([reviewed])
        incomplete.cleanupScanComplete = false
        incomplete.requestCleanupFromPage()
        precondition(incomplete.attempts.isEmpty && !incomplete.isApplying && incomplete.confirmation == nil,
                     "Reviewed leftovers must not bypass an incomplete scan")
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
        for gate in ["agent-data", "agent-program", "data-review", "cli-uninstall", "software-update"] {
            let page = PageStateFixture()
            page.isApplying = false
            page.categories = [captured]
            await page.configureCleanupRetry([captured], family: .clean, mode: .manual,
                installers: nil, maintenanceIDs: [], result: .init(), verified: true)
            if gate == "agent-data" { page.agentApplying = true }
            if gate == "agent-program" { page.agentProgramBusyID = "other-agent" }
            if gate == "data-review" { page.uninstallDataReview = UUID() }
            if gate == "cli-uninstall" { page.commandLineToolBusyID = "other-cli" }
            if gate == "software-update" { page.softwareUpdatingID = "other-update" }
            page.applyCleanup()
            page.retryFailedCleanup()
            precondition(page.attempts.isEmpty && !page.isApplying && page.cleanupRetryAvailable
                         && page.cleanupRuntime.retryAction != nil,
                         "Shared mutation consumed the captured cleanup retry")
            page.agentApplying = false
            page.agentProgramBusyID = nil
            page.uninstallDataReview = nil
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

    private static func testPartialSuccessAndRetry() async {
        let completed = "/fixture/gone"
        let pending = "/fixture/pending"
        let requested = category([completed, pending])
        let partial = CleanupExecutionResult(removed: 1, skipped: 1, failed: 1,
            messages: ["Permission denied"], executionFailed: true,
            removedPaths: [completed], reclaimedBytes: 4096)
        let page = PageStateFixture()
        page.categories = [category([pending])]
        await page.configureCleanupRetry([requested], family: .clean, mode: .manual,
            installers: nil, maintenanceIDs: [], result: partial, verified: true)
        await page.reportCleanupResult(partial, permanently: true,
            verified: false, waitingApplications: ["Browser"])
        page.recordRemainingCleanup([category([pending])], owners: ["Browser"])

        precondition(page.cleanupOutcomeMood == .success && page.headerMood == .success,
                     "Partial deletion must display successful cleanup")
        precondition(page.cleanupReclaimedBytes == 4096
            && page.statusText == "cleanup.task.reclaimed:" + ByteFormat.format(4096),
            "Cleanup displayed an estimate rather than the executor's released bytes")
        precondition(page.cleanupOutcomeDetails.isEmpty && page.popupCount == 0 && page.taskNotice == nil
            && page.cleanupFailureApplications.isEmpty && !page.cleanupRetryAvailable && page.cleanupRuntime.retryAction == nil,
            "Partial success exposed failure details or a manual retry action after automatic retry")
        precondition(page.isApplying && page.cleanupTaskProgress == nil && page.cleanupCelebrating,
                     "Reporting released the busy state before the caller completes verification")

        page.retryFailedCleanup()
        page.isApplying = false
        page.retryFailedCleanup()
        precondition(page.attempts.isEmpty, "A settled result left an executable manual retry")

        let remaining = requested.selectingPaths([pending]).selectedSubset!
        precondition(remaining.pathIdentities[pending] == requested.pathIdentities[pending])
        let finished = CleanupExecutionResult(removed: 1, removedPaths: [pending], reclaimedBytes: 2048)
        page.categories = []
        await page.configureCleanupRetry([remaining], family: .clean, mode: .manual,
            installers: nil, maintenanceIDs: [], result: finished, verified: true)
        await page.reportCleanupResult(finished, permanently: true)
        precondition(page.cleanupReclaimedBytes == 2048 && page.cleanupCompletedCount == 1,
                     "The second result accumulated the first attempt's deletion again")
        precondition(!page.cleanupRetryAvailable && page.cleanupRuntime.retryAction == nil,
                     "A completed plan left a stale retry action")
        page.retryFailedCleanup()
        precondition(page.attempts.isEmpty, "A settled result dispatched another cleanup")
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

    private static func testCompleteFailure() async {
        let page = PageStateFixture()
        await page.reportCleanupResult(.init(failed: 2, messages: ["Permission denied"], executionFailed: true),
            permanently: true, verified: false, waitingApplications: ["Browser"])
        precondition(page.cleanupOutcomeMood == nil && page.headerMood == nil && page.popupCount == 0
            && page.taskNotice == nil && page.cleanupOutcomeDetails.isEmpty && page.cleanupFailureApplications.isEmpty
            && !page.cleanupRetryAvailable && page.cleanupRuntime.retryAction == nil && page.statusText == "status.ready",
            "Exhausted failure must settle silently without attention, a popup or a manual retry")
        precondition(page.logLines.contains("Permission denied"), "Silent UI lost bounded background diagnostics")
        precondition(page.cleanupReclaimedBytes == 0 && page.isApplying,
                     "Failure invented released bytes or ended the caller's busy state")
    }

    private static func testActualByteAggregation() async {
        let page = PageStateFixture()
        await page.reportCleanupResult(.init(removed: 1, reclaimedBytes: 512), permanently: true,
            maintenance: .init(removed: 1, reclaimedBytes: 1024))
        precondition(page.cleanupReclaimedBytes == 1536 && page.cleanupCompletedCount == 2,
                     "Maintenance and deletion results lost their released byte totals")
    }

    private static func testUnverifiedInventoryRetainsRetry() async {
        let pending = "/fixture/unverified"
        let page = PageStateFixture()
        page.categories = []
        await page.configureCleanupRetry([category([pending])], family: .clean, mode: .manual,
            installers: nil, maintenanceIDs: ["maintenance-pending"],
            result: .init(failed: 1), verified: false)
        await page.reportCleanupResult(.init(failed: 1), permanently: true, verified: false)
        page.isApplying = false
        page.retryFailedCleanup()
        precondition(page.attempts.isEmpty && page.taskNotice == nil && !page.cleanupRetryAvailable
            && page.cleanupRuntime.retryAction == nil && page.statusText == "status.ready"
            && CleanupRetryPolicy.remainingCategories([category([pending])], after: .init(failed: 1)).first?.paths == [pending],
            "Incomplete verification exposed manual retry or discarded the original unresolved scope")
    }

    private static func testQuietRetainedFeedback() async {
        let root = "/fixture/retained"
        let child = root + "/child"
        let failed = "/fixture/actionable"
        let captured = category([root, child])
        let receipt = DeletionPlan.RetainedTarget(record: root, identity: captured.pathIdentities[root]!,
            reason: .protectedFlags, count: 1)
        let childReceipt = DeletionPlan.RetainedTarget(record: child, identity: captured.pathIdentities[child]!,
            reason: .readOnlyVolume, count: 1)
        let quiet = CleanupExecutionResult(skipped: 2, messages: ["Retained independently proven targets"], retainedTargets: [receipt, childReceipt])
        let page = PageStateFixture()
        page.categories = [captured]
        await page.configureCleanupRetry([captured], family: .clean, mode: .manual,
            installers: nil, maintenanceIDs: [], result: quiet, verified: false)
        await page.reportCleanupResult(quiet, permanently: true)
        precondition(page.popupCount == 0 && page.cleanupOutcomeMood == nil && !page.cleanupCelebrating
                     && page.cleanupCompletedCount == 0 && page.cleanupReclaimedBytes == 0
                     && page.statusText == "status.ready" && !page.cleanupRetryAvailable,
                     "A confirmed retained-only plan must be neutral, nonretryable and never successful deletion")
        precondition(quiet.remainingPaths(in: captured.paths) == captured.paths && !quiet.completedSuccessfully,
                     "Quiet feedback must not rewrite execution accounting or pretend retained paths were removed")
        let mixed = PageStateFixture()
        let pending = category([failed])
        mixed.categories = [captured, pending]
        var result = quiet
        result.merge(.init(failed: 1, messages: ["I/O failed"]))
        await mixed.configureCleanupRetry([captured, pending], family: .clean, mode: .manual,
            installers: nil, maintenanceIDs: [], result: result, verified: true)
        await mixed.reportCleanupResult(result, permanently: true)
        mixed.isApplying = false
        mixed.retryFailedCleanup()
        let actionable = CleanupRetryPolicy.remainingCategories([captured, pending], after: result)
        precondition(mixed.popupCount == 0 && mixed.taskNotice == nil && mixed.attempts.isEmpty
            && !mixed.cleanupRetryAvailable && mixed.cleanupRuntime.retryAction == nil
            && actionable.first?.paths == [failed] && actionable.first?.pathIdentities[failed] == pending.pathIdentities[failed],
            "Silent settlement discarded the original pending target or replayed exact retained targets")
        let parentOnly = PageStateFixture()
        let unprovenChild = CleanupExecutionResult(skipped: 2, retainedTargets: [receipt])
        await parentOnly.configureCleanupRetry([captured], family: .clean, mode: .manual,
            installers: nil, maintenanceIDs: [], result: unprovenChild, verified: false)
        await parentOnly.reportCleanupResult(unprovenChild, permanently: true)
        parentOnly.isApplying = false
        parentOnly.retryFailedCleanup()
        precondition(parentOnly.popupCount == 0 && parentOnly.taskNotice == nil && parentOnly.attempts.isEmpty
            && CleanupRetryPolicy.remainingCategories([captured], after: unprovenChild).first?.paths == [child],
            "Silent settlement suppressed an unproven explicitly submitted child or exposed manual retry")
        let partial = PageStateFixture()
        partial.categories = [captured]
        let childRemoved = CleanupExecutionResult(removed: 1, skipped: 1, removedPaths: [child], reclaimedBytes: 512,
            retainedTargets: [receipt])
        await partial.configureCleanupRetry([captured], family: .clean, mode: .manual,
            installers: nil, maintenanceIDs: [], result: childRemoved, verified: false)
        await partial.reportCleanupResult(childRemoved, permanently: true)
        precondition(partial.popupCount == 0 && !partial.cleanupRetryAvailable
                     && partial.cleanupCompletedCount == 1 && partial.cleanupReclaimedBytes == 512,
                     "A kept exact root conflicted with actual child deletion or invented an ineffective retry")
        var changed = category([root])
        changed.pathIdentities[root] = "replacement-identity"
        let replaced = PageStateFixture()
        await replaced.configureCleanupRetry([changed], family: .clean, mode: .manual,
            installers: nil, maintenanceIDs: [], result: quiet, verified: false)
        precondition(CleanupRetryPolicy.remainingCategories([changed], after: quiet).first?.pathIdentities[root] == "replacement-identity",
                     "A recreated path inherited an old retained receipt")
        for message in ["Skipped protected content: /fixture/p", "Skipped while the path is open: /fixture/p",
                        "Skipped content that requires administrator access or cannot be deleted: /fixture/p",
                        "User cancelled authorization", "Unknown refusal"] {
            let legacy = PageStateFixture()
            await legacy.reportCleanupResult(.init(skipped: 1, messages: [message]), permanently: true)
            precondition(legacy.popupCount == 0 && legacy.taskNotice == nil && legacy.cleanupOutcomeMood == nil
                && legacy.cleanupCompletedCount == 0 && legacy.cleanupReclaimedBytes == 0
                && legacy.cleanupOutcomeDetails.isEmpty && legacy.statusText == "status.ready"
                && legacy.logLines.contains(message),
                "An unresolved skip exposed failure UI, invented deletion, or lost bounded diagnostics")
        }
    }

    private static func testFreshAdministratorPreview() async {
        let allowed = category(["/fixture/admin-allowed"])
        let blocked = category(["/fixture/admin-blocked"])
        let changed = category(["/fixture/admin-changed"])
        let split = category(["/fixture/admin-split"])
        let original = [allowed, blocked, changed, split]
        AdministratorCleanupPlan.proposed = original.flatMap { category in
            category.paths.map { DeletionPlan.Item(record: $0, identity: category.pathIdentities[$0]!) }
        }
        var recreated = changed
        recreated.pathIdentities[changed.paths[0]] = "new-object"
        let splitChild = category([split.paths[0] + "/child"])
        let unrequested = category(["/fixture/worker-added"])
        CleanupScanProcess.inputs = []
        CleanupScanProcess.reply = .init(categories: [allowed, recreated, splitChild, unrequested], succeeded: true,
            administratorRequiredPaths: Set([allowed, recreated, splitChild, unrequested].flatMap(\.paths)))
        let page = PageStateFixture()
        let items = await page.freshAdministratorCleanupItems(original, administratorRequiredPaths: [], family: .clean, mode: .manual)
        precondition(items.map(\.record) == allowed.paths && items.first?.identity == allowed.pathIdentities[allowed.paths[0]],
                     "Fresh prompt expanded scope, approved a split descendant, or rebound a replaced identity")
        precondition(CleanupScanProcess.inputs.count == 1
                     && Set(CleanupScanProcess.inputs[0].flatMap(\.paths)) == Set(original.flatMap(\.paths)),
                     "Fresh preflight must receive exactly the selected proposed roots")
        CleanupScanProcess.reply.succeeded = false
        let unavailable = await page.freshAdministratorCleanupItems(original, administratorRequiredPaths: [], family: .clean, mode: .manual)
        precondition(unavailable.isEmpty, "A failed worker added administrator permission")
        CleanupScanProcess.reply = .init()
        AdministratorCleanupPlan.proposed = [DeletionPlan.Item(record: blocked.paths[0], identity: blocked.pathIdentities[blocked.paths[0]]!)]
        let retained = await page.freshAdministratorCleanupItems([blocked], administratorRequiredPaths: [], family: .clean, mode: .manual)
        precondition(retained.isEmpty, "A root rejected by fresh inspection still requested a password")
        let calls = CleanupScanProcess.inputs.count
        let automatic = await page.freshAdministratorCleanupItems(original, administratorRequiredPaths: [], family: .clean, mode: .automatic)
        precondition(automatic.isEmpty && CleanupScanProcess.inputs.count == calls, "Automatic cleanup requested administrator consent")
        AdministratorCleanupPlan.proposed = []
    }

    private static func testBoundedDiagnostics() async {
        let messages = (0..<100_000).map { "Failed to remove /fixture/\($0): denied" }
        let result = CleanupExecutionResult(failed: 1, messages: messages)
        let page = PageStateFixture()
        await page.reportCleanupResult(result, permanently: true)
        precondition(page.logLines.count <= 400 && page.logPublicationCount <= 3
                     && page.cleanupOutcomeDetails.isEmpty && page.taskNotice == nil && page.popupCount == 0,
                     "A large diagnostic batch performed unbounded main-actor publication/localization")
        precondition(page.logLines.contains(messages.last!) && result.messages == messages,
                     "Bounded UI feedback discarded the original diagnostics or its newest log tail")
        print("100000 cleanup diagnostics: \(page.logPublicationCount) bounded log publications, \(page.cleanupOutcomeDetails.count) visible details")
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
