import Foundation

/// Shell 配置文件体检（开发环境页）：找出失效条目并支持备份后清理。
/// 只做保守判定——只标记“确定无效”的行，避免误删：
/// - PATH 行里指向不存在目录的字面量段（保留 $PATH 引用与有效段，改写该行）
/// - 同一行内完全重复的 PATH 字面量段（原地去重）
/// - 已知路径型环境变量（NVM_DIR/PYENV_ROOT/CARGO_HOME 等）指向不存在目录
/// - 未加存在性守卫、且目标文件已不存在的 source/. 初始化行
enum ShellEnvAudit {
    struct Issue: Identifiable, Equatable {
        enum Kind: String {
            case deadPath
            case duplicatePath
            case deadExport
            case deadToolInit
        }

        let file: String
        /// 1-based 行号；apply 按行号改写。
        let lineNumber: Int
        /// 原始行内容（不含换行）。
        let line: String
        let kind: Kind
        /// 人读原因（哪个变量、哪段路径）。
        let detail: String
        /// nil = 删除整行；非 nil = 用该内容改写本行（PATH 清理保留有效段）。
        let replacement: String?

        var id: String { "\(file):\(lineNumber)" }
    }

    static let profileFileNames = [
        ".zshenv", ".zprofile", ".zshrc", ".zlogin",
        ".bash_profile", ".bashrc", ".profile"
    ]

    /// 常见的“值是目录”的环境变量；仅对这些做失效判定。
    static let pathLikeVariables: Set<String> = [
        "NVM_DIR", "PYENV_ROOT", "RBENV_ROOT", "CARGO_HOME", "RUSTUP_HOME",
        "GOPATH", "GOBIN", "BUN_INSTALL", "VOLTA_HOME", "PNPM_HOME",
        "JENV_ROOT", "SDKMAN_DIR", "GRADLE_USER_HOME", "MAVEN_HOME", "HERMIT_HOME"
    ]

    private static let fileManager = FileManager.default

    // MARK: 扫描

    static func scan(home: String = NSHomeDirectory()) async -> [Issue] {
        await Task.detached(priority: .utility) {
            var issues: [Issue] = []
            for name in profileFileNames {
                let path = home + "/" + name
                guard let lines = (try? String(contentsOfFile: path, encoding: .utf8))?
                    .components(separatedBy: "\n") else { continue }
                for (index, rawLine) in lines.enumerated() {
                    let line = rawLine.trimmingCharacters(in: .whitespaces)
                    guard !line.isEmpty, !line.hasPrefix("#") else { continue }
                    if let issue = inspectLine(line, at: index + 1, in: path, home: home) {
                        issues.append(issue)
                    }
                }
            }
            return issues
        }.value
    }

    /// 返回 nil 表示该行没有可判定的问题。
    private static func inspectLine(_ line: String, at number: Int, in file: String,
                                    home: String) -> Issue? {
        // 未加守卫的 source/. 行，目标文件不存在 → 工具初始化失效。
        if let issue = deadToolInit(line, at: number, in: file, home: home) {
            return issue
        }
        // export VAR=...（已知路径型变量）指向缺失目录。
        if let issue = deadExport(line, at: number, in: file, home: home) {
            return issue
        }
        // PATH 行：死段 / 重复段。
        if line.contains("PATH=") {
            return pathLineIssue(line, at: number, in: file, home: home)
        }
        return nil
    }

    private static func deadToolInit(_ line: String, at number: Int, in file: String,
                                     home: String) -> Issue? {
        // 带存在性守卫（[ -s ... ]、[ -f ... ]、command -v 等）的行交给 shell 自己跳过。
        let guarded = line.contains("[ -") || line.contains("[[ -") || line.contains("command -v")
        guard !guarded else { return nil }
        let trimmed = line
        let sourcePattern: [String] = ["source ", ". "]
        for prefix in sourcePattern {
            guard trimmed.hasPrefix(prefix) else { continue }
            let rest = trimmed.dropFirst(prefix.count)
                .trimmingCharacters(in: .whitespaces)
            let target = unquote(expandTilde(String(rest), home: home))
            guard !target.isEmpty, !target.contains("$") else { return nil }
            guard !fileManager.fileExists(atPath: target) else { return nil }
            return Issue(file: file, lineNumber: number, line: line, kind: .deadToolInit,
                         detail: target, replacement: nil)
        }
        return nil
    }

    private static func deadExport(_ line: String, at number: Int, in file: String,
                                   home: String) -> Issue? {
        guard line.hasPrefix("export ") else { return nil }
        let body = line.dropFirst("export ".count)
        guard let equals = body.firstIndex(of: "=") else { return nil }
        let name = String(body[..<equals]).trimmingCharacters(in: .whitespaces)
        guard pathLikeVariables.contains(name) else { return nil }
        let rawValue = String(body[body.index(after: equals)...])
        let value = unquote(expandTilde(rawValue, home: home))
        guard !value.isEmpty, !value.contains("$") else { return nil }
        guard !fileManager.fileExists(atPath: value) else { return nil }
        return Issue(file: file, lineNumber: number, line: line, kind: .deadExport,
                     detail: name, replacement: nil)
    }

