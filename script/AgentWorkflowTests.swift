import Foundation

// Override the imported Foundation convenience function for this executable.
// Every service below additionally rejects any other home, including the real one.
private let workflowHome = "/nori-agent-workflow-in-memory"
func NSHomeDirectory() -> String { workflowHome }

struct AgentDefinition {
    let id: String
    let name: String
    let documented: Bool
    let owners: [String]
}
enum AgentCatalog {
    static let definitions = [AgentDefinition(id: "fixture", name: "Fixture", documented: true,
        owners: ["FixtureCLI"])]
}

// Use deterministic application names instead of consulting the user's desktop.
struct WorkflowApplication {
    let bundleIdentifier: String?
    let localizedName: String?
    let executableURL: URL?
}
enum NSWorkspace {
    static let shared = WorkflowWorkspace()
}
final class WorkflowWorkspace {
    let runningApplications = [WorkflowApplication(bundleIdentifier: "test.nori.fixture",
        localizedName: "Fixture Desktop", executableURL: URL(fileURLWithPath: workflowHome + "/bin/FixtureHost"))]
}

struct AgentCLIInstallation {
    let id: String
    let agentID: String
    let executablePaths: [String]
    let detail: String
    var name: String { "Fixture" }
    var managedPaths: [String] { executablePaths }
    var onlyUnlinksExecutable = false
    var identity = "original-cli-identity"
}
struct AgentSkill {
    let path: String
    let name: String
    let agentID: String
    let bytes: UInt64
    let identity: String
    let linked: Bool
}
struct AgentMCPServer {
    enum Issue { case unreadableConfig }
    let id: String
    let name: String
    let agentID: String
    let agentName: String
    let configPath: String
    let issues: [Issue]
}
struct AgentMCPInstallation {
    let id: String
    let name: String
    let path: String
    let bytes: UInt64
    let identity: String
}
struct AgentGroupSummary {
    let id: String
    let name: String
    let documented: Bool
    let orphaned: Bool
    let categoryIDs: [UUID]
    let skillIDs: [String]
    let serverIDs: [String]
    let bytes: UInt64
}
struct AgentScanReport {
    var groups: [AgentGroupSummary] = []
    var categories: [CleanupCategory] = []
    var skills: [AgentSkill] = []
    var servers: [AgentMCPServer] = []
    var installations: [AgentMCPInstallation] = []
    var complete = true
}

// New read-only presentation dependencies have their own production service
// tests. This legacy lifecycle fixture injects their results without linking
// application enumeration or storage inspection against the user's computer.
struct AgentStorageFootprint: Equatable, Sendable {
    struct Totals {
        let identifiedDataBytes: UInt64
        let reclaimableBytes: UInt64
        let preservedBytes: UInt64
    }

    static func build(report: AgentScanReport, cli: [AgentCLIInstallation]) -> [String: Self] { [:] }
    static func totals(_ footprints: [Self]) -> Totals {
        .init(identifiedDataBytes: 0, reclaimableBytes: 0, preservedBytes: 0)
    }
}
struct AgentInstallationSize: Sendable {
    let bytes: UInt64
    let complete: Bool
}

enum AgentSoftwareInventory {
    static func applications(home: String) -> [String: [UninstallApp]] {
        precondition(home == workflowHome, "Workflow test attempted to enumerate real applications")
        return [:]
    }
}

enum SoftwareUpdateProcesses {
    struct Scope: Sendable { var roots: [String] = [] }
    struct Process: Sendable { let name: String }
    struct Probe: Sendable {
        let processes: [Process]
        let isComplete: Bool
    }
    static func probe(_ scope: Scope) -> Probe {
        WorkflowFixture.current.nextDataProbe()
    }
    @MainActor static func close(_ scope: Scope, stillCurrent: () -> Bool) async -> Bool {
        preconditionFailure("The legacy Agent fixture must not close real processes")
    }
}

@MainActor
enum AgentDataProcessScope {
    static func make(agentIDs: Set<String>, cli: [AgentCLIInstallation], home: String)
        -> SoftwareUpdateProcesses.Scope {
        precondition(home == workflowHome, "Workflow test attempted to inspect a real process scope")
        return .init()
    }
}

/// A deterministic pause at an asynchronous service boundary. Waiting never
/// blocks the main actor and times out if the tested workflow fails to proceed.
final class WorkflowGate {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var didStart = false
    var started: Bool {
        lock.lock(); defer { lock.unlock() }
        return didStart
    }
    func pause() {
        lock.lock(); didStart = true; lock.unlock()
        precondition(semaphore.wait(timeout: .now() + 5) == .success, "Workflow service was never released")
    }
    func release() { semaphore.signal() }
}

final class WorkflowFixture {
    static var current = WorkflowFixture()
    let cleanupGate = WorkflowGate()
    let cleanupCompletionGate = WorkflowGate()
    let uninstallGate = WorkflowGate()
    let scanGate = WorkflowGate()
    var pauseScan = false
    var pauseAfterCleanupProgress = false
    var report = AgentScanReport()
    var reportForRemovedAgents: AgentScanReport?
    var cli: [AgentCLIInstallation] = []
    var cleanup = AgentCleanupExecutor.Outcome(summary: .init(removed: 1), refused: 0)
    var uninstall = AgentCLIService.Outcome(removed: 1, failed: 0, messages: [])
    var uninstallByID: [String: AgentCLIService.Outcome] = [:]
    var dependencyOwners = ["FixtureHost", "test.nori.fixture"]
    var permitsFileGuardedCaches = false
    private let lock = NSLock()
    private var cleanupRequests = 0
    private var uninstallRequests = 0
    private var preflightRequests = 0
    private var scanRequests = 0
    private var runtime = RunningApplicationSnapshot()
    private var runtimeQueue: [RunningApplicationSnapshot] = []
    private var dataProbeQueue: [SoftwareUpdateProcesses.Probe] = []
    private var receivedCategories: [CleanupCategory] = []
    private var receivedSkills: [AgentSkill] = []
    private var receivedServers: [AgentMCPServer] = []
    private var receivedInstallations: [AgentMCPInstallation] = []
    private var removalID: String?
    private var requestedAgentIDs = Set<String>()
    private var receivedCLIIDs: [String] = []
    private var receivedCLIIdentities: [String] = []

    func recordCleanup(_ categories: [CleanupCategory], skills: [AgentSkill],
                       servers: [AgentMCPServer], installations: [AgentMCPInstallation],
                       removingAgentID: String?) {
        lock.lock(); defer { lock.unlock() }
        cleanupRequests += 1
        receivedCategories = categories
        receivedSkills = skills
        receivedServers = servers
        receivedInstallations = installations
        removalID = removingAgentID
    }
    func recordScan(_ includingAgentIDs: Set<String>) {
        lock.lock(); scanRequests += 1; requestedAgentIDs = includingAgentIDs; lock.unlock()
    }
    func recordUninstall(_ installation: AgentCLIInstallation) {
        lock.lock(); uninstallRequests += 1; receivedCLIIDs.append(installation.id)
        receivedCLIIdentities.append(installation.identity); lock.unlock()
    }
    func recordPreflight() { lock.lock(); preflightRequests += 1; lock.unlock() }
    func setRunning(_ snapshot: RunningApplicationSnapshot) {
        lock.lock(); runtime = snapshot; lock.unlock()
    }
    func setSnapshots(_ snapshots: [RunningApplicationSnapshot]) {
        lock.lock(); runtimeQueue = snapshots; lock.unlock()
    }
    func nextSnapshot() -> RunningApplicationSnapshot {
        lock.lock(); defer { lock.unlock() }
        return runtimeQueue.isEmpty ? runtime : runtimeQueue.removeFirst()
    }
    func setDataProbes(_ probes: [SoftwareUpdateProcesses.Probe]) {
        lock.lock(); dataProbeQueue = probes; lock.unlock()
    }
    func nextDataProbe() -> SoftwareUpdateProcesses.Probe {
        lock.lock(); defer { lock.unlock() }
        return dataProbeQueue.isEmpty ? .init(processes: [], isComplete: true) : dataProbeQueue.removeFirst()
    }
    var cleanupCount: Int { lock.lock(); defer { lock.unlock() }; return cleanupRequests }
    var uninstallCount: Int { lock.lock(); defer { lock.unlock() }; return uninstallRequests }
    var preflightCount: Int { lock.lock(); defer { lock.unlock() }; return preflightRequests }
    var scanCount: Int { lock.lock(); defer { lock.unlock() }; return scanRequests }
    var submittedPaths: [String] { lock.lock(); defer { lock.unlock() }; return receivedCategories.flatMap(\.paths) }
    var submittedSkillPaths: [String] { lock.lock(); defer { lock.unlock() }; return receivedSkills.map(\.path) }
    var submittedSkillIdentities: [String] { lock.lock(); defer { lock.unlock() }; return receivedSkills.map(\.identity) }
    var submittedServerIDs: [String] { lock.lock(); defer { lock.unlock() }; return receivedServers.map(\.id) }
    var submittedInstallationIDs: [String] { lock.lock(); defer { lock.unlock() }; return receivedInstallations.map(\.id) }
    var submittedRemovalID: String? { lock.lock(); defer { lock.unlock() }; return removalID }
    var includedAgentIDs: Set<String> { lock.lock(); defer { lock.unlock() }; return requestedAgentIDs }
    var submittedCLIIDs: [String] { lock.lock(); defer { lock.unlock() }; return receivedCLIIDs }
    var submittedCLIIdentities: [String] { lock.lock(); defer { lock.unlock() }; return receivedCLIIdentities }
}

