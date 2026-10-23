import Darwin
import Foundation

enum DirectorySortField: String, CaseIterable, Sendable {
    case name, kind, modified, size

    var defaultAscending: Bool { self == .name || self == .kind }

    func sorted(_ entries: [DirectoryEntry], ascending: Bool) -> [DirectoryEntry] {
        entries.sorted { left, right in
            switch self {
            case .name:
                if left.isDirectory != right.isDirectory { return left.isDirectory }
            case .kind:
                let order = left.kindLabel.localizedStandardCompare(right.kindLabel)
                if order != .orderedSame { return ascending ? order == .orderedAscending : order == .orderedDescending }
            case .modified:
                if left.modifiedAt != right.modifiedAt {
                    guard let lhs = left.modifiedAt else { return false }
                    guard let rhs = right.modifiedAt else { return true }
                    return ascending ? lhs < rhs : lhs > rhs
                }
            case .size:
                if left.allocatedBytes != right.allocatedBytes {
                    guard let lhs = left.allocatedBytes else { return false }
                    guard let rhs = right.allocatedBytes else { return true }
                    return ascending ? lhs < rhs : lhs > rhs
                }
            }
            let order = left.name.localizedStandardCompare(right.name)
            if order == .orderedSame { return left.id < right.id }
            return self == .name && !ascending ? order == .orderedDescending : order == .orderedAscending
        }
    }
}

/// A single filesystem entry. Directory sizes are measured asynchronously;
/// nil means unknown rather than zero. A directory symlink remains navigable,
/// while its allocated size measures the link itself, never its target.
struct DirectoryEntry: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let isHidden: Bool
    let logicalBytes: Int64?
    var allocatedBytes: Int64?
    let modifiedAt: Date?
    var isGitRepository: Bool = false

    var kindLabel: String {
        if isSymbolicLink { return L10n.shared.t("dir.kind.link") }
        if isGitRepository { return L10n.shared.t("dir.git.repository") }
        if isDirectory { return L10n.shared.t("dir.kind.folder") }
        let fileExtension = url.pathExtension
        return fileExtension.isEmpty ? L10n.shared.t("dir.kind.file") : fileExtension.uppercased()
    }

    static func metadata(url: URL) throws -> DirectoryEntry {
        let url = try DirectoryFileService.fileURL(url)
        let info = try DirectoryFileService.fileInfo(url)
        let isLink = (info.st_mode & S_IFMT) == S_IFLNK
        var isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
        if isLink {
            var target = stat()
            if fstatat(AT_FDCWD, url.path, &target, 0) == 0 {
                isDirectory = (target.st_mode & S_IFMT) == S_IFDIR
            }
        }
        // stat flags do not require opening the content of cloud placeholders.
        let hidden = url.lastPathComponent.hasPrefix(".") || (info.st_flags & UInt32(UF_HIDDEN)) != 0
        let measured = !isDirectory || isLink
        let isGitRepository: Bool
        if isDirectory, !isLink, info.st_flags & 0x40000000 == 0,
           let marker = try? DirectoryFileService.fileInfo(url.appendingPathComponent(".git")) {
            isGitRepository = [S_IFDIR, S_IFREG].contains(marker.st_mode & S_IFMT)
        } else {
            isGitRepository = false
        }
        return DirectoryEntry(id: url.path, url: url, name: url.lastPathComponent,
                              isDirectory: isDirectory, isSymbolicLink: isLink, isHidden: hidden,
                              logicalBytes: measured ? max(0, Int64(info.st_size)) : nil,
                              allocatedBytes: measured ? DirectoryFileService.blocks(info) : nil,
                              modifiedAt: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)
                                  + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000),
                              isGitRepository: isGitRepository)
    }
}

extension DirectoryEntry {
    init(url: URL) throws {
        self = try Self.metadata(url: url)
    }
}

struct DirectorySizeResult: Equatable, Sendable {
    let bytes: Int64
    /// False means bytes is a lower bound, for example after cancellation or
    /// an unreadable directory. Dataless directories are never downloaded.
    let isComplete: Bool
}

enum DirectoryFileOperation: String, Sendable {
    case copy, move, trash
}

struct DirectoryFileFailure: Sendable {
    let url: URL
    let message: String
}

/// Batches continue after individual failures. The UI can refresh and report
/// successful items without implying that a partially completed batch failed
/// entirely. For trash, succeededURLs are original paths; for copy/move they
/// are the resulting destination paths.
struct DirectoryFileBatchError: LocalizedError, Sendable {
    let operation: DirectoryFileOperation
    let succeededURLs: [URL]
    let failures: [DirectoryFileFailure]

