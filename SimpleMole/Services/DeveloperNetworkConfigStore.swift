import Foundation
import Darwin

/// Fixed user-owned Cargo target. Source selection is edited as a Nori block;
/// unrelated text is preserved, while ambiguous existing replacements are refused.
enum DeveloperNetworkConfigStore {
    struct Draft {
        let path: String
        let original: Data
        let text: String
        let existed: Bool
        let identity: String?
        let directoryPath: String
        var preview: String {
            func block(_ data: String) -> String {
                guard let start = data.range(of: DeveloperNetworkConfigStore.begin),
                      let finish = data.range(of: DeveloperNetworkConfigStore.end, range: start.upperBound..<data.endIndex) else { return "" }
                return String(data[start.lowerBound..<finish.upperBound])
            }
            let previous = block(String(data: original, encoding: .utf8) ?? "")
            let next = block(text)
            return DeveloperSecretRedactor.redact(previous.split(separator: "\n").map { "- " + $0 }.joined(separator: "\n")
                + "\n" + next.split(separator: "\n").map { "+ " + $0 }.joined(separator: "\n"))
        }
    }
    private static let begin = "# Nori registry: begin"
    private static let end = "# Nori registry: end"
    static func cargoDraft(target: String, home: String = NSHomeDirectory(), cargoHome: String? = nil) throws -> Draft {
        guard DeveloperNetworkToolsService.validMirror(target, tool: .cargo) else { throw DeveloperNetworkToolsService.Failure.invalidValue }
        let directory = cargoHome ?? home + "/.cargo"
        guard directory == home + "/.cargo" || directory.hasPrefix(home + "/"),
              !directory.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              !directory.contains("//") else { throw DeveloperNetworkToolsService.Failure.unsafeConfig }
        try physicalDirectory(directory, owner: getuid(), allowAbsent: true)
        let path = directory + "/config.toml"
        let existed = FileManager.default.fileExists(atPath: path)
        let original: Data
        let identity: String?
        if existed {
            identity = try fileIdentity(path)
            original = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
            guard original.count <= 1_048_576 else { throw DeveloperNetworkToolsService.Failure.unsafeConfig }
        } else { original = Data(); identity = nil }
        guard var text = String(data: original, encoding: .utf8) else { throw DeveloperNetworkToolsService.Failure.unsafeConfig }
        text = try replacingCargoSource(text, target: target)
        return Draft(path: path, original: original, text: text, existed: existed, identity: identity, directoryPath: directory)
    }

    static func replacingCargoSource(_ original: String, target: String) throws -> String {
        guard DeveloperNetworkToolsService.validMirror(target, tool: .cargo) else { throw DeveloperNetworkToolsService.Failure.invalidValue }
        let parsedOriginal = try DeveloperNetworkTOMLValidator.validate(original)
        var text = original
        if let opening = text.range(of: begin) {
            guard parsedOriginal.sourceConfigured else { throw DeveloperNetworkToolsService.Failure.unsafeConfig }
            guard let closing = text.range(of: end, range: opening.upperBound..<text.endIndex),
                  text.range(of: begin, range: opening.upperBound..<text.endIndex) == nil,
                  text.range(of: end, range: closing.upperBound..<text.endIndex) == nil else { throw DeveloperNetworkToolsService.Failure.unsafeConfig }
            var upper = closing.upperBound
            if upper < text.endIndex, text[upper] == "\n" { upper = text.index(after: upper) }
            text.removeSubrange(opening.lowerBound..<upper)
        } else if text.contains(end) { throw DeveloperNetworkToolsService.Failure.unsafeConfig }
        // Decode dotted and quoted table keys rather than assuming one spelling.
        guard try !DeveloperNetworkTOMLValidator.validate(text).sourceConfigured else {
            throw DeveloperNetworkToolsService.Failure.unsafeConfig
        }
        guard !text.utf8.contains(0) else { throw DeveloperNetworkToolsService.Failure.unsafeConfig }
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        if !text.isEmpty, !text.hasSuffix("\n\n") { text += "\n" }
        if target == DeveloperNetworkToolsService.MirrorTool.cargo.official { return text }
        let quoted = target.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let candidate = text + begin + "\n[source.crates-io]\nreplace-with = \"nori-registry\"\n\n[source.nori-registry]\nregistry = \"" + quoted + "\"\n" + end + "\n"
        _ = try DeveloperNetworkTOMLValidator.validate(candidate)
        return candidate
    }

