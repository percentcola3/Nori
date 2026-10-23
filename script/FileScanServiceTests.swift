import Darwin
import Foundation

@main
struct FileScanServiceTests {
    static func main() throws {
        let manager = FileManager.default
        let root = CommandLine.arguments[1]
        let nested = root + "/nested"
        try manager.createDirectory(atPath: nested, withIntermediateDirectories: true)
        let file = nested + "/payload.txt"
        try Data(repeating: 1, count: 4096).write(to: URL(fileURLWithPath: file))
        try manager.linkItem(atPath: file, toPath: root + "/hard-link")
        try manager.createSymbolicLink(atPath: root + "/loop", withDestinationPath: root)
        try manager.createSymbolicLink(atPath: root + "/missing", withDestinationPath: root + "/absent")
        try Data([1]).write(to: URL(fileURLWithPath: root + "/.hidden"))

        func blocks(_ path: String) -> UInt64 {
            var info = stat()
            precondition(lstat(path, &info) == 0)
            return UInt64(max(0, info.st_blocks)) * 512
        }
        let expected = blocks(root) + blocks(nested) + blocks(file) + blocks(root + "/.hidden")
        let cleanup = FileScanService.measure(root, policy: .cleanup)
        precondition(cleanup.complete && cleanup.files == 2 && cleanup.bytes == expected,
                     "Cleanup must count allocated bytes, hidden files and hard links exactly once")
        precondition(cleanup.newestModified != nil && cleanup.newestAccessed != nil,
                     "Activity evidence must share the size walk")
        let directory = FileScanService.measure(root, policy: .directory)
        precondition(directory.complete && directory.bytes == expected + blocks(root + "/loop") + blocks(root + "/missing"),
                     "Directory measurement must include links themselves without traversing them")
        let linkOnly = FileScanService.measure(root + "/loop", policy: .directory)
        precondition(linkOnly.complete && linkOnly.bytes == blocks(root + "/loop") && linkOnly.files == 0,
                     "A root symlink must never size its target")
        precondition(FileScanService.measure(root + "/loop", policy: .cleanup).bytes == 0,
                     "Cleanup's existing link exclusion must remain separate from directory accounting")
        let names = try FileScanService.childNames(in: root)
        precondition(Set(names) == Set(["nested", "hard-link", "loop", "missing", ".hidden"]),
                     "Shared listing must preserve hidden and dangling entries and exclude dot/dotdot")
        let paths = try FileScanService.childPaths(in: root, sorted: true)
        precondition(paths == names.sorted().map { root + "/" + $0 })
        errno = 0
        precondition(FileScanService.metadata(at: root + "/absent") == nil && errno == ENOENT,
                     "Metadata must preserve a missing path's POSIX reason")
        precondition((FileScanService.metadata(at: root + "/missing")?.st_mode ?? 0) & S_IFMT == S_IFLNK,
                     "Metadata must inspect the dangling link itself")
        precondition(!FileScanService.measure(root, policy: .cleanup, maximumSeconds: 0).complete)
        precondition(!FileScanService.measure(root, policy: .directory, shouldStop: { true }).complete)
        var stopped = false
        let partial = FileScanService.measure(root, policy: .cleanup, shouldStop: { stopped }, onDirectory: { path in
            if path == nested { stopped = true }
        })
        precondition(!partial.complete && partial.bytes <= cleanup.bytes,
                     "Mid-walk cancellation must return a lower bound, not a complete zero")
        do {
            _ = try FileScanService.childNames(in: file)
            preconditionFailure("A non-directory cannot return an empty successful inventory")
        } catch {
            let error = error as NSError
            precondition(error.domain == NSPOSIXErrorDomain && error.code == Int(ENOTDIR))
        }
        if geteuid() != 0 {
            let locked = root + "/locked"
            try manager.createDirectory(atPath: locked, withIntermediateDirectories: true)
            precondition(chmod(locked, 0) == 0)
            defer { chmod(locked, 0o700) }
            precondition(!FileScanService.measure(locked, policy: .cleanup).complete)
            precondition(!FileScanService.measure(locked, policy: .directory).complete)
        }
        print("PASS: shared file scanning, accounting policies, links, hard links, activity, cancellation and access failures")
    }
}
