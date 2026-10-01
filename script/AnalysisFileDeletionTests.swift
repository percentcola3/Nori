import Foundation

/// Substitute only FileManager's final Trash operation in the fixture copy of
/// NativeCore. All selection, identity, root, whitelist and runtime guards run
/// through the production executor; mutations stay inside the test directory.
final class AnalysisFixtureFileManager: FileManager {
    static var trashDirectory: URL!
    static var trashedPaths: [String] = []

    override func trashItem(at url: URL,
                            resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        let destination = Self.trashDirectory.appendingPathComponent(url.lastPathComponent)
        try moveItem(at: url, to: destination)
        Self.trashedPaths.append(url.path)
        outResultingURL?.pointee = destination as NSURL
    }
}

@main
struct AnalysisFileDeletionTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw NSError(domain: "AnalysisFileDeletionTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func main() throws {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let downloads = home.appendingPathComponent("Downloads")
        let trash = home.appendingPathComponent(".Trash")
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        AnalysisFixtureFileManager.trashDirectory = trash

        func file(_ name: String) throws -> URL {
            let url = downloads.appendingPathComponent(name)
            try Data(("owned fixture " + name).utf8).write(to: url)
            return url
        }
        let selected = try file("selected.txt")
        let unrelated = try file("unrelated.txt")
        let foreign = AnalysisFileDeletionPlan(requestedPaths: [unrelated.path],
                                              inventoryPaths: [selected.path])
        let foreignResult = foreign.execute(homeDirectory: home.path)
        try expect(foreignResult.removed == 0 && foreignResult.skipped == 1
                   && fm.fileExists(atPath: unrelated.path) && AnalysisFixtureFileManager.trashedPaths.isEmpty,
                   "out-of-inventory request must preserve the file and never reach Trash")

        let stale = AnalysisFileDeletionPlan(requestedPaths: [selected.path],
                                            inventoryPaths: [selected.path])
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: selected.path)
        let staleResult = stale.execute(homeDirectory: home.path)
        try expect(staleResult.removed == 0 && staleResult.skipped == 1
                   && fm.fileExists(atPath: selected.path) && AnalysisFixtureFileManager.trashedPaths.isEmpty,
                   "identity changed after confirmed action must never reach Trash")

        let parent = downloads.appendingPathComponent("parent")
        try fm.createDirectory(at: parent, withIntermediateDirectories: false)
        let child = parent.appendingPathComponent("child.txt")
        try Data("original file".utf8).write(to: child)
        let parentPlan = AnalysisFileDeletionPlan(requestedPaths: [child.path], inventoryPaths: [child.path])
        let movedParent = downloads.appendingPathComponent("moved-parent")
        try fm.moveItem(at: parent, to: movedParent)
        try fm.createSymbolicLink(at: parent, withDestinationURL: movedParent)
        let parentResult = parentPlan.execute(homeDirectory: home.path)
        try expect(parentResult.removed == 0 && parentResult.skipped == 1
                   && fm.fileExists(atPath: movedParent.appendingPathComponent("child.txt").path),
                   "a parent symlink replacement must preserve the original object")

        let current = AnalysisFileDeletionPlan(requestedPaths: [selected.path, selected.path],
                                              inventoryPaths: [selected.path])
        let result = current.execute(homeDirectory: home.path)
        try expect(result.removed == 1 && result.skipped == 0 && result.failed == 0
                   && result.removedPaths == [selected.path]
                   && !fm.fileExists(atPath: selected.path)
                   && fm.fileExists(atPath: trash.appendingPathComponent(selected.lastPathComponent).path)
                   && AnalysisFixtureFileManager.trashedPaths == [selected.path],
                   "a current inventoried file must move to Trash exactly once and reconcile the result")
        try expect(fm.fileExists(atPath: unrelated.path), "successful Trash must preserve unrelated files")
        print("PASS: analysis deletion rejects foreign paths, stale identities and parent symlinks; current selection moves to isolated Trash once")
    }
}
