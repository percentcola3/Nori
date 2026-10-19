import Foundation

// Production preference writes stay in memory in this workflow executable.
final class UserDefaults: @unchecked Sendable {
    static let standard = UserDefaults()
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func data(forKey key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }
    func set(_ value: Any?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value as? Data
    }
}

enum AgentCodexFeatureEditor {
    enum State: Equatable, Sendable { case enabled, disabled, unknown }
    static func setThreadStoreCompression(_ enabled: Bool, home: String) -> Result<Void, Error> {
        .success(())
    }
}

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
    var codexThreadStoreCompression: AgentCodexFeatureEditor.State? = nil
    var complete = true
}

// New read-only presentation dependencies have their own production service
// tests. This legacy lifecycle fixture injects their results without linking
// application enumeration or storage inspection against the user's computer.
private final class AgentPresentationProbe: @unchecked Sendable {
    static let shared = AgentPresentationProbe()
    private let lock = NSLock()
    private var builds = 0
    func builtStorageTotals() { lock.lock(); builds += 1; lock.unlock() }
    var storageTotalBuilds: Int { lock.lock(); defer { lock.unlock() }; return builds }
}

struct AgentStorageFootprint: Equatable, Sendable {
    struct Totals: Sendable {
        let identifiedDataBytes: UInt64
        let reclaimableBytes: UInt64
        let preservedBytes: UInt64
    }

    static func build(report: AgentScanReport, cli: [AgentCLIInstallation]) -> [String: Self] { [:] }
    static func totals(_ footprints: [Self]) -> Totals {
        AgentPresentationProbe.shared.builtStorageTotals()
        return .init(identifiedDataBytes: 0, reclaimableBytes: 0, preservedBytes: 0)
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
    var removalPlan: AgentRemovalService.Plan?
    var remainingRemovalPlan: AgentRemovalService.Plan?
    var removalItems: [DeletionPlan.Item] = []
    var removalRequests = 0
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
        var retainedPaths: [String] = []
        var reclaimedBytes: UInt64 = 0
    }
}

/// The complete-removal UI is exercised without linking its filesystem sink.
/// Plans are immutable, and a successful fixture execution removes its roots
/// from the subsequent verification plan.
enum AgentRemovalService {
    struct Plan: @unchecked Sendable {
        let agentIDs: Set<String>
        let items: [DeletionPlan.Item]
        let retainedPaths: [String]
        let messages: [String]
    }
    static func plan(agentIDs: Set<String>, home: String) -> Plan {
        precondition(home == workflowHome)
        let fixture = WorkflowFixture.current
        if fixture.removalRequests > 0 {
            return fixture.remainingRemovalPlan ?? .init(agentIDs: agentIDs, items: [], retainedPaths: [], messages: [])
        }
        if let plan = fixture.removalPlan { return plan }
        let report = fixture.reportForRemovedAgents ?? fixture.report
        let items = report.categories.flatMap { category in
            category.paths.map { DeletionPlan.Item(record: $0, identity: category.pathIdentities[$0] ?? "fixture-identity") }
        } + report.skills.map { DeletionPlan.Item(record: $0.path, identity: $0.identity) }
        return .init(agentIDs: agentIDs, items: items, retainedPaths: [], messages: [])
    }
    static func execute(_ plan: Plan, running: RunningApplicationSnapshot, home: String) -> NativeCore.ApplySummary {
        precondition(home == workflowHome)
        let fixture = WorkflowFixture.current
        fixture.removalRequests += 1
        fixture.removalItems = plan.items
        fixture.cleanupGate.pause()
        return fixture.cleanup.summary
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
                        home: String, trashHandler: ((URL) throws -> Void)? = nil,
                        skills: [AgentSkill] = [],
                        installations: [AgentMCPInstallation] = [], servers: [AgentMCPServer] = [],
                        removingAgentID: String? = nil, removingAgentIDs: Set<String> = [],
                        onProgress: ((Int, Int, String) -> Void)? = nil) -> Outcome {
        precondition(home == workflowHome)
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
        precondition(home == workflowHome && running.isComplete && !permanent,
                     "Native CLI removal must keep the reversible Trash route")
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
                     onlyAgentIDs: Set<String>? = nil,
                     retention: AgentRetentionPreferences = .load(),
                     now: Date = Date()) -> AgentScanReport {
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

    var agentCategories: [CleanupCategory] = [] {
        didSet { agentSelectionSummaryCache = nil }
    }
    var agentRetentionPreferences = AgentRetentionPreferences()
    var agentCodexThreadStoreCompression: AgentCodexFeatureEditor.State?
    var agentGroups: [AgentGroupSummary] = [] {
        didSet { agentSelectionSummaryCache = nil; agentStorageTotalsCache = [:] }
    }
    var agentSkills: [AgentSkill] = [] {
        didSet { agentSelectionSummaryCache = nil }
    }
    var agentServers: [AgentMCPServer] = [] {
        didSet { agentSelectionSummaryCache = nil }
    }
    var agentMCPInstallations: [AgentMCPInstallation] = [] {
        didSet { agentSelectionSummaryCache = nil }
    }
    var agentCLIInstallations: [AgentCLIInstallation] = [] {
        didSet { agentSelectionSummaryCache = nil }
    }
    var agentStorageFootprints: [String: AgentStorageFootprint] = [:] {
        didSet { agentStorageTotalsCache = [:] }
    }
    var agentSelectionSummaryCache: (count: Int, bytes: UInt64)?
    var agentSelectionPathIndex = DeletionPlan.PathCoverageIndex()
    var agentStorageTotalsCache: [String: AgentStorageFootprint.Totals] = [:]
    var agentCLIBodySizes: [String: AgentInstallationSize] = [:]
    var agentApplications: [String: [UninstallApp]] = [:]
    var agentProgramBusyID: String?
    var confirmation: Confirmation?
    let l10n = L10n.shared
    var agentSelectedSkills = Set<String>() {
        didSet { agentSelectionSummaryCache = nil }
    }
    var agentSelectedSkillRegistrations = Set<String>()
    var agentSelectedServers = Set<String>() {
        didSet { agentSelectionSummaryCache = nil }
    }
    var agentSelectedMCPInstallations = Set<String>() {
        didSet { agentSelectionSummaryCache = nil }
    }
    var agentSelectedCLIInstallations = Set<String>() {
        didSet { agentSelectionSummaryCache = nil }
    }
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
    var externallyBusy = false
    var isCleanupMutationBusy = false
    var commandLineToolBusyID: String?
    var softwareUpdatingID: String?
    var queueStarts = 0
    private var isDispatchingConfirmation = false
    var taskNotice: TaskFeedbackNotice?
    private var taskFeedbackQueue = TaskFeedbackQueue()
    var isAgentTaskBusy: Bool { agentScanning || agentApplying || agentProgramBusyID != nil }
    var isBusyExcludingUninstall: Bool { isAgentTaskBusy || externallyBusy }
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
        precondition(!state.agentApplying && !state.agentCelebrating
                     && state.agentCleanupHasFeedback && state.agentCleanupProgress == nil)
        precondition(state.agentOutcomeMood == (state.agentCompletedCount > 0 ? .success : .attention))
        guard let notice = state.taskNotice else { preconditionFailure("Incomplete Agent tasks need a modal") }
        precondition(!notice.message.isEmpty && notice.onRetry != nil,
                     "The result dialog must retain a recovery action without expanding the inventory")
        precondition(state.agentRetryAvailable == retry)
        // Subsequent fixture actions model a user dismissing the result first.
        state.dismissTaskNotice()
    }

