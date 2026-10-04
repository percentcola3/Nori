import Foundation

@main
struct DeveloperPathCommandTests {
    typealias Service = DeveloperPathCommandService

    static func expect(_ condition: Bool, _ message: String) {
        guard condition else {
            FileHandle.standardError.write(Data(("FAIL: \(message)\n").utf8))
            exit(1)
        }
    }

    static func write(_ contents: String, to url: URL, executable: Bool = true) throws {
        try contents.write(to: url, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644],
                                             ofItemAtPath: url.path)
    }

    static func main() throws {
        let manager = FileManager.default
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let directory = fixture.appendingPathComponent("commands with spaces", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let sentinel = fixture.appendingPathComponent("must-not-execute")
        let sentinelCommand = directory.appendingPathComponent("python3")
        try write("#!/bin/sh\n: > '\(sentinel.path)'\n", to: sentinelCommand)
        try write("#!/bin/sh\nexit 0\n", to: directory.appendingPathComponent("pip3"))
        try write("#!/bin/sh\nexit 0\n", to: directory.appendingPathComponent(".hidden-command"))
        try write("plain text", to: directory.appendingPathComponent("not-executable"), executable: false)
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        try write("#!/bin/sh\nexit 0\n", to: nested.appendingPathComponent("nested-command"))

        let target = fixture.appendingPathComponent("actual executable")
        try write("#!/bin/sh\nexit 0\n", to: target)
        try manager.createSymbolicLink(atPath: directory.appendingPathComponent("linked-tool").path,
                                       withDestinationPath: "../actual executable")
        try manager.createSymbolicLink(atPath: directory.appendingPathComponent("dangling-tool").path,
                                       withDestinationPath: "../missing-file")
        try manager.createSymbolicLink(atPath: directory.appendingPathComponent("directory-link").path,
                                       withDestinationPath: nested.path)
        try manager.createSymbolicLink(atPath: directory.appendingPathComponent("non-executable-link").path,
                                       withDestinationPath: "not-executable")

        let inventory = Service.scan(directory: directory.path)
        expect(inventory.status == .available, "a readable PATH directory is available")
        expect(inventory.names == ["linked-tool", "pip3", "python3"],
               "only direct executable regular files and valid executable symlinks are commands")
        expect(!manager.fileExists(atPath: sentinel.path), "scanning must never launch a discovered command")
        expect(Service.scan(directory: fixture.appendingPathComponent("missing-directory").path).status == .missingDirectory,
               "a missing directory is distinguished from an empty directory")
        expect(Service.scan(directory: target.path).status == .notDirectory,
               "a regular file is distinguished from a directory")
        expect(Service.scan(directory: "relative/bin").status == .unavailable,
               "relative directories are not implicitly resolved")
        expect(Service.normalizedDirectory("~/bin") == nil, "shell expressions are not evaluated")

        let empty = fixture.appendingPathComponent("empty", isDirectory: true)
        try manager.createDirectory(at: empty, withIntermediateDirectories: true)
        expect(Service.scan(directory: empty.path) == Service.Inventory(names: [], status: .available),
               "a readable empty directory is available with no commands")
        let unreadable = fixture.appendingPathComponent("unreadable", isDirectory: true)
        try manager.createDirectory(at: unreadable, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unreadable.path) }
        // Elevated test runners can still read mode-000 directories; exercise the failure when
        // the runner's filesystem permissions actually deny access.
        if !manager.isReadableFile(atPath: unreadable.path) {
            expect(Service.scan(directory: unreadable.path).status == .unavailable,
                   "a directory read failure is distinguished from an empty directory")
        }
        let normalized = directory.appendingPathComponent("../commands with spaces/.", isDirectory: true).path
        let inventories = Service.scan(directories: [directory.path, normalized, empty.path, "relative"])
        expect(inventories.count == 2 && inventories[Service.normalizedDirectory(directory.path)!] == inventory,
               "batch scans deduplicate standardized absolute keys")
        let directoryLink = fixture.appendingPathComponent("linked directory", isDirectory: true)
        try manager.createSymbolicLink(atPath: directoryLink.path, withDestinationPath: directory.path)
        let linkedInventory = Service.scan(directory: directoryLink.path)
        expect(linkedInventory == inventory,
               "a directory symlink exposes its direct executable contents: \(linkedInventory)")

        // Each scan must reflect the disk, including a symlink whose target stopped being executable.
        try manager.removeItem(at: directory.appendingPathComponent("pip3"))
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        try write("#!/bin/sh\nexit 0\n", to: directory.appendingPathComponent("new-tool"))
        expect(Service.scan(directory: directory.path).names == ["new-tool", "python3"],
               "rescans replace stale file and symlink inventories")
        expect(!manager.fileExists(atPath: sentinel.path), "repeated scans must still never execute commands")
        print("Developer PATH command tests passed")
    }
}
