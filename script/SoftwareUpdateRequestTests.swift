import Foundation

struct UninstallApp {
    let name: String
    let path: String
    let bundleID: String?
    var appIdentity: String? { "fixture-app" }
}
struct CommandLineTool { let name: String; let path: String }
struct SoftwareUpdateResult {
    enum State { case available, current }
    let state: State
    let latest: String?
}
enum SoftwareUpdateService {
    static func appKey(_ app: UninstallApp) -> String { "app:" + app.path }
    static func toolKey(_ tool: CommandLineTool) -> String { "tool:" + tool.path }
}
enum DeletionPlan { static func identity(at path: String) -> String? { "fixture-identity" } }
struct ProcessSample: Sendable { let name: String }
enum SoftwareUpdateProcesses {
    struct Probe: Sendable { let isComplete: Bool; let processes: [ProcessSample] }
    static func probe(_ scope: Int) -> Probe { ProbeFixture.shared.probe() }
}
final class ProbeFixture: @unchecked Sendable {
    static let shared = ProbeFixture()
    private let lock = NSLock()
    private var running = false
    func setRunning(_ value: Bool) { lock.lock(); running = value; lock.unlock() }
    func probe() -> SoftwareUpdateProcesses.Probe {
        lock.lock(); defer { lock.unlock() }
        return .init(isComplete: true, processes: running ? [.init(name: "fixture")] : [])
    }
}
final class L10n {
    static let shared = L10n()
    func t(_ key: String) -> String { key }
    func tf(_ key: String, _ arguments: CVarArg...) -> String { key }
}
@MainActor
final class AppUpdateController {
    static let shared = AppUpdateController()
    var canCheckForUpdates = true
    var acceptedChecks = 0
    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        acceptedChecks += 1
    }
}

@MainActor
final class AppState {
    var externallyBusy = false
    var softwareBusy = false
    var isApplying = false
    var isSystemMaintenanceRunning = false
    var isAutoCleanupMutationActive = false
    var agentApplying = false
    var agentProgramBusyID: String?
    var isCheckingSoftwareUpdates = false
    struct Confirmation {
        let title: String
        let message: String
        let confirmLabel: String
        let onConfirm: () -> Void
    }
    var confirmation: Confirmation?
    var taskNotice: String?
    var softwareUpdateResults: [String: SoftwareUpdateResult] = [:]
    var softwareUpdatingID: String?
    var isSoftwareTaskBusy: Bool { softwareBusy || softwareUpdatingID != nil }
    var isBusy: Bool { externallyBusy || isSoftwareTaskBusy || isSoftwareMutationBlocked }
    // PRODUCTION_MUTATION_GATES
    var scopeRequests = 0
    var installations = 0
    var failures = 0
}

@MainActor
extension AppState {
    // PRODUCTION_SELECTION
    // PRODUCTION_REQUEST

    func requestFixture(_ app: UninstallApp) { requestSoftwareUpdate(.app(app, token: nil)) }
    private func updateProcessScope(_ selection: UpdateSelection) -> Int { scopeRequests += 1; return 0 }
    private func softwareUpdateFailed(_ selection: UpdateSelection, reason: String) {
        failures += 1
        softwareUpdatingID = nil
    }
    // PRODUCTION_CLOSE_CONFIRMATION
    private func performSoftwareUpdate(_ selection: UpdateSelection, result: SoftwareUpdateResult,
                                       identity: String?, mayClose: Bool) async {
        installations += 1
        softwareUpdatingID = nil
    }
}

@main
struct SoftwareUpdateRequestTests {
    @MainActor
    static func main() async throws {
        let state = AppState()
        let app = UninstallApp(name: "Nori", path: Bundle.main.bundleURL.path,
                               bundleID: Bundle.main.bundleIdentifier)
        let other = UninstallApp(name: "Nori", path: "/fixture/another/Nori.app", bundleID: app.bundleID)
        for item in [app, other] {
            state.softwareUpdateResults[SoftwareUpdateService.appKey(item)] = .init(state: .available, latest: "2.0")
        }
        state.externallyBusy = true
        state.softwareBusy = true
        state.agentApplying = true
        state.isApplying = true
        state.confirmation = .init(title: "another tab", message: "", confirmLabel: "", onConfirm: {})
        state.taskNotice = "another tab's result"
        state.requestFixture(app)
        precondition(state.isBusy && AppUpdateController.shared.acceptedChecks == 1
                     && state.scopeRequests == 0 && state.softwareUpdatingID == nil,
                     "Nori's signed updater must remain independent of page activity and app dialogs")
        AppUpdateController.shared.canCheckForUpdates = false
        state.requestFixture(app)
        precondition(AppUpdateController.shared.acceptedChecks == 1,
                     "The signed updater must own its own duplicate-check protection")
        state.requestFixture(other)
        precondition(AppUpdateController.shared.acceptedChecks == 1 && state.scopeRequests == 0,
                     "An app at another path must not inherit Nori's self-update route")

        state.softwareBusy = false
        state.agentApplying = false
        state.isApplying = false
        state.confirmation = nil
        state.taskNotice = nil
        state.requestFixture(other)
        state.requestFixture(other)
        precondition(state.softwareUpdatingID == SoftwareUpdateService.appKey(other),
                     "A software update must claim its own task before yielding")
        let deadline = Date().addingTimeInterval(3)
        while state.installations == 0 {
            precondition(Date() < deadline)
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        precondition(state.externallyBusy && state.installations == 1 && state.scopeRequests == 1,
                     "Another tab must not block a software update or permit duplicate execution")
        AppUpdateController.shared.canCheckForUpdates = true
        state.softwareUpdateResults[SoftwareUpdateService.appKey(app)] = .init(state: .current, latest: "2.0")
        state.requestFixture(app)
        state.softwareUpdateResults[SoftwareUpdateService.appKey(app)] = .init(state: .available, latest: nil)
        state.requestFixture(app)
        precondition(AppUpdateController.shared.acceptedChecks == 1,
                     "Unavailable or incomplete metadata must not start the self-update route")
        for gate in ["cleanup", "automatic-cleanup", "agent-data", "agent-program"] {
            for boundary in ["request", "confirmation"] {
                let blocked = AppState()
                blocked.externallyBusy = true
                blocked.softwareUpdateResults[SoftwareUpdateService.appKey(other)] = .init(state: .available, latest: "2.0")
                ProbeFixture.shared.setRunning(boundary == "confirmation")
                if boundary == "confirmation" {
                    blocked.requestFixture(other)
                    let deadline = Date().addingTimeInterval(3)
                    while blocked.confirmation == nil {
                        precondition(Date() < deadline)
                        try await Task.sleep(nanoseconds: 5_000_000)
                    }
                }
                if gate == "cleanup" { blocked.isApplying = true }
                if gate == "automatic-cleanup" { blocked.isAutoCleanupMutationActive = true }
                if gate == "agent-data" { blocked.agentApplying = true }
                if gate == "agent-program" { blocked.agentProgramBusyID = "another-program" }
                if boundary == "request" { blocked.requestFixture(other) }
                else {
                    let consent = blocked.confirmation!
                    blocked.confirmation = nil
                    consent.onConfirm()
                }
                precondition(blocked.softwareUpdatingID == nil && blocked.installations == 0,
                             "Software update crossed a shared mutation at the \(boundary) boundary")
            }
        }
        ProbeFixture.shared.setRunning(false)
        print("Software update requests: independent Nori checks, signed-updater reentry, exact app identity, per-page updates and duplicate protection passed")
    }
}
