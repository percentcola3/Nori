import Foundation
import Darwin

/// 将用户确认时看到的路径绑定到当时的文件对象。
struct DeletionPlan {
    struct Item {
        let record: String
        let identity: String
    }

    let items: [Item]

    init(items: [Item]) {
        self.items = items
    }

    init(paths: [String]) {
        items = Self.nonOverlappingPaths(paths).map {
            Item(record: $0, identity: Self.identity(at: $0) ?? "")
        }
    }

    /// 编码记录与实际文件路径不同时使用（例如 `compress|/path/image.png`）。
    init(records: [String], identityPath: (String) -> String?) {
        items = records.map { record in
            let path = identityPath(record) ?? ""
            return Item(record: record, identity: Self.identity(at: path) ?? "")
        }
    }

    /// 词法校验（删除漏斗第一道）：非空绝对路径；不含控制字符（含 NUL）；
    /// 任何完整路径分量都不允许是 "." 或 ".."。像 `name..files` 这样的
    /// 文件名是合法的，不受影响。
    static func isLexicallySafePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.hasPrefix("/") else { return false }
        if path.utf8.contains(where: { $0 < 0x20 || $0 == 0x7f }) { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: true)
            .contains { $0 == "." || $0 == ".." }
    }

    /// NUL 分隔的 `<path><identity>` 记录，避免文件名中的空格和换行改变协议。
    var stdinData: Data {
        var data = Data()
        for item in items {
            data.append(contentsOf: item.record.utf8)
            data.append(0)
            data.append(contentsOf: item.identity.utf8)
            data.append(0)
        }
        return data
    }

    /// 与 Mole 的 `stat -f%d:%i:%m` 使用相同格式。
    static func identity(at path: String) -> String? {
        var metadata = stat()
        // BSD `/usr/bin/stat`（Mole 使用的实现）默认也是 lstat 语义。
        guard Darwin.lstat(path, &metadata) == 0 else { return nil }
        return "\(metadata.st_dev):\(metadata.st_ino):\(metadata.st_mtimespec.tv_sec)"
    }

    static func nonOverlappingPaths(_ paths: [String]) -> [String] {
        // A selected ancestor covers its descendants regardless of input
        // order. Keeping the first child instead could leave the rest of a
        // selected cache untouched while reporting that parent as coalesced.
        // Unsafe literals remain independent so normalization cannot let a
        // rejected `..` path swallow an otherwise valid deletion target.
        let normalized = paths.map { path in
            isLexicallySafePath(path) ? URL(fileURLWithPath: path).standardizedFileURL.path : nil
        }
        let allPaths = Set(normalized.compactMap { $0 })
        var seen = Set<String>()
        return paths.indices.compactMap { index in
            let record = paths[index]
            guard let path = normalized[index] else {
                return seen.insert(record).inserted ? record : nil
            }
            guard seen.insert(path).inserted else { return nil }
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty && parent != "/" {
                if allPaths.contains(parent) { return nil }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return record
        }
    }
}