    private static func pathLineIssue(_ line: String, at number: Int, in file: String,
                                      home: String) -> Issue? {
        guard let value = pathValue(of: line) else { return nil }
        var segments = value.split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
        // 变量引用段（$PATH 等）不参与判定，原样保留。
        var kept: [String] = []
        var dead: [String] = []
        var duplicates: [String] = []
        var seen = Set<String>()
        for segment in segments {
            let raw = segment.trimmingCharacters(in: .whitespaces)
            if raw.contains("$") || raw.isEmpty {
                kept.append(segment)
                continue
            }
            let expanded = unquote(expandTilde(raw, home: home))
            if !fileManager.fileExists(atPath: expanded) {
                dead.append(expanded)
                continue // 死段直接丢弃，不进入 kept/seen。
            }
            if seen.contains(expanded) {
                duplicates.append(expanded)
                continue
            }
            seen.insert(expanded)
            kept.append(segment)
        }
        guard !dead.isEmpty || !duplicates.isEmpty else { return nil }
        let kind: Issue.Kind = dead.isEmpty ? .duplicatePath : .deadPath
        let detail = (dead + duplicates).map { abbreviate($0, home: home) }.joined(separator: ", ")
        // 全部字面量段都失效且没有变量引用 → 整行已无意义，删除；
        // 否则改写为仅保留有效段的 PATH 行。
        let hasReferences = segments.contains { $0.contains("$") }
        let replacement: String?
        if kept.filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).isEmpty && !hasReferences {
            replacement = nil
        } else {
            let keptValue = kept.filter { !$0.isEmpty }.joined(separator: ":")
            let newValue = keptValue.isEmpty ? "$PATH" : keptValue
            if line.hasPrefix("export ") {
                replacement = "export PATH=" + "\"\(newValue)\""
            } else if let range = line.range(of: "PATH=") {
                let prefix = String(line[..<range.lowerBound])
                replacement = prefix + "PATH=" + "\"\(newValue)\""
            } else {
                replacement = line
            }
            if let replacement, replacement == line {
                return nil
            }
        }
        return Issue(file: file, lineNumber: number, line: line, kind: kind,
                     detail: detail, replacement: replacement)
    }

    /// 提取 PATH= 右侧的值（支持双引号/单引号/裸值），失败返回 nil。
    private static func pathValue(of line: String) -> String? {
        guard let range = line.range(of: "PATH=") else { return nil }
        var value = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        if let quoted = value.first, quoted == "\"" || quoted == "'" {
            guard value.count >= 2, value.last == quoted else { return nil }
            value = String(value.dropFirst().dropLast())
        }
        guard !value.isEmpty else { return nil }
        return value
    }

    // MARK: 应用修复

    /// 备份后应用修复：每个被修改的文件先复制为 `<原路径>.nori-backup-<时间戳>`，
    /// 再按行号（降序）改写或删除。返回移除/改写的行数与备份路径。
    static func apply(_ issues: [Issue], home: String = NSHomeDirectory()) async
        -> (removed: Int, backups: [String]) {
        await Task.detached(priority: .utility) {
            let byFile = Dictionary(grouping: issues, by: \.file)
            var backups: [String] = []
            var removed = 0
            let stamp = Int(Date().timeIntervalSince1970)
            for (file, fileIssues) in byFile {
                guard var lines = (try? String(contentsOfFile: file, encoding: .utf8))?
                    .components(separatedBy: "\n") else { continue }
                // 行号按文件原始内容计算；先备份，再降序应用避免位移。
                let backup = "\(file).nori-backup-\(stamp)"
                if fileManager.fileExists(atPath: file),
                   (try? fileManager.copyItem(atPath: file, toPath: backup)) != nil {
                    backups.append(backup)
                }
                for issue in fileIssues.sorted(by: { $0.lineNumber > $1.lineNumber }) {
                    guard issue.lineNumber >= 1, issue.lineNumber <= lines.count else { continue }
                    guard lines[issue.lineNumber - 1].trimmingCharacters(in: .whitespaces)
                        == issue.line.trimmingCharacters(in: .whitespaces) else { continue }
                    if let replacement = issue.replacement {
                        lines[issue.lineNumber - 1] = replacement
                    } else {
                        lines.remove(at: issue.lineNumber - 1)
                    }
                    removed += 1
                }
                // 保留结尾换行习惯：内容为空数组时写空串。
                try? lines.joined(separator: "\n").write(toFile: file, atomically: true, encoding: .utf8)
            }
            return (removed, backups)
        }.value
    }

    // MARK: 小工具

    private static func expandTilde(_ value: String, home: String) -> String {
        value.hasPrefix("~") ? home + value.dropFirst() : value
    }

    private static func unquote(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\"") || trimmed.hasPrefix("'") {
            trimmed = String(trimmed.dropFirst())
        }
        if trimmed.hasSuffix("\"") || trimmed.hasSuffix("'") {
            trimmed = String(trimmed.dropLast())
        }
        return trimmed
    }

    private static func abbreviate(_ path: String, home: String) -> String {
        path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// AppState 暴露给视图的别名，避免视图直接依赖审计实现。
typealias ShellEnvIssue = ShellEnvAudit.Issue
