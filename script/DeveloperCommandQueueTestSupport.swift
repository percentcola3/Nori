import Foundation
import Combine

// Dependency doubles isolate the real workspace scheduler and terminal sampler
// from installed toolchains, package managers, authorization, and shell startup.
struct RunResult: Sendable {
    let output: String
    var errorOutput = ""
    let exitCode: Int32
    let timedOut: Bool
    var succeeded: Bool { exitCode == 0 && !timedOut }
}

actor DeveloperQueueFixture {
    static let shared = DeveloperQueueFixture()

    struct Invocation: Sendable {
        let id: UUID
        let engineID: UUID
        let path: String
        let arguments: [String]
        let environment: [String: String]
        var key: String { DeveloperQueueFixture.key(path, arguments) }
        var isManagementCommand: Bool { path.hasPrefix("/fixture/") }
    }
    struct Snapshot: Sendable {
        let invocations: [Invocation]
        let activeCommands: Int
        let maximumActiveCommands: Int
        let cancellations: Int
    }
    private struct Pending {
        let invocation: Invocation
        let continuation: CheckedContinuation<RunResult, Never>
    }
    private struct StartWaiter {
        let key: String
        let occurrence: Int
        let continuation: CheckedContinuation<Invocation, Never>
    }

    private var allowedKeys: Set<String> = []
    private var invocations: [Invocation] = []
    private var pending: [UUID: Pending] = [:]
    private var startWaiters: [StartWaiter] = []
    private var activeCommands = 0
    private var maximumActiveCommands = 0
    private var cancellations = 0
    private var cancellationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    nonisolated static func key(_ path: String, _ arguments: [String] = []) -> String {
        ([path] + arguments).joined(separator: "\0")
    }

    func reset(allowed: [String]) {
        precondition(pending.isEmpty && startWaiters.isEmpty, "Previous queue fixture has unfinished work")
        allowedKeys = Set(allowed)
        invocations = []
        activeCommands = 0
        maximumActiveCommands = 0
        cancellations = 0
    }

    func run(engineID: UUID, path: String, arguments: [String], environment: [String: String]) async -> RunResult {
        precondition(path.hasPrefix("/fixture/commands/") || path.hasPrefix("/fixture/bridge/")
                     || (path == "/usr/bin/xcode-select" && arguments == ["-p"]),
                     "Queue fixture attempted a real shell or management command: " + path)
        let invocation = Invocation(id: UUID(), engineID: engineID, path: path,
                                    arguments: arguments, environment: environment)
        precondition(allowedKeys.contains(invocation.key), "Unregistered queue fixture command: " + path)
        return await withCheckedContinuation { continuation in
            invocations.append(invocation)
            pending[invocation.id] = Pending(invocation: invocation, continuation: continuation)
            if invocation.isManagementCommand {
                activeCommands += 1
                maximumActiveCommands = max(maximumActiveCommands, activeCommands)
            }
            let matching = invocations.filter { $0.key == invocation.key }
            let ready = startWaiters.filter { $0.key == invocation.key && $0.occurrence <= matching.count }
            startWaiters.removeAll { $0.key == invocation.key && $0.occurrence <= matching.count }
            for waiter in ready { waiter.continuation.resume(returning: matching[waiter.occurrence - 1]) }
        }
    }

    func waitForCall(_ path: String, arguments: [String] = [], occurrence: Int = 1) async -> Invocation {
        precondition(occurrence > 0)
        let key = Self.key(path, arguments)
        let matching = invocations.filter { $0.key == key }
        if matching.count >= occurrence { return matching[occurrence - 1] }
        return await withCheckedContinuation { continuation in
            startWaiters.append(.init(key: key, occurrence: occurrence, continuation: continuation))
        }
    }

    func release(_ invocation: Invocation, result: RunResult = .init(output: "fixture completed", exitCode: 0, timedOut: false)) {
        guard let item = pending.removeValue(forKey: invocation.id) else {
            preconditionFailure("Queue fixture released a call that is no longer pending")
        }
        if item.invocation.isManagementCommand { activeCommands -= 1 }
        item.continuation.resume(returning: result)
    }

    func cancel(engineID: UUID) {
        cancellations += 1
        for id in pending.values.filter({ $0.invocation.engineID == engineID }).map({ $0.invocation.id }) {
            let item = pending.removeValue(forKey: id)!
            if item.invocation.isManagementCommand { activeCommands -= 1 }
            item.continuation.resume(returning: .init(output: "fixture cancelled", exitCode: 143, timedOut: false))
        }
        let ready = cancellationWaiters.filter { $0.0 <= cancellations }
        cancellationWaiters.removeAll { $0.0 <= cancellations }
        for waiter in ready { waiter.1.resume() }
    }

    func waitForCancellation(count: Int = 1) async {
        if cancellations >= count { return }
        await withCheckedContinuation { cancellationWaiters.append((count, $0)) }
    }

    func snapshot() -> Snapshot {
        .init(invocations: invocations, activeCommands: activeCommands,
              maximumActiveCommands: maximumActiveCommands, cancellations: cancellations)
    }
}