    @MainActor private static func retryAgentRecovery(_ state: AppState) {
        if let notice = state.taskNotice {
            state.retryTaskNotice(notice)
        } else {
            state.retryFailedAgentCleanup()
        }
    }

    @MainActor private static func successAndRefreshed(_ state: AppState, removed: Int, line: UInt = #line) {
        precondition(!state.agentApplying && state.agentOutcomeMood == .success
                     && !state.agentCelebrating && state.agentCompletedCount == removed)
        precondition((state.taskNotice == nil) == WorkflowFixture.current.report.complete
                     && !state.agentRetryAvailable && state.agentCleanupProgress == nil,
                     "Confirmed success at line \(line) must remain on the current page without a result popup: notice=\(String(describing: state.taskNotice?.message)), removed=\(removed), retry=\(state.agentRetryAvailable), scanComplete=\(state.agentScanComplete), progress=\(String(describing: state.agentCleanupProgress))")
        precondition(state.agentHasScanned && state.agentScanComplete == WorkflowFixture.current.report.complete
                     && WorkflowFixture.current.scanCount > 0 && state.agentSelectedCount == 0,
                     "Cleanup must refresh the inventory and clear selection before finishing")
        if state.taskNotice != nil { state.dismissTaskNotice() }
    }

    @MainActor static func main() async throws {
        if ProcessInfo.processInfo.environment["NORI_AGENT_SELECTION_BENCHMARK"] == "1" {
            benchmarkSelectionChanges()
            return
        }
        perAgentRetentionStaysScoped()
        presentationSummariesStayCurrent()
        cachedPathCoverageMatchesDeletionRules()
        largeInventoryPresentationReusesSummaries()
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
        try await manuallySelectedOrphanData()
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
        try await associatedDataMutationGuards()
        try await completeRemovalIncludesProtectedData()
        try await completeRemovalReportsRetainedData()
        try await completeRemovalEmptyPlanSucceedsWithoutFailurePopup()
        try await completeRemovalReportsPartialResult()
        try await bulkCLIOffersSeparateCompleteRemoval()
        try await bulkLinkDoesNotOfferCompleteRemoval()
        print("Agent workflow: modal prerequisites/errors, frozen and proven CLI retries, owner/runtime guards, partial refresh, CLI + data progress, per-attempt reclaimed bytes, success without popups passed")
    }

    @MainActor private static func perAgentRetentionStaysScoped() {
        let state = AppState()
        let old = Date().addingTimeInterval(-100 * 24 * 3600)
        let recent = Date().addingTimeInterval(-10 * 24 * 3600)
        let future = Date().addingTimeInterval(3600)
        func history(_ name: String) -> CleanupCategory {
            CleanupCategory(name: name, paths: [name + "/old", name + "/recent", name + "/future"],
                bytes: 3, pathIdentities: [:], retentionClass: .conversations,
                pathActivity: [name + "/old": old, name + "/recent": recent, name + "/future": future],
                selected: false, risk: .warning, retention: 90 * 24 * 3600)
                .selectingPaths([name + "/old"])
        }
        let codex = history("codex"), cursor = history("cursor")
        let orphan = history("orphan").selectingPaths([])
        let worktrees = CleanupCategory(name: "worktrees", paths: ["clean", "dirty"], bytes: 2,
            pathIdentities: [:], retentionClass: .artifacts, pathActivity: ["clean": recent, "dirty": old],
            pathRetentionBlocked: ["dirty"], selected: false, risk: .warning,
            retention: 90 * 24 * 3600, reasonKey: "agents.reason.worktree")
        func group(_ id: String, categories: [CleanupCategory], orphaned: Bool = false) -> AgentGroupSummary {
            .init(id: id, name: id, documented: true, orphaned: orphaned,
                categoryIDs: categories.map(\.id), skillIDs: [], serverIDs: [], bytes: 0)
        }
        state.agentCategories = [codex, cursor, worktrees, orphan]
        state.agentGroups = [group("codex", categories: [codex, worktrees]),
                             group("cursor", categories: [cursor]),
                             group("orphan", categories: [orphan], orphaned: true)]
        precondition(state.agentSelectedCount == 2)
        state.setAgentRetention(.days(7), for: .conversations, agentID: "codex")
        precondition(state.agentCategories[0].isPathSelected("codex/old")
                     && state.agentCategories[0].isPathSelected("codex/recent")
                     && !state.agentCategories[0].isPathSelected("codex/future")
                     && state.agentCategories[0].retention == 7 * 24 * 3600
                     && state.agentCategories[1] == cursor && state.agentCategories[2] == worktrees
                     && state.agentCategories[3] == orphan && state.agentSelectedCount == 3,
                     "Per-Agent policy changed another Agent/class or lost selection cache invalidation")
        state.setAgentRetention(.never, for: .conversations, agentID: "codex")
        precondition(state.agentCategories[0].selectedPathCount == 0
                     && state.agentCategories[0].retention == 0 && state.agentCategories[1] == cursor,
                     "Never-clean affected another Agent's history")
        state.setAgentRetention(.days(7), for: .artifacts, agentID: "codex")
        precondition(state.agentCategories[2].isPathSelected("clean")
                     && !state.agentCategories[2].isPathSelected("dirty"),
                     "Policy change bypassed the scanned worktree guard")
        state.setAgentRetention(.days(7), for: .conversations, agentID: "orphan")
        precondition(state.agentCategories[3].selectedPathCount == 0
                     && state.agentCategories[3].retention == 7 * 24 * 3600,
                     "Policy change automatically selected orphaned data")
        let saved = AgentRetentionPreferences.load()
        precondition(saved == state.agentRetentionPreferences
                     && saved.rule(for: .conversations, agentID: "codex") == .never
                     && saved.rule(for: .conversations, agentID: "cursor") == .days(90)
                     && saved.rule(for: .artifacts, agentID: "codex") == .days(7),
                     "Per-Agent changes were not persisted independently")
        let beforeBusy = state.agentCategories
        state.agentScanning = true
        state.setAgentRetention(.days(365), for: .conversations, agentID: "codex")
        precondition(state.agentCategories == beforeBusy && state.agentRetentionPreferences == saved,
                     "Policy changed during a scan and invalidated its frozen preferences")
    }

