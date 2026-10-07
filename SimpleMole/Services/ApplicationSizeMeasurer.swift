import Darwin
import Foundation

protocol ApplicationSizeMeasuring: Sendable {
    func allocatedBytes(at root: URL) -> UInt64
}

/// Size-only traversal for application inventories and previews. The old
/// analysis-shaped result was never consumed: avoid collecting/sorting large
/// file records while retaining the same limits and hard-link accounting.
struct BoundedApplicationSizeMeasurer: ApplicationSizeMeasuring {
    var maximumEntries = 200_000
    var maximumSeconds: TimeInterval = 3
    private let keys: Set<URLResourceKey> = [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
        .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .fileSizeKey
    ]
    private struct Identity: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    func allocatedBytes(at root: URL) -> UInt64 {
        let fileManager = FileManager.default
        func isSymlink(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true }
        func isDirectory(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        func size(_ url: URL) -> UInt64 {
            guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
            return UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
        }
        guard fileManager.fileExists(atPath: root.path), !isSymlink(root) else { return 0 }
        guard isDirectory(root) else { return size(root) }
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: []) else { return 0 }
        let deadline = Date().addingTimeInterval(maximumSeconds)
        var bytes: UInt64 = 0
        var visited = 0
        var seen = Set<Identity>()
        for case let child as URL in enumerator {
            visited += 1
            if visited > maximumEntries || Date() >= deadline { break }
            if isSymlink(child) { enumerator.skipDescendants(); continue }
            if isDirectory(child) { continue }
            var metadata = stat()
            guard Darwin.lstat(child.path, &metadata) == 0,
                  seen.insert(.init(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))).inserted else { continue }
            bytes &+= size(child)
        }
        return bytes
    }
}
