import CryptoKit
import Darwin
import Foundation

@main
struct DuplicateScannerTests {
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else {
            FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
            exit(1)
        }
    }

    static func rejects(_ message: String, _ action: () throws -> Void) {
        do { try action(); expect(false, message) } catch {}
    }

    static func main() throws {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: CommandLine.arguments[1]).standardized
        let root = home.appendingPathComponent("Documents")
        let second = home.appendingPathComponent("Downloads")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: second, withIntermediateDirectories: true)
        func write(_ relative: String, _ data: Data) throws -> URL {
            let target = home.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target)
            return target
        }
        let content = Data("abc".utf8)
        let original = try write("Documents/original.pdf", content)
        let renamed = try write("Downloads/nested/renamed.pdf", content)
        try fm.linkItem(at: original, to: root.appendingPathComponent("hardlink.pdf"))
        _ = try write("Documents/empty", Data())
        _ = try write("Documents/.hidden/unique", Data("hidden candidate".utf8))
        for i in 0..<125 {
            _ = try write("Documents/many/value-\(i)", Data("small file \(i)".utf8))
        }
        let after100 = try write("Documents/many/last-copy", Data("small file 124".utf8))
        var middleA = Data(repeating: 1, count: 256 * 1024)
        var middleB = middleA
        middleA[128 * 1024] = 2
        middleB[128 * 1024] = 3
        _ = try write("Documents/same-sample-a", middleA)
        _ = try write("Documents/same-sample-b", middleB)
        let forbidden = ["Library/Application Support/WeChat/copy", "Documents/Test.app/Contents/copy",
                         "Documents/Photos.photoslibrary/originals/copy", "Documents/project/.git/copy",
                         "Documents/project/node_modules/a/copy", "Documents/not-downloaded.icloud"]
        for path in forbidden { _ = try write(path, content) }
        let resourceFork = try write("Documents/resource-fork", content)
        let forkContent = Data("different resource fork".utf8)
        let attributeResult = forkContent.withUnsafeBytes {
            setxattr(resourceFork.path, "com.apple.ResourceFork", $0.baseAddress, $0.count, 0, 0)
        }
        expect(attributeResult == 0, "resource-fork fixture must be supported")
        let outside = try write("outside/copy", content)
        try fm.createSymbolicLink(at: root.appendingPathComponent("linked-file"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: root.appendingPathComponent("linked-directory"),
                                 withDestinationURL: outside.deletingLastPathComponent())
        var reports: [DuplicateScanProgress] = []
        let scan = DuplicateScanner.scan(roots: [root.path, second.path, root.appendingPathComponent("many").path],
                                         control: DuplicateScanControl(), home: home.path) { reports.append($0) }
        expect(!scan.isPartial && !scan.cancelled,
               "safe readable scan should complete: roots=\(scan.roots), files=\(scan.files.count), skipped=\(scan.skippedFiles), groups=\(scan.groups.count), error=\(scan.error ?? "none")")
        expect(scan.roots.count == 2, "overlapping selected folders must be coalesced")
        expect(scan.groups.count == 2, "exact duplicates only; identical first/last samples are not enough")
        let pdfGroup = scan.groups.first { $0.files.contains { $0.path == renamed.path } }!
        expect(pdfGroup.files.count == 2, "hardlink aliases must count once")
        expect(pdfGroup.files.allSatisfy { $0.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" },
               "SHA-256 must match known complete-content digest")
        expect(scan.groups.contains { $0.files.contains { $0.path == after100.path } },
               "small files beyond the old top-100 limit must be included")
        expect(scan.files.count > 125, "candidate enumeration must not be capped at 100")
        expect(!scan.files.contains { $0.path.contains(".hidden/unique") }, "hidden application data must be excluded")
        expect(scan.files.allSatisfy { !$0.path.contains("linked-") && $0.path != resourceFork.path },
               "symlinks and resource forks must be excluded")
        expect(scan.files.allSatisfy { file in !forbidden.contains { file.path == home.appendingPathComponent($0).path } },
               "private data, packages, managed trees and placeholders must be excluded")
        expect(reports.first?.phase == "enumerating" && reports.last?.phase == "finished",
               "progress must include enumeration and completion")
        expect(reports.count < scan.files.count, "progress must be throttled")
        expect(pdfGroup.reclaimableBytes == 3, "candidate size counts only additional logical copies")
        let blocked = try write("Documents/blocked-subtree/secret", Data("private fixture".utf8)).deletingLastPathComponent()
        expect(chmod(blocked.path, 0) == 0, "permission-denied descendant fixture must be restricted")
        defer { chmod(blocked.path, 0o700) }
        let restricted = DuplicateScanner.scan(roots: [root.path, second.path],
                                               control: DuplicateScanControl(), home: home.path)
        expect(chmod(blocked.path, 0o700) == 0, "restore permission-denied descendant fixture")
        expect(!restricted.isPartial && !restricted.cancelled && restricted.error == nil,
               "permission-denied descendants are ordinary skips rather than an incomplete scan failure")
        expect(restricted.skippedFiles > scan.skippedFiles && restricted.groups.count == scan.groups.count,
               "permission skips remain counted while readable duplicate groups are retained")
        expect(!restricted.files.contains { $0.path.hasPrefix(blocked.path + "/") },
               "restricted descendant contents must not be scanned")

        let unreadableRoot = try write("Unreadable/secret", Data("unreadable root fixture".utf8)).deletingLastPathComponent()
        expect(chmod(unreadableRoot.path, 0) == 0, "selected unreadable root fixture must be restricted")
        defer { chmod(unreadableRoot.path, 0o700) }
        let rootFailure = DuplicateScanner.scan(roots: [unreadableRoot.path],
                                                control: DuplicateScanControl(), home: home.path)
        expect(chmod(unreadableRoot.path, 0o700) == 0, "restore selected unreadable root fixture")
        expect(rootFailure.isPartial && rootFailure.error != nil && !rootFailure.cancelled
               && rootFailure.files.isEmpty && rootFailure.groups.isEmpty,
               "failure to read the selected root remains a real error rather than a complete empty result")
        for file in pdfGroup.files {
            try DuplicateScanner.revalidate(file, allowedRoots: scan.roots, control: DuplicateScanControl(), home: home.path)
        }
        let originalFile = pdfGroup.files.first { $0.path != renamed.path }!
        rejects("unselected roots must not authorize hashing") {
            _ = try DuplicateScanner.hash(originalFile, allowedRoots: [second.path], control: DuplicateScanControl(), home: home.path)
        }
        let unhashed = scan.files.first { $0.sha256.isEmpty }!
        rejects("unhashed file must not pass a deletion content check") {
            try DuplicateScanner.revalidate(unhashed, allowedRoots: scan.roots, control: DuplicateScanControl(), home: home.path)
        }
        try Data("xyz".utf8).write(to: renamed)
        let stale = pdfGroup.files.first { $0.path == renamed.path }!
        rejects("same-length changed file must invalidate scan identity") {
            try DuplicateScanner.revalidate(stale, allowedRoots: scan.roots, control: DuplicateScanControl(), home: home.path)
        }
        try fm.removeItem(at: renamed)
        try fm.createSymbolicLink(at: renamed, withDestinationURL: original)
        rejects("replacement symlink must never be followed") {
            _ = try DuplicateScanner.hash(stale, allowedRoots: scan.roots, control: DuplicateScanControl(), home: home.path)
        }
        let alias = home.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: second)
        expect(!DuplicateScanner.isAllowedRoot(alias.appendingPathComponent("nested").path, home: home.path),
               "a root with a symlink ancestor must be refused")
        for forbiddenRoot in ["/", "/System", "/Library", "/Applications", home.appendingPathComponent("Library").path,
                              root.appendingPathComponent("Test.app/Contents").path] {
            expect(!DuplicateScanner.isAllowedRoot(forbiddenRoot, home: home.path), "unsafe root must be refused: \(forbiddenRoot)")
        }
        let cancelled = DuplicateScanControl()
        cancelled.cancel()
        let stopped = DuplicateScanner.scan(roots: [root.path], control: cancelled, home: home.path)
        expect(stopped.cancelled && stopped.isPartial && stopped.files.isEmpty, "pre-cancelled scan must stop immediately")
        let midScan = DuplicateScanControl()
        let midResult = DuplicateScanner.scan(roots: [root.path], control: midScan, home: home.path) {
            if $0.phase == "hashing" { midScan.cancel() }
        }
        expect(midResult.cancelled && midResult.isPartial && midResult.groups.isEmpty,
               "cancellation between sampling and hashing must not emit unverified groups")
        // Enumeration identity must survive until full hashing, not merely sampling.
        let racing = try write("Downloads/racing-a", Data(repeating: 7, count: 256 * 1024))
        _ = try write("Downloads/racing-b", Data(repeating: 7, count: 256 * 1024))
        var modified = false
        let raced = DuplicateScanner.scan(roots: [second.path], control: DuplicateScanControl(), home: home.path) {
            if $0.phase == "hashing", !modified {
                modified = true
                try! Data(repeating: 8, count: 256 * 1024).write(to: racing)
            }
        }
        expect(raced.isPartial && raced.groups.isEmpty, "changed file must not enter a complete duplicate group")
        try testIncrementalCache(home: home)
        print("DuplicateScanner: all checks passed")
    }

    static func testIncrementalCache(home: URL) throws {
        let root = home.appendingPathComponent("Documents/Cache")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("a.dat"), second = root.appendingPathComponent("b.dat")
        try Data(repeating: 31, count: 256 * 1_024).write(to: first)
        try FileManager.default.copyItem(at: first, to: second)
        let cache = DuplicateContentCache()
        var reads: UInt64 = 0
        func scan() -> DuplicateScanResult {
            DuplicateScanner.scan(roots: [root.path], control: DuplicateScanControl(), home: home.path,
                                  cache: cache) { reads = $0.bytesRead }
        }
        let initial = scan()
        expect(initial.groups.count == 1 && reads > 0, "first cached scan must read and verify content")
        let repeated = scan()
        expect(repeated.groups.count == 1 && reads == 0,
               "an unchanged re-scan must reuse sample and full digests without reading file content")
        let old = repeated.files.first { $0.path == second.path }!
        try Data(repeating: 32, count: 256 * 1_024).write(to: second)
        let changed = scan()
        expect(changed.groups.isEmpty && reads > 0 && cache.digest(for: old, sample: false) == nil,
               "same-size replacement must invalidate old hashes and update only the changed content")
        let added = root.appendingPathComponent("c.dat")
        try FileManager.default.copyItem(at: first, to: added)
        let appended = scan()
        expect(appended.groups.count == 1 && appended.groups[0].files.map(\.path).contains(added.path),
               "incremental re-scan must discover newly added duplicate files")
        let removed = appended.files.first { $0.path == added.path }!
        try FileManager.default.removeItem(at: added)
        let pruned = scan()
        expect(pruned.groups.isEmpty && cache.digest(for: removed, sample: false) == nil,
               "successful discovery must prune vanished files from the content cache")
        cache.invalidate(paths: [root.path])
        expect(cache.digest(for: appended.files.first { $0.path == first.path }!, sample: false) == nil,
               "a known directory mutation must invalidate all descendant cache entries")
    }
}