    @MainActor private static func presentationSummariesStayCurrent() {
        let (state, _) = prepare()
        func expect(_ count: Int, _ bytes: UInt64) {
            precondition(state.agentSelectedCount == count && state.agentSelectedBytes == bytes,
                         "Selection presentation became stale after changing a dependency")
        }
        expect(4, 3)
        state.agentSelectedSkills = []
        expect(3, 2)
        state.agentSkills[0] = AgentSkill(path: "\(workflowHome)/skill", name: "Skill", agentID: "fixture",
            bytes: 9, identity: "fixture-identity", linked: false)
        state.agentSelectedSkills = [state.agentSkills[0].path]
        expect(4, 11)
        state.agentSelectedServers = []
        expect(3, 11)
        state.agentSelectedServers = ["server"]
        state.agentServers = []
        expect(3, 11)
        state.agentSelectedMCPInstallations = []
        expect(2, 10)
        state.agentSelectedMCPInstallations = ["installation"]
        state.agentMCPInstallations[0] = AgentMCPInstallation(id: "installation", name: "MCP body",
            path: "\(workflowHome)/mcp", bytes: 7, identity: "fixture-identity")
        expect(3, 17)
        state.agentCategories[0].setPathSelected("\(workflowHome)/untouched", selected: true)
        expect(4, 18)
        state.agentSelectedCLIInstallations = ["cli"]
        expect(5, 18)
        // CLI scope supplies categories and skills even when manual checks are empty.
        state.agentCategories[0].selected = false
        state.agentSelectedSkills = []
        expect(5, 18)
        state.agentGroups = []
        expect(3, 16)
        state.agentCLIInstallations = []
        expect(1, 7)
        state.agentMCPInstallations = []
        expect(0, 0)
    }

    @MainActor private static func benchmarkSelectionChanges() {
        let (state, _) = prepare()
        let paths = (0..<50_000).map {
            "\(workflowHome)/selection-performance/Library/Application Support/Agent/cache/storage/session/\($0)/download.bin"
        }
        state.agentCategories = [CleanupCategory(name: "Downloads", paths: paths, bytes: 50_000,
            pathBytes: Dictionary(uniqueKeysWithValues: paths.map { ($0, UInt64(1)) }),
            pathIdentities: Dictionary(uniqueKeysWithValues: paths.map { ($0, "fixture") }),
            pathNotes: Dictionary(uniqueKeysWithValues: paths.map { ($0, "fixture note") }),
            selected: false, risk: .safe)]
        let group = AgentGroupSummary(id: "fixture", name: "Fixture", documented: true, orphaned: false,
                                      categoryIDs: [state.agentCategories[0].id], skillIDs: [], serverIDs: [], bytes: 50_001)
        state.agentGroups = [group]
        _ = state.agentSelectedCount
        precondition(state.agentGroupBytes(group) == 50_001)
        for turn in 0..<4 {
            let start = ProcessInfo.processInfo.systemUptime
            state.agentCategories[0].selected.toggle()
            let count = state.agentSelectedCount
            let bytes = state.agentSelectedBytes
            precondition(state.agentGroupBytes(group) == 50_001,
                         "Group storage must stay independent of checkbox selection")
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            precondition(count == (turn % 2 == 0 ? 50_003 : 3) && bytes == (turn % 2 == 0 ? 50_002 : 2))
            precondition(elapsed < 0.25, "Selection changes must not block feedback for a 50,000-path inventory")
            print(String(format: "Selection change %d (50,000 paths): %.3f ms", turn, elapsed * 1000))
        }
    }

    private static func cachedPathCoverageMatchesDeletionRules() {
        var index = DeletionPlan.PathCoverageIndex()
        let cases = [
            ["/fixture/cache/a", "/fixture/cache", "/fixture/cache/b"],
            ["/fixture//cache/", "/fixture/cache", "/fixture/cache/item"],
            ["/fixture/cache/../other", "/fixture/other", "relative/path"],
            ["/", "/fixture/a", "/fixture/ab", "/fixture/a/item"],
            ["/fixture/cache\nunsafe", "/fixture/cache\nunsafe", "/fixture/cache/safe"],
            ["/fixture/é", "/fixture/e\u{301}/child", "/fixture/x/\u{301}child", "/fixture/x"],
        ]
        index.prepare(sources: cases)
        for paths in cases {
            for selection in [paths, Array(paths.reversed()), Array(paths.dropFirst()), Array(paths.prefix(1)), []] {
                precondition(index.nonOverlappingPaths(selection) == DeletionPlan.nonOverlappingPaths(selection),
                             "Cached presentation must preserve normalization, unsafe-path, duplicate and parent coverage rules")
            }
        }
        let replacement = ["/fixture/new/root/child", "/fixture/new/root"]
        index.prepare(sources: [replacement])
        precondition(index.nonOverlappingPaths(replacement) == ["/fixture/new/root"],
                     "Changed inventory must build relationships for new paths")
        var category = CleanupCategory(name: "Fixture", paths: ["/fixture/a", "/fixture/b"], bytes: 2,
            pathBytes: ["/fixture/a": 1, "/fixture/b": 1], selected: false, risk: .safe)
        var reviewed = category
        reviewed.selected = true
        category.paths = ["/fixture/b", "/fixture/c"]
        category.updateSelection(from: reviewed)
        precondition(category.selectedPaths == ["/fixture/b"], "A replaced inventory must not inherit unknown selected paths")
        category.risk = .protected
        category.updateSelection(from: reviewed)
        precondition(!category.selected, "Row updates must preserve protected-data guards")
        print("Cached selection path coverage: parent/alias/unsafe/Unicode/replaced-inventory and protected-selection rules passed")
    }

