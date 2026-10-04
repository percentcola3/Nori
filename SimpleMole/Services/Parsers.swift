import Foundation

/// 解析引擎与桥接脚本的文本输出。
enum Parsers {
    /// 解析开发工具扫描 TSV：`bytes\tname\tpath`。
    static func toolCategories(_ text: String) -> [CleanupCategory] {
        text.components(separatedBy: "\n").compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3, let bytes = UInt64(parts[0]), bytes > 0 else { return nil }
            return makeCategory(name: parts[1], paths: [parts[2]], bytes: bytes,
                                policy: CleanupRiskPolicy.tool())
        }
    }

    /// 安装包扫描 TSV：`bytes\tname\tpath`，合并为一个类别。
    static func installerCategory(_ text: String) -> CleanupCategory? {
        var paths: [String] = []
        var pathBytes: [String: UInt64] = [:]
        var acceptedPaths: [String] = []
        var bytes: UInt64 = 0
        for line in text.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3, (parts[2] as NSString).isAbsolutePath else { continue }
            let pathSize = UInt64(parts[0]) ?? 0
            guard pathSize > 0 else { continue }
            guard let path = deconflictedPath(parts[2], accepted: &acceptedPaths) else { continue }
            paths.append(path)
            pathBytes[path] = pathSize
            bytes &+= pathSize
        }
        guard !paths.isEmpty else { return nil }
        return makeCategory(name: L10n.shared.t("file.installer"), paths: paths, bytes: bytes,
                            pathBytes: pathBytes,
                            policy: CleanupRiskPolicy.installer())
    }

    private static func makeCategory(name: String,
                                     paths: [String],
                                     bytes: UInt64,
                                     pathBytes: [String: UInt64]? = nil,
                                     policy: CleanupPolicyDescriptor) -> CleanupCategory {
        CleanupCategory(name: name, paths: paths, bytes: bytes, pathBytes: pathBytes,
                        source: policy.source, risk: policy.risk,
                        disposal: policy.disposal, applyRoute: policy.applyRoute,
                        activityGuard: policy.activityGuard, reasonKey: policy.reasonKey)
    }

    /// Preserve scanner order and give each physical subtree one owner. This is
    /// deliberately conservative: a later parent never expands an earlier plan.
    private static func deconflictedPath(_ rawPath: String,
                                         accepted: inout [String]) -> String? {
        guard let path = normalizedAbsolutePath(rawPath) else { return rawPath }
        guard !accepted.contains(where: { pathsOverlap(path, $0) }) else { return nil }
        accepted.append(path)
        return path
    }

    private static func normalizedAbsolutePath(_ path: String) -> String? {
        guard (path as NSString).isAbsolutePath else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
    }

    /// 解析 apply 脚本的 `removed=/failed=` 摘要。
    static func applySummary(_ text: String) -> (removed: Int, failed: Int) {
        var removed = 0
        var failed = 0
        for line in text.components(separatedBy: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "removed": removed = Int(parts[1]) ?? removed
            case "failed": failed = Int(parts[1]) ?? failed
            default: break
            }
        }
        return (removed, failed)
    }

    /// 解析 app_net_reset.sh 的 `step<TAB>state<TAB>detail` 输出：
    /// 全部成功/跳过时返回一句可读摘要；任一步失败返回 nil（调用方展示
    /// 失败文案，完整明细走日志）。
    static func networkResetSummary(_ text: String) -> String? {
        let rows = text.split(whereSeparator: \.isNewline).compactMap { line -> (state: String, detail: String)? in
            let fields = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard fields.count == 3 else { return nil }
            return (fields[1], fields[2])
        }
        guard !rows.isEmpty, !rows.contains(where: { $0.state == "fail" }) else { return nil }
        let backups = rows.map(\.detail).filter { $0.contains("backup") }
        let done = rows.filter { $0.state == "ok" }.count
        let skipped = rows.filter { $0.state == "skip" }.count
        var summary = L10n.shared.tf("audit.network.resetSummary", done, rows.count, skipped)
        if let first = backups.first, let open = first.firstIndex(of: "(") {
            summary += " \(first[open...])"
        }
        return summary
    }


    /// 解析开发环境 TSV：`bytes\tkind\tname\tpath`。同一路径出现多次时
    /// 保留 current 记录（nvm 默认版本会与 family 扫描重复）。
    static func devEnvEntries(_ text: String) -> [DevEnvEntry] {
        var byPath: [String: DevEnvEntry] = [:]
        var order: [String] = []
        for line in text.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 4, parts[3].hasPrefix("/") else { continue }
            let entry = DevEnvEntry(bytes: UInt64(parts[0]) ?? 0,
                                    kind: parts[1], name: parts[2], path: parts[3],
                                    relatedBytes: parts.count > 4 ? UInt64(parts[4]) ?? 0 : 0,
                                    relatedPath: parts.count > 5 && parts[5].hasPrefix("/")
                                        ? parts[5] : nil)
            if let existing = byPath[entry.path] {
                if entry.isCurrent && !existing.isCurrent { byPath[entry.path] = entry }
            } else {
                order.append(entry.path)
                byPath[entry.path] = entry
            }
        }
        return order.compactMap { byPath[$0] }
    }

    /// 解析 APFS 快照桥接输出：`purgeable\tbytes` 与 `snapshot\tname`。
    static func snapshotInfo(_ text: String) -> (purgeable: UInt64, names: [String]) {
        var purgeable: UInt64 = 0
        var names: [String] = []
        for line in text.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 2 else { continue }
            switch parts[0] {
            case "purgeable": purgeable = UInt64(parts[1]) ?? 0
            case "snapshot": names.append(parts[1])
            default: break
            }
        }
        return (purgeable, names)
    }

    /// 解析 `docker system df` 桥接输出：`type\tcount\tsize\treclaimable`。
    static func dockerDfRows(_ text: String) -> [DockerDfRow] {
        var rows: [DockerDfRow] = []
        for line in text.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 4, !parts[0].isEmpty else { continue }
            rows.append(DockerDfRow(type: parts[0], count: parts[1],
                                    size: parts[2], reclaimable: parts[3]))
        }
        return rows
    }

    /// 解析重复检测桥接输出：`bytes\tdupkey\tpath`，相邻同 key 聚为一组。
    static func duplicateGroups(_ text: String) -> [[AnalyzeEntry]] {
        var groups: [[AnalyzeEntry]] = []
        var current: [AnalyzeEntry] = []
        var currentKey = ""
        for line in text.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3, parts[2].hasPrefix("/") else { continue }
            if parts[1] != currentKey {
                if current.count >= 2 { groups.append(current) }
                current = []
                currentKey = parts[1]
            }
            current.append(AnalyzeEntry(
                name: (parts[2] as NSString).lastPathComponent,
                path: parts[2],
                size: UInt64(parts[0]) ?? 0,
                isDir: false))
        }
        if current.count >= 2 { groups.append(current) }
        return groups
    }

    /// 解析 Shell 配置体检输出：`file\tkind\tdetail\tline`。
    static func shellIssues(_ text: String) -> [ShellIssue] {
        var issues: [ShellIssue] = []
        for line in text.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 4, parts[0].hasPrefix("/") else { continue }
            issues.append(ShellIssue(file: parts[0], kind: parts[1],
                                     detail: parts[2], line: Int(parts[3]) ?? 0))
        }
        return issues
    }

    /// 解析网络体检输出：proxy 行与 hosts 行。
    static func netAudit(_ text: String) -> (proxies: [ProxyIssue], hosts: [String]) {
        var proxies: [ProxyIssue] = []
        var hosts: [String] = []
        for line in text.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 2 else { continue }
            switch parts[0] {
            case "proxy" where parts.count >= 4:
                proxies.append(ProxyIssue(service: parts[1], kind: parts[2], endpoint: parts[3]))
            case "hosts":
                hosts.append(parts[1])
            default:
                break
            }
        }
        return (proxies, hosts)
    }

    // MARK: - 流量监控

    /// 解析 netmon 字节快照 TSV：`proc\tpid\tbytes_in\tbytes_out\tcomm`。
    /// comm 是最后一列，可含空格（nettop 的进程名保留原始宽度）。
    static func netmonProcessSamples(_ text: String) -> [NetmonProcessSample] {
        var samples: [NetmonProcessSample] = []
        for line in text.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 5, parts[0] == "proc",
                  let pid = Int32(parts[1]), pid > 0,
                  let bytesIn = UInt64(parts[2]),
                  let bytesOut = UInt64(parts[3]),
                  !parts[4].isEmpty else { continue }
            samples.append(NetmonProcessSample(pid: pid, bytesIn: bytesIn,
                                               bytesOut: bytesOut, command: parts[4]))
        }
        return samples
    }

    /// 解析连接快照 TSV：`flow\tpid\tcomm\tproto\tlocal\tremote`。
    static func netmonFlows(_ text: String) -> [NetmonFlow] {
        var flows: [NetmonFlow] = []
        for line in text.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 6, parts[0] == "flow",
                  let pid = Int32(parts[1]), pid > 0,
                  !parts[2].isEmpty, !parts[5].isEmpty else { continue }
            flows.append(NetmonFlow(pid: pid, command: parts[2],
                                    proto: parts[3], local: parts[4], remote: parts[5]))
        }
        return flows
    }

    /// 解析路由查询 TSV：`route\taddress\tinterface`。
    static func netmonRoutes(_ text: String) -> [NetmonRoute] {
        var routes: [NetmonRoute] = []
        for line in text.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 3, parts[0] == "route",
                  !parts[1].isEmpty, !parts[2].isEmpty else { continue }
            routes.append(NetmonRoute(address: parts[1], interface: parts[2]))
        }
        return routes
    }

}
