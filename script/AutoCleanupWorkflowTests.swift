import Foundation

struct AutoCleanupRoot {
    var directory: String
    var authorizedIdentity: String?
}
enum AutoCleanupPolicy { case sizeLimit, retentionDays }
enum AutoCleanupPlannerError: Error { case rootAuthorizationChanged(String) }
enum AutoCleanupRuleStore {
    static var pausesConsolidatedTasks = false
    static func consolidatedTasks(from rules: [AutoCleanupRule]) -> [AutoCleanupRule] {
        rules.map { rule in
            var grouped = rule
            if pausesConsolidatedTasks { grouped.isEnabled = false }
            return grouped
        }
    }
}
struct AutoCleanupRule: Equatable {
    static let safetyToken = "safe-trash-v4"
    var id = UUID()
    var isEnabled = true
    var isSafetyAuthorized = true
    var directory = "/fixture/cache"
    var sourceName: String?
    var policy = AutoCleanupPolicy.sizeLimit
    var sizeLimitBytes: UInt64 = 1_000_000_000
    var isRegenerable = true
    var retentionDays = 7
    var authorizedRootIdentity: String? = "1:2:3"
    var lastRunAt: Date?
    var lastCheckedAt: Date?
    var lastReclaimedBytes: UInt64 = 0
    var executionCount = 0
    var totalReclaimedBytes: UInt64 = 0
    var extraDirectory: String?
    var roots: [AutoCleanupRoot] {
        [AutoCleanupRoot(directory: directory, authorizedIdentity: authorizedRootIdentity)]
            + (extraDirectory.map { [AutoCleanupRoot(directory: $0, authorizedIdentity: "2:3:4")] } ?? [])
    }
    var directories: [String] { roots.map(\.directory) }