    @MainActor private static func largeInventoryPresentationReusesSummaries() {
        let (state, _) = prepare()
        let paths = (0..<30_000).map { "\(workflowHome)/large-inventory/\($0)/history.json" }
        state.agentCategories = [CleanupCategory(name: "Large fixture", paths: paths, bytes: 30_000,
            pathBytes: Dictionary(uniqueKeysWithValues: paths.map { ($0, UInt64(1)) }),
            pathIdentities: [:], selected: true, risk: .safe)]
        state.agentStorageFootprints = ["fixture": AgentStorageFootprint()]
        precondition(state.agentSelectedCount == 30_003 && state.agentSelectedBytes == 30_002)
        let probe = AgentPresentationProbe.shared
        let before = probe.storageTotalBuilds
        precondition(state.agentStorageTotals() != nil && state.agentStorageTotals(for: "fixture") != nil)
        let start = ProcessInfo.processInfo.systemUptime
        for tick in 0..<100 {
            state.agentStatus = "Unrelated update \(tick)"
            precondition(state.agentSelectedCount == 30_003 && state.agentSelectedBytes == 30_002)
            precondition(state.agentStorageTotals() != nil && state.agentStorageTotals(for: "fixture") != nil)
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        precondition(elapsed < 0.25, "Repeated presentation reads must not traverse the 30,000-path inventory")
        precondition(probe.storageTotalBuilds == before + 2,
                     "Navigation and unrelated state changes must reuse the measured storage totals")
        state.agentStorageFootprints["fixture"] = AgentStorageFootprint()
        precondition(state.agentStorageTotals() != nil && state.agentStorageTotals(for: "fixture") != nil)
        precondition(probe.storageTotalBuilds == before + 4, "A replaced footprint must rebuild its totals")
        let combinedBefore = probe.storageTotalBuilds
        for _ in 0..<100 {
            _ = state.agentStorageTotals(for: Set(["fixture"]))
            _ = state.agentStorageTotals(for: Set(["fixture", "another-agent"]))
        }
        precondition(probe.storageTotalBuilds == combinedBefore + 1,
                     "Software rows must share group totals and build their combined scope only once")
        state.agentStorageFootprints["another-agent"] = AgentStorageFootprint()
        _ = state.agentStorageTotals(for: Set(["fixture", "another-agent"]))
        precondition(probe.storageTotalBuilds == combinedBefore + 2,
                     "A newly measured Agent must invalidate combined software totals")
        state.agentStorageFootprints = [:]
        _ = state.agentStorageTotals(for: Set(["fixture"]))
        precondition(state.agentStorageTotals() == nil && state.agentStorageTotals(for: "fixture") == nil)
        state.clearAgentSelection()
        precondition(state.agentSelectedCount == 0 && state.agentSelectedBytes == 0)
        print(String(format: "Agent presentation: 100 reads of 30,000 paths took %.3f ms; storage totals built once per snapshot", elapsed * 1000))
    }

    @MainActor private static func associatedDataMutationGuards() async throws {
        for running in [false, true] {
            for gate in ["cleanup", "app-uninstall", "cli-uninstall", "software-update"] {
                let (state, f) = prepare()
                if running { f.setDataProbes([.init(processes: [.init(name: "node")], isComplete: true)]) }
                state.offerAgentAssociatedDataCleanup(agentIDs: ["fixture"])
                try await waitUntil { state.confirmation != nil }
                let consent = state.confirmation!
                state.confirmation = nil
                if gate == "cleanup" { state.isCleanupMutationBusy = true }
                if gate == "app-uninstall" { state.uninstallQueue.activeJob = "other-app" }
                if gate == "cli-uninstall" { state.commandLineToolBusyID = "other-cli" }
                if gate == "software-update" { state.softwareUpdatingID = "other-update" }
                consent.onConfirm()
                precondition(!state.agentApplying && state.agentProgramBusyID == nil
                             && state.snapshots == 0 && f.cleanupCount == 0 && f.uninstallCount == 0
                             && f.removalRequests == 0,
                             "Associated data consent crossed a shared mutation before process close or deletion")
            }
        }
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
            precondition(!f.removalItems.map(\.record).contains(workflowHome + "/new-data")
                         && f.removalItems.map(\.record).contains(workflowHome + "/cache")
                         && f.removalItems.contains { $0.record == workflowHome + "/skill" && $0.identity == "fixture-identity" }
                         && f.cleanupCount == 0,
                         "A fresh idle process probe preserves the confirmed data envelope")
            f.cleanupGate.release()
            try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
        }
    }

    @MainActor private static func completeRemovalIncludesProtectedData() async throws {
        let (state, fixture) = prepare()
        let root = workflowHome + "/protected-agent-home"
        fixture.removalPlan = .init(agentIDs: ["fixture"],
            items: [.init(record: root, identity: "reviewed-root")], retainedPaths: [], messages: [])
        state.agentCategories = [.init(name: "Credentials and history", paths: [root], bytes: 8192,
            pathIdentities: [root: "reviewed-root"], selected: false, risk: .protected)]
        state.offerAgentAssociatedDataCleanup(agentIDs: ["fixture"])
        try await waitUntil { state.confirmation != nil }
        precondition(state.confirmation!.message.contains(root)
                     && state.confirmation!.title == L10n.shared.t("agents.data.confirm.title")
                     && fixture.removalRequests == 0 && fixture.cleanupCount == 0,
                     "Protected roots require an exact-path complete-removal preview, not ordinary cleanup selection")
        let consent = state.confirmation!
        state.confirmation = nil
        consent.onConfirm()
        try await waitUntil { fixture.cleanupGate.started }
        precondition(fixture.removalItems.map(\.record) == [root] && fixture.cleanupCount == 0,
                     "Complete removal must use its dedicated Trash service, including protected exclusive roots")
        fixture.cleanupGate.release()
        try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
        precondition(state.agentOutcomeMood == .success && state.taskNotice == nil)
    }

