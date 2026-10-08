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
enum SoftwareUpdateProcesses {
    struct Probe { let isComplete = true; let processes: [Int] = [] }
    static func probe(_ scope: Int) -> Probe { .init() }
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
    var isAgentCLIMutationActive = false
    var confirmation: String?
    var taskNotice: String?
    var softwareUpdateResults: [String: SoftwareUpdateResult] = [:]
    var softwareUpdatingID: String?
    var isSoftwareTaskBusy: Bool { softwareBusy || softwareUpdatingID != nil }
    var isBusy: Bool { externallyBusy || isSoftwareTaskBusy || isAgentCLIMutationActive }
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
    private func presentUpdateCloseConfirmation(_ selection: UpdateSelection, result: SoftwareUpdateResult,
                                                identity: String?, processes: [Int]) {
        preconditionFailure("The fixture has no running process")
    }
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
        state.isAgentCLIMutationActive = true
        state.confirmation = "another tab's confirmation"
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
        state.isAgentCLIMutationActive = false
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
        print("Software update requests: independent Nori checks, signed-updater reentry, exact app identity, per-page updates and duplicate protection passed")
    }
}