    var errorDescription: String? {
        failures.map { "\($0.url.lastPathComponent): \($0.message)" }.joined(separator: "\n")
    }
}

enum DirectoryFileError: LocalizedError {
    case invalidName
    case notFileURL
    case notDirectory(URL)
    case recursiveDestination(URL)
    case alreadyInDirectory(URL)
    case protectedRoot

    var errorDescription: String? {
        switch self {
        case .invalidName: return L10n.shared.t("dir.fileError.name")
        case .notFileURL: return L10n.shared.t("dir.fileError.url")
        case .notDirectory(let url): return L10n.shared.tf("dir.fileError.folder", url.path)
        case .recursiveDestination: return L10n.shared.t("dir.fileError.recursive")
        case .alreadyInDirectory: return L10n.shared.t("dir.fileError.sameFolder")
        case .protectedRoot: return L10n.shared.t("dir.fileError.root")
        }
    }
}

enum DirectoryFileService {
    static func list(directory: URL, showHidden: Bool) throws -> [DirectoryEntry] {
        let directory = try directoryURL(directory)
        let children = try FileScanService.childPaths(in: directory.path).map { URL(fileURLWithPath: $0) }
        // Metadata races are expected if another application removes an item
        // between enumeration and lstat. Preserve the remaining listing.
        return children.compactMap { try? DirectoryEntry.metadata(url: $0) }
            .filter { showHidden || !$0.isHidden }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
    }

    /// Sum actual filesystem blocks, including hidden entries and directory
    /// metadata. Hard links within a tree are counted once. No content is read,
    /// symlinks are not followed, and cancellation is checked for every entry.
    static func allocatedSize(of url: URL,
                              cancellation: @Sendable () -> Bool = { false }) -> DirectorySizeResult {
        guard let url = try? fileURL(url) else { return DirectorySizeResult(bytes: 0, isComplete: false) }
        let measured = FileScanService.measure(url.path, policy: .directory, shouldStop: cancellation)
        return DirectorySizeResult(bytes: Int64(measured.bytes), isComplete: measured.complete)
    }

    static func createDirectory(in directory: URL, name: String) throws -> URL {
        let destination = try newItemURL(in: directory, name: name)
        guard mkdir(destination.path, 0o755) == 0 else { throw posixError(url: destination) }
        return destination
    }

    static func createFile(in directory: URL, name: String) throws -> URL {
        let destination = try newItemURL(in: directory, name: name)
        // FileManager.createFile may truncate an existing file. Exclusive
        // creation protects both existing files and dangling symlinks.
        let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard descriptor >= 0 else { throw posixError(url: destination) }
        guard close(descriptor) == 0 else { throw posixError(url: destination) }
        return destination
    }

