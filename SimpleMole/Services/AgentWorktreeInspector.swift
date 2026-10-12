import Darwin
import Foundation

enum AgentWorktreeState: String, Sendable {
    case clean, dirty, unmerged, orphaned, unknown
}

struct AgentWorktreeStatus: Sendable {
    let path: String
    let state: AgentWorktreeState
    let detail: String?
}

enum AgentWorktreeInspector {
    private static let outputLimit = 64 * 1024

    static func isWorktree(_ path: String) -> Bool {
        guard let contents = readFile(path + "/.git", maximumBytes: 4096) else { return false }
        return contents.hasPrefix("gitdir: ")
    }

    static func inspect(_ path: String, git: String? = resolvedGit(),
                        timeout: TimeInterval = 5) -> AgentWorktreeStatus {
        guard isWorktree(path), let git else { return .init(path: path, state: .unknown, detail: nil) }
        guard let contents = readFile(path + "/.git", maximumBytes: 4096),
              let firstLine = contents.split(whereSeparator: \Character.isNewline).first,
              firstLine.hasPrefix("gitdir: ") else {
            return .init(path: path, state: .unknown, detail: nil)
        }
        let rawGitDirectory = String(firstLine.dropFirst("gitdir: ".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawGitDirectory.isEmpty else { return .init(path: path, state: .unknown, detail: nil) }
        let gitDirectory = URL(fileURLWithPath: rawGitDirectory,
            relativeTo: URL(fileURLWithPath: path, isDirectory: true)).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitDirectory, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .init(path: path, state: .orphaned, detail: nil)
        }
        let commonFile = gitDirectory + "/commondir"
        if FileManager.default.fileExists(atPath: commonFile) {
            guard let rawCommon = readFile(commonFile, maximumBytes: 4096)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawCommon.isEmpty else {
                return .init(path: path, state: .orphaned, detail: nil)
            }
            let common = URL(fileURLWithPath: rawCommon,
                relativeTo: URL(fileURLWithPath: gitDirectory, isDirectory: true)).standardizedFileURL.path
            var commonIsDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: common, isDirectory: &commonIsDirectory),
                  commonIsDirectory.boolValue else {
                return .init(path: path, state: .orphaned, detail: nil)
            }
        }

        let status = run(git, ["-C", path, "status", "--porcelain=v1", "--untracked-files=all"],
            home: NSHomeDirectory(), timeout: timeout)
        guard status.succeeded else { return .init(path: path, state: .unknown, detail: nil) }
        let branch = run(git, ["-C", path, "symbolic-ref", "-q", "--short", "HEAD"],
            home: NSHomeDirectory(), timeout: timeout)
        let detail = branch.succeeded && !branch.output.isEmpty ? branch.output : nil
        guard status.output.isEmpty else { return .init(path: path, state: .dirty, detail: detail) }

        let head = run(git, ["-C", path, "rev-parse", "HEAD"], home: NSHomeDirectory(), timeout: timeout)
        guard head.succeeded, !head.output.isEmpty else {
            return .init(path: path, state: .unknown, detail: detail)
        }
        let refs = run(git, ["-C", path, "for-each-ref", "--format=%(refname)",
                             "--contains", head.output, "refs/heads", "refs/remotes"],
            home: NSHomeDirectory(), timeout: timeout)
        guard refs.succeeded else { return .init(path: path, state: .unknown, detail: detail) }
        let currentRef = detail.map { "refs/heads/" + $0 }
        let containingRefs = refs.output.split(whereSeparator: \Character.isNewline).map(String.init)
            .filter { $0 != currentRef }
        return .init(path: path, state: containingRefs.isEmpty ? .unmerged : .clean, detail: detail)
    }

    static func resolvedGit() -> String? {
        let fileManager = FileManager.default
        let homebrew = "/opt/homebrew/bin/git"
        let system = "/usr/bin/git"
        let xcodeSelect = "/usr/bin/xcode-select"
        if fileManager.isExecutableFile(atPath: xcodeSelect),
           run(xcodeSelect, ["-p"], home: NSHomeDirectory(), timeout: 2).succeeded,
           fileManager.isExecutableFile(atPath: system) {
            return system
        }
        return fileManager.isExecutableFile(atPath: homebrew) ? homebrew : nil
    }

    private static func readFile(_ path: String, maximumBytes: Int) -> String? {
        var metadata = stat()
        guard lstat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size <= off_t(maximumBytes),
              let data = FileManager.default.contents(atPath: path), data.count <= maximumBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func run(_ executable: String, _ arguments: [String], home: String,
                            timeout: TimeInterval) -> (succeeded: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let collector = OutputCollector(limit: outputLimit)
        let reachedEOF = DispatchSemaphore(value: 0)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                reachedEOF.signal()
            } else { collector.append(data) }
        }
        defer {
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        do { try process.run() } catch { return (false, "") }
        try? pipe.fileHandleForWriting.close()
        let timedOut = completed.wait(timeout: .now() + max(0.05, timeout)) == .timedOut
        if timedOut, process.isRunning {
            process.terminate()
            if completed.wait(timeout: .now() + 0.1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = completed.wait(timeout: .now() + 0.1)
            }
        }
        _ = reachedEOF.wait(timeout: .now() + 0.1)
        return (!timedOut && !process.isRunning && process.terminationStatus == 0,
                collector.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let limit: Int

        init(limit: Int) { self.limit = limit }

        func append(_ incoming: Data) {
            lock.lock()
            defer { lock.unlock() }
            data.append(incoming.prefix(max(0, limit - data.count)))
        }

        var output: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
