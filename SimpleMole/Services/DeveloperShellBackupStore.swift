import Foundation
import Darwin

/// Owner-only, descriptor-relative Shell checkpoints. Imported files and symlinks are refused.
enum DeveloperShellBackupStore {
    struct Entry: Identifiable, Equatable, Sendable {
        let name: String
        let path: String
        let date: Date
        let bytes: Int
        var id: String { path }
    }
    private static let maximumBytes = 2 * 1_024 * 1_024
    private static func targetKey(_ path: String) -> String {
        var value: UInt64 = 14695981039346656037
        for byte in path.utf8 { value = (value ^ UInt64(byte)) &* 1099511628211 }
        return String(value, radix: 16)
    }
    private static func components(targetPath: String) -> [String] {
        ["Library", "Application Support", "Nori", "Backups", URL(fileURLWithPath: targetPath).lastPathComponent, targetKey(targetPath)]
    }
    static func directoryPath(targetPath: String, home: String) -> String {
        components(targetPath: targetPath).reduce(URL(fileURLWithPath: home)) { $0.appendingPathComponent($1) }.path
    }
    private static func openDirectory(targetPath: String, home: String, create: Bool) throws -> Int32 {
        var descriptor = open(home, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw DeveloperShellService.Failure.unsafeFile }
        do {
            for (index, component) in components(targetPath: targetPath).enumerated() {
                if create, mkdirat(descriptor, component, 0o700) != 0, errno != EEXIST {
                    throw DeveloperShellService.Failure.writeFailed
                }
                let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard next >= 0 else { throw DeveloperShellService.Failure.unsafeFile }
                var info = stat()
                guard fstat(next, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
                    close(next); throw DeveloperShellService.Failure.unsafeFile
                }
                if index >= 2, create, fchmod(next, 0o700) != 0 { close(next); throw DeveloperShellService.Failure.writeFailed }
                if index >= 2, !create, (info.st_mode & 0o777) != 0o700 { close(next); throw DeveloperShellService.Failure.unsafeFile }
                close(descriptor); descriptor = next
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }
    static func create(_ data: Data, targetPath: String, home: String) throws -> String {
        guard data.count <= maximumBytes else { throw DeveloperShellService.Failure.tooLarge }
        let directory = try openDirectory(targetPath: targetPath, home: home, create: true)
        defer { close(directory) }
        let timestamp = String(format: "%013lld", Int64(Date().timeIntervalSince1970 * 1000))
        let name = timestamp + "-" + UUID().uuidString + ".shell"
        let descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw DeveloperShellService.Failure.writeFailed }
        defer { close(descriptor) }
        do {
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw DeveloperShellService.Failure.writeFailed }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0 else { throw DeveloperShellService.Failure.writeFailed }
            _ = fsync(directory)
        } catch { unlinkat(directory, name, 0); throw error }
        return URL(fileURLWithPath: directoryPath(targetPath: targetPath, home: home)).appendingPathComponent(name).path
    }
    private static func names(_ directory: Int32) -> [String] {
        guard let stream = fdopendir(dup(directory)) else { return [] }
        defer { closedir(stream) }
        var values: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name.range(of: #"^[0-9]{13}-[0-9A-Fa-f-]{36}\.shell$"#, options: .regularExpression) != nil { values.append(name) }
        }
        return values.sorted(by: >)
    }
    static func history(targetPath: String, home: String) throws -> [Entry] {
        let path = directoryPath(targetPath: targetPath, home: home)
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        let directory = try openDirectory(targetPath: targetPath, home: home, create: false)
        defer { close(directory) }
        return names(directory).compactMap { name in
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
                  (info.st_mode & 0o777) == 0o600, info.st_size <= maximumBytes else { return nil }
            let milliseconds = Double(name.prefix(13)) ?? 0
            return Entry(name: name, path: URL(fileURLWithPath: path).appendingPathComponent(name).path,
                         date: Date(timeIntervalSince1970: milliseconds / 1000), bytes: Int(info.st_size))
        }
    }
    static func read(_ entry: Entry, targetPath: String, home: String) throws -> String {
        guard try history(targetPath: targetPath, home: home).contains(entry) else { throw DeveloperShellService.Failure.changedOnDisk }
        let directory = try openDirectory(targetPath: targetPath, home: home, create: false)
        defer { close(directory) }
        let descriptor = openat(directory, entry.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw DeveloperShellService.Failure.unsafeFile }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_uid == getuid(), before.st_nlink == 1, before.st_size <= maximumBytes,
              (before.st_mode & 0o777) == 0o600 else { throw DeveloperShellService.Failure.unsafeFile }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw DeveloperShellService.Failure.unreadable }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumBytes else { throw DeveloperShellService.Failure.tooLarge }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, before.st_ino == after.st_ino, before.st_dev == after.st_dev,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec, data.count == after.st_size else {
            throw DeveloperShellService.Failure.changedOnDisk
        }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw DeveloperShellService.Failure.invalidEncoding }
        return text
    }
    static func rotate(targetPath: String, home: String, keep: Int = 10) {
        guard let directory = try? openDirectory(targetPath: targetPath, home: home, create: false) else { return }
        defer { close(directory) }
        for name in names(directory).dropFirst(max(1, keep)) {
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else { continue }
            _ = unlinkat(directory, name, 0)
        }
        _ = fsync(directory)
    }

    static func redactedLine(_ line: String, hidden: String = "••••••••") -> String {
        let patterns = [#"(?i)(?:token|secret|password|passwd|authorization|bearer|credential|private.?key|api.?key)"#,
                        #"(?i)https?://[^\s/]+@"#]
        return patterns.contains { line.range(of: $0, options: .regularExpression) != nil } ? hidden : line
    }

    /// Compare without exporting the source. Secret-bearing lines are masked in both sides.
    static func redactedDiff(current: String, backup: String, hidden: String) -> String {
        let currentLines = current.components(separatedBy: "\n")
        let backupLines = backup.components(separatedBy: "\n")
        let difference = backupLines.difference(from: currentLines)
        var lines: [String] = []
        for change in difference.prefix(200) {
            switch change {
            case .remove(let offset, let line, _): lines.append("− \(offset + 1)  " + redactedLine(line, hidden: hidden))
            case .insert(let offset, let line, _): lines.append("+ \(offset + 1)  " + redactedLine(line, hidden: hidden))
            }
        }
        return lines.isEmpty ? "=" : String(lines.joined(separator: "\n").prefix(20_000))
    }
}
