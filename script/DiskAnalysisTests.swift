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
        expect(chmod(denied.path, 0o700) == 0, "restore fixture permissions")

        let cancel = CleanupScanControl(mode: .deep)
        let partial = DiskAnalysisWorker.scan(root.path, control: cancel) { _ in cancel.cancel() }
        expect(partial.isPartial == true && partial.entries.count < report.entries.count,
               "cancel must stop traversal and mark the total as a lower bound")

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
        let legacy = Data("{\"name\":\"old\",\"path\":\"/old\",\"size\":1,\"is_dir\":true}".utf8)
        let decoded = try JSONDecoder().decode(AnalyzeEntry.self, from: legacy)
        expect(decoded.isPartial == nil,
               "old analysis records must remain decodable")
        print("PASS: directory hierarchy, allocated size, hardlinks, symlinks, sparse files, in-subtree progress/cancellation, deterministic sorting, cleanup protection, errors and cached navigation")
    }
}
