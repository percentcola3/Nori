import Darwin
import Foundation

/// Fixed argv only; bounded output and lifetime. No shell and no prompts.
final class AgentHistoryProcess: @unchecked Sendable {
    struct Output: Sendable {
        let status: Int32
        let data: Data
        let timedOut: Bool
        let overflowed: Bool
    }

    let process = Process()
    let input = Pipe()
    let output = Pipe()
    private let finished = DispatchSemaphore(value: 0)

    init(context: AgentHistoryContext, arguments: [String], environment: [String: String] = [:]) throws {
        try context.checkExecutable()
        process.executableURL = URL(fileURLWithPath: context.executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: context.project)
        process.environment = CLICommandEnvironment.make(home: context.home, searchPath: context.searchPath,
            executable: context.executable, overrides: environment)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.terminationHandler = { [finished] _ in finished.signal() }
    }

    func start() throws {
        do { try process.run() } catch { throw AgentHistoryFailure("agents.history.error.launch") }
        try? output.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
    }

    func close() {
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            if finished.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 0.5)
            }
        }
        output.fileHandleForReading.readabilityHandler = nil
        try? output.fileHandleForReading.close()
    }

    deinit { close() }

    static func run(context: AgentHistoryContext, arguments: [String], timeout: TimeInterval = 30,
                    environment: [String: String] = [:]) async throws -> Output {
        try await Task.detached(priority: .utility) {
            let child = try AgentHistoryProcess(context: context, arguments: arguments, environment: environment)
            let collector = Collector()
            let eof = DispatchSemaphore(value: 0)
            child.output.fileHandleForReading.readabilityHandler = { handle in
                let data = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
                if data.isEmpty { eof.signal(); return }
                collector.append(data)
            }
            defer { child.close() }
            try child.start()
            try? child.input.fileHandleForWriting.close()
            let timedOut = child.finished.wait(timeout: .now() + timeout) == .timedOut
            if timedOut { child.close() }
            _ = eof.wait(timeout: .now() + 0.5)
            return Output(status: child.process.isRunning ? -1 : child.process.terminationStatus,
                          data: collector.data, timedOut: timedOut, overflowed: collector.overflowed)
        }.value
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        private var tooLarge = false
        func append(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            let room = max(0, 2 * 1024 * 1024 - storage.count)
            if data.count > room { tooLarge = true }
            storage.append(data.prefix(room))
        }
        var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
        var overflowed: Bool { lock.lock(); defer { lock.unlock() }; return tooLarge }
    }
}

enum AgentHistoryProcessGuard {
    /// Exclude only this operation's child and descendants. A newly launched
    /// peer remains a blocker, even if it appeared after the inventory scan.
    static func requireIdle(_ context: AgentHistoryContext, excluding owned: Set<Int32> = []) async throws {
        let ps = AgentHistoryContext(provider: context.provider, project: context.project, home: context.home,
            executable: "/bin/ps", executableIdentity: DeletionPlan.identity(at: "/bin/ps") ?? "",
            searchPath: context.searchPath)
        let output = try await AgentHistoryProcess.run(context: ps,
            arguments: ["-axo", "pid=,ppid=,comm=,args="], timeout: 5)
        guard output.status == 0, !output.timedOut, !output.overflowed,
              let text = String(data: output.data, encoding: .utf8), !text.isEmpty else {
            throw AgentHistoryFailure("agents.history.error.runtime")
        }
        var rows: [(pid: Int32, parent: Int32, command: String)] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
            guard parts.count == 3, let pid = Int32(parts[0]), let parent = Int32(parts[1]) else {
                throw AgentHistoryFailure("agents.history.error.runtime")
            }
            rows.append((pid, parent, String(parts[2]).lowercased()))
        }
        var excluded = owned
        var changed = true
        while changed {
            let previous = excluded.count
            rows.filter { excluded.contains($0.parent) }.forEach { excluded.insert($0.pid) }
            changed = previous != excluded.count
        }
        let markers: [String]
        switch context.provider {
        case .opencode: markers = ["opencode"]
        case .copilot: markers = ["copilot", "@github/copilot"]
        case .gemini: markers = ["gemini", "@google/gemini-cli"]
        }
        let patterns = markers.map { #"(?:^|[/\s])"# + NSRegularExpression.escapedPattern(for: $0) + #"(?:$|[/\s.])"# }
        if rows.contains(where: { row in
            !excluded.contains(row.pid) && patterns.contains {
                row.command.range(of: $0, options: .regularExpression) != nil
            }
        }) { throw AgentHistoryFailure("agents.history.error.running") }
    }
}
