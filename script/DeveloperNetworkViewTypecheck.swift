import SwiftUI

// Minimal shared APIs for independently checking the new panel while other
// workbench agents edit AppState and the neighboring views.
@MainActor final class AppState: ObservableObject {
    struct Confirmation {
        let title: String
        let message: String
        let confirmLabel: String
        let onConfirm: () -> Void
    }
    @Published var confirmation: Confirmation?
    @Published var isNetworkToolRunning = false
    @Published var networkToolStatus = ""
    func runAdminNetworkTask(_ task: String) {}
    func log(_ message: String) {}
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
    var display: String { ([executable] + arguments).joined(separator: " ") }
}
@MainActor final class DeveloperWorkspaceModel: ObservableObject {
    @Published var refreshRevision = 0
    @Published var commandRunning = false
    func enqueue(_ command: DeveloperCommand) {}
}
