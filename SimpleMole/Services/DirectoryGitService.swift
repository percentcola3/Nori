import Foundation

struct DirectoryGitSnapshot: Equatable, Sendable {
    let root: URL
    let branch: String?
    let head: String
    let branches: [String]
    let occupiedBranches: Set<String>
    let upstream: String?
    let isDirty: Bool
    let operationInProgress: Bool
    let aheadCount: Int
    let behindCount: Int
}

actor DirectoryGitService {
    enum Failure: LocalizedError, Equatable {
        case unavailable, notRepository, dirty, operationInProgress, branchUnavailable, branchOccupied
        case noUpstream, detached, timeout, outputTooLarge, cancelled, repositoryChanged
        case command(String)

        var errorDescription: String? {
            switch self {
            case .unavailable: return L10n.shared.t("dir.git.unavailable")
            case .notRepository: return L10n.shared.t("dir.git.notRepository")
            case .dirty: return L10n.shared.t("dir.git.dirty")
            case .operationInProgress: return L10n.shared.t("dir.git.operationInProgress")
            case .branchUnavailable: return L10n.shared.t("dir.git.branchUnavailable")
            case .branchOccupied: return L10n.shared.t("dir.git.branchOccupied")
            case .noUpstream: return L10n.shared.t("dir.git.noUpstream")
            case .detached: return L10n.shared.t("dir.git.detached")
            case .timeout: return L10n.shared.t("dir.git.timeout")
            case .outputTooLarge: return L10n.shared.t("dir.git.outputTooLarge")
            case .cancelled: return L10n.shared.t("dir.git.cancelled")
            case .repositoryChanged: return L10n.shared.t("dir.git.repositoryChanged")
            case .command(let message): return L10n.shared.tf("dir.git.failed", message)
            }
        }
    }

    private final class Execution: @unchecked Sendable {
        let engine = MoleEngine()
        private let lock = NSLock()
        private var revision: UInt64 = 0

        var token: UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return revision
        }

        func cancel() {
            lock.lock()
            revision &+= 1
            lock.unlock()
            engine.cancelAll()
        }
    }

    private struct Context {
        let executable: String
        let environment: [String: String]
        let token: UInt64
    }

    private nonisolated let execution = Execution()
    private let suppliedExecutable: String?
    private let suppliedEnvironment: [String: String]?
    private var isMutating = false
    private let captureLimit: Int

    init(executable: String? = nil, environment: [String: String]? = nil, captureLimit: Int = 256 * 1024) {
        suppliedExecutable = executable
        suppliedEnvironment = environment
        self.captureLimit = max(1, captureLimit)
    }

    nonisolated func cancel() { execution.cancel() }

    func snapshot(at directory: URL) async throws -> DirectoryGitSnapshot {
        let context = try await context()
        return try await inspect(directory, context: context)
    }

    func switchBranch(_ name: String, at directory: URL) async throws {
        guard !isMutating else { throw Failure.operationInProgress }
        isMutating = true
        defer { isMutating = false }
        let context = try await context()
        let current = try await inspect(directory, context: context)
        try requireClean(current)
        guard current.branches.contains(name) else { throw Failure.branchUnavailable }
        guard !current.occupiedBranches.contains(name) else { throw Failure.branchOccupied }
        guard name != current.branch else { return }
        _ = try await run(["switch", "--no-guess", "--no-overwrite-ignore", "--", name],
                          at: current.root, context: context, timeout: 30, requiresCompleteOutput: false)
    }

    func pull(at directory: URL) async throws {
        guard !isMutating else { throw Failure.operationInProgress }
        isMutating = true
        defer { isMutating = false }
        let context = try await context()
        let current = try await inspect(directory, context: context)
        try requireClean(current)
        guard let branch = current.branch else { throw Failure.detached }
        guard current.upstream != nil else { throw Failure.noUpstream }
        let tracking = try await run(["for-each-ref", "--format=%(upstream:remotename)%00%(upstream:remoteref)",
                                      "refs/heads/" + branch], at: current.root, context: context)
            .trimmingCharacters(in: .newlines).components(separatedBy: "\0")
        guard tracking.count == 2, tracking.allSatisfy({ !$0.isEmpty && !$0.contains("\n") }),
              tracking[1].hasPrefix("refs/") else { throw Failure.noUpstream }
        // `pull` cannot forward --no-overwrite-ignore. Fetch, then fast-forward
        // explicitly so ignored local files receive the same protection as switch.
        _ = try await run(["fetch", "--no-recurse-submodules", "--", tracking[0], tracking[1]],
                          at: current.root, context: context, timeout: 120, requiresCompleteOutput: false)
        let fetchedHead = try await run(["rev-parse", "--verify", "FETCH_HEAD^{commit}"], at: current.root, context: context)
            .trimmingCharacters(in: .newlines)
        guard fetchedHead.range(of: #"^(?:[0-9a-f]{40}|[0-9a-f]{64})$"#, options: .regularExpression) != nil else {
            throw Failure.repositoryChanged
        }
        let refreshed = try await inspect(current.root, context: context)
        guard refreshed.branch == current.branch, refreshed.head == current.head,
              refreshed.upstream == current.upstream else { throw Failure.repositoryChanged }
        try requireClean(refreshed)
        _ = try await run(["merge", "--ff-only", "--no-squash", "--no-autostash", "--no-edit", "--no-overwrite-ignore", fetchedHead],
                          at: current.root, context: context, timeout: 30, requiresCompleteOutput: false)
    }

    private func context() async throws -> Context {
        let token = execution.token
        let sampled = suppliedEnvironment ?? DeveloperTerminalEnvironmentService.fallback().environment
        guard !Task.isCancelled, token == execution.token else { throw Failure.cancelled }
        let executable = try await localGit(environment: sampled, token: token)
        // Ignore inherited Git location overrides; every command targets the checked directory.
        let filtered = sampled.filter { !$0.key.hasPrefix("GIT_") }
        var environment = DeveloperSSHGitService.commandEnvironment(filtered, home: sampled["HOME"] ?? NSHomeDirectory())
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_ASKPASS"] = "/usr/bin/false"
        environment["SSH_ASKPASS"] = "/usr/bin/false"
        environment["SSH_ASKPASS_REQUIRE"] = "never"
        environment["GCM_INTERACTIVE"] = "never"
        return Context(executable: executable, environment: environment, token: token)
    }

    private func localGit(environment: [String: String], token: UInt64) async throws -> String {
        guard let candidate = suppliedExecutable ?? DeveloperToolchainService.executable("git", environment: environment),
              Self.isExecutableFile(candidate) else { throw Failure.unavailable }
        guard URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path == "/usr/bin/git" else {
            return candidate
        }

        // The macOS shim can open an installer. Only run the already-installed Git behind it.
        let developerDirectory: String
        if let configured = environment["DEVELOPER_DIR"], !configured.isEmpty {
            developerDirectory = configured
        } else {
            let result = await withTaskCancellationHandler {
                await execution.engine.run(executable: URL(fileURLWithPath: "/usr/bin/xcode-select"),
                                           arguments: ["-p"], environment: environment, timeout: 3, captureLimit: 4096)
            } onCancel: { execution.cancel() }
            guard !Task.isCancelled, token == execution.token else { throw Failure.cancelled }
            guard result.succeeded, !result.outputTruncated else { throw Failure.unavailable }
            developerDirectory = result.output.trimmingCharacters(in: .newlines)
        }
        guard developerDirectory.hasPrefix("/"), !developerDirectory.contains("\n") else { throw Failure.unavailable }
        let directory = URL(fileURLWithPath: developerDirectory)
        for suffix in ["usr/bin/git", "Contents/Developer/usr/bin/git"] {
            let path = directory.appendingPathComponent(suffix).resolvingSymlinksInPath().path
            if path != "/usr/bin/git", Self.isExecutableFile(path) { return path }
        }
        throw Failure.unavailable
    }

    private static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }

    private func inspect(_ directory: URL, context: Context) async throws -> DirectoryGitSnapshot {
        let expectedRoot = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard expectedRoot.isFileURL,
              FileManager.default.fileExists(atPath: expectedRoot.appendingPathComponent(".git").path) else {
            throw Failure.notRepository
        }
        let paths = try await run(["rev-parse", "--show-toplevel", "--absolute-git-dir"], at: expectedRoot, context: context)
        let lines = paths.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count == 3, lines[2].isEmpty, lines[0].hasPrefix("/"), lines[1].hasPrefix("/") else {
            throw Failure.notRepository
        }
        let root = URL(fileURLWithPath: String(lines[0])).standardizedFileURL.resolvingSymlinksInPath()
        guard root.path == expectedRoot.path else { throw Failure.notRepository }
        let gitDirectory = URL(fileURLWithPath: String(lines[1]))
        let status = try await run(["status", "--porcelain=v2", "--branch", "--untracked-files=normal", "--ignore-submodules=none", "-z"],
                                   at: root, context: context)
        var branch: String?, upstream: String?, head: String?
        var dirty = false
        var ahead = 0, behind = 0
        var isRenameSource = false
        for field in status.split(separator: "\0") {
            if isRenameSource { isRenameSource = false; continue }
            if field.hasPrefix("# branch.head ") {
                let name = String(field.dropFirst("# branch.head ".count))
                branch = name == "(detached)" ? nil : name
            } else if field.hasPrefix("# branch.oid ") {
                head = String(field.dropFirst("# branch.oid ".count))
            } else if field.hasPrefix("# branch.upstream ") {
                upstream = String(field.dropFirst("# branch.upstream ".count))
            } else if field.hasPrefix("# branch.ab ") {
                let counts = field.dropFirst("# branch.ab ".count).split(separator: " ")
                if counts.count == 2 {
                    ahead = max(0, Int(counts[0]) ?? 0)
                    behind = max(0, -(Int(counts[1]) ?? 0))
                }
            } else if !field.hasPrefix("# ") {
                dirty = true
                isRenameSource = field.hasPrefix("2 ")
            }
        }
        guard let head else { throw Failure.notRepository }
        let refs = try await run(["for-each-ref", "--format=%(refname)%00%(worktreepath)%00", "refs/heads/"],
                                at: root, context: context)
        let fields = refs.components(separatedBy: "\0")
        var branches: [String] = []
        var occupied: Set<String> = []
        var index = 0
        while index + 1 < fields.count {
            let ref = fields[index].trimmingCharacters(in: .newlines)
            guard ref.hasPrefix("refs/heads/") else { throw Failure.branchUnavailable }
            let name = String(ref.dropFirst("refs/heads/".count))
            branches.append(name)
            let worktree = fields[index + 1]
            if !worktree.isEmpty, URL(fileURLWithPath: worktree).resolvingSymlinksInPath().path != root.path {
                occupied.insert(name)
            }
            index += 2
        }
        guard fields[index].trimmingCharacters(in: .newlines).isEmpty else { throw Failure.branchUnavailable }
        let markers = ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer", "BISECT_LOG"]
        let inProgress = markers.contains { FileManager.default.fileExists(atPath: gitDirectory.appendingPathComponent($0).path) }
        return .init(root: root, branch: branch, head: head, branches: branches, occupiedBranches: occupied,
                     upstream: upstream, isDirty: dirty, operationInProgress: inProgress,
                     aheadCount: ahead, behindCount: behind)
    }

    private func requireClean(_ snapshot: DirectoryGitSnapshot) throws {
        guard !snapshot.operationInProgress else { throw Failure.operationInProgress }
        guard !snapshot.isDirty else { throw Failure.dirty }
    }

    private func run(_ arguments: [String], at root: URL, context: Context, timeout: TimeInterval = 10,
                     requiresCompleteOutput: Bool = true) async throws -> String {
        guard !Task.isCancelled, context.token == execution.token else { throw Failure.cancelled }
        let result = await withTaskCancellationHandler {
            await execution.engine.run(executable: URL(fileURLWithPath: context.executable),
                                       arguments: ["-c", "submodule.recurse=false"] + arguments,
                                       environment: context.environment, currentDirectory: root,
                                       timeout: timeout, captureLimit: captureLimit)
        } onCancel: { execution.cancel() }
        guard !Task.isCancelled, context.token == execution.token else { throw Failure.cancelled }
        guard !result.timedOut else { throw Failure.timeout }
        guard !requiresCompleteOutput || !result.outputTruncated else { throw Failure.outputTooLarge }
        guard result.succeeded else {
            throw Failure.command(String(DeveloperSecretRedactor.redact(result.diagnosticOutput)
                .trimmingCharacters(in: .whitespacesAndNewlines).suffix(4096)))
        }
        return result.output
    }
}

/// Visible rows share a small read queue instead of launching Git for every
/// repository at once. Navigating away cancels queued and running inspections.
actor DirectoryGitReadQueue {
    static let shared = DirectoryGitReadQueue()
    private let maximumReads: Int
    private var activeReads = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(maximumReads: Int = 2) { self.maximumReads = max(1, maximumReads) }

    func snapshot(at url: URL, using reader: DirectoryGitService = DirectoryGitService()) async throws -> DirectoryGitSnapshot {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await reader.snapshot(at: url)
        } onCancel: { reader.cancel() }
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if activeReads < maximumReads {
            activeReads += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty { activeReads -= 1 }
        else { waiters.removeFirst().continuation.resume() }
    }
}