    @MainActor private static func completeRemovalReportsRetainedData() async throws {
        let (state, fixture) = prepare()
        let root = workflowHome + "/shared-agent-home"
        fixture.removalPlan = .init(agentIDs: ["fixture"], items: [], retainedPaths: [root],
                                   messages: ["Another installation still uses this data."])
        state.offerAgentAssociatedDataCleanup(agentIDs: ["fixture"])
        try await waitUntil { state.taskNotice != nil }
        precondition(state.confirmation == nil && fixture.removalRequests == 0
                     && state.taskNotice!.details.contains(root)
                     && state.taskNotice!.details.contains("Another installation still uses this data."),
                     "An empty deletion plan with retained data must explain its location and reason")
    }

    @MainActor private static func completeRemovalEmptyPlanSucceedsWithoutFailurePopup() async throws {
        let (state, fixture) = prepare()
        fixture.removalPlan = .init(agentIDs: ["fixture"], items: [], retainedPaths: [], messages: [])
        state.offerAgentAssociatedDataCleanup(agentIDs: ["fixture"])
        try await waitUntil { state.agentProgramBusyID == nil && state.agentOutcomeMood == .success }
        precondition(state.taskNotice == nil && state.confirmation == nil
                     && fixture.removalRequests == 0
                     && state.agentStatus == L10n.shared.t("agents.data.empty"),
                     "No known residuals is a successful refresh without a failure popup")
    }

    @MainActor private static func bulkCLIOffersSeparateCompleteRemoval() async throws {
        let (state, fixture) = prepare()
        fixture.removalPlan = .init(agentIDs: ["fixture"],
            items: [.init(record: workflowHome + "/exclusive-agent-home", identity: "reviewed-root")],
            retainedPaths: [], messages: [])
        startCLI(state)
        try await waitUntil { fixture.uninstallGate.started }
        fixture.uninstallGate.release()
        try await waitUntil { fixture.cleanupGate.started }
        fixture.cleanupGate.release()
        try await waitUntil { !state.agentApplying && state.confirmation != nil }
        precondition(fixture.uninstallCount == 1 && fixture.cleanupCount == 1 && fixture.removalRequests == 0
                     && state.confirmation!.message.contains(workflowHome + "/exclusive-agent-home"),
                     "A successful bulk CLI action may offer complete removal only after ordinary cleanup, with fresh separate consent")
    }

    @MainActor private static func completeRemovalReportsPartialResult() async throws {
        let (state, fixture) = prepare()
        let removed = workflowHome + "/removed-home", retained = workflowHome + "/retained-home"
        fixture.removalPlan = .init(agentIDs: ["fixture"], items: [
            .init(record: removed, identity: "reviewed-removed"),
            .init(record: retained, identity: "reviewed-retained")], retainedPaths: [], messages: [])
        fixture.remainingRemovalPlan = .init(agentIDs: ["fixture"], items: [], retainedPaths: [retained],
                                             messages: ["A shared owner still uses this root."])
        fixture.cleanup = .init(summary: .init(removed: 1, skipped: 1, messages: ["Retained shared data."],
            removedPaths: [removed], remainingPaths: [retained], retainedPaths: [retained]), refused: 0)
        state.offerAgentAssociatedDataCleanup(agentIDs: ["fixture"])
        try await waitUntil { state.confirmation != nil }
        let consent = state.confirmation!
        state.confirmation = nil
        consent.onConfirm()
        try await waitUntil { fixture.cleanupGate.started }
        fixture.cleanupGate.release()
        try await waitUntil { state.taskNotice != nil && !state.agentApplying }
        precondition(state.agentOutcomeMood == .attention && state.agentCompletedCount == 1
                     && state.agentStatus.contains("agents.data.result.partial")
                     && state.taskNotice!.details.contains(retained)
                     && state.taskNotice!.onRetry != nil,
                     "One successful Trash move must not hide remaining or shared data behind a success result")
    }

    @MainActor private static func bulkLinkDoesNotOfferCompleteRemoval() async throws {
        let (state, fixture) = prepare()
        state.agentCLIInstallations[0].onlyUnlinksExecutable = true
        fixture.cli = state.agentCLIInstallations
        fixture.removalPlan = .init(agentIDs: ["fixture"],
            items: [.init(record: workflowHome + "/still-installed-source-data", identity: "source")],
            retainedPaths: [], messages: [])
        startCLI(state)
        try await waitUntil { fixture.uninstallGate.started }
        fixture.uninstallGate.release()
        try await waitUntil { fixture.cleanupGate.started }
        precondition(fixture.submittedRemovalID == nil,
                     "Unlinking a launcher must not grant removed-product privileges to everyday data cleanup")
        fixture.cleanupGate.release()
        try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(state.confirmation == nil && fixture.removalRequests == 0,
                     "Successful launcher unlinking must not offer complete data removal while its source remains")
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
        precondition(f.scanCount == 1 && f.cleanupCount == 0 && f.uninstallCount == 0 && (state.taskNotice == nil) == complete,
                     "Partial scans need a result dialog and must never initiate cleanup or uninstall")
        if !complete { state.dismissTaskNotice() }
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
        try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
        successAndRefreshed(state, removed: 1)
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
        try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
        attention(state)
        if !runtimeAvailable {
            precondition(state.agentOutcomeMood == .success && state.agentOutcomeDetails.isEmpty)
            return
        }
        precondition(state.agentFailureApplications.isEmpty)
        f.setRunning(RunningApplicationSnapshot())
        retryAgentRecovery(state)
        try await waitUntil { f.cleanupCount == 2 }
        precondition(f.submittedSkillIdentities == ["fixture-identity"],
                     "Refresh may prove presence but cannot replace an accepted sensitive identity")
        precondition(f.submittedPaths == (retainedCache ? ["\(workflowHome)/cache"] : []),
                     "Retry may reclaim retained/new cache contents but must exclude absent completed targets")
        f.cleanupGate.release()
        try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
        successAndRefreshed(state, removed: 1)
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
        try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
        precondition(f.cleanupCount == 1)
        successAndRefreshed(state, removed: 1)
    }

