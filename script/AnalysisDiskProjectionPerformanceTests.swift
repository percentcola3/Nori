import Darwin
import Foundation

/// Synthetic indexed data only. No directory is created or scanned by this benchmark.
@main
struct AnalysisDiskProjectionPerformanceTests {
    struct Options {
        var files = 100_000
        var iterations = 1
        var depth = 8
        var label = "current"

        init() {
            var arguments = CommandLine.arguments.dropFirst().makeIterator()
            while let option = arguments.next() {
                guard let value = arguments.next() else { fail("Missing value for " + option) }
                switch option {
                case "--files": files = Int(value) ?? 0
                case "--iterations": iterations = Int(value) ?? 0
                case "--depth": depth = Int(value) ?? 0
                case "--label": label = value
                default: fail("Unknown option " + option)
                }
            }
            guard files >= 1_000, iterations > 0, (2...32).contains(depth) else {
                fail("Use --files >= 1000, --iterations > 0 and --depth between 2 and 32")
            }
        }
    }

    struct Fixture {
        let snapshot: AnalysisInventorySnapshot
        let expectedSizes: [String: UInt64]
        let failedDirectories: Set<String>
        let issuePaths: Set<String>
        let uniqueFiles: Int
        let aliases: Int
        let generationSeconds: Double
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
        exit(1)
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fail(message) }
    }

    static func fingerprint(inode: UInt64, directory: Bool, allocated: UInt64) -> AnalysisFileFingerprint {
        var value = stat()
        value.st_dev = 7
        value.st_ino = inode
        value.st_mode = mode_t((directory ? S_IFDIR : S_IFREG) | 0o644)
        value.st_size = off_t(allocated + (directory ? 0 : 8_192))
        value.st_blocks = blkcnt_t(allocated / 512)
        value.st_mtimespec = timespec(tv_sec: 123_456, tv_nsec: 11)
        value.st_ctimespec = timespec(tv_sec: 123_456, tv_nsec: 22)
        return .init(value)
    }

    static func makeFixture(_ options: Options) -> Fixture {
        let start = ProcessInfo.processInfo.systemUptime
        let root = "/nori-projection-fixture/家目录-📁-révisions"
        let branches = 32
        let groups = 16
        let aliases = min(512, options.files / 100)
        let uniqueFiles = options.files - aliases
        var directories: [String: AnalysisInventorySnapshot.Directory] = [:]
        var files: [String: AnalysisFileFingerprint] = [:]
        files.reserveCapacity(options.files)
        var directoryOrder: [String] = []
        var parents: [String: String] = [:]
        var owners: [UInt64: String] = [:]
        var leaves: [String] = []
        var failedCandidates: [String] = []
        var nextDirectoryInode: UInt64 = UInt64(options.files) + 10_000

        func addDirectory(_ path: String, parent: String?) {
            guard directories[path] == nil else { return }
            nextDirectoryInode += 1
            directories[path] = .init(fingerprint: fingerprint(inode: nextDirectoryInode,
                directory: true, allocated: 4_096), directories: [], files: [])
            directoryOrder.append(path)
            if let parent {
                parents[path] = parent
                directories[parent]!.directories.append(path)
            }
        }
        addDirectory(root, parent: nil)
        for branch in 0..<branches {
            // Foundation's path API intentionally produces the same foreign
            // Unicode-backed strings as production directory enumeration.
            let branchPath = (root as NSString).appendingPathComponent(
                String(format: "项目-%02d-研究资料-🐚", branch))
            addDirectory(branchPath, parent: root)
            for group in 0..<groups {
                var path = branchPath
                for level in 0..<options.depth {
                    let component = level == 0
                        ? String(format: "工程归档-%02d-révisions-δοκιμή-📦", group)
                        : String(format: "深层目录-%02d-révisions-δοκιμή-🧪", level)
                    let child = (path as NSString).appendingPathComponent(component)
                    addDirectory(child, parent: path)
                    if group == 0 && (branch == 0 || branch == 1) && level == options.depth / 2 {
                        failedCandidates.append(child)
                    }
                    path = child
                }
                leaves.append(path)
            }
        }
        for index in 0..<uniqueFiles {
            let parent = leaves[index % leaves.count]
            let path = (parent as NSString).appendingPathComponent(
                String(format: "文件-%08d-épreuves-文档-🧬.bin", index))
            let identity = UInt64(index + 1)
            files[path] = fingerprint(inode: identity, directory: false,
                                      allocated: UInt64(index % 13 + 1) * 4_096)
            directories[parent]!.files.append(path)
            parents[path] = parent
            owners[identity] = path
        }
        for index in 0..<aliases {
            let identity = UInt64(index + 1)
            let original = owners[identity]!
            let parent = leaves[(index + groups * 2) % leaves.count]
            let alias = (parent as NSString).appendingPathComponent(
                String(format: "0000-链接-%08d-copie-🪸.bin", index))
            files[alias] = files[original]
            directories[parent]!.files.append(alias)
            parents[alias] = parent
            owners[identity] = min(original, alias)
        }

        var expectedSizes = directories.mapValues { $0.fingerprint.allocated }
        expectedSizes.reserveCapacity(files.count + directories.count)
        for (path, file) in files {
            let size = owners[file.inode] == path ? file.allocated : 0
            expectedSizes[path] = size
            expectedSizes[parents[path]!]! += size
        }
        // Creation order is already topological; independently aggregate the
        // expected capacities without reusing production path traversal logic.
        for directory in directoryOrder.reversed() {
            if let parent = parents[directory] { expectedSizes[parent]! += expectedSizes[directory]! }
        }
        let failed = Set(failedCandidates)
        let issueFile = directories[leaves[groups * 2 + 1]]!.files.first!
        let issuePaths = failed.union([issueFile])
        var snapshot = AnalysisInventorySnapshot(kind: .disk, home: root,
            roots: [root], scannedAt: Date(timeIntervalSince1970: 123_456),
            directories: directories, files: files)
        snapshot.unreadableDirectories = failed
        snapshot.issues = issuePaths.sorted().map {
            .init(path: $0, kind: .readFailure, errorCode: EACCES)
        }
        snapshot.issueCount = snapshot.issues.count
        return .init(snapshot: snapshot, expectedSizes: expectedSizes,
                     failedDirectories: failed, issuePaths: issuePaths,
                     uniqueFiles: uniqueFiles, aliases: aliases,
                     generationSeconds: ProcessInfo.processInfo.systemUptime - start)
    }

    static func verify(_ inventory: AnalysisDiskBrowserInventory, fixture: Fixture) {
        let snapshot = fixture.snapshot
        let report = inventory.report(for: snapshot)
        expect(report.totalSize == fixture.expectedSizes[snapshot.home], "Tree capacity differs from unique allocated blocks")
        expect(report.totalFiles == snapshot.files.count, "Hardlink aliases must remain visible file paths")
        expect(report.isPartial == true && report.scanIssueCount == fixture.issuePaths.count,
               "Projection lost partial traversal provenance")
        let hasOverview = snapshot.directories[inventory.rootPath] == nil
        expect(inventory.entriesByPath.count == snapshot.directories.count + (hasOverview ? 1 : 0),
               "Directory columns are missing")
        if hasOverview {
            expect(inventory.entriesByPath[inventory.rootPath]?.first(where: { $0.path == snapshot.home })?.size
                == fixture.expectedSizes[snapshot.home], "Overview scope capacity differs from its physical tree")
        }
        var projectedFiles = 0
        var projectedDirectories = 0
        var zeroSizedAliases = 0
        var partialFiles = 0
        var cleanFiles = 0
        // The fixture intentionally keeps foreign paths inside production.
        // Native copies keep the independent prefix oracle from dominating
        // verification time without changing any path or Unicode content.
        let nativeFailed = fixture.failedDirectories.map { String(decoding: $0.utf8, as: UTF8.self) }
        let nativeIssues = fixture.issuePaths.map { String(decoding: $0.utf8, as: UTF8.self) }
        for (parent, entries) in inventory.entriesByPath {
            if hasOverview && parent == inventory.rootPath { continue }
            expect(snapshot.directories[parent] != nil, "Projection invented a column")
            var previous: AnalyzeEntry?
            for entry in entries {
                expect(entry.size == fixture.expectedSizes[entry.path], "Wrong hardlink owner or subtree capacity")
                let nativePath = String(decoding: entry.path.utf8, as: UTF8.self)
                let insideFailed = nativeFailed.contains {
                    nativePath == $0 || nativePath.hasPrefix($0 + "/")
                }
                let isIssueAncestor = nativeIssues.contains {
                    nativePath == $0 || $0.hasPrefix(nativePath + "/")
                }
                expect((entry.isPartial == true) == (insideFailed || isIssueAncestor),
                       "Partial marker escaped its failed subtree/ancestor chain")
                if entry.isDir { projectedDirectories += 1 }
                else {
                    projectedFiles += 1
                    if entry.size == 0 { zeroSizedAliases += 1 }
                    if entry.isPartial == true { partialFiles += 1 } else { cleanFiles += 1 }
                }
                if let previous {
                    expect(previous.size > entry.size ||
                        (previous.size == entry.size && previous.name < entry.name),
                        "Column sorting is not deterministic")
                }
                previous = entry
            }
        }
        expect(projectedFiles == snapshot.files.count, "File paths disappeared during projection")
        expect(projectedDirectories == snapshot.directories.count - 1, "Directory paths were duplicated or omitted")
        expect(zeroSizedAliases == fixture.aliases, "Physical hardlink blocks were not assigned to exactly one path")
        expect(partialFiles > 0 && cleanFiles > partialFiles,
               "A few failed directories must leave unrelated file paths trusted")
    }

    static func emit(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }

    static func removingOneFile(from fixture: Fixture) -> (fixture: Fixture, path: String, ancestorCount: Int) {
        let path = fixture.snapshot.files.first { entry in
            entry.value.inode > UInt64(fixture.aliases) && !fixture.issuePaths.contains(entry.key) &&
                !fixture.failedDirectories.contains(where: { failed in entry.key.hasPrefix(failed + "/") })
        }!.key
        let removedBytes = fixture.snapshot.files[path]!.allocated
        var updated = fixture.snapshot
        updated.files.removeValue(forKey: path)
        let parent = (path as NSString).deletingLastPathComponent
        updated.directories[parent]!.files.removeAll { $0 == path }
        var expectedSizes = fixture.expectedSizes
        expectedSizes.removeValue(forKey: path)
        var ancestor = parent
        var ancestorCount = 0
        while let bytes = expectedSizes[ancestor] {
            expectedSizes[ancestor] = bytes - removedBytes
            ancestorCount += 1
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
        let repairedFixture = Fixture(snapshot: updated, expectedSizes: expectedSizes,
            failedDirectories: fixture.failedDirectories, issuePaths: fixture.issuePaths,
            uniqueFiles: fixture.uniqueFiles - 1, aliases: fixture.aliases, generationSeconds: 0)
        return (repairedFixture, path, ancestorCount)
    }

    static func main() throws {
        let options = Options()
        let fixture = makeFixture(options)
        let removal = removingOneFile(from: fixture)
        let removedPaths: Set<String> = [removal.path]
        let firstPath = fixture.snapshot.files.keys.first!
        try emit(["phase": "fixture", "label": options.label,
                  "files": fixture.snapshot.files.count, "unique_files": fixture.uniqueFiles,
                  "hardlink_aliases": fixture.aliases, "directories": fixture.snapshot.directories.count,
                  "depth": options.depth, "failed_directories": fixture.failedDirectories.count,
                  "path_bytes": firstPath.utf8.count,
                  "bridged_path_type": String(describing: type(of: firstPath as NSString)),
                  "wall_seconds": fixture.generationSeconds])
        var durations: [Double] = []
        var repairDurations: [Double] = []
        for iteration in 1...options.iterations {
            let start = ProcessInfo.processInfo.systemUptime
            let inventory = AnalysisDiskBrowserInventory(snapshot: fixture.snapshot)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            durations.append(elapsed)
            try emit(["phase": "projection", "label": options.label, "iteration": iteration,
                      "files": fixture.snapshot.files.count, "directories": inventory.entriesByPath.count,
                      "total_allocated_bytes": inventory.report(for: fixture.snapshot).totalSize,
                      "wall_seconds": elapsed])
            let verificationStart = ProcessInfo.processInfo.systemUptime
            verify(inventory, fixture: fixture)
            try emit(["phase": "projection-verification", "label": options.label, "iteration": iteration,
                      "wall_seconds": ProcessInfo.processInfo.systemUptime - verificationStart,
                      "verification": "passed"])
            var repaired = inventory
            let repairStart = ProcessInfo.processInfo.systemUptime
            repaired.repair(from: fixture.snapshot, to: removal.fixture.snapshot,
                            removed: removedPaths.contains, changedPaths: [])
            let repairElapsed = ProcessInfo.processInfo.systemUptime - repairStart
            repairDurations.append(repairElapsed)
            try emit(["phase": "repair", "label": options.label, "iteration": iteration,
                      "files": removal.fixture.snapshot.files.count,
                      "repaired_directories": repaired.repairedDirectoryCount,
                      "wall_seconds": repairElapsed])
            let repairVerificationStart = ProcessInfo.processInfo.systemUptime
            verify(repaired, fixture: removal.fixture)
            expect(repaired.repairedDirectoryCount == removal.ancestorCount,
                   "Single-file removal must rebuild only its ancestor columns")
            try emit(["phase": "repair-verification", "label": options.label, "iteration": iteration,
                      "wall_seconds": ProcessInfo.processInfo.systemUptime - repairVerificationStart,
                      "verification": "passed"])
        }
        try emit(["phase": "summary", "label": options.label, "iterations": durations.count,
                  "files": fixture.snapshot.files.count,
                  "min_seconds": durations.min()!, "max_seconds": durations.max()!,
                  "mean_seconds": durations.reduce(0, +) / Double(durations.count),
                  "repair_mean_seconds": repairDurations.reduce(0, +) / Double(repairDurations.count),
                  "verification": "passed"])
    }
}
