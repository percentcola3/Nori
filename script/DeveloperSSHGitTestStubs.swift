import Foundation
import SwiftUI
struct DeveloperCommand {
    let titleKey: String
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let timeout: TimeInterval
    let privilegedArguments: [String]?
    var operationGroup: UUID? = nil
    var display: String { ([executable] + arguments).joined(separator: " ") }
}
enum DeveloperToolchainService {
    static func executable(_ name: String, environment: [String: String]) -> String? { environment["PATH"]?.hasPrefix("/") == true ? "/fixture/bin/" + name : nil }
}
enum DeveloperSecretRedactor { static func redact(_ value: String) -> String { value } }
struct DeveloperTerminalSnapshot { let environment: [String: String] }
@MainActor final class DeveloperWorkspaceModel: ObservableObject {
    @Published var refreshRevision = 0
    @Published var terminal = DeveloperTerminalSnapshot(environment: [:])
    func propose(_ command: DeveloperCommand?, state: AppState) {}
    func enqueue(_ command: DeveloperCommand) {}
    @discardableResult func runConfigurationWrite(titleKey: String, failureKey: String, operation: @escaping @MainActor () async throws -> Void) -> Bool { true }
}
@MainActor final class AppState: ObservableObject {
    struct Confirmation { let title: String; let message: String; let confirmLabel: String; let onConfirm: () -> Void }
    @Published var confirmation: Confirmation?
}
enum DeveloperWorkspaceSection { case sshGit }
struct DeveloperEnvironmentIssue {
    enum Severity { case attention, suggestion, information }
    let id: String; let titleKey: String; let detail: String; let section: DeveloperWorkspaceSection; let severity: Severity
}
struct RunResult { let output: String; let succeeded: Bool; let exitCode: Int32 }
final class MoleEngine {
    func run(executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) async -> RunResult { .init(output: "", succeeded: false, exitCode: 127) }
}
enum DeveloperCLIService {
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