    static func save(_ draft: Draft, home: String = NSHomeDirectory()) throws {
        guard draft.directoryPath == home + "/.cargo" || draft.directoryPath.hasPrefix(home + "/"),
              !draft.directoryPath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              !draft.directoryPath.contains("//"),
              draft.path == draft.directoryPath + "/config.toml" else { throw DeveloperNetworkToolsService.Failure.unsafeConfig }
        _ = try DeveloperNetworkTOMLValidator.validate(draft.text)
        let directoryPath = draft.directoryPath
        try physicalDirectory(directoryPath, owner: getuid(), allowAbsent: true)
        if !FileManager.default.fileExists(atPath: directoryPath) {
            guard mkdir(directoryPath, 0o700) == 0 else { throw DeveloperNetworkToolsService.Failure.unsafeConfig }
        }
        let directory = open(directoryPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw DeveloperNetworkToolsService.Failure.unsafeConfig }
        defer { close(directory) }
        try unchanged(draft)
        if draft.existed {
            _ = try DeveloperShellBackupStore.create(draft.original, targetPath: draft.path, home: home)
        }
        let temporary = ".nori-cargo-" + UUID().uuidString
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw DeveloperNetworkToolsService.Failure.unsafeConfig }
        defer { close(descriptor); unlinkat(directory, temporary, 0) }
        let data = Data(draft.text.utf8)
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < data.count {
                let count = write(descriptor, buffer.baseAddress!.advanced(by: offset), data.count - offset)
                guard count > 0 else { throw DeveloperNetworkToolsService.Failure.unsafeConfig }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw DeveloperNetworkToolsService.Failure.unsafeConfig }
        try unchanged(draft)
        let result = draft.existed ? renameat(directory, temporary, directory, "config.toml") : renameatx_np(directory, temporary, directory, "config.toml", UInt32(RENAME_EXCL))
        guard result == 0 else { throw DeveloperNetworkToolsService.Failure.changed }
        _ = fsync(directory)
        DeveloperShellBackupStore.rotate(targetPath: draft.path, home: home)
    }
    private static func unchanged(_ draft: Draft) throws {
        if draft.existed {
            guard try fileIdentity(draft.path) == draft.identity,
                  try Data(contentsOf: URL(fileURLWithPath: draft.path)) == draft.original else { throw DeveloperNetworkToolsService.Failure.changed }
        } else {
            var info = stat()
            guard lstat(draft.path, &info) != 0, errno == ENOENT else { throw DeveloperNetworkToolsService.Failure.changed }
        }
    }
    private static func fileIdentity(_ path: String) throws -> String {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, (info.st_mode & 0o022) == 0 else { throw DeveloperNetworkToolsService.Failure.unsafeConfig }
        return "\(info.st_dev):\(info.st_ino):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_size)"
    }
    private static func physicalDirectory(_ path: String, owner: uid_t, allowAbsent: Bool) throws {
        var current = URL(fileURLWithPath: path)
        while current.path != "/" {
            var info = stat()
            if lstat(current.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFDIR else { throw DeveloperNetworkToolsService.Failure.unsafeConfig }
                if current.path == path { guard info.st_uid == owner, (info.st_mode & 0o022) == 0 else { throw DeveloperNetworkToolsService.Failure.unsafeConfig } }
            } else if !(allowAbsent && errno == ENOENT && current.path == path) { throw DeveloperNetworkToolsService.Failure.unsafeConfig }
            current.deleteLastPathComponent()
        }
    }
}
