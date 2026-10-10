import Foundation

// The production page predicates and CLI request/confirmation methods are
// linked unchanged. Every scanner, probe and remover is an in-memory boundary.
struct FixtureAgentInstallation: Equatable, Sendable { let name: String }
struct CommandLineTool: Equatable, Sendable {
    enum Manager: Sendable {
        case fixture
        var displayName: String { "Fixture manager" }
    }
    let id: String
    let name: String
    let path: String
    var bytes: UInt64 = 123
    var manager: Manager = .fixture
    var agentID: String? = nil
    var installationSource: String? = nil
    var agentInstallation: FixtureAgentInstallation? = nil
    var canUninstall = true
}
enum DeletionPlan {
    static func identity(at path: String) -> String? { "fixture:" + path }
}
enum SoftwareUpdateService {
    static func toolKey(_ tool: CommandLineTool) -> String { "cli:" + tool.id }
}
enum CommandLineToolInventory {
    static func scan(home: String) -> [CommandLineTool] {
        preconditionFailure("The request fixture must never start a scanner")
    }
}
enum SoftwareUpdateProcesses {
    struct Scope: Sendable {
        let id: String
        static func tool(_ tool: CommandLineTool) -> Self { .init(id: tool.id) }
    }
    struct OwnedProcess: Sendable { let name: String }
    struct Probe: Sendable {
        let processes: [OwnedProcess]
        let isComplete: Bool
    }
    static func probe(_ scope: Scope) -> Probe { RequestProbeFixture.current.probe(scope.id) }
}
private final class RequestProbeFixture: @unchecked Sendable {
    static var current = RequestProbeFixture()
    private let lock = NSLock()
    private var calls: [String] = []
    private var result = SoftwareUpdateProcesses.Probe(processes: [], isComplete: true)
    func probe(_ id: String) -> SoftwareUpdateProcesses.Probe {
        lock.lock(); defer { lock.unlock() }
        calls.append(id)
        return result
    }
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls.count }
    func set(_ value: SoftwareUpdateProcesses.Probe) { lock.lock(); result = value; lock.unlock() }
}
enum CLIUninstallService {
    struct Outcome { let succeeded: Bool; var messages: [String] = [] }
}
@MainActor
enum CLIUninstallWorkflow {
    enum Result {
        case needsConfirmation(SoftwareUpdateProcesses.Probe)
        case failed(reasonKey: String)
        case finished(CLIUninstallService.Outcome)
    }
    struct Call { let toolID: String; let identity: String?; let mayClose: Bool }
    static var calls: [Call] = []
    static var result: Result = .finished(.init(succeeded: true))
    static func execute(_ tool: CommandLineTool, identity: String?, mayClose: Bool) async -> Result {
        calls.append(.init(toolID: tool.id, identity: identity, mayClose: mayClose))
        return result
    }
}
final class L10n {
    static let shared = L10n()
    func t(_ key: String) -> String { key }
    func tf(_ key: String, _ values: CVarArg...) -> String {
        key + " " + values.map { String(describing: $0) }.joined(separator: " ")
    }
}
enum ByteFormat { static func format(_ bytes: UInt64) -> String { "fixture-bytes:\(bytes)" } }
enum ProtectedOperation {
    case cleanupScan, deepCleanupScan, quickOptimize, developerToolsScan, previewAutoCleanup, runAutoCleanup
    case aiScan, installedAppsScan, uninstall, developmentEnvironmentScan, diskOverview
}
@MainActor
final class AppState {
    final class Queue { var hasWork = false; var activeJob: Int? }
    final class Simulator { var isDeleting = false }
    struct Confirmation {
        let title: String
        let message: String
        let confirmLabel: String
        let onConfirm: () -> Void
    }
    let uninstallQueue = Queue()
    let simulatorInventory = Simulator()
    var isScanning = false
    var isApplying = false
    var cleanupQueued = false
    var isAutoCleanupScanning = false
    var isAutoCleanupMutationActive = false
    var isSystemMaintenanceRunning = false
    var isAnalyzing = false
    var isScanningDuplicates = false
    var isSlimming = false
    var isDeletingDuplicates = false
    var isDeletingAnalysisFiles = false
    var isRefreshingAnalysisCache = false
    var agentScanning = false
    var agentApplying = false
    var agentProgramBusyID: String?
    var isScanningApps = false
    var isScanningCommandLineTools = false
    var isCheckingSoftwareUpdates = false
    var commandLineToolBusyID: String?
    var softwareUpdatingID: String?
    var isScanningEnv = false
    var isApplyingDevEnv = false
    var isRefreshingGc = false
    var gcRunningId: String?
    var isDeveloperCommandRunning = false
    var isDeveloperConfigurationWriting = false
    var isNetworkToolRunning = false
    var commandLineTools: [CommandLineTool] = []
    var commandLineToolsScanned = true
    var commandLineToolStatus = ""
    var commandLineToolUninstallGeneration = UUID()
    var uninstallSearch = ""
    var confirmation: Confirmation?
    var taskNotice: String?
    var softwareUpdateResults: [String: Int] = [:]
    var agentHasScanned = true
    var resamples = 0
    var failures = 0
    var logs: [String] = []
    let l10n = L10n.shared
    func uninstallAgentTool(_ tool: CommandLineTool) {
        preconditionFailure("Generic CLI requests cannot enter the Agent-removal adapter")
    }
    func ensureAgentStorageFootprints(for ids: Set<String>) {
        preconditionFailure("A request test cannot start storage discovery")
    }
    func presentTaskFailure(message: String = "", details: [String] = [], detailsAreLocalized: Bool = false) {
        failures += 1; taskNotice = message
    }
    func resampleAfterMutation() { resamples += 1 }
    func log(_ message: String) { logs.append(message) }
}

