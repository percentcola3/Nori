import Darwin
import Foundation

@main
struct DirectoryFileServiceTests {
    typealias Service = DirectoryFileService

    private final class CancellationCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func cancelAfterThreeChecks() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return count >= 3
        }
    }

    static func expect(_ condition: Bool, _ message: String) {
        guard condition else {
            FileHandle.standardError.write(Data(("FAIL: \(message)\n").utf8))
            exit(1)
        }
    }

    static func expectFailure(_ message: String, _ operation: () throws -> Void) {
        do {
            try operation()
            expect(false, message)
        } catch { }
    }

    static func blocks(_ url: URL) throws -> Int64 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return max(0, Int64(info.st_blocks)) * 512
    }

    static func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    static func main() throws {
        let manager = FileManager.default
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try manager.createDirectory(at: fixture, withIntermediateDirectories: true)
        let folder = try Service.createDirectory(in: fixture, name: "目录 with spaces")
        let file = try Service.createFile(in: folder, name: "notes.txt")
        try "original contents".write(to: file, atomically: false, encoding: .utf8)
        let hidden = try Service.createFile(in: folder, name: ".hidden")
        try Data(repeating: 7, count: 8192).write(to: hidden)
        let nested = try Service.createDirectory(in: folder, name: "nested")
        let nestedHidden = try Service.createFile(in: nested, name: ".nested-hidden")
        try Data(repeating: 1, count: 16384).write(to: nestedHidden)

        for invalid in ["", " ", ".", "..", "../escape", "a/b", "nul\0byte", String(repeating: "a", count: 256)] {
            expectFailure("unsafe file name must fail: \(invalid)") { _ = try Service.createFile(in: folder, name: invalid) }
            expectFailure("unsafe folder name must fail: \(invalid)") { _ = try Service.createDirectory(in: folder, name: invalid) }
            expectFailure("unsafe rename must fail: \(invalid)") { _ = try Service.rename(file, to: invalid) }
        }
        expect(!manager.fileExists(atPath: fixture.appendingPathComponent("escape").path), "names cannot escape the selected parent")
        expectFailure("creating a file never truncates an existing file") { _ = try Service.createFile(in: folder, name: "notes.txt") }
        expect(try read(file) == "original contents", "existing data survives exclusive creation")
        expectFailure("creating an existing folder is reported as a collision") { _ = try Service.createDirectory(in: folder, name: "nested") }
        expectFailure("non-file URL creation must fail") { _ = try Service.createFile(in: URL(string: "https://example.com/")!, name: "bad") }
        expectFailure("listing a file must fail") { _ = try Service.list(directory: file, showHidden: true) }

        let visible = try Service.list(directory: folder, showHidden: false)
        let all = try Service.list(directory: folder, showHidden: true)
        expect(visible.map(\.name) == ["nested", "notes.txt"], "folders sort first and immediate hidden entries can be disabled")
        expect(all.contains { $0.name == ".hidden" && $0.isHidden }, "hidden entries are exposed when enabled")
        expect(try Service.list(directory: nested, showHidden: false).isEmpty, "hidden filtering applies inside every visited folder")
        expect(try Service.list(directory: nested, showHidden: true).map(\.name) == [".nested-hidden"], "nested dot files are independently visible")
        let flagHidden = try Service.createFile(in: folder, name: "flag-hidden")
        expect(chflags(flagHidden.path, UInt32(UF_HIDDEN)) == 0, "fixture accepts native Finder hidden flag")
        expect(try DirectoryEntry(url: flagHidden).isHidden, "native hidden flag is recognized without a dot prefix")
        expect(!(try Service.list(directory: folder, showHidden: false)).contains { $0.url == flagHidden }, "native hidden flags participate in filtering")
        expect(chflags(flagHidden.path, 0) == 0, "native hidden fixture flag can be cleared")

        let sparse = try Service.createFile(in: folder, name: "sparse.data")
        let descriptor = open(sparse.path, O_WRONLY)
        expect(descriptor >= 0, "sparse fixture is writable")
        expect(ftruncate(descriptor, 32 * 1024 * 1024) == 0, "sparse file is created without content writes")
        expect(close(descriptor) == 0, "sparse descriptor closes")
        let sparseEntry = try DirectoryEntry.metadata(url: sparse)
        expect(sparseEntry.logicalBytes == 32 * 1024 * 1024, "logical size is retained separately")
        expect(sparseEntry.allocatedBytes == (try blocks(sparse)), "file disk use is actual filesystem blocks")
        expect((sparseEntry.allocatedBytes ?? Int64.max) < (sparseEntry.logicalBytes ?? 0), "sparse holes are not counted as occupied disk space")
        let folderEntry = try DirectoryEntry(url: folder)
        expect(folderEntry.logicalBytes == nil && folderEntry.allocatedBytes == nil, "unknown directory size is not displayed as zero")

        let loop = folder.appendingPathComponent("loop")
        try manager.createSymbolicLink(atPath: loop.path, withDestinationPath: folder.path)
        let broken = folder.appendingPathComponent("broken")
        try manager.createSymbolicLink(atPath: broken.path, withDestinationPath: "missing")
        let loopEntry = try DirectoryEntry(url: loop)
        expect(loopEntry.isSymbolicLink && loopEntry.isDirectory, "directory links remain navigable")
        expect(try DirectoryEntry(url: broken).isSymbolicLink, "dangling links have metadata")
        let linkSize = Service.allocatedSize(of: loop)
        expect(try linkSize.isComplete && linkSize.bytes == blocks(loop), "a root directory link is never traversed")
        let hardLink = folder.appendingPathComponent("hard-link")
        try manager.linkItem(at: file, to: hardLink)
        let paths = [folder, file, hidden, nested, nestedHidden, flagHidden, sparse, loop, broken]
        let expected = try paths.reduce(Int64(0)) { try $0 + blocks($1) }
        let size = Service.allocatedSize(of: folder)
        expect(size.isComplete && size.bytes == expected, "directory disk use includes hidden children and link blocks, and deduplicates hard links")
        let cancelled = Service.allocatedSize(of: folder, cancellation: { true })
        expect(!cancelled.isComplete && cancelled.bytes == 0, "immediate cancellation stops before opening a tree")
        let counter = CancellationCounter()
        let partial = Service.allocatedSize(of: folder, cancellation: { counter.cancelAfterThreeChecks() })
        expect(!partial.isComplete && partial.bytes <= size.bytes, "mid-tree cancellation returns a lower bound")
        expect(!Service.allocatedSize(of: fixture.appendingPathComponent("missing")).isComplete, "a vanished root is an incomplete measurement")

        let unreadable = try Service.createDirectory(in: fixture, name: "unreadable")
        _ = try Service.createFile(in: unreadable, name: "secret")
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        if !manager.isReadableFile(atPath: unreadable.path) {
            expect(!Service.allocatedSize(of: unreadable).isComplete, "access denial is an incomplete measurement")
        }
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unreadable.path)

        let destination = try Service.createDirectory(in: fixture, name: "destination")
        let firstCopy = try Service.copy([file], into: destination)
        let secondCopy = try Service.copy([file, file], into: destination)
        expect(firstCopy.map(\.lastPathComponent) == ["notes.txt"], "initial copies retain their original names")
        expect(secondCopy.map(\.lastPathComponent) == ["notes 2.txt"], "collisions receive a suffix and repeated pasteboard paths are deduplicated")
        expect(try read(firstCopy[0]) == "original contents" && read(secondCopy[0]) == "original contents", "copy preserves both source and preexisting destination contents")
        let dotCopies = try Service.copy([hidden], into: destination)
        let moreDotCopies = try Service.copy([hidden], into: destination)
        expect(dotCopies[0].lastPathComponent == ".hidden" && moreDotCopies[0].lastPathComponent == ".hidden 2", "dot-file collisions do not treat the whole name as an extension")
        let copiedLoop = try Service.copy([loop], into: destination)[0]
        expect(try DirectoryEntry(url: copiedLoop).isSymbolicLink, "copying a link does not recursively copy its target")
        let destinationBroken = destination.appendingPathComponent("broken")
        try manager.createSymbolicLink(atPath: destinationBroken.path, withDestinationPath: "does-not-exist")
        expectFailure("new-file creation must not replace a dangling symlink") { _ = try Service.createFile(in: destination, name: "broken") }
        let copiedBroken = try Service.copy([broken], into: destination)[0]
        expect(try copiedBroken.lastPathComponent == "broken 2" && DirectoryEntry(url: destinationBroken).isSymbolicLink, "collision checks protect dangling symlinks")

        expectFailure("copy into a descendant must fail") { _ = try Service.copy([folder], into: nested) }
        expectFailure("move into a descendant must fail") { _ = try Service.move([folder], into: nested) }
        expectFailure("copy into the source itself must fail") { _ = try Service.copy([folder], into: folder) }
        let nestedAlias = fixture.appendingPathComponent("nested-alias")
        try manager.createSymbolicLink(atPath: nestedAlias.path, withDestinationPath: nested.path)
        expectFailure("resolved destination aliases cannot bypass recursive copy protection") { _ = try Service.copy([folder], into: nestedAlias) }
        expectFailure("move to the same directory must fail without renaming") { _ = try Service.move([file], into: folder) }
        expect(manager.fileExists(atPath: file.path), "a rejected move preserves the original file")

        let renameSource = try Service.createFile(in: fixture, name: "rename-me.txt")
        let renamed = try Service.rename(renameSource, to: "renamed.txt")
        expect(!manager.fileExists(atPath: renameSource.path) && manager.fileExists(atPath: renamed.path), "rename moves only the selected entry")
        expect(try Service.rename(renamed, to: "renamed.txt") == renamed, "renaming to the existing name is a harmless no-op")
        let caseRenamed = try Service.rename(renamed, to: "RENAMED.txt")
        expect(caseRenamed.lastPathComponent == "RENAMED.txt", "case-only renames work on case-insensitive volumes")
        expect((try Service.list(directory: fixture, showHidden: true)).contains { $0.name == "RENAMED.txt" }, "case-only rename updates the displayed filename")
        let renamedAgain = try Service.rename(caseRenamed, to: "renamed.txt")
        expect(renamedAgain == renamed, "case-only rename can be reversed")
        let protected = try Service.createFile(in: fixture, name: "protected.txt")
        try "protected".write(to: protected, atomically: false, encoding: .utf8)
        expectFailure("rename never overwrites a different existing file") { _ = try Service.rename(renamed, to: "protected.txt") }
        expect(try read(protected) == "protected" && manager.fileExists(atPath: renamed.path), "failed rename preserves both files")

        let moveSource = try Service.createFile(in: fixture, name: "notes.txt")
        try "moved".write(to: moveSource, atomically: false, encoding: .utf8)
        let moved = try Service.move([moveSource], into: destination)
        expect(moved[0].lastPathComponent == "notes 3.txt" && !manager.fileExists(atPath: moveSource.path), "move suffixes collisions without overwriting existing files")
        expect(try read(moved[0]) == "moved" && read(firstCopy[0]) == "original contents", "collision-safe move retains every file's contents")

        let missing = fixture.appendingPathComponent("missing-source")
        do {
            _ = try Service.copy([missing, protected], into: destination)
            expect(false, "partial copy failure must report accurately")
        } catch let error as DirectoryFileBatchError {
            expect(error.operation == .copy && error.succeededURLs.count == 1 && error.failures.count == 1,
                   "batch error includes successful destinations and failed sources")
            expect(try error.failures[0].url == missing && read(error.succeededURLs[0]) == "protected", "batch continues after an individual failure")
        }
        let movePartial = try Service.createFile(in: fixture, name: "partial-move")
        do {
            _ = try Service.move([movePartial, missing], into: destination)
            expect(false, "partial move failure must report accurately")
        } catch let error as DirectoryFileBatchError {
            expect(error.operation == .move && error.succeededURLs.count == 1 && error.failures.count == 1,
                   "partial move reports completed items")
            expect(!manager.fileExists(atPath: movePartial.path) && manager.fileExists(atPath: error.succeededURLs[0].path), "completed moves are not hidden by later batch failure")
        }
        expect(!(try Service.list(directory: destination, showHidden: true)).contains { $0.name.hasPrefix(".nori-copy-") }, "staged copies leave no temporary files behind")

        let overlapping = try Service.createDirectory(in: fixture, name: "overlapping-selection")
        let overlappingChild = try Service.createFile(in: overlapping, name: "child")
        let overlapCopy = try Service.copy([overlappingChild, overlapping], into: destination)
        expect(overlapCopy.count == 1 && manager.fileExists(atPath: overlapCopy[0].appendingPathComponent("child").path), "copy collapses a selected descendant into its selected parent")
        let overlapMove = try Service.move([overlappingChild, overlapping], into: destination)
        expect(overlapMove.count == 1 && !manager.fileExists(atPath: overlapping.path), "move collapses selected descendants before moving the parent")

        // Trash refuses protected/invalid paths without exercising the user's
        // actual Trash. Successful deletion uses only FileManager.trashItem in
        // the service and has no permanent-delete fallback.
        do {
            try Service.trash([URL(fileURLWithPath: "/"), missing])
            expect(false, "invalid trash requests must fail")
        } catch let error as DirectoryFileBatchError {
            expect(error.operation == .trash && error.succeededURLs.isEmpty && error.failures.count == 1,
                   "trash refuses the selected root and collapses its descendants without deleting another item")
        }
        expectFailure("missing trash items must be reported") { try Service.trash([missing]) }
        expect(try read(protected) == "protected", "failed trash leaves unrelated entries intact")
        print("Directory filesystem tests passed")
    }
}