    init(directory: String = "/fixture/cache", sourceName: String? = nil,
         policy: AutoCleanupPolicy = .sizeLimit, sizeLimitBytes: UInt64 = 1_000_000_000,
         retentionDays: Int = 7, isEnabled: Bool = true, isRegenerable: Bool = true,
         lastRunAt: Date? = nil, lastReclaimedBytes: UInt64 = 0) {
        self.directory = directory
        self.sourceName = sourceName
        self.policy = policy
        self.sizeLimitBytes = sizeLimitBytes
        self.retentionDays = retentionDays
        self.isEnabled = isEnabled
        self.isRegenerable = isRegenerable
        self.isSafetyAuthorized = isRegenerable
        self.lastRunAt = lastRunAt
        self.lastReclaimedBytes = lastReclaimedBytes
    }
}
struct AutoCleanupCandidate {
    var path = "/fixture/cache/old.cache"
    var identity = "1:3:4"
    var modifiedAt = Date(timeIntervalSince1970: 4)
    var bytes: UInt64 = 4096
    var automaticEligible = true
}
struct AutoCleanupPlan {
    var root = "/fixture/cache"
    var candidates = [AutoCleanupCandidate()]
}
struct DeletionPlan {
    struct Item: Sendable { let record: String; let identity: String }
}
final class NativeCore: @unchecked Sendable {
    struct ApplySummary: Sendable {
        var removed: Int
        var skipped: Int = 0
        var failed: Int = 0
        var removedPaths = Set<String>()
        var messages: [String] = []
    }
    static let shared = NativeCore()
    var calls = 0
    var fail = false
    var items: [DeletionPlan.Item] = []
    var allowedRoots: [String] = []
    func applyCleanup(items: [DeletionPlan.Item], permanent: Bool, allowedRoots: [String],
                      finalValidation: ((String) -> Bool)?) -> ApplySummary {
        precondition(!permanent, "automatic cleanup must remain recoverable")
        calls += 1; self.items = items; self.allowedRoots = allowedRoots
        if fail { return .init(removed: 0, failed: items.count, messages: ["Fixture cleanup failed"]) }
        let approved = items.filter { finalValidation?($0.record) == true }
        return .init(removed: approved.count, skipped: items.count - approved.count,
                     removedPaths: Set(approved.map(\.record)))
    }
}
enum CleanupCache { static func invalidate() {} }
enum FixtureError: Error { case unavailable }
@MainActor enum AutoCleanupPlanner {
    static var calls = 0
    static var fail = false
    static var empty = false
    static var paused = false
    static var continuation: CheckedContinuation<Void, Never>?
    static func validatedRoot(_ url: URL) throws -> String { url.path }
    nonisolated static func revalidate(_ candidate: AutoCleanupCandidate, for rule: AutoCleanupRule,
                                      protecting directories: [String]) -> Bool {
        candidate.automaticEligible && rule.isSafetyAuthorized
    }
    static func plan(for rule: AutoCleanupRule, protecting: [String]) async throws -> AutoCleanupPlan {
        calls += 1
        if paused { await withCheckedContinuation { continuation = $0 } }
        if fail { throw FixtureError.unavailable }
        return AutoCleanupPlan(candidates: empty ? [] : [AutoCleanupCandidate()])
    }
    static func reset() { calls = 0; fail = false; empty = false; paused = false; continuation = nil }
}
final class FixturePermissions {
    var fullDiskAccessGranted = true
    func refresh() {}
}
struct FixtureL10n {
    func t(_ key: String) -> String { key }
    func tf(_ key: String, _ args: CVarArg...) -> String { key }
}
enum ByteFormat { static func format(_ bytes: UInt64) -> String { String(bytes) } }
@MainActor final class SchedulerFixture {
    static let autoCleanupLastCheckKey = "nori-scheduler-fixture-last-check"
    static let autoCleanupMinimumInterval: TimeInterval = 6 * 60 * 60
    var autoCleanupRules = [AutoCleanupRule()]
    let permissionCenter = FixturePermissions()
    var externallyBusy = false
    var isBusy: Bool { externallyBusy || isAutoCleanupScanning }
    var taskNotice: String?
    var scheduledAutomationRetry: DispatchWorkItem?
    var reportedScheduledPermissionRequirement = false
    var autoCleanupStatus = ""
    var autoCleanupRuleIssues: [UUID: String] = [:]
    var isAutoCleanupScanning = false
    var applied: Int { NativeCore.shared.calls }
    var applyFails: Bool {
        get { NativeCore.shared.fail }
        set { NativeCore.shared.fail = newValue }
    }
    var autoCleanupPreviewRuleID: UUID?
    var autoCleanupPreview: AutoCleanupPlan?
    var notifications = 0
    var logs = 0
    var persistCalls = 0
    let l10n = FixtureL10n()
    func log(_ value: String) { logs += 1 }
    func presentTaskFailure(message: String, details: [String]) { notifications += 1 }
    func presentTaskFailure(details: [String]) { notifications += 1 }
    func protectedAutoCleanupDirectories(excluding id: UUID) -> [String] {
        autoCleanupRules.filter { $0.id != id }.flatMap(\.directories)
    }
    func persistAutoCleanupRules() { persistCalls += 1 }
    // PRODUCTION_SCHEDULER
}
@main struct AutoCleanupWorkflowTests {
    @MainActor static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError("FAIL: " + message) }
    }
    @MainActor static func fixture() -> SchedulerFixture {
        AutoCleanupPlanner.reset()
        AutoCleanupRuleStore.pausesConsolidatedTasks = false
        NativeCore.shared.calls = 0; NativeCore.shared.fail = false; NativeCore.shared.items = []
        UserDefaults.standard.removeObject(forKey: SchedulerFixture.autoCleanupLastCheckKey)
        return SchedulerFixture()
    }
    @MainActor static func settle(_ state: SchedulerFixture) async {
        for _ in 0..<1000 {
            if !state.isAutoCleanupScanning { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        fatalError("scheduler did not finish")
    }
    @MainActor static func main() async {
        defer { UserDefaults.standard.removeObject(forKey: SchedulerFixture.autoCleanupLastCheckKey) }
        var s = fixture()
        s.autoCleanupRules = []
        UserDefaults.standard.set(Date(), forKey: SchedulerFixture.autoCleanupLastCheckKey)
        let created = s.addAutoCleanupRules(forDirectories: ["/fixture/cache"], policy: .sizeLimit,
            sizeLimitBytes: 1_000_000_000, retentionDays: 7, regenerableConfirmed: true,
            sourceName: "Fixture")
        expect(created.added == 1 && s.autoCleanupRules[0].isEnabled
               && s.autoCleanupRules[0].isSafetyAuthorized, "new task did not start enabled")
        await settle(s)
        expect(s.applied == 1 && s.autoCleanupRules[0].executionCount == 1 && s.persistCalls >= 2,
               "creating a task did not immediately check, execute and persist despite the old throttle")
        s = fixture(); s.autoCleanupRules = []
        AutoCleanupRuleStore.pausesConsolidatedTasks = true
        let grouped = s.addAutoCleanupRules(forDirectories: ["/fixture/cache"], policy: .sizeLimit,
            sizeLimitBytes: 1_000_000_000, retentionDays: 7, regenerableConfirmed: true)
        await settle(s)
        expect(grouped.added == 1 && s.autoCleanupRules[0].isEnabled && s.applied == 1,
               "task consolidation silently disabled an explicitly created task")
        s = fixture(); s.autoCleanupRules = []
        let unconfirmed = s.addAutoCleanupRules(forDirectories: ["/fixture/cache"], policy: .sizeLimit,
            sizeLimitBytes: 1_000_000_000, retentionDays: 7, regenerableConfirmed: false)
        expect(unconfirmed.added == 0 && s.autoCleanupRules.isEmpty && AutoCleanupPlanner.calls == 0,
               "an unconfirmed folder became an active task")
        s = fixture(); s.autoCleanupRules[0].isEnabled = false
        let duplicate = s.addAutoCleanupRules(forDirectories: ["/fixture/cache"], policy: .sizeLimit,
            sizeLimitBytes: 1_000_000_000, retentionDays: 7, regenerableConfirmed: true)
        expect(duplicate.added == 0 && duplicate.skipped == 1 && !s.autoCleanupRules[0].isEnabled
               && AutoCleanupPlanner.calls == 0, "duplicate creation resumed a previously paused task")
        s = fixture()
        s.autoCleanupRules[0].isEnabled = false
        s.runScheduledAutoCleanup(force: true)
        expect(AutoCleanupPlanner.calls == 0 && !s.isAutoCleanupScanning, "disabled rule scheduled")
        s = fixture(); s.autoCleanupRules[0].isSafetyAuthorized = false
        s.runScheduledAutoCleanup(force: true)
        expect(!s.isAutoCleanupScanning, "unauthorized rule scheduled")
        s = fixture(); s.permissionCenter.fullDiskAccessGranted = false
        s.runScheduledAutoCleanup(force: true); s.runScheduledAutoCleanup(force: true)
        expect(s.logs == 1 && !s.isAutoCleanupScanning && s.notifications == 0, "permission guard")
        s = fixture(); s.externallyBusy = true
        s.runScheduledAutoCleanup(); let firstRetry = s.scheduledAutomationRetry
        s.runScheduledAutoCleanup()
        expect(firstRetry != nil && firstRetry === s.scheduledAutomationRetry, "busy retry duplicated")
        s.cancelAutomationRetry()
        s = fixture(); s.taskNotice = "pending"
        s.runScheduledAutoCleanup(); expect(s.scheduledAutomationRetry != nil, "notice did not defer")
        s.cancelAutomationRetry()
        s = fixture(); UserDefaults.standard.set(Date(), forKey: SchedulerFixture.autoCleanupLastCheckKey)
        s.runScheduledAutoCleanup(); expect(!s.isAutoCleanupScanning, "six-hour throttle bypassed")
        s.runScheduledAutoCleanup(force: true); await settle(s)
        expect(s.applied == 1, "forced schedule did not run")
        expect(s.autoCleanupRules[0].executionCount == 1 && s.autoCleanupRules[0].lastReclaimedBytes == 4096,
               "confirmed execution statistics lost")
        expect(NativeCore.shared.items.map(\.record) == ["/fixture/cache/old.cache"]
               && NativeCore.shared.items.map(\.identity) == ["1:3:4"]
               && NativeCore.shared.allowedRoots == ["/fixture/cache"],
               "native plan must bind reviewed candidate identities and authorized roots")
        s = fixture()
        s.autoCleanupRules[0].extraDirectory = "/fixture/other-cache"
        var combinedPlan = AutoCleanupPlan()
        var secondCandidate = AutoCleanupCandidate()
        secondCandidate.path = "/fixture/other-cache/second.cache"
        combinedPlan.candidates.append(secondCandidate)
        _ = await s.applyAutoCleanup(rule: s.autoCleanupRules[0], plan: combinedPlan)
        expect(s.applied == 1 && s.autoCleanupRules[0].executionCount == 1,
               "multi-root task executed or recorded multiple times")
        expect(NativeCore.shared.items.count == 2
               && NativeCore.shared.allowedRoots == ["/fixture/cache", "/fixture/other-cache"],
               "multi-root native batch lost an authorized scope")
        s = fixture()
        var outsidePlan = AutoCleanupPlan()
        outsidePlan.candidates[0].path = "/fixture/unapproved/old.cache"
        let rejected = await s.applyAutoCleanup(rule: s.autoCleanupRules[0], plan: outsidePlan)
        expect(rejected.failed > 0 && s.applied == 0,
               "candidate outside the task scope crossed the apply boundary")
        s = fixture()
        s.runScheduledAutoCleanup(force: true); await settle(s)
        s.runScheduledAutoCleanup(); expect(!s.isAutoCleanupScanning, "successful schedule not throttled")
        s = fixture(); AutoCleanupPlanner.empty = true
        s.runScheduledAutoCleanup(force: true); await settle(s)
        expect(s.applied == 0 && s.notifications == 0, "empty plan applied")
        expect(s.autoCleanupRules[0].lastCheckedAt != nil && s.autoCleanupRules[0].executionCount == 0
               && s.autoCleanupRules[0].lastRunAt == nil,
               "an empty scheduled check looked unexecuted or claimed a cleanup")
        s = fixture(); AutoCleanupPlanner.fail = true
        s.runScheduledAutoCleanup(force: true); await settle(s)
        expect(s.applied == 0 && s.notifications == 1 && !s.autoCleanupRuleIssues.isEmpty, "scan failure lost")
        expect(UserDefaults.standard.object(forKey: SchedulerFixture.autoCleanupLastCheckKey) == nil, "failure suppresses retry")
        s = fixture(); s.applyFails = true
        s.runScheduledAutoCleanup(force: true, notifyingUser: false); await settle(s)
        expect(s.notifications == 0 && !s.autoCleanupRuleIssues.isEmpty, "quiet apply failure lost")
        expect(s.autoCleanupRules[0].lastReclaimedBytes == 0, "failed deletion claimed reclaimed bytes")
        s = fixture()
        let reviewed = s.autoCleanupRules[0]
        s.autoCleanupRules[0].retentionDays = 30
        let stale = await s.applyAutoCleanup(rule: reviewed, plan: AutoCleanupPlan())
        expect(stale.failed > 0 && s.applied == 0, "edited rule crossed final apply boundary")
        s = fixture(); var unsafePlan = AutoCleanupPlan()
        unsafePlan.candidates[0].automaticEligible = false
        let unsafe = await s.applyAutoCleanup(rule: s.autoCleanupRules[0], plan: unsafePlan)
        expect(unsafe.failed > 0 && s.applied == 0, "unsafe candidate crossed apply boundary")
        s = fixture(); s.autoCleanupPreviewRuleID = s.autoCleanupRules[0].id
        s.autoCleanupPreview = AutoCleanupPlan()
        _ = await s.applyAutoCleanup(rule: s.autoCleanupRules[0], plan: AutoCleanupPlan())
        expect(s.autoCleanupPreview == nil && s.autoCleanupPreviewRuleID == nil, "obsolete preview retained after cleanup")
        for mutation in ["disable", "revoke", "remove", "policy", "scope", "nested"] {
            s = fixture(); AutoCleanupPlanner.paused = true
            s.runScheduledAutoCleanup(force: true)
            for _ in 0..<1000 {
                if AutoCleanupPlanner.continuation != nil { break }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            expect(AutoCleanupPlanner.continuation != nil, "scan never paused")
            s.runScheduledAutoCleanup(force: true)
            expect(AutoCleanupPlanner.calls == 1, "concurrent scheduler scan")
            s.cancelAutomationRetry()
            switch mutation {
            case "disable": s.autoCleanupRules[0].isEnabled = false
            case "revoke": s.autoCleanupRules[0].isSafetyAuthorized = false
            case "remove": s.autoCleanupRules.removeAll()
            case "policy": s.autoCleanupRules[0].retentionDays = 30
            case "scope": s.autoCleanupRules[0].extraDirectory = "/fixture/other-cache"
            default: s.autoCleanupRules.append(AutoCleanupRule(directory: "/fixture/cache/nested"))
            }
            AutoCleanupPlanner.continuation?.resume(); AutoCleanupPlanner.continuation = nil
            await settle(s)
            expect(s.applied == 0, "stale plan applied after " + mutation + " during scan")
        }
        print("PASS: production scheduler disabled/unauthorized rules, FDA, retry coalescing, pending notice, throttle, force, empty/failed scans, quiet failures, concurrent calls and scan-time rule mutations")
    }
}
