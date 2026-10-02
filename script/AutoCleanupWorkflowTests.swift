import Foundation

struct AutoCleanupRule: Equatable {
    static let safetyToken = "safe-trash-v4"
    var id = UUID()
    var isEnabled = true
    var isSafetyAuthorized = true
    var directory = "/fixture/cache"
    var retentionDays = 7
    var authorizedRootIdentity: String? = "1:2:3"
    var lastRunAt: Date?
    var lastReclaimedBytes: UInt64 = 0
    var executionCount = 0
    var totalReclaimedBytes: UInt64 = 0
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
struct FixtureBridgeResult {
    var output: String
    var succeeded = true
    var diagnosticOutput: String { output }
}
@MainActor final class MoleEngine {
    static let shared = MoleEngine()
    var calls = 0
    var fail = false
    var input = Data()
    func runBridgeWithStdin(_ script: String, stdinData: Data, timeout: Int) async -> FixtureBridgeResult {
        precondition(script == "bin/app_auto_apply.sh" && timeout == 900)
        calls += 1; input = stdinData
        return .init(output: fail ? "removed=0\nskipped=0\nfailed=1" : "removed=1\nskipped=0\nfailed=0", succeeded: !fail)
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
    var applied: Int { MoleEngine.shared.calls }
    var applyFails: Bool {
        get { MoleEngine.shared.fail }
        set { MoleEngine.shared.fail = newValue }
    }
    var autoCleanupPreviewRuleID: UUID?
    var autoCleanupPreview: AutoCleanupPlan?
    var notifications = 0
    var logs = 0
    let l10n = FixtureL10n()
    func log(_ value: String) { logs += 1 }
    func presentTaskFailure(message: String, details: [String]) { notifications += 1 }
    func protectedAutoCleanupDirectories(excluding id: UUID) -> [String] {
        autoCleanupRules.filter { $0.id != id }.map(\.directory)
    }
    func logFailure(_ result: FixtureBridgeResult, stdoutAlreadyLogged: Bool, notifyingUser: Bool) {}
    func persistAutoCleanupRules() {}
    // PRODUCTION_SCHEDULER
}
@main struct AutoCleanupWorkflowTests {
    @MainActor static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError("FAIL: " + message) }
    }
    @MainActor static func fixture() -> SchedulerFixture {
        AutoCleanupPlanner.reset()
        MoleEngine.shared.calls = 0; MoleEngine.shared.fail = false; MoleEngine.shared.input = Data()
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
        expect(String(data: MoleEngine.shared.input, encoding: .utf8)?.split(separator: "\0").map(String.init)
               == ["/fixture/cache", "1:2:3", "/fixture/cache/old.cache", "1:3:4", "4", "safe-trash-v4"],
               "bridge plan must bind root/candidate identities and safety token")
        s.runScheduledAutoCleanup(); expect(!s.isAutoCleanupScanning, "successful schedule not throttled")
        s = fixture(); AutoCleanupPlanner.empty = true
        s.runScheduledAutoCleanup(force: true); await settle(s)
        expect(s.applied == 0 && s.notifications == 0, "empty plan applied")
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
        for mutation in ["disable", "revoke", "remove", "policy", "nested"] {
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
            default: s.autoCleanupRules.append(AutoCleanupRule(directory: "/fixture/cache/nested"))
            }
            AutoCleanupPlanner.continuation?.resume(); AutoCleanupPlanner.continuation = nil
            await settle(s)
            expect(s.applied == 0, "stale plan applied after " + mutation + " during scan")
        }
        print("PASS: production scheduler disabled/unauthorized rules, FDA, retry coalescing, pending notice, throttle, force, empty/failed scans, quiet failures, concurrent calls and scan-time rule mutations")
    }
}
