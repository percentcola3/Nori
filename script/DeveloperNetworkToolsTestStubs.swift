import SwiftUI
import Foundation
struct RunResult {
    let output: String
    let exitCode: Int32
    let timedOut: Bool
    var succeeded: Bool { exitCode == 0 && !timedOut }
}
final class MoleEngine {
    static let shared = MoleEngine()
    func standardEnvironment(_ extra: [String: String] = [:], includeHomebrew: Bool = true) -> [String: String] { extra }
    func run(executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL? = nil,
             timeout: TimeInterval, onLine: ((String) -> Void)? = nil) async -> RunResult { fatalError("Fixtures cannot run management or network commands") }
    func runPrivilegedBridge(_ path: String, arguments: [String], timeout: TimeInterval) async -> RunResult { fatalError("Fixtures cannot request authority") }
    func cancelAll() {}
}
enum DeveloperPrivilegedBridge { case xcode, proxy }
struct DeveloperCommand {
    let titleKey: String
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let timeout: TimeInterval
    let privilegedArguments: [String]?
    var privilegedBridge: DeveloperPrivilegedBridge = .xcode
    var operationGroup: UUID? = nil
    var display: String { ([executable] + arguments).joined(separator: " ") }
}
@MainActor final class DeveloperWorkspaceModel: ObservableObject {
    @Published var terminal = DeveloperTerminalEnvironmentService.fallback()
    @Published var refreshRevision = 0
    @Published var commandRunning = false
    func enqueue(_ command: DeveloperCommand) {}
    func refresh(forceEnvironment: Bool = false) async {}
    func didChangeEnvironment() {}
    @discardableResult func runConfigurationWrite(titleKey: String, failureKey: String = "dev.network.invalidSettings",
                                                  operation: @escaping @MainActor () async throws -> Void) -> Bool {
        fatalError("Fixtures cannot save configuration")
    }
}
enum DeveloperWorkspaceSection { case network }
struct DeveloperEnvironmentIssue {
    enum Severity { case information }
    let id: String
    let titleKey: String
    let detail: String
    let section: DeveloperWorkspaceSection
    let severity: Severity
}
@MainActor final class AppState: ObservableObject {
    struct Confirmation { let title: String; let message: String; let confirmLabel: String; let onConfirm: () -> Void }
    @Published var confirmation: Confirmation?
    @Published var isNetworkToolRunning = false
    @Published var networkToolStatus = ""
    var isBusy: Bool { false }
    func runAdminNetworkTask(_ task: String) {}
    func log(_ value: String) {}
}
