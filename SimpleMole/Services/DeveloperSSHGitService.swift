import Foundation
import CryptoKit
import Darwin

enum DeveloperSSHGitService {
    struct Key: Identifiable, Equatable, Sendable {
        let publicPath: String
        let privatePath: String?
        let type: String
        let bits: Int?
        let fingerprint: String
        let comment: String
        let needsPermissionRepair: Bool
        let privatePermissionsLoose: Bool
        var id: String { publicPath }
    }
    struct SSHConfig: Equatable {
        let text: String
        let data: Data
        let path: String
        let identity: FileIdentity?
        let blocks: [HostBlock]
    }
    struct FileIdentity: Equatable { let device: dev_t; let inode: ino_t; let modified: Int; let nanos: Int; let mode: mode_t }
    struct HostBlock: Identifiable, Equatable {
        let id = UUID()
        let start: Int
        let end: Int
        let host: String
        let fields: [String: String]
        let isEditable: Bool
    }
    enum Failure: Error { case unsafe, changed, invalid, write }
    private static let fields = Set(["hostname", "user", "port", "identityfile", "identitiesonly", "proxyjump"])
    private static func complexScope(_ text: String) -> Bool {
        text.components(separatedBy: "\n").contains { line in
            let key = line.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0.isWhitespace || $0 == "=" }).first?.lowercased()
            return key == "match" || key == "include"
        }
    }
    private static func identity(_ info: stat) -> FileIdentity {
        .init(device: info.st_dev, inode: info.st_ino, modified: info.st_mtimespec.tv_sec, nanos: info.st_mtimespec.tv_nsec, mode: info.st_mode)
    }
    static func validName(_ value: String) -> Bool { value.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$"#, options: .regularExpression) != nil }
    private static func regular(_ path: String) -> stat? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else { return nil }
        return info
    }
    private static func readRegular(_ path: String, limit: Int = 262_144) throws -> (Data, FileIdentity) {
        let url = URL(fileURLWithPath: path)
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw Failure.unsafe }; defer { close(directory) }
        var parent = stat()
        guard fstat(directory, &parent) == 0, parent.st_uid == getuid() else { throw Failure.unsafe }
        let file = openat(directory, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { throw Failure.unsafe }; defer { close(file) }
        var before = stat()
        guard fstat(file, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG, before.st_uid == getuid(), before.st_nlink == 1,
              before.st_size <= limit else { throw Failure.unsafe }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw Failure.unsafe }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count)); guard data.count <= limit else { throw Failure.unsafe }
        }
        var after = stat()
        guard fstat(file, &after) == 0, identity(before) == identity(after), data.count == after.st_size else { throw Failure.changed }
        return (data, identity(after))
    }
    static func keys(home: String = NSHomeDirectory()) -> [Key] {
        let directory = home + "/.ssh"
        var info = stat()
        guard lstat(directory, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted().prefix(128).compactMap { name in
            guard name.hasSuffix(".pub"), validName(name), let (data, _) = try? readRegular(directory + "/" + name, limit: 16_384),
                  let text = String(data: data, encoding: .utf8), let parsed = publicKey(text) else { return nil }
            let candidate = directory + "/" + String(name.dropLast(4))
            let privateInfo = regular(candidate)
            return .init(publicPath: directory + "/" + name, privatePath: privateInfo == nil ? nil : candidate,
                         type: parsed.type, bits: parsed.bits, fingerprint: parsed.fingerprint,
                         comment: parsed.comment, needsPermissionRepair: (info.st_mode & 0o777) != 0o700 || privateInfo.map { ($0.st_mode & 0o777) != 0o600 } == true,
                         privatePermissionsLoose: privateInfo.map { ($0.st_mode & 0o077) != 0 } == true)
        }
    }
    static func publicKey(_ text: String) -> (type: String, bits: Int?, fingerprint: String, comment: String)? {
        let tokens = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 2).map(String.init)
        guard tokens.count >= 2, let data = Data(base64Encoded: tokens[1]), data.count <= 12_000 else { return nil }
        var offset = 0
        func field() -> Data? {
            guard offset + 4 <= data.count else { return nil }
            let count = data[offset..<offset+4].reduce(0) { ($0 << 8) + Int($1) }; offset += 4
            guard count <= data.count - offset else { return nil }
            defer { offset += count }; return data.subdata(in: offset..<offset+count)
        }
        guard let name = field(), String(data: name, encoding: .utf8) == tokens[0] else { return nil }
        var bits: Int?
        switch tokens[0] {
        case "ssh-ed25519": guard let key = field(), key.count == 32 else { return nil }; bits = 256
        case "ssh-rsa":
            guard field() != nil, let modulus = field(), let first = modulus.firstIndex(where: { $0 != 0 }) else { return nil }
            bits = (modulus.count - first - 1) * 8 + (8 - modulus[first].leadingZeroBitCount)
        case "ecdsa-sha2-nistp256": guard field() != nil, field() != nil else { return nil }; bits = 256
        case "ecdsa-sha2-nistp384": guard field() != nil, field() != nil else { return nil }; bits = 384
        case "ecdsa-sha2-nistp521": guard field() != nil, field() != nil else { return nil }; bits = 521
        default: return nil
        }
        let fingerprint = Data(SHA256.hash(data: data)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return (tokens[0], bits, "SHA256:" + fingerprint, tokens.count > 2 ? tokens[2] : "")
    }
    static func publicKeyText(_ key: Key, home: String = NSHomeDirectory()) throws -> String {
        guard key.publicPath.hasPrefix(home + "/.ssh/"), validName(URL(fileURLWithPath: key.publicPath).lastPathComponent) else { throw Failure.unsafe }
        var directory = stat()
        guard lstat(home + "/.ssh", &directory) == 0, (directory.st_mode & S_IFMT) == S_IFDIR, directory.st_uid == getuid() else { throw Failure.unsafe }
        let (data, _) = try readRegular(key.publicPath, limit: 16_384)
        guard let text = String(data: data, encoding: .utf8), publicKey(text)?.fingerprint == key.fingerprint else { throw Failure.changed }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func repairPermissions(_ key: Key, home: String = NSHomeDirectory()) throws {
        guard key.publicPath.hasPrefix(home + "/.ssh/"), validName(URL(fileURLWithPath: key.publicPath).lastPathComponent) else { throw Failure.unsafe }
        let directory = open(home + "/.ssh", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw Failure.unsafe }; defer { close(directory) }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_uid == getuid() else { throw Failure.unsafe }
        if let path = key.privatePath {
            guard path == String(key.publicPath.dropLast(4)) else { throw Failure.unsafe }
            let name = URL(fileURLWithPath: path).lastPathComponent
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else { throw Failure.unsafe }
            // A mode-000 key cannot be opened for reading. The descriptor-relative chmod
            // explicitly refuses following a symlink and never opens private key contents.
            guard fchmodat(directory, name, 0o600, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.write }
        }
        guard fchmod(directory, 0o700) == 0 else { throw Failure.write }
    }
    static func readConfig(home: String = NSHomeDirectory()) throws -> SSHConfig {
        let path = home + "/.ssh/config"
        var parent = stat()
        if lstat(home + "/.ssh", &parent) == 0 {
            guard (parent.st_mode & S_IFMT) == S_IFDIR, parent.st_uid == getuid() else { throw Failure.unsafe }
        } else if errno != ENOENT { throw Failure.unsafe }
        if access(path, F_OK) != 0, errno == ENOENT { return .init(text: "", data: Data(), path: path, identity: nil, blocks: []) }
        let (data, identity) = try readRegular(path)
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw Failure.invalid }
        return .init(text: text, data: data, path: path, identity: identity, blocks: parseConfig(text))
    }
    static func parseConfig(_ text: String) -> [HostBlock] {
        let lines = text.components(separatedBy: "\n")
        let starts = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0.isWhitespace || $0 == "=" }).first?.lowercased() == "host" }
        let complexDocument = complexScope(text)
        return starts.enumerated().map { offset, start in
            let end = offset + 1 < starts.count ? starts[offset + 1] : lines.count
            let host = lines[start].trimmingCharacters(in: .whitespaces).dropFirst(4).trimmingCharacters(in: CharacterSet(charactersIn: " \t="))
            var values: [String: String] = [:], safe = !complexDocument && validName(host)
            for line in lines[(start + 1)..<end] {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                let pieces = trimmed.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
                guard pieces.count == 2 else { safe = false; continue }
                let key = pieces[0].lowercased(), value = String(pieces[1]).trimmingCharacters(in: .whitespaces)
                if !fields.contains(key) || values[key] != nil || value.contains("#") { safe = false }
                values[key] = value
            }
            return HostBlock(start: start, end: end, host: host, fields: values, isEditable: safe)
        }
    }
    static func settingHost(in config: SSHConfig, block: HostBlock?, host: String, hostname: String,
                            user: String, port: String, identityFile: String) throws -> String {
        guard validName(host), validName(hostname), validName(user), let portNumber = Int(port), (1...65535).contains(portNumber),
              identityFile.hasPrefix("~/") || identityFile.hasPrefix("/"), !identityFile.contains("\n"), !identityFile.contains("\r"),
              !identityFile.contains("\""), !identityFile.contains("\\"), !identityFile.contains("%"), !identityFile.contains("\0") else { throw Failure.invalid }
        let replacements = ["hostname": hostname, "user": user, "port": port, "identityfile": "\"" + identityFile + "\"", "identitiesonly": "yes"]
        // OpenSSH takes the first value. A global preamble can therefore
        // override even a newly inserted Host; do not promise edits it defeats.
        let preamble = config.text.components(separatedBy: "\n").prefix(config.blocks.first?.start ?? Int.max)
        guard !preamble.contains(where: { line in
            let key = line.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0.isWhitespace || $0 == "=" }).first?.lowercased() ?? ""
            return replacements[key] != nil
        }) else { throw Failure.invalid }
        guard !config.blocks.contains(where: { $0.host == host && $0.id != block?.id }) else { throw Failure.invalid }
        var lines = config.text.components(separatedBy: "\n")
        if let block {
            guard block.isEditable, config.blocks.contains(block), lines.indices.contains(block.start) else { throw Failure.invalid }
            var seen = Set<String>()
            lines[block.start] = "Host " + host
            for index in (block.start + 1)..<block.end {
                let key = lines[index].trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).first?.lowercased() ?? ""
                if let value = replacements[key] { lines[index] = "    " + key + " " + value; seen.insert(key) }
            }
            for key in ["hostname", "user", "port", "identityfile", "identitiesonly"] where !seen.contains(key) {
                lines.insert("    " + key + " " + replacements[key]!, at: block.start + 1)
            }
            return lines.joined(separator: "\n")
        }
        guard !complexScope(config.text) else { throw Failure.invalid }
        let separator = config.text.isEmpty || config.text.hasSuffix("\n") ? "" : "\n"
        let addition = "Host \(host)\n    HostName \(hostname)\n    User \(user)\n    Port \(port)\n    IdentityFile \"\(identityFile)\"\n    IdentitiesOnly yes\n"
        if let first = config.blocks.first {
            lines.insert(contentsOf: addition.components(separatedBy: "\n"), at: first.start)
            return lines.joined(separator: "\n")
        }
        return config.text + separator + addition
    }
    static func saveConfig(_ text: String, replacing snapshot: SSHConfig, home: String = NSHomeDirectory()) throws {
        guard text.utf8.count <= 262_144, !text.contains("\0"), snapshot.path == home + "/.ssh/config" else { throw Failure.invalid }
        // No ssh -G: Include and Match exec must never execute during validation.
        let current = try readConfig(home: home)
        guard current.identity == snapshot.identity, current.data == snapshot.data else { throw Failure.changed }
        let parent = open(home, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw Failure.unsafe }; defer { close(parent) }
        if mkdirat(parent, ".ssh", 0o700) != 0, errno != EEXIST { throw Failure.write }
        let directory = openat(parent, ".ssh", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw Failure.unsafe }; defer { close(directory) }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_uid == getuid() else { throw Failure.unsafe }
        let temporary = ".nori-config-" + UUID().uuidString
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Failure.write }; defer { close(descriptor); unlinkat(directory, temporary, 0) }
        let data = Data(text.utf8)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }; guard count > 0 else { throw Failure.write }; offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw Failure.write }
        if snapshot.identity != nil { _ = try DeveloperShellBackupStore.create(snapshot.data, targetPath: snapshot.path, home: home) }
        let latest = try readConfig(home: home)
        guard latest.identity == snapshot.identity, latest.data == snapshot.data else { throw Failure.changed }
        let replaced = snapshot.identity == nil ? renameatx_np(directory, temporary, directory, "config", UInt32(RENAME_EXCL)) : renameat(directory, temporary, directory, "config")
        guard replaced == 0 else { throw Failure.write }; _ = fsync(directory)
        DeveloperShellBackupStore.rotate(targetPath: snapshot.path, home: home)
    }
}
