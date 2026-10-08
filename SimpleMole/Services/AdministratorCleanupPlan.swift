import Darwin
import Foundation

/// The administrator worker accepts only the same confirmed garbage inventory
/// as the cleanup scanner. Elevation changes permissions, never path policy.
enum AdministratorCleanupPlan {
    static let workerArgument = "--nori-cleanup-administrator"
    static let reportPrefix = "NORI_CLEANUP_ADMIN\t"
    static let maximumPlanBytes = 16 * 1024 * 1024

    struct Progress: Codable, Equatable, Sendable {
        let completed: Int
        let total: Int
        let path: String
    }

    /// Native cleanup reports roots and individual files from parallel workers.
    /// Keep their shared counter and the caller's callback under one lock.
    final class ProgressRelay: @unchecked Sendable {
        private let lock = NSLock()
        private let callback: ((Int, Int, String) -> Void)?
        private var latest = Progress(completed: 0, total: 0, path: "")

        init(onProgress: ((Int, Int, String) -> Void)?) { callback = onProgress }

        func report(completed: Int, total: Int, path: String) {
            lock.lock()
            defer { lock.unlock() }
            let done = max(latest.completed, completed)
            latest = Progress(completed: done, total: max(total, done), path: path)
            callback?(latest.completed, latest.total, latest.path)
        }

        func currentFile(_ path: String) {
            lock.lock()
            defer { lock.unlock() }
            latest = Progress(completed: latest.completed, total: latest.total, path: path)
            callback?(latest.completed, latest.total, latest.path)
        }

        func finish() {
            lock.lock()
            defer { lock.unlock() }
            latest = Progress(completed: latest.total, total: latest.total, path: latest.path)
            callback?(latest.completed, latest.total, latest.path)
        }
    }

    /// Serialization, throttling and the complete descriptor write are one
    /// operation. File notifications never bypass the limit at 100%; finish()
    /// explicitly flushes the final state once after all workers return.
    final class ProgressSink: @unchecked Sendable {
        private let lock = NSLock()
        private let clock: () -> TimeInterval
        private let write: (Data) -> Bool
        private let interval: TimeInterval
        private var lastAttempt: TimeInterval?
        private var latest = Progress(completed: 0, total: 0, path: "")
        private var finished = false

        init(interval: TimeInterval = 0.12,
             clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
             write: @escaping (Data) -> Bool) {
            self.interval = interval
            self.clock = clock
            self.write = write
        }

        func submit(_ progress: Progress) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            let done = max(latest.completed, progress.completed)
            latest = Progress(completed: done, total: max(progress.total, done), path: progress.path)
            let now = clock()
            guard lastAttempt.map({ now - $0 >= interval }) ?? true else { return }
            lastAttempt = now
            emitLocked()
        }

        func finish() {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            latest = Progress(completed: latest.total, total: latest.total, path: latest.path)
            emitLocked()
        }

