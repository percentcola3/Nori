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

        let cached = try file("cached-image.jpg")
        let scanFingerprint = AnalysisFileFingerprint.read(cached.path)!
        let replacementData = Data("replacement must survive stale cached selection".utf8)
        try replacementData.write(to: cached, options: .atomic)
        let cachedPlan = AnalysisFileDeletionPlan(requestedPaths: [cached.path],
            inventoryPaths: [cached.path], scanFingerprints: [cached.path: scanFingerprint])
        let cachedResult = cachedPlan.execute(homeDirectory: home.path)
        let remainingReplacement = try Data(contentsOf: cached)
        try expect(cachedResult.removed == 0 && cachedResult.skipped == 1
                   && remainingReplacement == replacementData && AnalysisFixtureFileManager.trashedPaths.isEmpty,
                   "a replacement at a cached file path must survive until the user reviews a fresh scan")

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
        let folder = downloads.appendingPathComponent("selected-folder")
        let nested = folder.appendingPathComponent("nested")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        let payload = nested.appendingPathComponent("payload.txt")
        try Data("folder payload".utf8).write(to: payload)
        try expect(!AnalysisFileDeletionPlan.isEligible(path: folder.path, homeDirectory: home.path)
            && AnalysisFileDeletionPlan.isEligible(path: folder.path, homeDirectory: home.path, allowsDirectories: true),
            "Directories require an explicit disk-browser opt-in")
        let folderFingerprint = AnalysisFileFingerprint.read(folder.path)!
        let implicitFolder = AnalysisFileDeletionPlan(requestedPaths: [folder.path], inventoryPaths: [folder.path])
        try expect(implicitFolder.items.isEmpty && implicitFolder.refusedCount == 1,
                   "File-only classifications must not acquire directory deletion")
        let staleFolder = AnalysisFileDeletionPlan(requestedPaths: [folder.path], inventoryPaths: [folder.path],
            scanFingerprints: [folder.path: folderFingerprint], allowsDirectories: true)
        try Data("new entry".utf8).write(to: folder.appendingPathComponent("added.txt"))
        let staleFolderResult = staleFolder.execute(homeDirectory: home.path)
        try expect(staleFolderResult.removed == 0 && staleFolderResult.skipped == 1 && fm.fileExists(atPath: payload.path),
                   "A directory changed after confirmation must survive")
        let changedScan = AnalysisFileDeletionPlan(requestedPaths: [folder.path], inventoryPaths: [folder.path],
            scanFingerprints: [folder.path: folderFingerprint], allowsDirectories: true)
        try expect(changedScan.items.isEmpty, "A stale scanned directory must require refreshed results")
        try expect(!AnalysisFileDeletionPlan.isEligible(path: home.path, homeDirectory: home.path, allowsDirectories: true)
            && !AnalysisFileDeletionPlan.isEligible(path: "/System", homeDirectory: home.path, allowsDirectories: true),
            "Home and system roots must remain unselectable")
        let bundle = downloads.appendingPathComponent("fixture.app")
        try fm.createDirectory(at: bundle, withIntermediateDirectories: false)
        try expect(!AnalysisFileDeletionPlan.isEligible(path: bundle.path, homeDirectory: home.path, allowsDirectories: true),
                   "Application bundles are not ordinary directory cleanup candidates")
        let link = downloads.appendingPathComponent("folder-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: folder)
        let linkPlan = AnalysisFileDeletionPlan(requestedPaths: [link.path], inventoryPaths: [link.path], allowsDirectories: true)
        try expect(linkPlan.items.isEmpty, "Directory symlinks must not enter the deletion plan")
        let currentFolder = AnalysisFileDeletionPlan(requestedPaths: [folder.path], inventoryPaths: [folder.path],
            scanFingerprints: [folder.path: AnalysisFileFingerprint.read(folder.path)!], allowsDirectories: true)
        let folderResult = currentFolder.execute(homeDirectory: home.path)
        let trashedPayload = trash.appendingPathComponent("selected-folder/nested/payload.txt")
        let trashedData = try Data(contentsOf: trashedPayload)
        try expect(folderResult.removed == 1 && folderResult.failed == 0 && folderResult.skipped == 0
            && folderResult.removedPaths == [folder.path] && !fm.fileExists(atPath: folder.path)
            && trashedData == Data("folder payload".utf8) && fm.fileExists(atPath: unrelated.path),
            "An explicitly selected directory must move intact into the isolated Trash")
        print("PASS: disk directory deletion is opt-in, rejects stale scans, packages, roots and symlinks, and preserves nested contents in Trash")
        print("PASS: analysis deletion rejects foreign paths, stale identities and parent symlinks; current selection moves to isolated Trash once")
    }
}