    @MainActor private static func partialReadyCacheRetry() async throws {
        let (state, f) = prepare(liveCache: true)
        state.agentSelectedSkills = ["\(workflowHome)/skill"]
        f.cleanup = .init(summary: .init(removed: 1, skipped: 1, messages: ["Held cache file remains."]), refused: 0)
        f.setRunning(RunningApplicationSnapshot(processNames: ["FixtureHost"]))
        state.applyAgentCleanup()
        try await waitUntil { f.cleanupGate.started }
        f.cleanupGate.release()
        try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
        attention(state)
        precondition(state.agentOutcomeMood == .success && state.agentOutcomeDetails.isEmpty)
        f.setRunning(RunningApplicationSnapshot())
        f.cleanup = .init(summary: .init(removed: 2), refused: 0)
        retryAgentRecovery(state)
        try await waitUntil { f.cleanupCount == 2 }
        precondition(f.submittedPaths == ["\(workflowHome)/cache"] && f.submittedSkillPaths == ["\(workflowHome)/skill"],
                     "Unresolved cache content must remain in the sensitive-resource retry")
        f.cleanupGate.release()
        try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
        successAndRefreshed(state, removed: 2)
    }

    @MainActor private static func blockedFrozenRetry() async throws {
        let (state, f) = prepare()
        f.setRunning(RunningApplicationSnapshot(bundleIdentifiers: ["test.nori.fixture"], processNames: ["FixtureHost"]))
        state.applyAgentCleanup()
        try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
        attention(state)
        precondition(state.agentFailureApplications == ["Fixture Desktop"] && state.agentSelectedCount == 4)
        precondition(f.cleanupCount == 0 && f.scanCount == 0 && f.uninstallCount == 0 && state.resamples == 0)
        let token = state.agentFeedbackID
        retryAgentRecovery(state)
        try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
        precondition(state.agentStatus == "task.closeApps.changed" && state.agentFeedbackID > token
                     && f.preflightCount == 2 && state.snapshots == 2)
        state.clearAgentSelection()
        state.agentCategories[0].setPathSelected("\(workflowHome)/untouched", selected: true)
        f.setRunning(RunningApplicationSnapshot())
        retryAgentRecovery(state)
        try await waitUntil { f.cleanupGate.started }
        precondition(f.submittedPaths == ["\(workflowHome)/cache"] && f.submittedSkillPaths == ["\(workflowHome)/skill"]
                     && f.submittedServerIDs == ["server"] && f.submittedInstallationIDs == ["installation"],
                     "Changing UI selections cannot substitute a different accepted retry scope")
        f.cleanupGate.release()
        try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
        successAndRefreshed(state, removed: 1)
    }

    @MainActor private static func leavePrerequisiteUnresolved() async throws {
        let (state, f) = prepare()
        f.setRunning(RunningApplicationSnapshot(processNames: ["FixtureHost"]))
        state.applyAgentCleanup()
        try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
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
            try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
            f.setRunning(RunningApplicationSnapshot())
            if active { state.uninstallQueue.activeJob = "active-uninstall" }
            else { state.uninstallQueue.pendingJobs = ["pending-uninstall"] }
            state.cleanupQueued = true
            state.externallyBusy = true
            retryAgentRecovery(state)
            if active {
                precondition(!state.agentApplying && state.snapshots == 1 && state.agentRetryAvailable,
                             "App uninstall and Agent data deletion must not mutate shared support data together")
                state.uninstallQueue.activeJob = nil
                retryAgentRecovery(state)
            }
            try await waitUntil { f.cleanupGate.started }
            precondition(state.isBusy && state.queueStarts == 0 && f.cleanupCount == 1,
                         "Unrelated cleanup, queued software, or another tab blocked the frozen Agent data retry")
            state.applyAgentCleanup()
            retryAgentRecovery(state)
            precondition(f.cleanupCount == 1, "Agent reentry duplicated the active data cleanup")
            f.cleanupGate.release()
            try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
            successAndRefreshed(state, removed: 1)
        }

        for kind in ["cleanup", "cli-uninstall", "software-update", "app-uninstall"] {
            let (state, f) = prepare()
            if kind == "cleanup" { state.isCleanupMutationBusy = true }
            if kind == "cli-uninstall" { state.commandLineToolBusyID = "other-tool" }
            if kind == "software-update" { state.softwareUpdatingID = "other-update" }
            if kind == "app-uninstall" { state.uninstallQueue.activeJob = "active-uninstall" }
            startCLI(state)
            precondition(!state.agentApplying && state.snapshots == 0 && f.uninstallCount == 0,
                         "A shared package mutation must block Agent CLI removal")
        }

