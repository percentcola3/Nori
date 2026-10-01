import Darwin
import Foundation

/// 只读取 Agent 官方登记过的项目数据，不遍历用户项目树。
/// Crush 证据：docs/agent-cleanup-research/open-source-cli.md。
enum AgentProjectStorage {
    private static let maximumRegistryBytes = 1_048_576
    private static let maximumProjects = 10_000

    static func targets(for agentID: String, home: String) -> [AgentTarget] {
        guard agentID == "crush" else { return [] }
        let base = URL(fileURLWithPath: home).standardizedFileURL.path
        guard AgentCatalog.isDirectory(base), !AgentCatalog.isSymlink(base) else { return [] }
        let registry = AgentCatalog.absolute(".local/share/crush/projects.json", home: base)
        guard isRegularPhysicalFile(registry, home: base),
              let handle = FileHandle(forReadingAtPath: registry) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumRegistryBytes + 1),
              data.count <= maximumRegistryBytes,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let projects = object["projects"] as? [Any],
              projects.count <= maximumProjects else { return [] }

        var roots = Set<String>()
        for project in projects {
            guard let entry = project as? [String: Any],
                  let rawDirectory = entry["data_dir"] as? String,
                  let rawProject = entry["path"] as? String,
                  let directory = normalizedAbsolutePath(rawDirectory),
                  let projectPath = normalizedAbsolutePath(rawProject),
                  directory.hasPrefix(base + "/"), directory != projectPath,
                  !isBroadDirectory(directory, home: base),
                  AgentCatalog.isPhysical(directory, home: base),
                  AgentCatalog.isDirectory(directory) else { continue }
            roots.insert(directory)
        }

        var result: [AgentTarget] = []
        for directory in roots.sorted() {
            let family = (["crush.db"] + AgentCatalog.sqliteCompanionSuffixes.map { "crush.db" + $0 })
                .filter { isRegularPhysicalFile(directory + "/" + $0, home: base) }
            if !family.isEmpty {
                result.append(.init(.review, .leaves(root: directory, names: family),
                                    "agents.label.conversationDatabase", owners: ["crush"]))
            }
            let logs = directory + "/logs"
            guard AgentCatalog.isPhysical(logs, home: base), AgentCatalog.isDirectory(logs) else { continue }
            let names = AgentCatalog.childNames(of: logs).filter {
                isCrushLogName($0) && isRegularPhysicalFile(logs + "/" + $0, home: base)
            }
            if !names.isEmpty {
                result.append(.init(.safe, .leaves(root: logs, names: names),
                                    "agents.label.logs", owners: ["crush"]))
            }
        }
        return result
    }

    /// 残留页只能拿到精确的数据库族 / 日志文件，不能拿整个配置指定 data_dir。
    static func residualPaths(for agentID: String, home: String) -> [String] {
        Array(Set(targets(for: agentID, home: home).flatMap {
            AgentCatalog.resolve($0.kind, home: home)
        }.filter { isRegularPhysicalFile($0, home: home) })).sorted()
    }

    private static func normalizedAbsolutePath(_ raw: String) -> String? {
        guard !raw.contains("\0"), (raw as NSString).isAbsolutePath else { return nil }
        return URL(fileURLWithPath: raw).standardizedFileURL.path
    }

    private static func isRegularPhysicalFile(_ path: String, home: String) -> Bool {
        guard AgentCatalog.isPhysical(path, home: home) else { return false }
        var metadata = stat()
        return lstat(path, &metadata) == 0 && (metadata.st_mode & S_IFMT) == S_IFREG
    }

    private static func isBroadDirectory(_ directory: String, home: String) -> Bool {
        let relative = String(directory.dropFirst(home.count + 1))
        let broadRoots: Set<String> = [
            "Library", "Library/Application Support", "Library/Caches", "Library/Logs",
            "Library/Preferences", "Library/Containers", "Library/Group Containers",
            "Library/CloudStorage", "Library/Developer", "Applications", "Desktop", "Documents",
            "Downloads", "Movies", "Music", "Pictures", "Public", "Code", "Projects", "Developer",
            ".config", ".cache", ".local", ".local/share", ".local/state", ".agents", ".agents/skills"
        ]
        return broadRoots.contains(relative)
    }

    private static func isCrushLogName(_ name: String) -> Bool {
        if name == "crush.log" { return true }
        // 官方 lumberjack 轮转文件：crush-2006-01-02T15-04-05.000.log。
        return name.range(of: #"^crush-[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}\.[0-9]{3}\.log$"#,
                          options: .regularExpression) != nil
    }
}
