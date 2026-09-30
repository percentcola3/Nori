import Darwin
import Foundation

@main
struct DuplicateDeletionTests {
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NSError(domain: "DuplicateDeletionTests", code: 1,
                                   userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func rejects(_ message: String, _ action: () throws -> Void) throws {
        var rejected = false
        do { try action() } catch { rejected = true }
        try expect(rejected, message)
    }

    static func main() throws {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: CommandLine.arguments[1]).standardized
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        func fixture(_ name: String, contents: [String] = ["same-file", "same-file", "same-file"])
            throws -> (String, [DuplicateFile]) {
            let root = home.appendingPathComponent(name)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            for (index, content) in contents.enumerated() {
                try Data(content.utf8).write(to: root.appendingPathComponent("\(index).txt"))
            }
            let discovery = DuplicateScanner.enumerate(roots: [root.path], control: DuplicateScanControl(), home: home.path)
            let files = try discovery.files.map {
                try DuplicateScanner.hash($0, allowedRoots: [root.path], control: DuplicateScanControl(), home: home.path)
            }
            try expect(files.count == contents.count, "fixture enumeration failed")
            return (root.path, files)
        }
        func plan(_ root: String, _ files: [DuplicateFile], _ selected: Set<String>, exact: Bool = true)
            throws -> DuplicateDeletionPlan {
            try DuplicateDeletionPlan(groups: [DuplicateDeletionGroup(files: files, requiresExactMatch: exact)],
                                      selectedPaths: selected, roots: [root], home: home.path)
        }

        let (root, files) = try fixture("selection")
        try rejects("selecting the whole group must fail") {
            _ = try plan(root, files, Set(files.map(\.path)))
        }
        try rejects("a path outside the reviewed group must fail") {
            _ = try plan(root, files, [root + "/not-in-result"])
        }
        let safe = try plan(root, files, [files[0].path, files[1].path])
        try safe.validate(files[0].path, control: DuplicateScanControl())
        try expect(safe.items.count == 2 && !safe.items.contains(where: { $0.record == files[2].path }),
                   "keeper must never reach the mutation sink")
        try fm.removeItem(atPath: files[2].path)
        try rejects("removed keeper must stop the next operation") {
            try safe.validate(files[1].path, control: DuplicateScanControl())
        }
        try expect(fm.fileExists(atPath: files[0].path) && fm.fileExists(atPath: files[1].path),
                   "validation must be read-only")

        let (changedRoot, changedFiles) = try fixture("changed")
        let changedPlan = try plan(changedRoot, changedFiles, [changedFiles[0].path])
        let oldDate = try fm.attributesOfItem(atPath: changedFiles[0].path)[.modificationDate]!
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: changedFiles[0].path))
        try handle.write(contentsOf: Data("else-file".utf8))
        try handle.close()
        try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: changedFiles[0].path)
        try rejects("same-size edit with restored mtime must fail") {
            try changedPlan.validate(changedFiles[0].path, control: DuplicateScanControl())
        }

        let (hashRoot, hashFiles) = try fixture("digest")
        let wrong = DuplicateFile(path: hashFiles[0].path, name: hashFiles[0].name, size: hashFiles[0].size,
                                  identity: hashFiles[0].identity, sha256: String(repeating: "0", count: 64))
        try rejects("full-content evidence must be checked, not only identity") {
            let mismatch = try plan(hashRoot, [wrong, hashFiles[1]], [wrong.path], exact: false)
            try mismatch.validate(wrong.path, control: DuplicateScanControl())
        }
        let cancelled = DuplicateScanControl()
        cancelled.cancel()
        try rejects("cancelled validation cannot permit deletion") {
            try plan(hashRoot, hashFiles, [hashFiles[0].path]).validate(hashFiles[0].path, control: cancelled)
        }

        let (similarRoot, similarFiles) = try fixture("similar", contents: ["image-one", "image-two"])
        try rejects("unequal content must not be accepted as an exact duplicate group") {
            _ = try plan(similarRoot, similarFiles, [similarFiles[0].path])
        }
        let similarPlan = try plan(similarRoot, similarFiles, [similarFiles[0].path], exact: false)
        try similarPlan.validate(similarFiles[0].path, control: DuplicateScanControl())
        try Data("edited-image".utf8).write(to: URL(fileURLWithPath: similarFiles[1].path))
        try rejects("changed similar-image keeper must also fail") {
            try similarPlan.validate(similarFiles[0].path, control: DuplicateScanControl())
        }

        let (linkRoot, linkFiles) = try fixture("parent")
        let linkPlan = try plan(linkRoot, linkFiles, [linkFiles[0].path])
        let moved = linkRoot + "-moved"
        try fm.moveItem(atPath: linkRoot, toPath: moved)
        try fm.createSymbolicLink(atPath: linkRoot, withDestinationPath: moved)
        try rejects("parent symlink substitution must fail") {
            try linkPlan.validate(linkFiles[0].path, control: DuplicateScanControl())
        }

        try rejects("a plan cannot authorize files outside selected roots") {
            let escaped = try DuplicateDeletionPlan(groups: [DuplicateDeletionGroup(files: hashFiles, requiresExactMatch: true)],
                selectedPaths: [hashFiles[0].path], roots: [root], home: home.path)
            try escaped.validate(hashFiles[0].path, control: DuplicateScanControl())
        }
        print("PASS: duplicate deletion keeps one copy, binds reviewed content, rejects stale/missing keepers, parent symlinks, changed similar images, cancelled and out-of-scope plans")
    }
}