        for kind in ["cleanup", "cli-uninstall", "software-update"] {
            let (state, f) = prepare()
            f.setRunning(RunningApplicationSnapshot(processNames: ["FixtureHost"]))
            state.applyAgentCleanup()
            try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
            precondition(state.agentRetryAvailable && state.agentRetryAction != nil)
            f.setRunning(RunningApplicationSnapshot())
            if kind == "cleanup" { state.isCleanupMutationBusy = true }
            if kind == "cli-uninstall" { state.commandLineToolBusyID = "other-tool" }
            if kind == "software-update" { state.softwareUpdatingID = "other-update" }
            retryAgentRecovery(state)
            state.applyAgentCleanup()
            state.offerAgentAssociatedDataCleanup(agentIDs: ["fixture"])
            precondition(!state.agentApplying && state.agentProgramBusyID == nil
                         && state.agentRetryAvailable && state.agentRetryAction != nil
                         && state.snapshots == 1 && f.cleanupCount == 0,
                         "Shared mutation consumed a frozen Agent retry or allowed associated data removal")
            state.isCleanupMutationBusy = false
            state.commandLineToolBusyID = nil
            state.softwareUpdatingID = nil
            retryAgentRecovery(state)
            try await waitUntil { f.cleanupGate.started }
            precondition(f.cleanupCount == 1)
            f.cleanupGate.release()
            try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
        }
    }

    @MainActor private static func CLIPrerequisitesAndDataRetry() async throws {
        let (state, f) = prepare()
        f.dependencyOwners = []
        f.setRunning(RunningApplicationSnapshot(processNames: ["FixtureCLI"]))
        startCLI(state)
        try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
        attention(state)
        precondition(f.uninstallCount == 0 && f.cleanupCount == 0 && state.agentFailureApplications == ["FixtureCLI"])
        f.dependencyOwners = ["FixtureHost", "test.nori.fixture"]
        f.setSnapshots([RunningApplicationSnapshot(), RunningApplicationSnapshot(processNames: ["FixtureHost"])])
        f.setRunning(RunningApplicationSnapshot(processNames: ["FixtureHost"]))
        retryAgentRecovery(state)
        try await waitUntil { f.uninstallGate.started }
        f.uninstallGate.release()
        try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
        attention(state)
        precondition(f.uninstallCount == 1 && f.cleanupCount == 0 && state.agentSelectedCLIInstallations.isEmpty)
        retryAgentRecovery(state)
        try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
        precondition(state.agentStatus == "task.closeApps.changed" && f.uninstallCount == 1)
        state.clearAgentSelection()
        f.setRunning(RunningApplicationSnapshot())
        retryAgentRecovery(state)
        try await waitUntil { f.cleanupGate.started }
        precondition(Set(f.submittedPaths) == ["\(workflowHome)/cache", "\(workflowHome)/untouched"]
                     && f.submittedRemovalID == "fixture" && f.uninstallCount == 1)
        precondition(state.agentCleanupProgress?.completed == 1 && state.agentCleanupProgress?.total == 6,
                     "Data-only retry must keep the completed CLI in the overall progress")
        f.cleanupGate.release()
        try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
        successAndRefreshed(state, removed: 1)
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
        try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
        attention(state)
        if !runtimeAvailable {
            precondition(state.agentOutcomeMood == .success && state.agentOutcomeDetails.isEmpty)
            return
        }
        f.setRunning(RunningApplicationSnapshot())
        retryAgentRecovery(state)
        try await waitUntil { f.cleanupCount == 2 }
        precondition(f.uninstallCount == 1 && f.submittedPaths.isEmpty && f.submittedSkillIdentities == ["fixture-identity"]
                     && f.submittedServerIDs == ["server"] && f.submittedRemovalID == "fixture")
        f.cleanupGate.release()
        try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
        successAndRefreshed(state, removed: 1)
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
        try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
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
        let refreshedCategory = CleanupCategory(name: "Fresh cache", paths: ["\(workflowHome)/new-cache"],
            bytes: 2, pathIdentities: [:], selected: true, risk: .safe)
        f.report.categories = [refreshedCategory]
        f.report.skills = []
        f.report.servers = []
        f.report.installations = []
        f.report.groups = [AgentGroupSummary(id: "fixture", name: "Fixture", documented: true,
            orphaned: false, categoryIDs: [refreshedCategory.id], skillIDs: [], serverIDs: [], bytes: 2)]
        state.agentCLIBodySizes["stale-installation"] = .init(bytes: 1, complete: true)
        f.cleanupGate.release()
        try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
        precondition(state.resamples == 1 && f.scanCount == 1)
        precondition(state.agentCategories.map(\.id) == [refreshedCategory.id]
                     && state.agentSkills.isEmpty && state.agentServers.isEmpty
                     && state.agentMCPInstallations.isEmpty && state.agentCLIBodySizes["stale-installation"] == nil,
                     "Automatic refresh must replace removed resources and stale installation measurements")
        successAndRefreshed(state, removed: 4)
        precondition(state.agentReclaimedBytes == 8192,
                     "Agent cleanup must report worker-confirmed bytes, not selected sizes")
    }

    @MainActor private static func manuallySelectedOrphanData() async throws {
        let (state, f) = prepare()
        state.agentCategories[0].risk = .warning
        state.agentCategories[0].source = .aiSession
        state.agentCategories[0].disposal = .permanentDelete
        state.agentCategories[0].applyRoute = .aiTrash
        state.agentCategories[0].activityGuard = .aiAgent
        state.agentCategories[0].reasonKey = "agents.reason.showOnly"
        state.agentCLIInstallations = []
        state.agentSelectedSkills = []
        state.agentSelectedServers = []
        state.agentSelectedMCPInstallations = []
        state.agentGroups = [AgentGroupSummary(id: "fixture", name: "Fixture", documented: true,
            orphaned: true, categoryIDs: [state.agentCategories[0].id], skillIDs: [], serverIDs: [], bytes: 2),
            AgentGroupSummary(id: "unselected", name: "Unselected", documented: true,
                orphaned: true, categoryIDs: [UUID()], skillIDs: [], serverIDs: [], bytes: 1)]
        f.cleanup.summary.removed = 1
        f.cleanup.summary.removedPaths = ["\(workflowHome)/cache"]
        state.applyAgentCleanup()
        try await waitUntil { f.cleanupGate.started }
        precondition(f.submittedRemovalID == "fixture" && f.submittedPaths == ["\(workflowHome)/cache"]
                     && f.submittedCLIIDs.isEmpty,
                     "Manual orphan selection must carry only its own residual scope and selected paths")
        f.cleanupGate.release()
        try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
        successAndRefreshed(state, removed: 1)
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
        try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
        attention(state)
        precondition(state.agentSelectedSkills == ["\(workflowHome)/skill"] && state.agentSelectedServers == ["server"])
        if kind == "partial" {
            precondition(!state.agentCategories[0].selected && state.agentOutcomeMood == .success
                         && state.agentOutcomeDetails.isEmpty,
                         "Unrelated fresh caches cannot silently enter the failed selection")
        } else if kind == "failed" { precondition(state.agentSelectedCount == 4 && state.agentOutcomeDetails == f.cleanup.summary.messages) }
        else { precondition(state.agentSelectedCount == 4 && state.agentOutcomeDetails == ["agents.result.noReason"]) }
        precondition(state.agentOutcomeMood == (kind == "partial" ? .success : .attention) && state.agentHasScanned,
                     "The result dialog must preserve the current inventory")
    }

    @MainActor private static func failedCLI(noop: Bool) async throws {
        let (state, f) = prepare()
        f.uninstall = noop ? .init(removed: 0, failed: 0, messages: [])
            : .init(removed: 0, failed: 1, messages: ["CLI is running."])
        startCLI(state)
        try await waitUntil { f.uninstallGate.started }
        precondition(state.agentApplying && state.agentHasScanned)
        f.uninstallGate.release()
        try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
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
        try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
        precondition(!state.cleanupScanComplete && state.progressHistory.contains { $0.phase == .verifying })
        precondition(state.agentReclaimedBytes == 6144,
                     "CLI and data cleanup must merge only their confirmed reclaimed allocation")
        successAndRefreshed(state, removed: 2)
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
        try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
        successAndRefreshed(state, removed: 2)
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
        try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
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
        try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
        attention(state)
        precondition(f.cleanupCount == 0 && state.agentSelectedCLIInstallations == ["cli-two"])
        var refreshed = second
        refreshed.identity = "new-inventory-identity"
        state.agentCLIInstallations = [refreshed]
        f.cli = [refreshed]
        f.uninstallByID = [:]
        retryAgentRecovery(state)
        try await waitUntil { f.uninstallCount == 3 }
        precondition(f.submittedCLIIDs == ["cli", "cli-two", "cli-two"]
                     && f.submittedCLIIdentities.last == "original-second-identity",
                     "CLI retry must preserve accepted identities and exclude already removed CLI instances")
        f.uninstallGate.release()
        try await waitUntil { f.cleanupGate.started }
        precondition(state.agentCleanupProgress?.completed == 2 && state.agentCleanupProgress?.total == 7)
        f.cleanupGate.release()
        try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
        successAndRefreshed(state, removed: 2)
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
        try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
        attention(state)
        precondition(state.agentCLIInstallations.isEmpty && state.agentRetryAvailable
                     && state.agentReclaimedBytes == 2048 && f.cleanupCount == 0,
                     "A partially removed CLI must retain its proven retry while associated data waits")

        f.uninstall = .init(removed: 0, failed: 1, messages: ["Package body is still locked."],
            retryInstallation: proven)
        retryAgentRecovery(state)
        precondition(state.agentCompletedCount == 0 && state.agentReclaimedBytes == 0,
                     "A new click must reset the previous attempt's deletion count and bytes")
        try await waitUntil { f.uninstallCount == 2 }
        precondition(f.submittedCLIIDs == ["cli", "cli"]
                     && f.submittedCLIIdentities == ["original-cli-identity", proven.identity],
                     "Fresh empty inventory cannot discard or rebind the service-proven CLI retry")
        f.uninstallGate.release()
        try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
        attention(state)
        precondition(state.agentOutcomeMood == .attention && state.agentCompletedCount == 0
                     && state.agentReclaimedBytes == 0 && f.cleanupCount == 0,
                     "A failed retry must show its current failure and 0B while data remains untouched")

        f.uninstall = .init(removed: 1, failed: 0, messages: [], reclaimedBytes: 1024)
        f.cleanup = .init(summary: .init(removed: 2, reclaimedBytes: 4096), refused: 0)
        retryAgentRecovery(state)
        try await waitUntil { f.uninstallCount == 3 }
        precondition(f.submittedCLIIdentities.last == proven.identity && f.cleanupCount == 0)
        f.uninstallGate.release()
        try await waitUntil { f.cleanupGate.started }
        precondition(f.cleanupCount == 1 && f.submittedRemovalID == "fixture"
                     && !f.submittedPaths.isEmpty && state.agentHasScanned && state.agentApplying,
                     "Associated data may run only after the same accepted CLI phase succeeds")
        f.cleanupGate.release()
        try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
        successAndRefreshed(state, removed: 3)
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
        try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
        attention(state, retry: false)
        precondition(f.cleanupCount == 0 && f.submittedCLIIdentities == ["original-cli-identity"]
                     && state.agentCompletedCount == 0 && state.agentReclaimedBytes == 0,
                     "An unproved replacement cannot authorize a CLI retry or its associated data cleanup")
        retryAgentRecovery(state)
        precondition(!state.agentApplying && f.uninstallCount == 1,
                     "A required rescan must not leave a hidden retry closure for the changed installation")
    }

    @MainActor private static func retryFeedbackUsesCurrentAttempt() async throws {
        let (state, f) = prepare()
        f.cleanup = .init(summary: .init(removed: 1, skipped: 1, reclaimedBytes: 8192), refused: 0)
        state.applyAgentCleanup()
        try await waitUntil { f.cleanupGate.started }
        f.cleanupGate.release()
        try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
        attention(state)
        precondition(state.agentCompletedCount == 1 && state.agentReclaimedBytes == 8192)

        f.cleanup = .init(summary: .init(failed: 4, messages: ["No pending files could be removed."]), refused: 0)
        retryAgentRecovery(state)
        precondition(state.agentCompletedCount == 0 && state.agentReclaimedBytes == 0)
        try await waitUntil { f.cleanupCount == 2 }
        f.cleanupGate.release()
        try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
        attention(state)
        precondition(state.agentOutcomeMood == .attention && state.agentCompletedCount == 0
                     && state.agentReclaimedBytes == 0 && state.agentOutcomeDetails == f.cleanup.summary.messages,
                     "A fully failed click must not inherit an earlier success, released space, or hidden errors")

        f.cleanup = .init(summary: .init(removed: 2, reclaimedBytes: 2048), refused: 0)
        retryAgentRecovery(state)
        try await waitUntil { f.cleanupCount == 3 }
        f.cleanupGate.release()
        try await waitUntil { !state.agentApplying && state.agentProgramBusyID == nil }
        successAndRefreshed(state, removed: 2)
        precondition(state.agentReclaimedBytes == 2048,
                     "A successful retry must show only space actually released during its current click")
    }
}
