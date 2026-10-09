import Foundation

// Every model and backend below is an in-memory dependency of the linked
// production AppState extension. No scanner, signal or remover is linked.
struct AgentCLIInstallation: Equatable, Sendable {
    let id: String
    let agentID: String
    let name: String
    let executablePaths: [String]
    let managedPaths: [String]
    let identities: [String: String]
}
struct CommandLineTool: Equatable, Sendable {
    let agentInstallation: AgentCLIInstallation?
    var bytes: UInt64 = 0
    var id: String { agentInstallation?.id ?? "unrelated-runtime" }
    var path: String { agentInstallation?.managedPaths.first ?? agentInstallation?.executablePaths.first ?? "" }
}
struct UninstallApp: Equatable, Sendable {
    let name: String
    let bundleID: String
    let path: String
    let appIdentity: String
    let infoIdentity: String
    var id: String { path + "#" + bundleID }
}
enum AgentSoftwareInventory {
    static func commandLineTool(for installation: AgentCLIInstallation) -> CommandLineTool {
        .init(agentInstallation: installation)
    }
    static func agentIDs(for app: UninstallApp) -> Set<String> {
        // This lookup is fixture data; catalog matching is tested separately.
        app.bundleID == "test.agent.one" ? ["agent-one", "shared-desktop"] : ["agent-other"]
    }
}
struct ProgramProcess: Sendable { let name: String }
enum SoftwareUpdateProcesses {
    struct Scope: Sendable { let installationID: String }
    struct Probe: Sendable { let processes: [ProgramProcess]; let isComplete: Bool }
    static func probe(_ scope: Scope) -> Probe { ProgramProbeFixture.current.probe() }
}
extension SoftwareUpdateProcesses.Scope {
    static func tool(_ tool: CommandLineTool) -> Self { .init(installationID: tool.id) }
}
private final class ProgramProbeFixture: @unchecked Sendable {
    static var current = ProgramProbeFixture()
    private let lock = NSLock()
    private var stored = SoftwareUpdateProcesses.Probe(processes: [], isComplete: true)
    func set(_ probe: SoftwareUpdateProcesses.Probe) { lock.lock(); stored = probe; lock.unlock() }
    func probe() -> SoftwareUpdateProcesses.Probe { lock.lock(); defer { lock.unlock() }; return stored }
}
final class ProcessSampler {
    struct Snapshot { let processes: [ProgramProcess]; let isComplete: Bool }
    static let shared = ProcessSampler()
    func sample() -> [ProgramProcess] { ProgramProbeFixture.current.probe().processes }
    func snapshot() -> Snapshot {
        let probe = ProgramProbeFixture.current.probe()
        return .init(processes: probe.processes, isComplete: probe.isComplete)
    }
}
enum UninstallProcessController {
    static func processes(for app: UninstallApp, samples: [ProgramProcess]) -> [ProgramProcess] { samples }
}
enum CLIUninstallService {
    struct Outcome { let succeeded: Bool; var messages: [String] = [] }
}
@MainActor
enum CLIUninstallWorkflow {
    enum Result {
        case finished(CLIUninstallService.Outcome)
        case needsConfirmation(SoftwareUpdateProcesses.Probe)
        case failed(reasonKey: String)
    }
    struct Call { let installationID: String; let identity: String?; let mayClose: Bool }
    static var results: [Result] = []
    static var calls: [Call] = []
    static func execute(_ tool: CommandLineTool, identity: String?, mayClose: Bool) async -> Result {
        calls.append(.init(installationID: tool.id, identity: identity, mayClose: mayClose))
        return results.isEmpty ? .failed(reasonKey: "fixture.unconfigured") : results.removeFirst()
    }
}
enum NativeCore {
    struct ApplySummary { let succeeded: Bool; let removedPaths: Set<String>; var messages: [String] = [] }
}
enum UninstallExecutionPhase { case closing, planning, removing }
enum UninstallExecutionOutcome {
    case processesCouldNotStop
    case planUnavailable
    case applied(NativeCore.ApplySummary)
}
struct UninstallJob {
    enum Scope { case applicationAndResidues, installationOnly }
    let id: UUID
    let app: UninstallApp
    let plan: String?
    let dataPaths: Set<String>
    var scope: Scope = .applicationAndResidues
}
@MainActor
final class ProgramExecutorFixture {
    var jobs: [UninstallJob] = []
    var results: [UninstallExecutionOutcome] = []
    func execute(_ job: UninstallJob, progress: (UninstallExecutionPhase) -> Void) async -> UninstallExecutionOutcome {
        jobs.append(job)
        return results.isEmpty ? .planUnavailable : results.removeFirst()
    }
}
enum CleanupCache {
    static var invalidations = 0
    static func invalidate() { invalidations += 1 }
}
final class L10n {
    static let shared = L10n()
    func t(_ key: String) -> String { key }
    func tf(_ key: String, _ arguments: CVarArg...) -> String {
        key + " " + arguments.map { String(describing: $0) }.joined(separator: " ")
    }
}
enum ByteFormat {
    static func format(_ bytes: UInt64) -> String { "fixture-bytes:\(bytes)" }
}
@MainActor
final class AppState {
    struct QueueFixture {
        var apps: [UninstallApp] = []
        var activeJob: String?
        func containsPendingOrActive(_ app: UninstallApp) -> Bool { apps.contains(app) }
    }
    var uninstallQueue = QueueFixture()
    struct Confirmation {
        let title: String
        let message: String
        let confirmLabel: String
        let onConfirm: () -> Void
    }
    struct DataOffer: Equatable { let agentIDs: Set<String>; let programName: String? }
    var agentCLIInstallations: [AgentCLIInstallation] = []
    var commandLineTools: [CommandLineTool] = []
    var commandLineToolStatus = ""
    var agentApplications: [String: [UninstallApp]] = [:]
    var installedApps: [UninstallApp] = []
    var agentProgramBusyID: String?
    var confirmation: Confirmation?
    var taskNotice: String?
    var softwareUpdateResults: [String: Int] = [:]
    var forcedAgentBusy = false
    var externallyBusy = false
    var isCleanupMutationBusy = false
    var agentApplying = false
    var agentSelectedCLIInstallations = Set<String>()
    var commandLineToolBusyID: String?
    var softwareUpdatingID: String?
    var isCheckingSoftwareUpdates = false
    var isScanningCommandLineTools = false
    var agentProgramRemovalGeneration = UUID()
    var isAgentTaskBusy: Bool { forcedAgentBusy || agentApplying || agentProgramBusyID != nil }
    var isBusy: Bool { externallyBusy || isAgentTaskBusy }
    var cleanupScanComplete = true
    var storageInvalidations = 0
    var resamples = 0
    var failures: [String] = []
    var dataOffers: [DataOffer] = []
    var logs: [String] = []
    let l10n = L10n.shared
    let uninstallExecutor = ProgramExecutorFixture()
    func presentTaskFailure(message: String = "", details: [String] = [], detailsAreLocalized: Bool = false) {
        failures.append(message + details.joined(separator: "\n"))
        taskNotice = "failure"
    }
    func log(_ message: String) { logs.append(message) }
    func invalidateAgentStorageFootprints() { storageInvalidations += 1 }
    func resampleAfterMutation() { resamples += 1 }
    func offerAgentAssociatedDataCleanup(agentIDs: Set<String>, programName: String? = nil) {
        dataOffers.append(.init(agentIDs: agentIDs, programName: programName))
    }
}