        private func emitLocked() {
            guard let data = try? JSONEncoder().encode(latest), data.count <= 16_384 else { return }
            _ = write(data)
        }
    }

    struct Record: Codable {
        let path: String
        let identity: String
        var metadata: DeletionPlan.Metadata? = nil
    }

    struct Request: Codable {
        let records: [Record]
    }

    struct Report: Codable {
        let removed: Int
        let skipped: Int
        let failed: Int
        let messages: [String]
        let removedPaths: [String]
        let reclaimedBytes: UInt64

        init(_ summary: NativeCore.ApplySummary) {
            removed = summary.removed
            skipped = summary.skipped
            failed = summary.failed
            messages = summary.messages
            removedPaths = summary.removedPaths.sorted()
            reclaimedBytes = summary.reclaimedBytes
        }
    }

    /// Headless mode runs before NSApplication or any normal launch effects.
    /// The bridge invokes the executable from its root-only, verified bundle.
    static func runWorker(arguments: [String]) -> Int32 {
        guard geteuid() == 0, arguments.count == 2,
              let uid = uid_t(arguments[0]), uid != 0,
              let account = getpwuid(uid), let directory = account.pointee.pw_dir,
              let home = String(validatingUTF8: directory),
              DeletionPlan.isLexicallySafePath(home), home != "/",
              let data = readPrivatePlan(arguments[1], owner: uid),
              let request = try? JSONDecoder().decode(Request.self, from: data),
              !request.records.isEmpty, request.records.count <= 100_000 else {
            fputs("Invalid administrator cleanup plan.\n", stderr)
            return 64
        }
        // As root, inspect all processes rather than just the root account.
        // A failed probe is still unknown and refuses the entire operation.
        let core = NativeCore(cleanupOpenFileProbe: allOpenFiles)
        let progressDescriptor = open(arguments[1] + ".progress", O_WRONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        var progressMetadata = stat()
        let validProgress = progressDescriptor >= 0 && fstat(progressDescriptor, &progressMetadata) == 0
            && progressMetadata.st_mode & S_IFMT == S_IFREG && progressMetadata.st_uid == uid
            && progressMetadata.st_nlink == 1 && progressMetadata.st_mode & 0o077 == 0
        defer { if progressDescriptor >= 0 { close(progressDescriptor) } }
        let progress = ProgressSink { data in
            guard validProgress else { return false }
            // Reuse the validated descriptor; never follow a replaced path as root.
            return writeProgress(data, to: progressDescriptor)
        }
        let summary = execute(request.records, homeDirectory: home, core: core,
            onProgress: { completed, total, path in
                progress.submit(Progress(completed: completed, total: total, path: path))
            })
        progress.finish()
        guard let report = try? JSONEncoder().encode(Report(summary)),
              let text = String(data: report, encoding: .utf8) else { return 70 }
        print(reportPrefix + text)
        // AppleScript moves stdout into its error description on nonzero
        // exit. An emitted report must stay on stdout, including partial work.
        return 0
    }

    static func execute(_ records: [Record], homeDirectory: String,
                        core: NativeCore,
                        onProgress: ((Int, Int, String) -> Void)? = nil) -> NativeCore.ApplySummary {
        let home = CleanupRiskPolicy.normalizedPathLiteral(homeDirectory)
        let progress = ProgressRelay(onProgress: onProgress)
        progress.report(completed: 0, total: records.count, path: "")
        var candidates: [CleanupCategory] = []
        var refused: [String] = []
        var seen = Set<String>()
        for record in records {
            let path = record.path
            guard DeletionPlan.isLexicallySafePath(path),
                  CleanupRiskPolicy.normalizedPathLiteral(path) == path,
                  (path.hasPrefix(home + "/")
                    || CleanupRiskPolicy.systemCleanupKind(for: path, homeDirectory: home) != nil),
                  seen.insert(path).inserted,
                  !record.identity.isEmpty else {
                refused.append("Skipped changed or unavailable path: " + path)
                continue
            }
            var policy = CleanupRiskPolicy.core(section: "Cache", path: path,
                                                 homeDirectory: home)
            // A prior partial cleanup changes a cache directory's mtime. Keep
            // the reviewed device/inode binding and recheck every child below;
            // files and other targets still require the full planned identity.
            var metadata = stat()
            guard lstat(path, &metadata) == 0,
                  record.metadata?.matches(metadata, allowingDirectoryContentChanges: true) != false,
                  NativeCore.matchesCleanupIdentity(metadata, expected: record.identity,
                    allowingDirectoryContentChanges: policy.risk == .safe
                        && policy.disposal == .permanentDelete) else {
                refused.append("Skipped changed or unavailable path: " + path)
                continue
            }
            let trash = home + "/.Trash"
            if (path as NSString).deletingLastPathComponent == trash,
               policy.risk != .protected {
                policy = CleanupRiskPolicy.recommendedTrash()
            }
            guard policy.risk == .safe, policy.disposal == .permanentDelete,
                  policy.applyRoute != .toolCommand, policy.applyRoute != .none else {
                refused.append("Skipped protected content: " + path)
                continue
            }
            candidates.append(CleanupCategory(
                name: "Administrator cleanup", paths: [path], bytes: 0,
                pathIdentities: [path: record.identity], selected: true,
                source: policy.source, risk: policy.risk, disposal: policy.disposal,
                applyRoute: policy.applyRoute, activityGuard: policy.activityGuard,
                reasonKey: policy.reasonKey))
        }

        guard !candidates.isEmpty else {
            progress.report(completed: 0, total: 0, path: "")
            progress.finish()
            return NativeCore.ApplySummary(removed: 0, skipped: refused.count, failed: 0,
                messages: refused, remainingPaths: records.map(\.path))
        }

        progress.report(completed: 0, total: candidates.count, path: candidates.first?.paths.first ?? "")
        let checked = core.preflightCleanupCategories(candidates,
            homeDirectory: home, control: CleanupScanControl(mode: .deep),
            includingAdministratorRequired: true, onVisit: { progress.currentFile($0) })
        let eligible = Set(checked.categories.flatMap(\.paths))
        let originalByPath = Dictionary(records.map { ($0.path, $0) },
                                        uniquingKeysWith: { first, _ in first })
        let items = candidates.flatMap(\.paths).compactMap { path -> DeletionPlan.Item? in
            // If fresh inspection splits a directory around a newly protected
            // child, do not silently authorize a different plan as root.
            guard checked.succeeded, eligible.contains(path),
                  let record = originalByPath[path] else {
                refused.append("Skipped because final content validation failed: " + path)
                return nil
            }
            return .init(record: path, identity: record.identity, metadata: record.metadata)
        }
        let total = DeletionPlan.nonOverlappingPaths(items.map(\.record)).count
        progress.report(completed: 0, total: total, path: items.first?.record ?? "")
        let applied = items.isEmpty
            ? NativeCore.ApplySummary(removed: 0, skipped: 0, failed: 0, messages: [])
            : core.applyCleanup(items: items, permanent: true, homeDirectory: home,
                liveCleanupTargets: Set(items.map(\.record).filter {
                    CleanupRiskPolicy.core(section: "Cache", path: $0,
                                           homeDirectory: home).risk == .safe
                }), onProgress: { done, total, path in
                    progress.report(completed: done, total: total, path: path)
                }, onCurrentFile: { path in
                    progress.currentFile(path)
                })
        progress.finish()
        return NativeCore.ApplySummary(
            removed: applied.removed, skipped: applied.skipped + refused.count,
            failed: applied.failed, messages: refused + applied.messages,
            removedPaths: applied.removedPaths,
            remainingPaths: records.map(\.path).filter { path in
                !DeletionPlan.isPathCovered(path, by: applied.removedPaths)
            }, reclaimedBytes: applied.reclaimedBytes)
    }

    /// The caller validates ownership and file mode before retaining this FD.
    /// Its sink serializes truncate/seek/all write retries as one operation.
    static func writeProgress(_ data: Data, to descriptor: Int32) -> Bool {
        guard ftruncate(descriptor, 0) == 0, lseek(descriptor, 0, SEEK_SET) == 0 else { return false }
        return data.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, address.advanced(by: offset), bytes.count - offset)
                if count < 0 { if errno == EINTR { continue }; return false }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }

    static func readPrivatePlan(_ path: String, owner: uid_t) -> Data? {
        guard DeletionPlan.isLexicallySafePath(path) else { return nil }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == owner, metadata.st_nlink == 1,
              metadata.st_mode & 0o077 == 0,
              metadata.st_size > 0, metadata.st_size <= maximumPlanBytes else { return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while data.count <= maximumPlanBytes {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; return nil }
            if count == 0 { return data.count == metadata.st_size ? data : nil }
            data.append(contentsOf: buffer.prefix(count))
        }
        return nil
    }

    private static func allOpenFiles() -> Set<String>? {
        guard let output = SystemMetrics.commandOutput("/usr/sbin/lsof",
            arguments: ["-O", "-nP", "-F", "n"]) else { return nil }
        return Set(output.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.first == "n" else { return nil }
            let path = String(line.dropFirst())
            guard path.hasPrefix("/") else { return nil }
            return CleanupRiskPolicy.canonicalOpenFilePath(path)
        })
    }
}