enum NativeCore {
    struct ApplySummary {
        var removed = 0
        var skipped = 0
        var failed = 0
        var messages: [String] = []
        var removedPaths: Set<String> = []
        var remainingPaths: [String] = []
        var reclaimedBytes: UInt64 = 0
    }
}
enum AgentCleanupExecutor {
    struct Outcome { var summary: NativeCore.ApplySummary; var refused: Int }
    struct BlockingResources {
        var paths = Set<String>()
        var skillPaths = Set<String>()
        var installationIDs = Set<String>()
        var serverIDs = Set<String>()
        var owners: [String] = []
    }
    static func blockingResources(_ categories: [CleanupCategory], skills: [AgentSkill] = [],
                               installations: [AgentMCPInstallation] = [], servers: [AgentMCPServer] = [],
                               running: RunningApplicationSnapshot, home: String,
                               removingAgentID: String? = nil, removingAgentIDs: Set<String> = []) -> BlockingResources {
        precondition(home == workflowHome)
        let fixture = WorkflowFixture.current
        fixture.recordPreflight()
        let owners = fixture.dependencyOwners.filter {
            running.contains(processName: $0) || running.contains(bundleIdentifier: $0)
        }
        guard !running.isComplete || !owners.isEmpty else { return .init() }
        let paths = categories.filter {
            !fixture.permitsFileGuardedCaches || !CleanupRiskPolicy.usesFileActivityGuard($0)
        }.flatMap { $0.paths.filter($0.isPathSelected) }
        return .init(paths: Set(paths), skillPaths: Set(skills.map(\.path)),
            installationIDs: Set(installations.map(\.id)), serverIDs: Set(servers.map(\.id)),
            owners: paths.isEmpty && skills.isEmpty && installations.isEmpty && servers.isEmpty ? [] : owners)
    }
    static func execute(_ categories: [CleanupCategory], running: RunningApplicationSnapshot,
                        home: String, permanent: Bool, skills: [AgentSkill] = [],
                        installations: [AgentMCPInstallation] = [], servers: [AgentMCPServer] = [],
                        removingAgentID: String? = nil, removingAgentIDs: Set<String> = [],
                        onProgress: ((Int, Int, String) -> Void)? = nil) -> Outcome {
        precondition(home == workflowHome && permanent)
        let fixture = WorkflowFixture.current
        fixture.recordCleanup(categories, skills: skills, servers: servers,
                              installations: installations, removingAgentID: removingAgentID ?? removingAgentIDs.sorted().first)
        let paths = categories.flatMap(\.paths) + skills.map(\.path) + installations.map(\.path)
        let total = paths.count + servers.count
        onProgress?(0, total, paths.first ?? servers.first?.configPath ?? "")
        onProgress?(0, total, (paths.first ?? "") + "/nested/actual-cache-file")
        fixture.cleanupGate.pause()
        onProgress?(total, total, "")
        if fixture.pauseAfterCleanupProgress { fixture.cleanupCompletionGate.pause() }
        return fixture.cleanup
    }
}
enum AgentCLIService {
    struct Outcome {
        let removed: Int
        let failed: Int
        let messages: [String]
        var reclaimedBytes: UInt64 = 0
        var retryInstallation: AgentCLIInstallation? = nil
        var requiresRescan = false
        var succeeded: Bool { removed > 0 && failed == 0 }
    }
    static func installations(for agent: AgentDefinition, home: String) -> [AgentCLIInstallation] {
        precondition(home == workflowHome)
        return WorkflowFixture.current.cli.filter { $0.agentID == agent.id }
    }
    static func uninstall(_ installation: AgentCLIInstallation, home: String,
                          running: RunningApplicationSnapshot, permanent: Bool = false,
                          onCurrentFile: ((String) -> Void)? = nil) -> Outcome {
        precondition(home == workflowHome && running.isComplete && permanent)
        let fixture = WorkflowFixture.current
        fixture.recordUninstall(installation)
        onCurrentFile?(installation.executablePaths.first ?? "")
        fixture.uninstallGate.pause()
        return fixture.uninstallByID[installation.id] ?? fixture.uninstall
    }
}
enum AgentInventory {
    static func scan(home: String, control: CleanupScanControl, localize: (String) -> String,
                     includingAgentIDs: Set<String> = [],
                     excludingGlobalCleanupCaches: Bool = false,
                     onlyAgentIDs: Set<String>? = nil) -> AgentScanReport {
        precondition(home == workflowHome, "Workflow test attempted to scan a real home")
        let fixture = WorkflowFixture.current
        fixture.recordScan(includingAgentIDs)
        control.reportDirectory(home + "/.codex/sessions")
        if fixture.pauseScan { fixture.scanGate.pause() }
        if !includingAgentIDs.isEmpty, let report = fixture.reportForRemovedAgents { return report }
        return fixture.report
    }
}
enum CleanupCache {
    static var invalidations = 0
    static func invalidate() { invalidations += 1 }
}
enum NoriMood { case idle, success, attention }
enum NoriCleanupFeedback {
    static func mood(removed: Int, skipped: Int, failed: Int) -> NoriMood {
        if removed > 0 { return .success }
        if skipped > 0 || failed > 0 { return .attention }
        return removed > 0 ? .success : .idle
    }
}
enum NoriHeaderReaction {
    static func mood(removed: Int, skipped: Int, failed: Int) -> NoriMood? {
        NoriCleanupFeedback.mood(removed: removed, skipped: skipped, failed: failed)
    }
}

struct WorkflowUninstallQueue {
    var activeJob: String?
    var pendingJobs: [String] = []
    var hasWork: Bool { activeJob != nil || !pendingJobs.isEmpty }
}