@main
@MainActor
struct AgentProgramRemovalTests {
    static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            precondition(Date() < deadline, "Program workflow did not settle")
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    static func consent(_ state: AppState) {
        guard let confirmation = state.confirmation else { preconditionFailure("Missing consent prompt") }
        state.confirmation = nil
        confirmation.onConfirm()
    }
    static func reset() {
        ProgramProbeFixture.current = ProgramProbeFixture()
        CLIUninstallWorkflow.results = []
        CLIUninstallWorkflow.calls = []
        CleanupCache.invalidations = 0
    }
    static func cli(_ id: String, agentID: String, path: URL) -> AgentCLIInstallation {
        .init(id: id, agentID: agentID, name: "Agent \(id)", executablePaths: [path.path], managedPaths: [path.path],
              identities: [path.path: DeletionPlan.identity(at: path.path)!])
    }
    static func seededCLI(_ fixture: URL) -> (AppState, AgentCLIInstallation, AgentCLIInstallation, AgentCLIInstallation) {
        reset()
        let state = AppState()
        let selected = cli("selected", agentID: "agent-one", path: fixture.appendingPathComponent("cli-one"))
        let neighbor = cli("neighbor", agentID: "agent-one", path: fixture.appendingPathComponent("cli-two"))
        let other = cli("other", agentID: "agent-other", path: fixture.appendingPathComponent("cli-other"))
        state.agentCLIInstallations = [selected, neighbor, other]
        state.commandLineTools = state.agentCLIInstallations.map { AgentSoftwareInventory.commandLineTool(for: $0) }
        state.softwareUpdateResults = ["cli:" + selected.managedPaths[0]: 1, "cli:" + neighbor.managedPaths[0]: 2,
                                       "cli:" + other.managedPaths[0]: 3]
        return (state, selected, neighbor, other)
    }
    static func assertCLIOnly(_ state: AppState, selected: AgentCLIInstallation,
                              neighbor: AgentCLIInstallation, other: AgentCLIInstallation) {
        precondition(state.agentCLIInstallations == [neighbor, other]
                     && state.commandLineTools.map(\.id) == [neighbor.id, other.id], "Uninstall changed another installation")
        precondition(state.dataOffers == [.init(agentIDs: [selected.agentID], programName: selected.name)],
                     "Successful installation removal must offer separate scoped data consent exactly once")
        precondition(state.storageInvalidations == 1 && state.resamples == 1 && !state.cleanupScanComplete)
        precondition(state.softwareUpdateResults.count == 2)
    }
    static func cliSuccessAndCancel(_ fixture: URL) async throws {
        let (state, selected, neighbor, other) = seededCLI(fixture)
        CLIUninstallWorkflow.results = [.finished(.init(succeeded: true))]
        state.externallyBusy = true
        state.uninstallAgentCLI(selected)
        precondition(state.isBusy && state.agentProgramBusyID != nil,
                     "The program probe must claim its own resource while another tab stays active")
        state.uninstallAgentCLI(selected)
        try await waitUntil { state.confirmation != nil }
        precondition(CLIUninstallWorkflow.calls.isEmpty && state.dataOffers.isEmpty,
                     "Initial installation consent cannot remove installation or data")
        state.confirmation = nil
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(CLIUninstallWorkflow.calls.isEmpty && state.dataOffers.isEmpty, "Cancellation executed removal")
        state.uninstallAgentCLI(selected)
        try await waitUntil { state.confirmation != nil }
        consent(state)
        try await waitUntil { !state.dataOffers.isEmpty }
        assertCLIOnly(state, selected: selected, neighbor: neighbor, other: other)
        precondition(CLIUninstallWorkflow.calls.count == 1
                     && CLIUninstallWorkflow.calls[0].installationID == selected.id
                     && CLIUninstallWorkflow.calls[0].identity == DeletionPlan.identity(at: selected.managedPaths[0]))
    }
    static func cliFaultsAndRenewedConsent(_ fixture: URL) async throws {
        for result in [CLIUninstallWorkflow.Result.failed(reasonKey: "fixture.changed"),
                       .finished(.init(succeeded: false, messages: ["fixture.managerFailed"]))] {
            let (state, selected, _, _) = seededCLI(fixture)
            CLIUninstallWorkflow.results = [result]
            state.uninstallAgentCLI(selected)
            try await waitUntil { state.confirmation != nil }
            consent(state)
            try await waitUntil { state.taskNotice != nil && state.agentProgramBusyID == nil }
            precondition(state.dataOffers.isEmpty && state.agentCLIInstallations.count == 3
                         && state.commandLineTools.count == 3 && state.storageInvalidations == 0)
        }
        let (state, selected, neighbor, other) = seededCLI(fixture)
        let running = SoftwareUpdateProcesses.Probe(processes: [.init(name: "Owned CLI")], isComplete: true)
        CLIUninstallWorkflow.results = [.needsConfirmation(running), .finished(.init(succeeded: true))]
        state.uninstallAgentCLI(selected)
        try await waitUntil { state.confirmation != nil }
        precondition(state.confirmation?.confirmLabel == "uninstall.action")
        consent(state)
        try await waitUntil { CLIUninstallWorkflow.calls.count == 1 && state.confirmation != nil }
        precondition(state.dataOffers.isEmpty && state.agentCLIInstallations.count == 3
                     && state.confirmation?.confirmLabel == "cli.uninstall.confirm.closeAction"
                     && state.confirmation!.message.contains("Owned CLI"), "New processes need a second consent prompt")
        consent(state)
        try await waitUntil { !state.dataOffers.isEmpty }
        precondition(CLIUninstallWorkflow.calls.map(\.mayClose) == [false, true])
        assertCLIOnly(state, selected: selected, neighbor: neighbor, other: other)

        let (cancelled, cancelledSelection, _, _) = seededCLI(fixture)
        CLIUninstallWorkflow.results = [.needsConfirmation(running), .finished(.init(succeeded: true))]
        cancelled.uninstallAgentCLI(cancelledSelection)
        try await waitUntil { cancelled.confirmation != nil }
        consent(cancelled)
        try await waitUntil { CLIUninstallWorkflow.calls.count == 1 && cancelled.confirmation != nil }
        cancelled.confirmation = nil
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(CLIUninstallWorkflow.calls.count == 1 && cancelled.dataOffers.isEmpty
                     && cancelled.agentCLIInstallations.count == 3,
                     "Cancelling renewed process consent must preserve installation and data")
    }
    static func runningAndSoftwareEntry(_ fixture: URL) async throws {
        let (state, selected, _, _) = seededCLI(fixture)
        state.agentCLIInstallations = [] // The software page does not depend on a prior Agent-page scan.
        ProgramProbeFixture.current.set(.init(processes: [.init(name: "Running owned CLI")], isComplete: true))
        CLIUninstallWorkflow.results = [.finished(.init(succeeded: true))]
        state.uninstallAgentTool(state.commandLineTools[0])
        try await waitUntil { state.confirmation != nil }
        precondition(state.confirmation?.confirmLabel == "cli.uninstall.confirm.closeAction"
                     && state.confirmation!.message.contains("cli.uninstall.confirm.running")
                     && state.dataOffers.isEmpty)
        consent(state)
        try await waitUntil { !state.dataOffers.isEmpty }
        precondition(CLIUninstallWorkflow.calls[0].mayClose && state.commandLineTools.count == 2
                     && state.dataOffers[0].agentIDs == [selected.agentID], "Both pages must share the selected installation flow")
    }
    static func desktop(_ fixture: URL, success: Bool) async throws {
        reset()
        let state = AppState()
        func app(_ name: String, bundle: String) -> UninstallApp {
            let path = fixture.appendingPathComponent(name + ".app").path
            return .init(name: name, bundleID: bundle, path: path,
                         appIdentity: DeletionPlan.identity(at: path)!,
                         infoIdentity: DeletionPlan.identity(at: path + "/Contents/Info.plist")!)
        }
        let selected = app("Chosen", bundle: "test.agent.one")
        let sameAgent = app("Other prefix", bundle: "test.agent.one")
        let otherAgent = app("Other agent", bundle: "test.agent.other")
        state.installedApps = [selected, sameAgent, otherAgent]
        state.agentApplications = ["agent-one": [selected, sameAgent], "shared-desktop": [selected], "agent-other": [otherAgent]]
        state.uninstallExecutor.results = [success ? .applied(.init(succeeded: true, removedPaths: [selected.path])) : .planUnavailable]
        state.uninstallAgentApplication(selected)
        try await waitUntil { state.confirmation != nil }
        precondition(state.uninstallExecutor.jobs.isEmpty && state.dataOffers.isEmpty)
        consent(state)
        try await waitUntil { !state.uninstallExecutor.jobs.isEmpty && state.agentProgramBusyID == nil }
        precondition(state.uninstallExecutor.jobs.count == 1 && state.uninstallExecutor.jobs[0].app == selected
                     && state.uninstallExecutor.jobs[0].plan == nil && state.uninstallExecutor.jobs[0].dataPaths.isEmpty
                     && state.uninstallExecutor.jobs[0].scope == .installationOnly,
                     "Desktop removal must capture only the chosen app, without implicit data selection")
        if success {
            precondition(state.installedApps == [sameAgent, otherAgent] && state.agentApplications["agent-one"] == [sameAgent]
                         && state.agentApplications["shared-desktop"]!.isEmpty
                         && state.agentApplications["agent-other"] == [otherAgent])
            precondition(state.dataOffers == [.init(agentIDs: ["agent-one", "shared-desktop"], programName: selected.name)])
        } else {
            precondition(state.installedApps.count == 3 && state.dataOffers.isEmpty && state.taskNotice != nil)
        }
    }
    static func guards(_ fixture: URL) async throws {
        for reason in 0..<7 {
            let (state, selected, _, _) = seededCLI(fixture)
            if reason == 0 { state.forcedAgentBusy = true }
            if reason == 1 { state.taskNotice = "existing notice" }
            if reason == 3 { state.commandLineToolBusyID = "another-tool" }
            if reason == 4 { state.softwareUpdatingID = "another-update" }
            if reason == 5 { state.isCleanupMutationBusy = true }
            if reason == 6 { state.uninstallQueue.activeJob = "other-app" }
            if reason == 2 { state.confirmation = .init(title: "existing", message: "", confirmLabel: "", onConfirm: {}) }
            state.uninstallAgentCLI(selected)
            try await Task.sleep(nanoseconds: 20_000_000)
            precondition(state.agentProgramBusyID == nil && CLIUninstallWorkflow.calls.isEmpty && state.dataOffers.isEmpty)
        }
        for reason in ["cleanup", "app-uninstall", "cli-uninstall", "software-update"] {
            let (blocked, item, _, _) = seededCLI(fixture)
            blocked.uninstallAgentCLI(item)
            try await waitUntil { blocked.confirmation != nil }
            if reason == "cleanup" { blocked.isCleanupMutationBusy = true }
            if reason == "app-uninstall" { blocked.uninstallQueue.activeJob = "other-app" }
            if reason == "cli-uninstall" { blocked.commandLineToolBusyID = "other-tool" }
            if reason == "software-update" { blocked.softwareUpdatingID = "other-update" }
            consent(blocked)
            precondition(blocked.agentProgramBusyID == nil && CLIUninstallWorkflow.calls.isEmpty
                         && blocked.dataOffers.isEmpty,
                         "An earlier Agent CLI consent crossed a later shared mutation")
        }
        let (state, selected, _, _) = seededCLI(fixture)
        state.uninstallAgentCLI(selected)
        try await waitUntil { state.confirmation != nil }
        state.agentCLIInstallations.removeAll { $0.id == selected.id }
        state.commandLineTools.removeAll { $0.id == selected.id }
        consent(state)
        try await Task.sleep(nanoseconds: 30_000_000)
        precondition(CLIUninstallWorkflow.calls.isEmpty && state.dataOffers.isEmpty,
                     "An accepted stale installation absent from both inventories must not execute")

        let (probing, probingSelection, _, _) = seededCLI(fixture)
        probing.uninstallAgentCLI(probingSelection)
        probing.agentCLIInstallations.removeAll { $0.id == probingSelection.id }
        probing.commandLineTools.removeAll { $0.id == probingSelection.id }
        try await waitUntil { probing.agentProgramBusyID == nil }
        precondition(probing.confirmation == nil && CLIUninstallWorkflow.calls.isEmpty,
                     "A stale inventory at the probe boundary must not create consent for a removed installation")

        let (interrupted, interruptedSelection, _, _) = seededCLI(fixture)
        interrupted.uninstallAgentCLI(interruptedSelection)
        interrupted.confirmation = .init(title: "other consent", message: "", confirmLabel: "", onConfirm: {})
        try await waitUntil { interrupted.agentProgramBusyID == nil }
        precondition(interrupted.confirmation?.title == "other consent" && CLIUninstallWorkflow.calls.isEmpty,
                     "A finishing process probe must not replace another confirmation")

        reset()
        let desktopState = AppState()
        let path = fixture.appendingPathComponent("Chosen.app").path
        let app = UninstallApp(name: "Chosen", bundleID: "test.agent.one", path: path,
            appIdentity: DeletionPlan.identity(at: path)!, infoIdentity: DeletionPlan.identity(at: path + "/Contents/Info.plist")!)
        for boundary in ["request", "confirmation"] {
            for reason in ["cleanup", "app-uninstall", "cli-uninstall", "software-update"] {
                reset()
                let blocked = AppState()
                blocked.agentApplications = ["agent-one": [app]]
                blocked.installedApps = [app]
                if boundary == "confirmation" {
                    blocked.uninstallAgentApplication(app)
                    try await waitUntil { blocked.confirmation != nil }
                }
                if reason == "cleanup" { blocked.isCleanupMutationBusy = true }
                if reason == "app-uninstall" { blocked.uninstallQueue.activeJob = "other-app" }
                if reason == "cli-uninstall" { blocked.commandLineToolBusyID = "other-tool" }
                if reason == "software-update" { blocked.softwareUpdatingID = "other-update" }
                if boundary == "request" { blocked.uninstallAgentApplication(app) }
                else { consent(blocked) }
                precondition(blocked.agentProgramBusyID == nil && blocked.uninstallExecutor.jobs.isEmpty
                             && blocked.dataOffers.isEmpty,
                             "Agent app removal crossed a shared mutation at the \(boundary) boundary")
            }
        }
        reset()
        desktopState.agentApplications = ["agent-one": [app]]
        desktopState.installedApps = [app]
        desktopState.uninstallAgentApplication(app)
        try await waitUntil { desktopState.confirmation != nil }
        desktopState.agentApplications = [:]
        desktopState.installedApps = []
        consent(desktopState)
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(desktopState.uninstallExecutor.jobs.isEmpty && desktopState.dataOffers.isEmpty,
                     "A removed desktop inventory entry must invalidate captured consent")

        reset()
        let unknownState = AppState()
        unknownState.agentApplications = ["agent-one": [app]]
        ProgramProbeFixture.current.set(.init(processes: [], isComplete: false))
        unknownState.uninstallAgentApplication(app)
        try await waitUntil { unknownState.taskNotice != nil && unknownState.agentProgramBusyID == nil }
        precondition(unknownState.confirmation == nil && unknownState.uninstallExecutor.jobs.isEmpty,
                     "Unknown desktop process state cannot become idle consent")
    }
    static func main() async throws {
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath().standardizedFileURL
        precondition(fixture.lastPathComponent.hasPrefix(".agent-program-fixture."), "Unowned program fixture")
        let fm = FileManager.default
        for name in ["cli-one", "cli-two", "cli-other"] { try Data("owned fixture".utf8).write(to: fixture.appendingPathComponent(name)) }
        for name in ["Chosen", "Other prefix", "Other agent"] {
            let contents = fixture.appendingPathComponent(name + ".app/Contents")
            try fm.createDirectory(at: contents, withIntermediateDirectories: true)
            try Data("owned fixture metadata".utf8).write(to: contents.appendingPathComponent("Info.plist"))
        }
        try await cliSuccessAndCancel(fixture)
        try await cliFaultsAndRenewedConsent(fixture)
        try await runningAndSoftwareEntry(fixture)
        try await desktop(fixture, success: true)
        try await desktop(fixture, success: false)
        try await guards(fixture)
        print("Agent program removal: selected-installation scope, renewed consent, cancellation, failure isolation and separate data offers passed")
    }
}
