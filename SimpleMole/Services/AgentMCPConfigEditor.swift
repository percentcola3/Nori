import Foundation

/// 按用户勾选把 MCP 服务器条目从配置文件中移除。
/// 修改前把原文件备份为 `<path>.nori-backup`；JSON 重写为规格化输出，
/// TOML 只整段删除命中的 `[<table>.<name>]`，其余行保持原样。
enum AgentMCPConfigEditor {
    struct Request: Equatable, Sendable {
        let configPath: String
        let format: AgentMCPFormat
        let serverName: String
        let scope: String?
    }

    struct Outcome: Sendable {
        var removed = 0
        /// 复核时条目已不存在（配置被外部改动）。
        var missing = 0
        var failed = 0
        var messages: [String] = []
    }

    static func apply(_ requests: [Request]) -> Outcome {
        var outcome = Outcome()
        let byFile = Dictionary(grouping: requests, by: \.configPath)
        for (path, fileRequests) in byFile.sorted(by: { $0.key < $1.key }) {
            guard let format = fileRequests.first?.format else { continue }
            switch format {
            case .json(let keyPath):
                if !editJSON(at: path, keyPath: keyPath, requests: fileRequests, outcome: &outcome) {
                    outcome.failed += fileRequests.count
                    outcome.messages.append(path)
                }
            case .toml(let table):
                if !editTOML(at: path, table: table, requests: fileRequests, outcome: &outcome) {
                    outcome.failed += fileRequests.count
                    outcome.messages.append(path)
                }
            }
        }
        return outcome
    }

    // MARK: - JSON

    private static func editJSON(at path: String, keyPath: String,
                                 requests: [Request], outcome: inout Outcome) -> Bool {
        guard let data = FileManager.default.contents(atPath: path),
              let root = (try? JSONSerialization.jsonObject(
                with: data, options: [.json5Allowed, .mutableContainers])) as? NSMutableDictionary
        else { return false }
        var removals = 0
        for request in requests {
            var removed = false
            if request.scope == nil {
                removed = removeServer(request.serverName, keyPath: keyPath, object: root)
            }
            if let scope = request.scope,
               let projects = root["projects"] as? NSMutableDictionary,
               let project = projects[scope] as? NSMutableDictionary {
                if removeServer(request.serverName, keyPath: keyPath, object: project) {
                    removed = true
                }
            }
            if removed { removals += 1 } else { outcome.missing += 1 }
        }
        guard removals > 0 else { return true }
        guard backup(path),
              let output = try? JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        else { return false }
        do { try output.write(to: URL(fileURLWithPath: path), options: .atomic) }
        catch { return false }
        outcome.removed += removals
        return true
    }

    /// 按 keyPath 定位 name → server 表并删除条目；兼容「整个 key 写成带点名字」的工具。
    @discardableResult
    private static func removeServer(_ name: String, keyPath: String,
                                     object: NSMutableDictionary) -> Bool {
        var container: NSDictionary = object
        for component in keyPath.split(separator: ".") {
            guard let next = container[String(component)] as? NSDictionary else {
                container = [:]
                break
            }
            container = next
        }
        if let table = container as? NSMutableDictionary, table[name] != nil {
            table.removeObject(forKey: name)
            return true
        }
        if let flat = object[keyPath] as? NSMutableDictionary, flat[name] != nil {
            flat.removeObject(forKey: name)
            return true
        }
        return false
    }

    // MARK: - TOML

    private static func editTOML(at path: String, table: String,
                                 requests: [Request], outcome: inout Outcome) -> Bool {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        let targets = Set(requests.map(\.serverName))
        var kept: [String] = []
        var removedNames = Set<String>()
        var skipping = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                let parts = splitKey(String(trimmed.dropFirst().dropLast()))
                skipping = parts.count >= 2 && parts[0] == table && targets.contains(parts[1])
                if skipping {
                    removedNames.insert(parts[1])
                    continue
                }
            }
            if skipping && !trimmed.isEmpty { continue }
            kept.append(line)
        }
        for name in targets where !removedNames.contains(name) {
            outcome.missing += 1
        }
        guard !removedNames.isEmpty else { return true }
        guard backup(path) else { return false }
        do { try kept.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8) }
        catch { return false }
        outcome.removed += removedNames.count
        return true
    }

    /// 与 AgentInventory 的 TOML 解析一致：引号成对跳过，点号在引号外分隔。
    private static func splitKey(_ body: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quoted = false
        for character in body {
            if character == "\"" { quoted.toggle(); continue }
            if character == "." && !quoted { parts.append(current); current = ""; continue }
            current.append(character)
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - 备份

    /// 原子覆写式备份：重复清理时刷新为最新原貌，且不触碰删除漏斗。
    private static func backup(_ path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: path + ".nori-backup"), options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
