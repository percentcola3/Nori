import Darwin
import Foundation

@main
struct DiskAnalysisTests {
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() {
            FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
            exit(1)
        }
    }

    static func main() throws {
        let fm = FileManager.default
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = fixture.appendingPathComponent("selected").standardizedFileURL
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        func write(_ relative: String, _ count: Int) throws -> URL {
            let target = root.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: count).write(to: target)
            return target
        }
        func blocks(_ url: URL) -> UInt64 {
            var info = stat()
            expect(lstat(url.path, &info) == 0, "fixture stat failed")
            return UInt64(info.st_blocks) * 512
        }
        let large = try write("A/nested/large", 1_048_576)
        try fm.linkItem(at: large, to: root.appendingPathComponent("A/nested/hardlink"))
        _ = try write("B/small", 4096)
        _ = try write(".hidden/value", 8192)
        for index in 0..<12 {
            try fm.createDirectory(at: root.appendingPathComponent("empty-\(index)"),
                                   withIntermediateDirectories: true)
        }
        let outside = fixture.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 2_097_152).write(to: outside.appendingPathComponent("sentinel"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        let sparse = root.appendingPathComponent("sparse")
        let fd = open(sparse.path, O_CREAT | O_RDWR, mode_t(0o600))
        expect(fd >= 0, "sparse fixture open failed")
        expect(ftruncate(fd, 100 * 1024 * 1024) == 0, "sparse fixture truncate failed")
        close(fd)

        let report = DiskAnalysisWorker.scan(root.path, control: CleanupScanControl(mode: .deep))
        expect(report.entries.count == 17, "must show every immediate child, including empty/hidden entries")
        expect(report.entries.first?.name == "A", "children must be ordered by allocated size")
        expect(report.entries.allSatisfy { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path == root.path },
               "unexpected parent: root=\(root.path), report=\(report.path), parents=\(Set(report.entries.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path }))")
        expect(report.isPartial == false, "readable fixture must be complete")
        expect(DiskAnalysisWorker.completion(for: report) == .complete, "readable tree must complete normally")
        let a = report.entries.first { $0.name == "A" }!
        let expectedA = blocks(root.appendingPathComponent("A"))
            + blocks(root.appendingPathComponent("A/nested")) + blocks(large)
        expect(a.size == expectedA, "hardlinks must count only once")
        expect(report.entries.first { $0.name == "link" }?.size == blocks(root.appendingPathComponent("link")),
               "symlink target must never be traversed")
        expect(report.entries.first { $0.name == "sparse" }?.size == blocks(sparse),
               "use allocated size instead of sparse logical size")
        expect(report.totalSize == blocks(root) + report.entries.reduce(0) { $0 + $1.size },
               "current folder total must agree with child usage")
        let split = DiskAnalysisWorker.scan(root.path, control: CleanupScanControl(mode: .deep),
            overviewSplits: [root.appendingPathComponent("A").path,
                             root.appendingPathComponent("A/nested").path])
        expect(split.totalSize == report.totalSize && split.totalFiles == report.totalFiles,
               "partitioned overview must preserve allocated bytes and global hardlink deduplication")
        expect(split.entries == report.entries,
               "partitioned jobs must aggregate into the original immediate children")
        expect(split.directoryReports?.isEmpty == true,
               "overview partitions must not retain a filesystem-wide directory index")
        let symlinkPlan = DiskAnalysisWorker.partition(root.appendingPathComponent("link"),
            expanding: [root.appendingPathComponent("link").path], control: CleanupScanControl(mode: .deep))
        expect(symlinkPlan.paths.count == 1 && symlinkPlan.directoryBytes == 0,
               "partition planning must never follow a symlink")
        let devices = DiskAnalysisWorker.scan("/dev", control: CleanupScanControl(mode: .deep))
        expect(devices.isPartial == false && devices.scanIssues == nil && devices.totalSize == 0,
               "volatile device descriptors must be excluded without generating failures")

        let nested = DiskAnalysisWorker.scan(a.path, control: CleanupScanControl(mode: .deep))
        expect(nested.entries.count == 1 && nested.entries[0].name == "nested", "drill-down must show the next level")
        expect(nested.totalSize == a.size, "parent row and drilled-in total must agree")

        var cache = DiskAnalysisCache()
        cache.store(report)
        let firstLevel = cache.report(for: a.path)!
        let secondLevel = cache.report(for: root.appendingPathComponent("A/nested").path)!
        expect(firstLevel.totalSize == a.size && firstLevel.entries.count == 1,
               "first descent must already be available from the initial traversal")
        expect(secondLevel.entries.count == 2 && secondLevel.totalSize == firstLevel.entries[0].size,
               "deeper directory reports must also be captured on the first scan")
        let moved = fixture.appendingPathComponent("moved")
        try fm.moveItem(at: root, to: moved)
        expect(cache.report(for: root.path)?.totalSize == report.totalSize,
               "back navigation must work without rereading the directory")
        expect(cache.report(for: a.path)?.entries == firstLevel.entries,
               "forward navigation must not probe the filesystem")
        expect(cache.report(for: root.appendingPathComponent("A/nested").path)?.entries == secondLevel.entries,
               "repeated deeper navigation must use the same snapshot")
        try fm.moveItem(at: moved, to: root)
        cache.invalidate(a.path)
        expect(cache.report(for: a.path) == nil && cache.report(for: root.path) == nil,
               "refresh must invalidate old descendants and ancestor totals")
        expect(cache.report(for: root.appendingPathComponent("B").path) != nil,
               "refresh must preserve independent cached directories")
        _ = try write("A/new", 16384)
        let refreshed = DiskAnalysisWorker.scan(a.path, control: CleanupScanControl(mode: .deep))
        cache.store(refreshed)
        expect(cache.report(for: a.path)!.totalSize > firstLevel.totalSize,
               "explicit refresh must replace the old sizes")
        cache.clear()
        expect(cache.report(for: a.path) == nil, "cleanup must discard stale analysis results")

        // FTS emits D then DNR (without DP) for an unreadable directory.
        // Later siblings must remain attached to their actual parent.
        let denied = try write("permissions/wrapper/blocked/secret", 4096).deletingLastPathComponent()
        _ = try write("permissions/sibling/deeper/payload", 65536)
        _ = try write("permissions/other/payload", 32768)
        let denied2 = try write("permissions/another/blocked/secret", 4096).deletingLastPathComponent()
        expect(chmod(denied2.path, 0) == 0, "restrict second fixture")
        defer { chmod(denied2.path, 0o700) }
        expect(chmod(denied.path, 0) == 0, "restrict fixture permissions")
        defer { chmod(denied.path, 0o700) }
        let permissions = DiskAnalysisWorker.scan(root.path, control: CleanupScanControl(mode: .deep))
        expect(chmod(denied.path, 0o700) == 0, "restore fixture permissions")
        expect(chmod(denied2.path, 0o700) == 0, "restore second fixture permissions")
        let permissionsPath = root.appendingPathComponent("permissions").path
        let parentReport = permissions.directoryReports![permissionsPath]!
        expect(Set(parentReport.entries.map(\.name)) == Set(["wrapper", "another", "sibling", "other"]),
               "unreadable directory must not swallow sibling directories")
        let deniedReport = permissions.directoryReports![denied.path]!
        expect(deniedReport.isPartial == true && deniedReport.entries.isEmpty,
               "unreadable cached directory must contain no sibling data")
        for (path, cached) in permissions.directoryReports! {
            expect(cached.entries.allSatisfy {
                URL(fileURLWithPath: $0.path).deletingLastPathComponent().path == path
            }, "cached children must have their actual parent: \(path)")
            expect(cached.totalSize == blocks(URL(fileURLWithPath: path)) + cached.entries.reduce(0) { $0 + $1.size },
                   "cached directory totals must agree with their own children")
            for row in cached.entries where row.isDir {
                if let child = permissions.directoryReports?[row.path] {
                    expect(row.size == child.totalSize, "cached navigation must preserve directory size")
                }
            }
        }
        expect(parentReport.isPartial == true, "unreadable child must mark ancestors partial")
        expect(DiskAnalysisWorker.completion(for: permissions) == .complete,
               "inaccessible descendants must be skipped silently without a warning or failure")
        expect(permissions.scanIssueCount == 0 && permissions.scanIssues?.isEmpty == true,
               "expected access refusals must not occupy visible diagnostics")
        var noMatches = AnalyzeReport(path: root.path, overview: false, entries: [], largeFiles: [],
                                      totalSize: 0, totalFiles: 0, isPartial: true)
        noMatches.scanIssues = [.init(path: denied.path, kind: .readFailure, errorCode: EACCES)]
        noMatches.scanIssueCount = 1
        expect(DiskAnalysisWorker.completion(for: noMatches) == .complete,
               "legacy permission-only reports must remain silent even without matching large files")
        expect(DiskAnalysisWorker.failureDetails(for: permissions, using: { $0 }).isEmpty,
               "permission skips must not produce a user-facing explanation")
        noMatches.scanIssues = [.init(path: denied.path, kind: .readFailure, errorCode: EPERM)]
        expect(DiskAnalysisWorker.completion(for: noMatches) == .complete,
               "system protection refusals must also remain silent")
        noMatches.scanIssues = [.init(path: denied.path, kind: .readFailure, errorCode: EIO)]
        expect(DiskAnalysisWorker.completion(for: noMatches) == .partial,
               "genuine I/O failures must remain visible")
        expect(DiskAnalysisWorker.failureDetails(for: noMatches, using: { $0 }).contains {
            $0.contains(denied.path) && $0.contains("scan.reason.read")
        }, "I/O failures must retain the affected path and reason")
        expect(chmod(denied.path, 0) == 0, "restrict explicitly selected root")
        let deniedRoot = DiskAnalysisWorker.scan(denied.path, control: CleanupScanControl(mode: .deep))
        expect(DiskAnalysisWorker.completion(for: deniedRoot) == .failed && deniedRoot.error != nil,
               "an inaccessible selected root must retain a real error instead of a successful empty result")
        expect(chmod(denied.path, 0o700) == 0, "restore fixture permissions")

        let cancel = CleanupScanControl(mode: .deep)
        let partial = DiskAnalysisWorker.scan(root.path, control: cancel) { _ in cancel.cancel() }
        expect(partial.isPartial == true && partial.entries.count < report.entries.count,
               "cancel must stop traversal and mark the total as a lower bound")

        // Silently skipped restrictions must not interfere with cancellation.
        let restrictedRoot = fixture.appendingPathComponent("restricted-cancel").standardizedFileURL
        var blockedPaths: [String] = []
        defer { for path in blockedPaths { chmod(path, 0o700) } }
        for index in 0..<40 {
            let blocked = restrictedRoot.appendingPathComponent("only-child/blocked-\(index)")
            try fm.createDirectory(at: blocked, withIntermediateDirectories: true)
            blockedPaths.append(blocked.path)
            expect(chmod(blocked.path, 0) == 0, "restrict saturated diagnostic fixture")
        }
        let restrictedCancel = CleanupScanControl(mode: .deep)
        var visitedRestricted = Set<String>()
        let restrictedResult = DiskAnalysisWorker.scan(restrictedRoot.path, control: restrictedCancel,
            progressInterval: 0) { update in
                if let path = update.currentPath, path.contains("/blocked-") {
                    visitedRestricted.insert(path)
                }
                if visitedRestricted.count >= 32 { restrictedCancel.cancel() }
            }
        expect(restrictedCancel.isCancelled && restrictedResult.scanIssues?.count == 1,
               "only cancellation should be reported after many silent permission skips")
        expect(DiskAnalysisWorker.completion(for: restrictedResult) == .cancelled,
               "silent restrictions must not mislabel a cancelled scan as complete")
        for path in blockedPaths { chmod(path, 0o700) }

        // One large top-level child must publish measured progress before it
        // finishes, and cancellation from that progress must stop inside it.
        let progressRoot = fixture.appendingPathComponent("progress").standardizedFileURL
        let onlyChild = progressRoot.appendingPathComponent("only-child")
        try fm.createDirectory(at: onlyChild, withIntermediateDirectories: true)
        for index in 0..<256 {
            try Data(repeating: 1, count: 4096)
                .write(to: onlyChild.appendingPathComponent("file-\(index)"))
        }
        let midScanCancel = CleanupScanControl(mode: .deep)
        var progressBytes: [UInt64] = []
        var currentPath: String?
        let interrupted = DiskAnalysisWorker.scan(
            progressRoot.path, control: midScanCancel, progressInterval: 0
        ) { update in
            progressBytes.append(update.totalSize)
            expect(update.entries.count == 1 && update.entries[0].path == onlyChild.path,
                   "progress must include the active immediate child exactly once")
            expect(update.isPartial == true, "in-flight totals must remain lower bounds")
            if (update.totalFiles ?? 0) >= 32 && !midScanCancel.isCancelled {
                currentPath = update.currentPath
                expect(update.entries[0].isPartial == true && update.entries[0].size > 0,
                       "active subtree must show measured bytes without claiming completion")
                midScanCancel.cancel()
            }
        }
        expect(DiskAnalysisWorker.completion(for: interrupted) == .cancelled,
               "user cancellation must remain distinct from restrictions and failures")
        expect(interrupted.totalFiles == 32 && interrupted.isPartial == true,
               "cancel must take effect before the first large top-level child completes")
        expect(currentPath?.hasPrefix(onlyChild.path + "/") == true,
               "progress must identify the item being visited inside the subtree")
        expect(zip(progressBytes, progressBytes.dropFirst()).allSatisfy { $0 <= $1 },
               "measured bytes must not decrease between progress updates")
        let completeProgress = DiskAnalysisWorker.scan(
            progressRoot.path, control: CleanupScanControl(mode: .deep), progressInterval: 0
        ) { update in
            expect(update.entries.count == 1,
                   "completing a subtree must not duplicate its in-flight row")
        }
        expect(completeProgress.totalFiles == 256 && completeProgress.isPartial == false,
               "incremental progress must preserve final totals and completion")
        expect(completeProgress.currentPath == nil,
               "a finished report must not retain a currently scanning path")

        let tempRoot = fm.temporaryDirectory.appendingPathComponent("nori-temp-projects-\(UUID().uuidString)")
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }
        let checkout = tempRoot.appendingPathComponent("agent-checkout")
        try fm.createDirectory(at: checkout.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 65536).write(to: checkout.appendingPathComponent("source"))
        let worktree = tempRoot.appendingPathComponent("agent-worktree")
        try fm.createDirectory(at: worktree, withIntermediateDirectories: true)
        try Data("gitdir: /outside/repository".utf8).write(to: worktree.appendingPathComponent(".git"))
        try fm.createSymbolicLink(at: tempRoot.appendingPathComponent("linked-project"), withDestinationURL: checkout)
        let tempScan = DiskAnalysisWorker.scan(tempRoot.path, control: CleanupScanControl(mode: .deep))
        expect(Set(tempScan.temporaryProjects?.map(\.name) ?? []) == ["agent-checkout", "agent-worktree"],
               "temporary checkouts and worktrees must be discovered without following symlinks")
        for project in tempScan.temporaryProjects ?? [] {
            expect(project.size == tempScan.entries.first { $0.path == project.path }?.size,
                   "project usage must include source, dependencies, and Git metadata from the same traversal")
            expect(project.cleanable == false && !project.canCleanDirectly,
                   "temporary projects must remain inspection-only")
        }
        expect(!DiskAnalysisWorker.isTemporaryProjectPath("/private/tmp-other/repository"),
               "temporary root matching must respect component boundaries")
        let tempRestored = try JSONDecoder().decode(AnalyzeReport.self, from: JSONEncoder().encode(tempScan))
        expect(tempRestored.temporaryProjects?.count == 2, "temporary project inventory must survive caching")

        let ties = [
            AnalyzeEntry(name: "file10", path: "/tmp/file10", size: 4096, isDir: false),
            AnalyzeEntry(name: "file2", path: "/System/file2", size: 4096, isDir: false),
            AnalyzeEntry(name: "file2", path: "/Applications/file2", size: 4096, isDir: false)
        ].sorted(by: AnalyzeEntry.analysisOrder)
        expect(ties.map(\.path) == ["/Applications/file2", "/System/file2", "/tmp/file10"],
               "equal-size ordering must be natural and deterministic without path safety classification")
        expect(ties[1].canCleanDirectly == false,
               "cheaper display sorting must not weaken system-file cleanup protection")
        let missing = DiskAnalysisWorker.scan(fixture.appendingPathComponent("missing").path,
                                              control: CleanupScanControl(mode: .deep))
        expect(missing.isPartial == true && missing.error != nil, "unreadable root must not report a complete zero")
        expect(DiskAnalysisWorker.completion(for: missing) == .failed,
               "an unreadable selected root must retain the failure dialog")
        expect(missing.scanIssues?.first?.path == missing.path,
               "root errors must name the requested directory")
        let encoded = try JSONEncoder().encode(permissions)
        let restored = try JSONDecoder().decode(AnalyzeReport.self, from: encoded)
        expect(restored.scanIssueCount == permissions.scanIssueCount && restored.scanIssues?.count == permissions.scanIssues?.count,
               "analysis diagnostics must survive caching")
        let legacy = Data("{\"name\":\"old\",\"path\":\"/old\",\"size\":1,\"is_dir\":true}".utf8)
        let decoded = try JSONDecoder().decode(AnalyzeEntry.self, from: legacy)
        expect(decoded.isPartial == nil,
               "old analysis records must remain decodable")
        print("PASS: partitioned overview totals, temporary Git checkouts/worktrees, device exclusion, directory hierarchy, allocated size, hardlinks, symlinks, sparse files, progress/cancellation, cleanup protection, errors and cached navigation")
    }
}
