import Foundation

@main
struct DirectorySearchTests {
    static func main() async throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("nori-directory-search-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("files", isDirectory: true)
        let outside = temporary.appendingPathComponent("files-sibling", isDirectory: true)
        let databaseURL = temporary.appendingPathComponent("index/files.sqlite")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        func file(_ path: String, in folder: URL = root) throws -> URL {
            let url = folder.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("test".utf8).write(to: url)
            return url
        }
        let visible = try file("report.txt")
        let hiddenFile = try file(".secret-report.txt")
        let hiddenAncestor = try file(".hidden/nested/report.txt")
        let unicode = try file("ÉCOLE中文.txt")
        let literal = try file("literal_100%.txt")
        let quote = try file("double\"quote.txt")
        let slash = try file("slash\\file.txt")
        _ = try file("OutsideOnly.txt", in: outside)
        try fm.createSymbolicLink(at: root.appendingPathComponent("shortcut"), withDestinationURL: outside)
        let brokenLink = root.appendingPathComponent("broken-report-link")
        try fm.createSymbolicLink(at: brokenLink, withDestinationURL: outside.appendingPathComponent("missing"))
        _ = try file("HiddenPackageOnly.txt", in: root.appendingPathComponent("Sample.app"))

        let index = try DirectorySearchIndex(databaseURL: databaseURL)
        let initial = try await index.status()
        expect(initial.indexedItemCount == 0 && initial.lastUpdated == nil, "An empty index reports its unbuilt state")
        let built = try await index.rebuild(roots: [root, root.appendingPathComponent(".hidden")])
        expect(built.roots == [root] && !built.isBuilding && built.lastUpdated != nil, "Snapshot root overlaps collapse and status persists")
        let pathMatches = try await index.searchPath(DirectoryPathQuery(visible.path)!, showHidden: true)
        expect(pathMatches.first == visible, "Exact indexed path is ranked first")
        let typoMatches = try await index.searchPath(DirectoryPathQuery(visible.path.replacingOccurrences(of: "report", with: "reprot"))!, showHidden: true)
        expect(typoMatches.contains(visible), "Indexed paths match filename transpositions")
        let reports = try await index.search(query: "REPORT")
        expect(Set(reports.map(\.url)) == Set([visible, hiddenFile, hiddenAncestor, brokenLink]), "Default search includes dotfiles, ancestors and broken links: \(reports.map(\.url)) expected \([visible, hiddenFile, hiddenAncestor, brokenLink])")
        let visibleReports = try await index.search(query: "report", showHidden: false)
        expect(Set(visibleReports.map(\.url)) == Set([visible, brokenLink]), "Hidden filtering examines the full path")
        let unicodeResults = try await index.search(query: "école中文")
        expect(unicodeResults.map(\.url) == [unicode], "Search is Unicode case and accent insensitive")
        let accentResults = try await index.search(query: "ECOLE")
        expect(accentResults.map(\.url) == [unicode], "Unicode accent folding is stored and queried consistently")
        expect(try await index.search(query: "_100%").map(\.url) == [literal], "SQL wildcard characters remain literal with FTS")
        expect(try await index.search(query: "%").map(\.url) == [literal], "A short wildcard query remains literal without FTS")
        expect(try await index.search(query: "double\"quote").map(\.url) == [quote], "FTS quotes remain literal")
        expect(try await index.search(query: "slash\\file").map(\.url) == [slash], "Backslashes remain literal")
        expect(try await index.search(query: "OutsideOnly").isEmpty, "Directory symlinks are indexed but never traversed")
        expect(try await index.search(query: "HiddenPackageOnly").isEmpty, "Application packages are treated as one file")
        expect(try await index.search(query: "report", limit: 1).count == 1, "Query materialization respects its result limit")

        let reused = try DirectorySearchIndex(databaseURL: databaseURL)
        expect(try await reused.status().indexedItemCount == built.indexedItemCount, "A new service reuses the persisted snapshot")
        expect(try await reused.search(query: "école").map(\.url) == [unicode], "Persisted trigram data stays searchable")

        let renamed = root.appendingPathComponent("renamed.txt")
        try fm.moveItem(at: visible, to: renamed)
        try await index.refresh(paths: [visible, renamed])
        expect(try await index.search(query: "renamed").map(\.url) == [renamed], "Rename adds the new filename incrementally")
        expect(!(try await index.search(query: "report").map(\.url)).contains(visible), "Rename removes the old filename")
        let created = try file("nested/new-file.txt")
        try await index.refresh(paths: [root.appendingPathComponent("nested")])
        expect(try await index.search(query: "new-file").map(\.url) == [created], "An affected subtree discovers copied or new files")
        try fm.removeItem(at: created)
        expect(try await index.search(query: "new-file").isEmpty, "Externally deleted rows never appear as usable files")
        try await index.refresh(paths: [created])
        try await index.refresh(paths: [outside])
        expect(try await index.search(query: "OutsideOnly").isEmpty, "Incremental refresh cannot silently expand configured roots")

        let beforeCancel = try await index.status()
        let cancellationRoot = temporary.appendingPathComponent("cancel", isDirectory: true)
        for position in 0..<1_200 { _ = try file("cancel-file-\(position).txt", in: cancellationRoot) }
        let cancellation = DirectorySearchTaskBox()
        let task = Task {
            try await index.rebuild(roots: [cancellationRoot]) { progress in
                if progress.scannedCount >= 256 { cancellation.cancel() }
            }
        }
        cancellation.set(task)
        do {
            _ = try await task.value
            fatalError("A rebuild cancelled during enumeration must throw")
        } catch is CancellationError { }
        let afterCancel = try await index.status()
        expect(!afterCancel.isBuilding && afterCancel.roots == beforeCancel.roots
                && afterCancel.indexedItemCount == beforeCancel.indexedItemCount
                && afterCancel.lastUpdated == beforeCancel.lastUpdated, "Cancellation preserves the entire previous snapshot")
        expect(try await index.search(query: "renamed").map(\.url) == [renamed], "The previous snapshot remains searchable after cancellation")
        expect(try await index.search(query: "cancel-file").isEmpty, "Partially scanned replacement rows stay invisible")

        let cancelledQuery = Task { try await index.search(query: "report") }
        cancelledQuery.cancel()
        do { _ = try await cancelledQuery.value; fatalError("A cancelled query must throw") }
        catch is CancellationError { }
        do {
            _ = try await index.rebuild(roots: [root.appendingPathComponent("shortcut")])
            fatalError("A symbolic link cannot become an index root")
        } catch DirectorySearchError.invalidRoot { }
        do {
            _ = try await index.rebuild(roots: [URL(string: "https://example.com/files")!])
            fatalError("A non-file URL cannot become an index root")
        } catch DirectorySearchError.invalidRoot { }
        print("PASS: persistent filename index, Unicode/literal queries, hidden ancestors, bounded results, symlink/package handling, incremental mutations, cancellation and atomic snapshots")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            print("FAIL: " + message)
            fflush(stdout)
            exit(1)
        }
    }
}

private final class DirectorySearchTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<DirectoryIndexStatus, Error>?
    func set(_ task: Task<DirectoryIndexStatus, Error>) { lock.lock(); self.task = task; lock.unlock() }
    func cancel() { lock.lock(); let pending = task; lock.unlock(); pending?.cancel() }
}