@MainActor
final class AppState {
    struct Confirmation: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let confirmLabel: String
        let onConfirm: () -> Void
    }

    var agentCategories: [CleanupCategory] = []
    var agentGroups: [AgentGroupSummary] = []
    var agentSkills: [AgentSkill] = []
    var agentServers: [AgentMCPServer] = []
    var agentMCPInstallations: [AgentMCPInstallation] = []
    var agentCLIInstallations: [AgentCLIInstallation] = []
    var agentStorageFootprints: [String: AgentStorageFootprint] = [:]
    var agentCLIBodySizes: [String: AgentInstallationSize] = [:]
    var agentApplications: [String: [UninstallApp]] = [:]
    var agentProgramBusyID: String?
    var confirmation: Confirmation?
    let l10n = L10n.shared
    var agentSelectedSkills = Set<String>()
    var agentSelectedServers = Set<String>()
    var agentSelectedMCPInstallations = Set<String>()
    var agentSelectedCLIInstallations = Set<String>()
    var agentScanning = false
    var agentScanCurrentPath = ""
    var agentScanControl: CleanupScanControl?
    var agentApplying = false
    var agentHasScanned = true
    var agentScanComplete = true
    var agentOutcomeMood: NoriMood?
    var agentOutcomeDetails: [String] = []
    var progressHistory: [CleanupTaskProgress] = []
    var agentCleanupProgress: CleanupTaskProgress? {
        didSet { if let agentCleanupProgress { progressHistory.append(agentCleanupProgress) } }
    }
    var agentCelebrating = false
    var agentFeedbackID = 0
    var agentCompletedCount = 0
    var agentReclaimedBytes: UInt64 = 0
    var agentFailureApplications: [String] = []
    var agentRetryAvailable = false
    var agentCleanupHasFeedback = false
    var agentRetryAction: (() -> Void)?
    var agentTaskGeneration = UUID()
    var agentStatus = "Scanned"
    var cleanupScanComplete = true
    var resamples = 0
    var snapshots = 0
    var logs: [String] = []
    var uninstallQueue = WorkflowUninstallQueue()
    var cleanupQueued = false
    var queueStarts = 0
    private var isDispatchingConfirmation = false
    var taskNotice: TaskFeedbackNotice?
    private var taskFeedbackQueue = TaskFeedbackQueue()
    var isBusyExcludingUninstall: Bool { agentScanning || agentApplying || agentProgramBusyID != nil }
    var isBusy: Bool { isBusyExcludingUninstall || uninstallQueue.hasWork || cleanupQueued }
    func log(_ message: String) { logs.append(message) }
    func invalidateAgentStorageFootprints() { agentStorageFootprints = [:] }
    nonisolated static func measureAgentCLIBodies(_ installations: [AgentCLIInstallation],
                                                 control: CleanupScanControl) -> [String: AgentInstallationSize] {
        // Installed-body sizing is a separately tested read-only service. Keep
        // this fixture's lifecycle inputs deterministic without any disk walk.
        installations.reduce(into: [:]) { $0[$1.id] = .init(bytes: 0, complete: true) }
    }
    func noteHeaderReaction(_ mood: NoriMood?) {}
    func resampleAfterMutation() { resamples += 1 }
    func presentTaskNotice(_ notice: TaskFeedbackNotice) {
        taskFeedbackQueue.enqueue(notice)
        taskNotice = taskFeedbackQueue.active
    }
    func presentTaskFailure(message: String = "", details: [String] = [], detailsAreLocalized: Bool = false) {
        presentTaskNotice(TaskFeedbackNotice(
            message: message.isEmpty ? L10n.shared.t("task.failure.message") : message,
            details: details.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
            detailsAreLocalized: detailsAreLocalized))
    }
    func dismissTaskNotice(resumingQueuedTasks: Bool = true) {
        taskFeedbackQueue.dismiss()
        taskNotice = taskFeedbackQueue.active
        if resumingQueuedTasks, taskNotice == nil { startNextUninstallIfPossible() }
    }
    func retryTaskNotice(_ notice: TaskFeedbackNotice) {
        guard taskNotice?.id == notice.id else { return }
        isDispatchingConfirmation = true
        dismissTaskNotice(resumingQueuedTasks: false)
        notice.onRetry?()
        isDispatchingConfirmation = false
        startNextUninstallIfPossible()
    }
    private func startNextUninstallIfPossible() {
        guard !isDispatchingConfirmation, !isBusyExcludingUninstall, !cleanupQueued,
              taskNotice == nil, uninstallQueue.activeJob == nil,
              !uninstallQueue.pendingJobs.isEmpty else { return }
        queueStarts += 1
        uninstallQueue.activeJob = uninstallQueue.pendingJobs.removeFirst()
    }
    func captureRunningApplicationSnapshot() async -> RunningApplicationSnapshot {
        precondition(agentApplying)
        snapshots += 1
        return WorkflowFixture.current.nextSnapshot()
    }
}