    static func rename(_ url: URL, to name: String) throws -> URL {
        let source = try mutableSource(url)
        _ = try fileInfo(source)
        let destination = try newItemURL(in: source.deletingLastPathComponent(), name: name)
        if source.path == destination.path { return source }
        // The exclusive Darwin rename also accepts case-only name changes on
        // case-insensitive APFS. It atomically refuses a different destination,
        // including one that appears after the UI's collision check.
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw posixError(url: destination)
        }
        return destination
    }

    static func copy(_ urls: [URL], into directory: URL) throws -> [URL] {
        try transfer(urls, into: directory, operation: .copy)
    }

    static func move(_ urls: [URL], into directory: URL) throws -> [URL] {
        try transfer(urls, into: directory, operation: .move)
    }

    static func trash(_ urls: [URL]) throws {
        var succeeded: [URL] = []
        var failures: [DirectoryFileFailure] = []
        for url in uniqueSources(urls) {
            do {
                let source = try mutableSource(url)
                _ = try fileInfo(source)
                try FileManager.default.trashItem(at: source, resultingItemURL: nil)
                succeeded.append(source)
            } catch {
                failures.append(DirectoryFileFailure(url: url, message: error.localizedDescription))
            }
        }
        if !failures.isEmpty {
            throw DirectoryFileBatchError(operation: .trash, succeededURLs: succeeded, failures: failures)
        }
    }

    private static func transfer(_ urls: [URL], into directory: URL,
                                 operation: DirectoryFileOperation) throws -> [URL] {
        let directory = try directoryURL(directory)
        var succeeded: [URL] = []
        var failures: [DirectoryFileFailure] = []
        for url in uniqueSources(urls) {
            do {
                let source = try operation == .move ? mutableSource(url) : fileURL(url)
                let info = try fileInfo(source)
                let sourcePath = source.resolvingSymlinksInPath().path
                let directoryPath = directory.resolvingSymlinksInPath().path
                if (info.st_mode & S_IFMT) == S_IFDIR,
                   directoryPath == sourcePath || directoryPath.hasPrefix(sourcePath == "/" ? "/" : sourcePath + "/") {
                    throw DirectoryFileError.recursiveDestination(source)
                }
                if operation == .move,
                   source.deletingLastPathComponent().resolvingSymlinksInPath().path == directoryPath {
                    throw DirectoryFileError.alreadyInDirectory(source)
                }
                if operation == .copy {
                    succeeded.append(try stagedCopy(source, into: directory))
                } else {
                    let destination = uniqueDestination(for: source.lastPathComponent, in: directory)
                    try exclusiveMove(source, to: destination)
                    succeeded.append(destination)
                }
            } catch {
                failures.append(DirectoryFileFailure(url: url, message: error.localizedDescription))
            }
        }
        if !failures.isEmpty {
            throw DirectoryFileBatchError(operation: operation, succeededURLs: succeeded, failures: failures)
        }
        return succeeded
    }

    /// Copy into an owned temporary path first so a failed recursive copy does
    /// not leave a half-created public destination. The final move never
    /// replaces a colliding file, including a dangling symlink.
    private static func stagedCopy(_ source: URL, into directory: URL) throws -> URL {
        let staging = directory.appendingPathComponent(".nori-copy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging)
        let destination = uniqueDestination(for: source.lastPathComponent, in: directory)
        guard renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw posixError(url: destination)
        }
        return destination
    }

    private static func exclusiveMove(_ source: URL, to destination: URL) throws {
        if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return }
        // Darwin rename cannot cross devices. Foundation supports this case
        // and refuses an existing destination, preserving Finder semantics.
        guard errno == EXDEV else { throw posixError(url: destination) }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    private static func uniqueDestination(for name: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent(name)
        var suffix = 2
        let original = URL(fileURLWithPath: name)
        let hasExtension = !original.pathExtension.isEmpty
            && !(name.hasPrefix(".") && name.dropFirst().contains(".") == false)
        let stem = hasExtension ? original.deletingPathExtension().lastPathComponent : name
        let ext = hasExtension ? "." + original.pathExtension : ""
        while exists(candidate) {
            candidate = directory.appendingPathComponent("\(stem) \(suffix)\(ext)")
            suffix += 1
        }
        return candidate
    }

    private static func uniqueSources(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        let unique = urls.filter { seen.insert($0.standardizedFileURL.absoluteString).inserted }
        // Global search may select both a directory and its child. Transfer or
        // trash the parent only, avoiding duplicate copies and false failures
        // after a parent move. Symlinks never subsume their target's children.
        let directories = unique.compactMap { url -> String? in
            guard url.isFileURL, let info = try? fileInfo(url),
                  (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
            return url.standardizedFileURL.path
        }
        return unique.filter { url in
            guard url.isFileURL else { return true }
            let path = url.standardizedFileURL.path
            return !directories.contains { parent in
                path != parent && path.hasPrefix(parent == "/" ? "/" : parent + "/")
            }
        }
    }

    private static func newItemURL(in directory: URL, name: String) throws -> URL {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.contains("\0"),
              name.utf8.count <= 255 else {
            throw DirectoryFileError.invalidName
        }
        return try directoryURL(directory).appendingPathComponent(name)
    }

    private static func directoryURL(_ url: URL) throws -> URL {
        let url = try fileURL(url)
        var info = stat()
        guard fstatat(AT_FDCWD, url.path, &info, 0) == 0 else { throw posixError(url: url) }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw DirectoryFileError.notDirectory(url) }
        return url
    }

    private static func mutableSource(_ url: URL) throws -> URL {
        let source = try fileURL(url)
        guard source.path != "/" else { throw DirectoryFileError.protectedRoot }
        return source
    }

    fileprivate static func fileURL(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw DirectoryFileError.notFileURL }
        return url.standardizedFileURL
    }

    fileprivate static func fileInfo(_ url: URL) throws -> stat {
        guard let info = FileScanService.metadata(at: url.path) else { throw posixError(url: url) }
        return info
    }

    fileprivate static func blocks(_ info: stat) -> Int64 {
        let count = max(0, Int64(info.st_blocks))
        return count > Int64.max / 512 ? Int64.max : count * 512
    }

    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func posixError(url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
    }
}
