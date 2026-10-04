import Darwin
import Foundation

/// The administrator worker accepts only the same confirmed garbage inventory
/// as the cleanup scanner. Elevation changes permissions, never path policy.
enum AdministratorCleanupPlan {
    static let workerArgument = "--nori-cleanup-administrator"
    static let reportPrefix = "NORI_CLEANUP_ADMIN\t"
    static let maximumPlanBytes = 16 * 1024 * 1024

    struct Progress: Codable, Equatable {
        let completed: Int
        let total: Int
        let path: String
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
        var lastProgress = Date.distantPast
        let summary = execute(request.records, homeDirectory: home, core: core,
            onProgress: { completed, total, path in
                let now = Date()
                guard completed >= total || now.timeIntervalSince(lastProgress) >= 0.12 else { return }
                lastProgress = now
                guard validProgress, let data = try? JSONEncoder().encode(
                    Progress(completed: completed, total: total, path: path)), data.count <= 16_384 else { return }
                // Reuse the validated descriptor; never follow a replaced path as root.
                guard ftruncate(progressDescriptor, 0) == 0, lseek(progressDescriptor, 0, SEEK_SET) == 0 else { return }
                data.withUnsafeBytes { bytes in
                    if let address = bytes.baseAddress { _ = write(progressDescriptor, address, bytes.count) }
                }
            })
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

        let checked = core.preflightCleanupCategories(candidates,
            homeDirectory: home, control: CleanupScanControl(mode: .deep),
            includingAdministratorRequired: true)
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
        var completed = 0
        let applied = items.isEmpty
            ? NativeCore.ApplySummary(removed: 0, skipped: 0, failed: 0, messages: [])
            : core.applyCleanup(items: items, permanent: true, homeDirectory: home,
                liveCleanupTargets: Set(items.map(\.record).filter {
                    CleanupRiskPolicy.core(section: "Cache", path: $0,
                                           homeDirectory: home).risk == .safe
                }), onProgress: { done, total, path in
                    completed = done
                    onProgress?(done, total, path)
                }, onCurrentFile: { path in
                    onProgress?(completed, items.count, path)
                })
        return NativeCore.ApplySummary(
            removed: applied.removed, skipped: applied.skipped + refused.count,
            failed: applied.failed, messages: refused + applied.messages,
            removedPaths: applied.removedPaths,
            remainingPaths: records.map(\.path).filter { path in
                !applied.removedPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
            }, reclaimedBytes: applied.reclaimedBytes)
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