@main
struct AgentWorkflowTests {
    @MainActor private static func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() {
            precondition(Date() < deadline, "Agent workflow did not reach expected state")
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @MainActor private static func prepare(liveCache: Bool = false) -> (AppState, WorkflowFixture) {
        let f = WorkflowFixture()
        WorkflowFixture.current = f
        let state = AppState()
        let cache = "\(workflowHome)/cache", untouched = "\(workflowHome)/untouched"
        state.agentCategories = [CleanupCategory(name: "Cache", paths: [cache, untouched], bytes: 2,
            pathBytes: [cache: 1, untouched: 1], pathIdentities: [cache: "original-cache", untouched: "original-untouched"],
            selected: false, risk: .safe)]
        state.agentCategories[0].setPathSelected(cache, selected: true)
        state.agentSkills = [AgentSkill(path: "\(workflowHome)/skill", name: "Skill", agentID: "fixture",
            bytes: 1, identity: "fixture-identity", linked: false)]
        state.agentServers = [AgentMCPServer(id: "server", name: "MCP", agentID: "fixture",
            agentName: "Fixture", configPath: "\(workflowHome)/config", issues: [])]
        state.agentMCPInstallations = [AgentMCPInstallation(id: "installation", name: "MCP body",
            path: "\(workflowHome)/mcp", bytes: 1, identity: "fixture-identity")]
        state.agentCLIInstallations = [AgentCLIInstallation(id: "cli", agentID: "fixture",
            executablePaths: ["\(workflowHome)/bin/agent"], detail: "Fixture CLI")]
        state.agentGroups = [AgentGroupSummary(id: "fixture", name: "Fixture", documented: true,
            orphaned: false, categoryIDs: state.agentCategories.map(\.id),
            skillIDs: ["\(workflowHome)/skill"], serverIDs: ["server"], bytes: 3)]
        state.agentSelectedSkills = ["\(workflowHome)/skill"]
        state.agentSelectedServers = ["server"]
        state.agentSelectedMCPInstallations = ["installation"]
        if liveCache {
            f.permitsFileGuardedCaches = true
            state.agentCategories[0].source = .aiCache
            state.agentCategories[0].disposal = .permanentDelete
            state.agentCategories[0].applyRoute = .aiTrash
            state.agentCategories[0].activityGuard = .aiAgent
            state.agentSelectedSkills = []
            state.agentSelectedServers = []
            state.agentSelectedMCPInstallations = []
        }
        f.report = AgentScanReport(groups: state.agentGroups, categories: state.agentCategories,
            skills: state.agentSkills, servers: state.agentServers, installations: state.agentMCPInstallations)
        f.cli = state.agentCLIInstallations
        return (state, f)
    }

    @MainActor private static func startCLI(_ state: AppState) {
        state.toggleAgentCLIInstallation(state.agentCLIInstallations[0])
        state.applyAgentCleanup()
    }

    @MainActor private static func attention(_ state: AppState, retry: Bool = true) {
        if state.agentCompletedCount > 0 {
            precondition(!state.agentApplying && state.agentOutcomeMood == .success && state.agentCelebrating
                         && state.agentCleanupHasFeedback && state.agentCleanupProgress == nil
                         && state.agentOutcomeDetails.isEmpty && state.agentFailureApplications.isEmpty
                         && state.taskNotice == nil && state.agentRetryAvailable == retry,
                         "Partial deletion must keep a persistent success result and a retry without failure UI")
            return
        }
        precondition(!state.agentApplying && state.agentOutcomeMood == .attention
                     && state.agentCleanupHasFeedback && !state.agentCelebrating
                     && state.agentCleanupProgress == nil)
        precondition(state.taskNotice == nil
                     && (!state.agentOutcomeDetails.isEmpty || !state.agentFailureApplications.isEmpty),
                     "Agent failures must stay actionable on the page without a second modal")
        precondition(state.agentRetryAvailable == retry)
    }

    @MainActor private static func successAndIdle(_ state: AppState, removed: Int) {
        precondition(!state.agentApplying && state.agentOutcomeMood == .success
                     && state.agentCelebrating && state.agentCompletedCount == removed)
        precondition(state.taskNotice == nil && !state.agentRetryAvailable && state.agentCleanupProgress == nil,
                     "Confirmed success must celebrate once without a result popup")
        precondition(!state.agentHasScanned && state.agentCategories.isEmpty && state.agentSkills.isEmpty)
        let feedbackID = state.agentFeedbackID
        state.finishAgentCelebration(feedbackID: feedbackID - 1)
        precondition(state.agentCelebrating, "An obsolete timer cannot dismiss a newer success")
        state.finishAgentCelebration(feedbackID: feedbackID)
        precondition(!state.agentCelebrating && state.agentOutcomeMood == .success,
                     "Completed celebration must leave the idle SVG state without the success summary")
    }

    @MainActor static func main() async throws {
        try await scanKeepsInventoryRecommendations(complete: true)
        try await scanKeepsInventoryRecommendations(complete: false)
        try await cancelledScan(emptyReport: false)
        try await cancelledScan(emptyReport: true)
        try await liveCacheOnly(runtime: RunningApplicationSnapshot(processNames: ["FixtureHost"]))
        try await liveCacheOnly(runtime: .unavailable)
        try await mixedCache(runtimeAvailable: true)
        try await mixedCache(runtimeAvailable: false)
        try await mixedCache(runtimeAvailable: true, retainedCache: true)
        try await mixedCache(runtimeAvailable: true, retainedCache: true, refreshComplete: false)
        try await disappearedPendingResource()
        try await partialReadyCacheRetry()
        try await blockedFrozenRetry()
        try await leavePrerequisiteUnresolved()
        try await queueGuards()
        try await CLIPrerequisitesAndDataRetry()
        try await mixedUninstalledData(runtimeAvailable: true)
        try await mixedUninstalledData(runtimeAvailable: false)
        try await unknownRuntime(cli: false, afterCLI: false)
        try await unknownRuntime(cli: true, afterCLI: false)
        try await unknownRuntime(cli: true, afterCLI: true)
        try await completeCleanup()
        try await incompleteCleanup(kind: "partial")
        try await incompleteCleanup(kind: "failed")
        try await incompleteCleanup(kind: "refused")
        try await failedCLI(noop: false)
        try await failedCLI(noop: true)
        try await completeCLIProgress()
        try await CLIRemovedPathsCountAsCompleted()
        try await orphanedDataRetry()
        try await multipleCLIPhaseRetry()
        try await CLIResumeAfterLauncherRemoval()
        try await CLIChangedInstallationNeedsRescan()
        try await retryFeedbackUsesCurrentAttempt()
        try await associatedDataMutationPreflight(kind: "running")
        try await associatedDataMutationPreflight(kind: "incomplete")
        try await associatedDataMutationPreflight(kind: "idle")
        print("Agent workflow: inline prerequisites/errors, frozen and proven CLI retries, owner/runtime guards, partial refresh, CLI + data progress, per-attempt reclaimed bytes, success without popups passed")
    }

    @MainActor private static func associatedDataMutationPreflight(kind: String) async throws {
        let (state, f) = prepare()
        state.offerAgentAssociatedDataCleanup(agentIDs: ["fixture"])
        try await waitUntil { state.confirmation != nil }
        precondition(f.cleanupCount == 0 && f.uninstallCount == 0 && state.snapshots == 0,
                     "Previewing associated data cannot remove anything")
        let accepted = state.confirmation!
        state.confirmation = nil
        if kind == "running" {
            let running = SoftwareUpdateProcesses.Probe(processes: [.init(name: "node")], isComplete: true)
            f.setDataProbes([running, running])
        } else if kind == "incomplete" {
            f.setDataProbes([.init(processes: [], isComplete: false)])
        } else {
            // Later discovery cannot substitute new paths or identities for
            // the data snapshot that the user has already reviewed.
            f.report.categories = [CleanupCategory(name: "New unreviewed data",
                paths: [workflowHome + "/new-data"], bytes: 4096, selected: true)]
        }
        accepted.onConfirm()
        if kind == "running" {
            try await waitUntil { state.confirmation != nil }
            precondition(state.confirmation?.title == L10n.shared.t("agents.data.running.title")
                         && f.cleanupCount == 0 && f.uninstallCount == 0 && state.snapshots == 0,
                         "A newly started interpreter-hosted CLI requires close consent before any data cleanup")
            state.confirmation = nil
        } else if kind == "incomplete" {
            try await waitUntil { state.taskNotice != nil }
            precondition(f.cleanupCount == 0 && f.uninstallCount == 0 && state.snapshots == 0,
                         "Incomplete fresh process evidence cannot authorize data cleanup")
        } else {
            try await waitUntil { f.cleanupGate.started }
            precondition(!f.submittedPaths.contains(workflowHome + "/new-data")
                         && f.submittedPaths.contains(workflowHome + "/cache")
                         && f.submittedSkillIdentities == ["fixture-identity"],
                         "A fresh idle process probe preserves the confirmed data envelope")
            f.cleanupGate.release()
            try await waitUntil { !state.agentApplying }
        }
    }

    @MainActor private static func scanKeepsInventoryRecommendations(complete: Bool) async throws {
        let (state, f) = prepare()
        let cacheBytes: UInt64 = 422 * 1024
        let checkpointBytes: UInt64 = 2 * 1024 * 1024 * 1024
        let logBytes: UInt64 = 8 * 1024
        let logDatabaseBytes: UInt64 = 16 * 1024
        let temporaryBytes: UInt64 = 32 * 1024
        let recommendedBytes = cacheBytes + checkpointBytes + logBytes + logDatabaseBytes + temporaryBytes
        func category(_ name: String, bytes: UInt64, selected: Bool,
                      risk: CleanupRisk = .warning, source: CleanupSource = .aiSession) -> CleanupCategory {
            let path = "\(workflowHome)/recommendations/\(name)"
            var result = CleanupCategory(name: name, paths: [path], bytes: bytes,
                pathBytes: [path: bytes], pathIdentities: [path: "scan-identity-\(name)"], selected: selected,
                source: source, risk: risk, disposal: risk == .protected ? .none : .permanentDelete,
                applyRoute: .aiTrash, activityGuard: .aiAgent, reasonKey: "agents.reason.review")
            result.activityOwners = ["FixtureHost"]
            return result
        }
        let reported = [
            category("cache", bytes: cacheBytes, selected: true, risk: .safe, source: .aiCache),
            category("checkpoints", bytes: checkpointBytes, selected: true),
            category("logs", bytes: logBytes, selected: true),
            category("logDatabase", bytes: logDatabaseBytes, selected: true),
            category("tempFiles", bytes: temporaryBytes, selected: true, source: .aiCache),
            category("sessions", bytes: 1024 * 1024 * 1024, selected: false),
            category("stateDatabase", bytes: 512 * 1024 * 1024, selected: false),
            category("credentials", bytes: 1024, selected: false, risk: .protected)
        ]
        let recommendedNames: Set<String> = ["cache", "checkpoints", "logs", "logDatabase", "tempFiles"]
        f.report.categories = reported
        f.report.groups = [AgentGroupSummary(id: "fixture", name: "Fixture", documented: true,
            orphaned: false, categoryIDs: reported.map(\.id),
            skillIDs: state.agentSkills.map(\.path), serverIDs: state.agentServers.map(\.id),
            bytes: reported.reduce(0) { $0 + $1.bytes })]
        f.report.complete = complete
        f.pauseScan = true
        // A fresh scan must reset manual resource choices from the prior
        // inventory without replacing the new report's recommended data.
        state.agentSelectedCLIInstallations = ["cli"]
        precondition(!state.agentSelectedSkills.isEmpty && !state.agentSelectedServers.isEmpty
                     && !state.agentSelectedMCPInstallations.isEmpty)
        state.scanAgents()
        precondition(state.agentScanning && !state.agentScanComplete && !state.agentApplying,
                     "The real scan lifecycle must begin in the scanning state")
        try await waitUntil { f.scanGate.started }
        try await waitUntil { state.agentScanCurrentPath == workflowHome + "/.codex/sessions" }
        state.applyAgentCleanup()
        precondition(f.cleanupCount == 0 && f.uninstallCount == 0,
                     "Recommendations cannot execute while their scan is still running")
        f.scanGate.release()
        try await waitUntil { !state.agentScanning }
        precondition(state.agentScanCurrentPath.isEmpty,
                     "Finished Agent scans must clear the current directory")
        precondition(state.agentHasScanned && state.agentScanComplete == complete
                     && state.agentCategories.map(\.id) == reported.map(\.id))
        precondition(!state.agentCLIInstallations.isEmpty && !state.agentSkills.isEmpty
                     && !state.agentServers.isEmpty && !state.agentMCPInstallations.isEmpty)
        precondition(state.agentSelectedCLIInstallations.isEmpty && state.agentSelectedSkills.isEmpty
                     && state.agentSelectedServers.isEmpty && state.agentSelectedMCPInstallations.isEmpty,
                     "CLI, Skill, MCP registrations, and MCP bodies must remain manual selections after scanning")
        precondition(state.agentCategories.filter { ["sessions", "stateDatabase", "credentials"].contains($0.name) }
            .allSatisfy { !$0.selected }, "Sessions, durable databases, and show-only resources cannot be recommended")
        if complete {
            precondition(Set(state.agentCategories.filter(\.selected).map(\.name)) == recommendedNames,
                         "The workflow must preserve inventory recommendations instead of resetting them to Safe only")
            precondition(state.agentSelectedCount == 5 && state.agentSelectedBytes == recommendedBytes,
                         "The selected total must include GB checkpoints together with KB caches, logs, and temporary files")
            precondition(state.agentCategories.filter { recommendedNames.contains($0.name) && $0.name != "cache" }
                .allSatisfy { $0.risk == .warning && $0.activityGuard == .aiAgent && $0.activityOwners == ["FixtureHost"] },
                         "Default selection must retain review risk and owner guards")
            precondition(state.agentOutcomeMood == nil && !state.agentCleanupHasFeedback)
        } else {
            precondition(state.agentCategories.allSatisfy { !$0.selected }
                         && state.agentSelectedCount == 0 && state.agentSelectedBytes == 0,
                         "An incomplete inventory must clear every default recommendation")
            precondition(state.agentOutcomeMood == .attention && state.agentCleanupHasFeedback
                         && state.agentOutcomeDetails == ["log.scanPartial"] && !state.agentRetryAvailable,
                         "Partial scanning must stay reviewable and cannot leave a runnable default selection")
        }
        precondition(f.scanCount == 1 && f.cleanupCount == 0 && f.uninstallCount == 0 && state.taskNotice == nil,
                     "Scan fixtures must never initiate cleanup, uninstall, or popup work")
        print("Agent scan defaults: \(complete ? "complete" : "partial") report preserved the expected selection, bytes, risk, and manual resource state")
    }

    /// A cancelled scan keeps the partial inventory, every recommendation
    /// unselected, no attention mood, and no header reaction. An empty
    /// partial report returns the page to its unscanned empty state.
    @MainActor private static func cancelledScan(emptyReport: Bool) async throws {
        let (state, f) = prepare()
        f.pauseScan = true
        // A CLI-only fixture still synthesizes its agent group in the report,
        // so the empty-state check needs no reported resources at all.
        if emptyReport { f.report = AgentScanReport(); f.cli = [] }
        state.scanAgents()
        try await waitUntil { f.scanGate.started }
        state.cancelAgentScan()
        precondition(state.agentScanning,
                     "Cancel only stops the worker; the scan UI state ends when it returns")
        f.scanGate.release()
        try await waitUntil { !state.agentScanning }
        precondition(state.agentScanControl == nil,
                     "A finished scan must release its cancel handle")
        precondition(state.agentStatus == "agents.status.cancelled"
                     && state.agentOutcomeMood == nil && !state.agentCleanupHasFeedback
                     && state.agentOutcomeDetails.isEmpty && !state.agentScanComplete
                     && state.agentSelectedCount == 0
                     && state.agentCategories.allSatisfy { !$0.selected },
                     "Cancelled scans keep partial results unselected without attention feedback")
        precondition(state.agentHasScanned != emptyReport,
                     "An empty partial report returns to the empty scan state")
        precondition(f.scanCount == 1 && f.cleanupCount == 0 && f.uninstallCount == 0,
                     "Cancelled scans must never run cleanup or uninstall work")
        print("Agent scan cancel: \(emptyReport ? "empty" : "partial") report kept unselected without attention")
    }

    @MainActor private static func liveCacheOnly(runtime: RunningApplicationSnapshot) async throws {
        let (state, f) = prepare(liveCache: true)
        f.setRunning(runtime)
        state.applyAgentCleanup()
        precondition(state.agentApplying && state.agentCleanupProgress?.phase == .preparing)
        try await waitUntil { f.cleanupGate.started }
        try await waitUntil { state.agentCleanupProgress?.currentItem.hasSuffix("nested/actual-cache-file") == true }
        precondition(state.agentHasScanned && f.submittedPaths == ["\(workflowHome)/cache"])
        precondition(state.agentCleanupProgress?.completed == 0 && state.agentCleanupProgress?.total == 1,
                     "Leaf activity may report the actual file but cannot invent completed target units")
        f.cleanupGate.release()
        try await waitUntil { !state.agentApplying }
        successAndIdle(state, removed: 1)
    }

    @MainActor private static func mixedCache(runtimeAvailable: Bool, retainedCache: Bool = false,
                                            refreshComplete: Bool = true) async throws {
        let (state, f) = prepare(liveCache: true)
        state.agentSelectedSkills = ["\(workflowHome)/skill"]
        f.setRunning(runtimeAvailable ? RunningApplicationSnapshot(processNames: ["FixtureHost"]) : .unavailable)
        state.applyAgentCleanup()
        try await waitUntil { f.cleanupGate.started }
        precondition(state.agentApplying && f.submittedPaths == ["\(workflowHome)/cache"]
                     && f.submittedSkillPaths.isEmpty && state.taskNotice == nil)
        if !retainedCache { f.report.categories = [] }
        f.report.complete = refreshComplete
        f.report.skills = [AgentSkill(path: "\(workflowHome)/skill", name: "Skill", agentID: "fixture",
            bytes: 1, identity: "new-inventory-identity", linked: false)]
        f.cleanupGate.release()
        try await waitUntil { !state.agentApplying }
        attention(state)
        if !runtimeAvailable {
            precondition(state.agentOutcomeMood == .success && state.agentOutcomeDetails.isEmpty)
            return
        }
        precondition(state.agentFailureApplications.isEmpty)
        f.setRunning(RunningApplicationSnapshot())
        state.retryFailedAgentCleanup()
        try await waitUntil { f.cleanupCount == 2 }
        precondition(f.submittedSkillIdentities == ["fixture-identity"],
                     "Refresh may prove presence but cannot replace an accepted sensitive identity")
        precondition(f.submittedPaths == (retainedCache ? ["\(workflowHome)/cache"] : []),
                     "Retry may reclaim retained/new cache contents but must exclude absent completed targets")
        f.cleanupGate.release()
        try await waitUntil { !state.agentApplying }
        successAndIdle(state, removed: 1)
    }

    @MainActor private static func disappearedPendingResource() async throws {
        let (state, f) = prepare(liveCache: true)
        state.agentSelectedSkills = ["\(workflowHome)/skill"]
        f.setRunning(RunningApplicationSnapshot(processNames: ["FixtureHost"]))
        state.applyAgentCleanup()
        try await waitUntil { f.cleanupGate.started }
        f.report.skills = []
        f.report.categories = []
        f.cleanupGate.release()
        try await waitUntil { !state.agentApplying }
        precondition(f.cleanupCount == 1)
        successAndIdle(state, removed: 1)
    }

    @MainActor private static func partialReadyCacheRetry() async throws {
        let (state, f) = prepare(liveCache: true)
        state.agentSelectedSkills = ["\(workflowHome)/skill"]
        f.cleanup = .init(summary: .init(removed: 1, skipped: 1, messages: ["Held cache file remains."]), refused: 0)
        f.setRunning(RunningApplicationSnapshot(processNames: ["FixtureHost"]))
        state.applyAgentCleanup()
        try await waitUntil { f.cleanupGate.started }
        f.cleanupGate.release()
        try await waitUntil { !state.agentApplying }
        attention(state)
        precondition(state.agentOutcomeMood == .success && state.agentOutcomeDetails.isEmpty)
        f.setRunning(RunningApplicationSnapshot())
        f.cleanup = .init(summary: .init(removed: 2), refused: 0)
        state.retryFailedAgentCleanup()
        try await waitUntil { f.cleanupCount == 2 }
        precondition(f.submittedPaths == ["\(workflowHome)/cache"] && f.submittedSkillPaths == ["\(workflowHome)/skill"],
                     "Unresolved cache content must remain in the sensitive-resource retry")
        f.cleanupGate.release()
        try await waitUntil { !state.agentApplying }
        successAndIdle(state, removed: 2)
    }

    @MainActor private static func blockedFrozenRetry() async throws {
        let (state, f) = prepare()
        f.setRunning(RunningApplicationSnapshot(bundleIdentifiers: ["test.nori.fixture"], processNames: ["FixtureHost"]))
        state.applyAgentCleanup()
        try await waitUntil { !state.agentApplying }
        attention(state)
        precondition(state.agentFailureApplications == ["Fixture Desktop"] && state.agentSelectedCount == 4)
        precondition(f.cleanupCount == 0 && f.scanCount == 0 && f.uninstallCount == 0 && state.resamples == 0)
        let token = state.agentFeedbackID
        state.retryFailedAgentCleanup()
        try await waitUntil { !state.agentApplying }
        precondition(state.agentStatus == "task.closeApps.changed" && state.agentFeedbackID > token
                     && f.preflightCount == 2 && state.snapshots == 2)
        state.clearAgentSelection()
        state.agentCategories[0].setPathSelected("\(workflowHome)/untouched", selected: true)
        f.setRunning(RunningApplicationSnapshot())
        state.retryFailedAgentCleanup()
        try await waitUntil { f.cleanupGate.started }
        precondition(f.submittedPaths == ["\(workflowHome)/cache"] && f.submittedSkillPaths == ["\(workflowHome)/skill"]
                     && f.submittedServerIDs == ["server"] && f.submittedInstallationIDs == ["installation"],
                     "Changing UI selections cannot substitute a different accepted retry scope")
        f.cleanupGate.release()
        try await waitUntil { !state.agentApplying }
        successAndIdle(state, removed: 1)
    }

    @MainActor private static func leavePrerequisiteUnresolved() async throws {
        let (state, f) = prepare()
        f.setRunning(RunningApplicationSnapshot(processNames: ["FixtureHost"]))
        state.applyAgentCleanup()
        try await waitUntil { !state.agentApplying }
        attention(state)
        precondition(state.agentHasScanned && state.agentSelectedCount == 4 && state.resamples == 0
                     && f.cleanupCount == 0 && f.uninstallCount == 0,
                     "Leaving the prerequisite unresolved must retain selections without a mutation")
    }

    @MainActor private static func queueGuards() async throws {
        for active in [true, false] {
            let (state, f) = prepare()
            f.setRunning(RunningApplicationSnapshot(processNames: ["FixtureHost"]))
            state.applyAgentCleanup()
            try await waitUntil { !state.agentApplying }
            f.setRunning(RunningApplicationSnapshot())
            if active { state.uninstallQueue.activeJob = "active-uninstall" }
            else { state.uninstallQueue.pendingJobs = ["pending-uninstall"] }
            state.retryFailedAgentCleanup()
            if active {
                precondition(!state.agentApplying && state.snapshots == 1 && f.cleanupCount == 0)
                state.uninstallQueue.activeJob = nil
                state.cleanupQueued = true
                state.retryFailedAgentCleanup()
                precondition(!state.agentApplying && state.snapshots == 1 && state.agentRetryAvailable)
            } else {
                try await waitUntil { f.cleanupGate.started }
                precondition(state.uninstallQueue.activeJob == nil && state.uninstallQueue.pendingJobs == ["pending-uninstall"]
                             && state.queueStarts == 0, "Pending work must not steal the accepted inline retry")
                f.cleanupGate.release()
                try await waitUntil { !state.agentApplying }
                successAndIdle(state, removed: 1)
            }
        }
    }

    @MainActor private static func CLIPrerequisitesAndDataRetry() async throws {
        let (state, f) = prepare()
        f.dependencyOwners = []
        f.setRunning(RunningApplicationSnapshot(processNames: ["FixtureCLI"]))
        startCLI(state)
        try await waitUntil { !state.agentApplying }
        attention(state)
        precondition(f.uninstallCount == 0 && f.cleanupCount == 0 && state.agentFailureApplications == ["FixtureCLI"])
        f.dependencyOwners = ["FixtureHost", "test.nori.fixture"]
        f.setSnapshots([RunningApplicationSnapshot(), RunningApplicationSnapshot(processNames: ["FixtureHost"])])
        f.setRunning(RunningApplicationSnapshot(processNames: ["FixtureHost"]))
        state.retryFailedAgentCleanup()
        try await waitUntil { f.uninstallGate.started }
        f.uninstallGate.release()
        try await waitUntil { !state.agentApplying }
        attention(state)
        precondition(f.uninstallCount == 1 && f.cleanupCount == 0 && state.agentSelectedCLIInstallations.isEmpty)
        state.retryFailedAgentCleanup()
        try await waitUntil { !state.agentApplying }
        precondition(state.agentStatus == "task.closeApps.changed" && f.uninstallCount == 1)
        state.clearAgentSelection()
        f.setRunning(RunningApplicationSnapshot())
        state.retryFailedAgentCleanup()
        try await waitUntil { f.cleanupGate.started }
        precondition(Set(f.submittedPaths) == ["\(workflowHome)/cache", "\(workflowHome)/untouched"]
                     && f.submittedRemovalID == "fixture" && f.uninstallCount == 1)
        precondition(state.agentCleanupProgress?.completed == 1 && state.agentCleanupProgress?.total == 6,
                     "Data-only retry must keep the completed CLI in the overall progress")
        f.cleanupGate.release()
        try await waitUntil { !state.agentApplying }
        successAndIdle(state, removed: 1)
    }

    @MainActor private static func mixedUninstalledData(runtimeAvailable: Bool) async throws {
        let (state, f) = prepare(liveCache: true)
        f.setSnapshots([RunningApplicationSnapshot(), runtimeAvailable
            ? RunningApplicationSnapshot(processNames: ["FixtureHost"]) : .unavailable])
        startCLI(state)
        try await waitUntil { f.uninstallGate.started }
        f.uninstallGate.release()
        try await waitUntil { f.cleanupGate.started }
        precondition(Set(f.submittedPaths) == ["\(workflowHome)/cache", "\(workflowHome)/untouched"]
                     && f.submittedSkillPaths.isEmpty && f.submittedServerIDs.isEmpty && f.submittedRemovalID == "fixture")
        f.report.categories = []
        f.report.skills = [AgentSkill(path: "\(workflowHome)/skill", name: "Skill", agentID: "fixture",
            bytes: 1, identity: "new-scan-identity", linked: false)]
        f.cleanupGate.release()
        try await waitUntil { !state.agentApplying }
        attention(state)
        if !runtimeAvailable {
            precondition(state.agentOutcomeMood == .success && state.agentOutcomeDetails.isEmpty)
            return
        }
        f.setRunning(RunningApplicationSnapshot())
        state.retryFailedAgentCleanup()
        try await waitUntil { f.cleanupCount == 2 }
        precondition(f.uninstallCount == 1 && f.submittedPaths.isEmpty && f.submittedSkillIdentities == ["fixture-identity"]
                     && f.submittedServerIDs == ["server"] && f.submittedRemovalID == "fixture")
        f.cleanupGate.release()
        try await waitUntil { !state.agentApplying }
        successAndIdle(state, removed: 1)
    }

    @MainActor private static func unknownRuntime(cli: Bool, afterCLI: Bool) async throws {
        let (state, f) = prepare()
        if afterCLI { f.setSnapshots([RunningApplicationSnapshot(), .unavailable]) }
        else { f.setRunning(.unavailable) }
        if cli { startCLI(state) } else { state.applyAgentCleanup() }
        if afterCLI {
            try await waitUntil { f.uninstallGate.started }
            f.uninstallGate.release()
        }
        try await waitUntil { !state.agentApplying }
        attention(state)
        precondition(state.agentStatus == "task.failure.runtimeUnknown" && state.agentHasScanned && f.cleanupCount == 0)
        precondition(f.uninstallCount == (afterCLI ? 1 : 0))
        if afterCLI {
            precondition(state.agentSelectedCLIInstallations.isEmpty && state.agentSelectedCount == 5,
                         "Unknown runtime after CLI removal cannot discard or implicitly clear the selected data")
        }
    }

    @MainActor private static func completeCleanup() async throws {
        let (state, f) = prepare()
        f.cleanup.summary.removed = 4
        f.cleanup.summary.reclaimedBytes = 8192
        let categoryID = state.agentCategories[0].id
        state.applyAgentCleanup()
        precondition(state.agentApplying && state.agentHasScanned && state.agentCategories[0].id == categoryID)
        try await waitUntil { f.cleanupGate.started }
        precondition(f.submittedPaths == ["\(workflowHome)/cache"] && f.submittedSkillPaths == ["\(workflowHome)/skill"]
                     && f.submittedServerIDs == ["server"] && f.submittedInstallationIDs == ["installation"])
        state.applyAgentCleanup()
        precondition(f.cleanupCount == 1, "Repeated clicks must not duplicate a busy cleanup")
        f.cleanupGate.release()
        try await waitUntil { !state.agentApplying }
        precondition(state.resamples == 1 && f.scanCount == 0)
        successAndIdle(state, removed: 4)
        precondition(state.agentReclaimedBytes == 8192,
                     "Agent cleanup must report worker-confirmed bytes, not selected sizes")
    }

    @MainActor private static func incompleteCleanup(kind: String) async throws {
        let (state, f) = prepare()
        if kind == "partial" {
            f.cleanup = .init(summary: .init(removed: 1, skipped: 1, failed: 1,
                messages: ["Skill is open; quit the owner and retry.", "MCP config could not be written."]), refused: 0)
            f.report.categories = [CleanupCategory(name: "Unrelated", paths: ["\(workflowHome)/untouched"],
                bytes: 1, pathIdentities: [:], selected: true, risk: .safe)]
        } else if kind == "failed" {
            f.cleanup = .init(summary: .init(failed: 4, messages: ["Cleanup permission denied."]), refused: 0)
        } else { f.cleanup = .init(summary: .init(), refused: 4) }
        f.pauseScan = true
        state.applyAgentCleanup()
        try await waitUntil { f.cleanupGate.started }
        f.cleanupGate.release()
        try await waitUntil { f.scanGate.started }
        precondition(state.agentApplying && state.agentHasScanned && state.agentCleanupProgress?.phase == .verifying,
                     "The refreshing inventory must remain part of the cleanup lifecycle")
        f.scanGate.release()
        try await waitUntil { !state.agentApplying }
        attention(state)
        precondition(state.agentSelectedSkills == ["\(workflowHome)/skill"] && state.agentSelectedServers == ["server"])
        if kind == "partial" {
            precondition(!state.agentCategories[0].selected && state.agentOutcomeMood == .success
                         && state.agentOutcomeDetails.isEmpty,
                         "Unrelated fresh caches cannot silently enter the failed selection")
        } else if kind == "failed" { precondition(state.agentSelectedCount == 4 && state.agentOutcomeDetails == f.cleanup.summary.messages) }
        else { precondition(state.agentSelectedCount == 4 && state.agentOutcomeDetails == ["agents.result.noReason"]) }
        precondition(state.agentOutcomeMood == (kind == "partial" ? .success : .attention) && state.agentHasScanned,
                     "The inline result must preserve the current inventory")
    }

    @MainActor private static func failedCLI(noop: Bool) async throws {
        let (state, f) = prepare()
        f.uninstall = noop ? .init(removed: 0, failed: 0, messages: [])
            : .init(removed: 0, failed: 1, messages: ["CLI is running."])
        startCLI(state)
        try await waitUntil { f.uninstallGate.started }
        precondition(state.agentApplying && state.agentHasScanned)
        f.uninstallGate.release()
        try await waitUntil { !state.agentApplying }
        attention(state)
        precondition(f.cleanupCount == 0 && state.agentSelectedCLIInstallations == ["cli"],
                     "A failed or no-op CLI phase cannot authorize removal of its associated data")
        if !noop { precondition(state.agentOutcomeDetails == ["CLI is running."]) }
    }

    @MainActor private static func completeCLIProgress() async throws {
        let (state, f) = prepare()
        f.uninstall.reclaimedBytes = 2048
        f.cleanup.summary.reclaimedBytes = 4096
        startCLI(state)
        precondition(state.agentSelectedCount == 6 && state.agentCleanupProgress?.phase == .preparing)
        try await waitUntil { f.uninstallGate.started }
        try await waitUntil { state.agentCleanupProgress?.currentItem == "\(workflowHome)/bin/agent" }
        precondition(f.cleanupCount == 0 && state.agentCleanupProgress?.completed == 0 && state.agentCleanupProgress?.total == 6)
        f.uninstallGate.release()
        try await waitUntil { f.cleanupGate.started }
        try await waitUntil { state.agentCleanupProgress?.currentItem.hasSuffix("nested/actual-cache-file") == true }
        precondition(state.agentApplying && state.agentHasScanned && state.snapshots == 2
                     && state.agentCleanupProgress?.completed == 1 && state.agentCleanupProgress?.total == 6,
                     "CLI and data must use one real denominator and keep completed CLI progress")
        let updates = state.progressHistory.filter { $0.phase == .cleaning }
        precondition(updates.allSatisfy { $0.total == 6 }
                     && zip(updates, updates.dropFirst()).allSatisfy { $0.completed <= $1.completed })
        precondition(Set(f.submittedPaths) == ["\(workflowHome)/cache", "\(workflowHome)/untouched"]
                     && f.submittedRemovalID == "fixture")
        f.cleanupGate.release()
        try await waitUntil { !state.agentApplying }
        precondition(!state.cleanupScanComplete && state.progressHistory.contains { $0.phase == .verifying })
        precondition(state.agentReclaimedBytes == 6144,
                     "CLI and data cleanup must merge only their confirmed reclaimed allocation")
        successAndIdle(state, removed: 2)
    }

    @MainActor private static func CLIRemovedPathsCountAsCompleted() async throws {
        let (state, f) = prepare()
        let removedRoot = "\(workflowHome)/managed-cli"
        state.agentCLIInstallations = [AgentCLIInstallation(id: "cli", agentID: "fixture",
            executablePaths: [removedRoot], detail: "Managed CLI")]
        state.agentCategories[0].paths += [removedRoot, removedRoot + "/cache"]
        state.agentCategories[0].pathBytes[removedRoot] = 1
        state.agentCategories[0].pathBytes[removedRoot + "/cache"] = 1
        f.cli = state.agentCLIInstallations
        f.report.categories = state.agentCategories
        f.pauseAfterCleanupProgress = true
        startCLI(state)
        precondition(state.agentSelectedCount == 7,
                     "A selected ancestor and its descendant must form one data unit")
        try await waitUntil { f.uninstallGate.started }
        f.uninstallGate.release()
        try await waitUntil { f.cleanupGate.started }
        precondition(!f.submittedPaths.contains { $0 == removedRoot || $0.hasPrefix(removedRoot + "/") },
                     "The data worker must never resubmit paths already removed with the CLI")
        precondition(state.agentCleanupProgress?.completed == 2 && state.agentCleanupProgress?.total == 7,
                     "CLI removal must complete both its CLI unit and the overlapping data unit")
        f.cleanupGate.release()
        try await waitUntil { f.cleanupCompletionGate.started }
        try await waitUntil { state.agentCleanupProgress?.fraction == 1 }
        precondition(state.agentCleanupProgress?.completed == 7 && state.agentCleanupProgress?.total == 7,
                     "All remaining data plus CLI-covered paths must reach real 100% completion")
        f.cleanupCompletionGate.release()
        try await waitUntil { !state.agentApplying }
        successAndIdle(state, removed: 2)
    }

    @MainActor private static func orphanedDataRetry() async throws {
        let (state, f) = prepare()
        f.reportForRemovedAgents = f.report
        f.report = AgentScanReport()
        f.cli = []
        f.cleanup = .init(summary: .init(skipped: 1, failed: 1, messages: ["Agent data could not be removed."]), refused: 0)
        startCLI(state)
        try await waitUntil { f.uninstallGate.started }
        f.uninstallGate.release()
        try await waitUntil { f.cleanupGate.started }
        f.cleanupGate.release()
        try await waitUntil { !state.agentApplying }
        attention(state)
        precondition(f.includedAgentIDs == ["fixture"] && state.agentCLIInstallations.isEmpty
                     && !state.agentGroups.isEmpty && state.agentSelectedCLIInstallations.isEmpty,
                     "Explicit removed Agent scopes must keep orphaned data visible for retry")
        precondition(state.agentOutcomeMood == .success && state.agentOutcomeDetails.isEmpty && !state.cleanupScanComplete)
    }

    @MainActor private static func multipleCLIPhaseRetry() async throws {
        let (state, f) = prepare()
        var second = AgentCLIInstallation(id: "cli-two", agentID: "fixture",
            executablePaths: ["\(workflowHome)/bin/agent-two"], detail: "Second CLI")
        second.identity = "original-second-identity"
        state.agentCLIInstallations.append(second)
        f.cli = state.agentCLIInstallations
        f.uninstallByID["cli-two"] = .init(removed: 0, failed: 1, messages: ["Second CLI failed."])
        state.toggleAgentCLIInstallation(state.agentCLIInstallations[0])
        state.toggleAgentCLIInstallation(second)
        state.applyAgentCleanup()
        try await waitUntil { f.uninstallCount == 1 }
        f.uninstallGate.release()
        try await waitUntil { f.uninstallCount == 2 }
        f.uninstallGate.release()
        try await waitUntil { !state.agentApplying }
        attention(state)
        precondition(f.cleanupCount == 0 && state.agentSelectedCLIInstallations == ["cli-two"])
        var refreshed = second
        refreshed.identity = "new-inventory-identity"
        state.agentCLIInstallations = [refreshed]
        f.cli = [refreshed]
        f.uninstallByID = [:]
        state.retryFailedAgentCleanup()
        try await waitUntil { f.uninstallCount == 3 }
        precondition(f.submittedCLIIDs == ["cli", "cli-two", "cli-two"]
                     && f.submittedCLIIdentities.last == "original-second-identity",
                     "CLI retry must preserve accepted identities and exclude already removed CLI instances")
        f.uninstallGate.release()
        try await waitUntil { f.cleanupGate.started }
        precondition(state.agentCleanupProgress?.completed == 2 && state.agentCleanupProgress?.total == 7)
        f.cleanupGate.release()
        try await waitUntil { !state.agentApplying }
        successAndIdle(state, removed: 2)
    }

    @MainActor private static func CLIResumeAfterLauncherRemoval() async throws {
        let (state, f) = prepare()
        var proven = state.agentCLIInstallations[0]
        proven.identity = "service-proven-partial-installation"
        f.uninstall = .init(removed: 1, failed: 1, messages: ["Launcher was removed; package body remains."],
            reclaimedBytes: 2048, retryInstallation: proven)
        // Launcher-based discovery no longer finds the accepted installation.
        // The uninstaller's proof is the only permitted retry record.
        f.cli = []
        startCLI(state)
        try await waitUntil { f.uninstallCount == 1 }
        f.uninstallGate.release()
        try await waitUntil { !state.agentApplying }
        attention(state)
        precondition(state.agentCLIInstallations.isEmpty && state.agentRetryAvailable
                     && state.agentReclaimedBytes == 2048 && f.cleanupCount == 0,
                     "A partially removed CLI must retain its proven retry while associated data waits")

        f.uninstall = .init(removed: 0, failed: 1, messages: ["Package body is still locked."],
            retryInstallation: proven)
        state.retryFailedAgentCleanup()
        precondition(state.agentCompletedCount == 0 && state.agentReclaimedBytes == 0,
                     "A new click must reset the previous attempt's deletion count and bytes")
        try await waitUntil { f.uninstallCount == 2 }
        precondition(f.submittedCLIIDs == ["cli", "cli"]
                     && f.submittedCLIIdentities == ["original-cli-identity", proven.identity],
                     "Fresh empty inventory cannot discard or rebind the service-proven CLI retry")
        f.uninstallGate.release()
        try await waitUntil { !state.agentApplying }
        attention(state)
        precondition(state.agentOutcomeMood == .attention && state.agentCompletedCount == 0
                     && state.agentReclaimedBytes == 0 && f.cleanupCount == 0,
                     "A failed retry must show its current failure and 0B while data remains untouched")

        f.uninstall = .init(removed: 1, failed: 0, messages: [], reclaimedBytes: 1024)
        f.cleanup = .init(summary: .init(removed: 2, reclaimedBytes: 4096), refused: 0)
        state.retryFailedAgentCleanup()
        try await waitUntil { f.uninstallCount == 3 }
        precondition(f.submittedCLIIdentities.last == proven.identity && f.cleanupCount == 0)
        f.uninstallGate.release()
        try await waitUntil { f.cleanupGate.started }
        precondition(f.cleanupCount == 1 && f.submittedRemovalID == "fixture"
                     && !f.submittedPaths.isEmpty && state.agentHasScanned && state.agentApplying,
                     "Associated data may run only after the same accepted CLI phase succeeds")
        f.cleanupGate.release()
        try await waitUntil { !state.agentApplying }
        successAndIdle(state, removed: 3)
        precondition(state.agentReclaimedBytes == 5120,
                     "One click must aggregate its CLI and data bytes without recounting an earlier partial pass")
    }

    @MainActor private static func CLIChangedInstallationNeedsRescan() async throws {
        let (state, f) = prepare()
        var fresh = state.agentCLIInstallations[0]
        fresh.identity = "unaccepted-replacement-installation"
        f.cli = [fresh]
        f.uninstall = .init(removed: 0, failed: 1, messages: ["Installation identity changed; scan again."],
            requiresRescan: true)
        startCLI(state)
        try await waitUntil { f.uninstallGate.started }
        f.uninstallGate.release()
        try await waitUntil { !state.agentApplying }
        attention(state, retry: false)
        precondition(f.cleanupCount == 0 && f.submittedCLIIdentities == ["original-cli-identity"]
                     && state.agentCompletedCount == 0 && state.agentReclaimedBytes == 0,
                     "An unproved replacement cannot authorize a CLI retry or its associated data cleanup")
        state.retryFailedAgentCleanup()
        precondition(!state.agentApplying && f.uninstallCount == 1,
                     "A required rescan must not leave a hidden retry closure for the changed installation")
    }

    @MainActor private static func retryFeedbackUsesCurrentAttempt() async throws {
        let (state, f) = prepare()
        f.cleanup = .init(summary: .init(removed: 1, skipped: 1, reclaimedBytes: 8192), refused: 0)
        state.applyAgentCleanup()
        try await waitUntil { f.cleanupGate.started }
        f.cleanupGate.release()
        try await waitUntil { !state.agentApplying }
        attention(state)
        precondition(state.agentCompletedCount == 1 && state.agentReclaimedBytes == 8192)

        f.cleanup = .init(summary: .init(failed: 4, messages: ["No pending files could be removed."]), refused: 0)
        state.retryFailedAgentCleanup()
        precondition(state.agentCompletedCount == 0 && state.agentReclaimedBytes == 0)
        try await waitUntil { f.cleanupCount == 2 }
        f.cleanupGate.release()
        try await waitUntil { !state.agentApplying }
        attention(state)
        precondition(state.agentOutcomeMood == .attention && state.agentCompletedCount == 0
                     && state.agentReclaimedBytes == 0 && state.agentOutcomeDetails == f.cleanup.summary.messages,
                     "A fully failed click must not inherit an earlier success, released space, or hidden errors")

        f.cleanup = .init(summary: .init(removed: 2, reclaimedBytes: 2048), refused: 0)
        state.retryFailedAgentCleanup()
        try await waitUntil { f.cleanupCount == 3 }
        f.cleanupGate.release()
        try await waitUntil { !state.agentApplying }
        successAndIdle(state, removed: 2)
        precondition(state.agentReclaimedBytes == 2048,
                     "A successful retry must show only space actually released during its current click")
    }
}