// This engine has no Process, shell, or authorization implementation. Every
// invocation stays suspended until the fixture releases its async gate.
final class MoleEngine: @unchecked Sendable {
    static let shared = MoleEngine()
    private let id = UUID()
    func standardEnvironment(includeHomebrew: Bool = true) -> [String: String] { ["PATH": "/usr/bin:/bin"] }
    func run(executable: URL, arguments: [String], environment: [String: String] = [:],
             currentDirectory: URL? = nil, timeout: TimeInterval,
             onLine: ((String) -> Void)? = nil) async -> RunResult {
        let result = await DeveloperQueueFixture.shared.run(engineID: id, path: executable.path,
                                                            arguments: arguments, environment: environment)
        onLine?(result.output)
        return result
    }
    func runPrivilegedBridge(_ bridge: String, arguments: [String], timeout: TimeInterval) async -> RunResult {
        await DeveloperQueueFixture.shared.run(engineID: id, path: "/fixture/bridge/" + bridge,
                                               arguments: arguments, environment: [:])
    }
    func cancelAll() {
        Task { await DeveloperQueueFixture.shared.cancel(engineID: id) }
    }
}

@MainActor
final class AppState: ObservableObject {
    struct Confirmation {
        let title: String
        let message: String
        let confirmLabel: String
        let action: () -> Void
    }
    @Published var isDeveloperCommandRunning = false
    @Published var externalBusy = false
    var isBusy: Bool { externalBusy || isDeveloperCommandRunning }
    var confirmation: Confirmation?
}

final class L10n {
    static let shared = L10n()
    func t(_ key: String) -> String { key }
    func tf(_ key: String, _ arguments: CVarArg...) -> String { key }
}

enum DeveloperCLIService {
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum DeveloperToolchainService {
    static func inventory(environment: [String: String]) -> [DeveloperManagedVersion] { [] }
    static func javaHomes(environment: [String: String]) -> [String] { [] }
    static func defaultVersion(_ manager: DeveloperManager, candidate: String,
                               environment: [String: String], home: String) -> String? { nil }
    static func defaultVersions(_ manager: DeveloperManager, candidate: String,
                                environment: [String: String], home: String) -> [String] { [] }
    static func command(manager: DeveloperManager, operation: DeveloperToolchainOperation,
                        version: String, candidate: String, environment: [String: String]) -> DeveloperCommand? { nil }
    static func validIdentifier(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$"#, options: .regularExpression) != nil
    }
}

enum DeveloperPackageService {
    struct Inventory { var packages: [String] = []; var services: [String] = [] }
    static func scan(environment: [String: String], checkUpdates: Bool) async -> Inventory { .init() }
}

enum DeveloperShellProfiler {
    struct Result { let median: TimeInterval?; let functions: String; let failed: Bool }
    static func profile(engine: MoleEngine) async -> Result { .init(median: nil, functions: "", failed: true) }
}

enum DeveloperSSHGitService {
    static func connectionSucceeded(output: String, exitCode: Int32) -> Bool { exitCode == 0 }
}