@main
@MainActor
struct CLIUninstallRequestTests {
    static func state() -> AppState {
        RequestProbeFixture.current = RequestProbeFixture()
        CLIUninstallWorkflow.calls = []
        CLIUninstallWorkflow.result = .finished(.init(succeeded: true))
        let state = AppState()
        state.commandLineTools = [
            .init(id: "selected", name: "Selected CLI", path: "/fixture/prefix-one/tool"),
            .init(id: "neighbor", name: "Same package", path: "/fixture/prefix-two/tool")
        ]
        state.softwareUpdateResults = ["cli:selected": 1, "cli:neighbor": 2]
        return state
    }
    static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            precondition(Date() < deadline, "CLI request did not reach its expected boundary")
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    static func consent(_ state: AppState) {
        guard let prompt = state.confirmation else { preconditionFailure("Missing CLI consent") }
        state.confirmation = nil
        prompt.onConfirm()
    }
    static func mutationGuards() async throws {
        let mutations: [@MainActor (AppState) -> Void] = [
            { $0.isApplying = true }, { $0.isAutoCleanupMutationActive = true },
            { $0.agentApplying = true }, { $0.agentProgramBusyID = "Agent install" }
        ]
        for mutation in mutations {
            let blocked = state()
            mutation(blocked)
            precondition(blocked.isSoftwareMutationBlocked && !blocked.isSoftwareTaskBusy)
            blocked.uninstallCommandLineTool(blocked.commandLineTools[0])
            try await Task.sleep(nanoseconds: 15_000_000)
            precondition(RequestProbeFixture.current.callCount == 0 && blocked.confirmation == nil
                         && blocked.commandLineToolBusyID == nil && CLIUninstallWorkflow.calls.isEmpty,
                         "Cleanup/Agent writes must block a generic CLI request before probing")

            let confirming = state()
            let selected = confirming.commandLineTools[0]
            RequestProbeFixture.current.set(.init(processes: [.init(name: "Owned CLI")], isComplete: true))
            confirming.uninstallCommandLineTool(selected)
            try await waitUntil { confirming.confirmation != nil }
            precondition(confirming.confirmation?.confirmLabel == "cli.uninstall.confirm.closeAction")
            mutation(confirming)
            consent(confirming)
            try await Task.sleep(nanoseconds: 15_000_000)
            precondition(CLIUninstallWorkflow.calls.isEmpty && confirming.commandLineToolBusyID == nil
                         && confirming.commandLineTools.count == 2 && confirming.resamples == 0,
                         "A write started during consent must block the close/removal workflow")
        }
    }
    static func independentReadOnlyWork() async throws {
        let readOnly: [@MainActor (AppState) -> Void] = [
            { $0.isAnalyzing = true }, { $0.isScanningDuplicates = true },
            { $0.isScanning = true }, { $0.agentScanning = true },
            { $0.isScanningEnv = true }, { $0.isSystemMaintenanceRunning = true }
        ]
        for activity in readOnly {
            let independent = state()
            activity(independent)
            precondition(independent.isBusy && !independent.isSoftwareTaskBusy && !independent.isSoftwareMutationBlocked)
            let selected = independent.commandLineTools[0]
            independent.uninstallCommandLineTool(selected)
            try await waitUntil { independent.confirmation != nil }
            precondition(CLIUninstallWorkflow.calls.isEmpty, "Requesting consent cannot start removal")
            consent(independent)
            try await waitUntil { independent.commandLineTools.count == 1 }
            precondition(CLIUninstallWorkflow.calls.count == 1 && CLIUninstallWorkflow.calls[0].toolID == selected.id
                         && CLIUninstallWorkflow.calls[0].identity == DeletionPlan.identity(at: selected.path)
                         && independent.commandLineTools[0].id == "neighbor" && independent.isBusy
                         && independent.softwareUpdateResults == ["cli:neighbor": 2] && independent.resamples == 1,
                         "Read-only work must remain independent while the selected installation is removed")
        }
    }
    static func staleAndCancellation() async throws {
        let cancelled = state()
        cancelled.uninstallCommandLineTool(cancelled.commandLineTools[0])
        try await waitUntil { cancelled.confirmation != nil }
        cancelled.confirmation = nil
        try await Task.sleep(nanoseconds: 15_000_000)
        precondition(CLIUninstallWorkflow.calls.isEmpty && cancelled.commandLineTools.count == 2)
        for invalidation in 0..<2 {
            let stale = state()
            stale.uninstallCommandLineTool(stale.commandLineTools[0])
            try await waitUntil { stale.confirmation != nil }
            if invalidation == 0 { stale.commandLineToolUninstallGeneration = UUID() }
            else { stale.commandLineTools.removeFirst() }
            consent(stale)
            try await Task.sleep(nanoseconds: 15_000_000)
            precondition(CLIUninstallWorkflow.calls.isEmpty && stale.commandLineToolBusyID == nil,
                         "An obsolete generation or removed row cannot authorize mutation")
        }
    }
    static func main() async throws {
        try await mutationGuards()
        try await independentReadOnlyWork()
        try await staleAndCancellation()
        print("PASS: production generic CLI request/consent excludes overlapping writes, permits independent scans and rejects stale consent")
    }
}
