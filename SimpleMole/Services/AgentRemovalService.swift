import CryptoKit
import Darwin
import Foundation

/// Separate from cache cleaning: the caller must obtain explicit consent to
/// discard an uninstalled product's configuration, credentials and history.
/// Unknown files inside a verified, exclusive product root are included in the
/// preview. The only disposal operation available here is a reversible Trash move.
enum AgentRemovalService {
    struct Plan: @unchecked Sendable {
        let agentIDs: Set<String>
        let items: [DeletionPlan.Item]
        let retainedPaths: [String]
        let messages: [String]
        fileprivate let fingerprints: [String: TreeFingerprint]
        fileprivate let home: String
    }

    fileprivate struct TreeFingerprint: Equatable {
        let digest: Data
        let entries: Int
    }

    private struct Eligibility {
        var roots = Set<String>()
        var retained = Set<String>()
        var messages: [String] = []
    }

    static func plan(agentIDs: Set<String>, home: String,
                     presence: AgentPresenceContext? = nil) -> Plan {
        var scope = eligibleRoots(agentIDs: agentIDs, home: home, presence: presence)
        var items: [DeletionPlan.Item] = []
        var fingerprints: [String: TreeFingerprint] = [:]
        for path in scope.roots.sorted() {
            guard let identity = DeletionPlan.identity(at: path),
                  let metadata = DeletionPlan.Metadata.read(path),
                  let fingerprint = treeFingerprint(path),
                  DeletionPlan.identity(at: path) == identity,
                  DeletionPlan.Metadata.read(path) == metadata else {
                scope.retained.insert(path)
                scope.messages.append("Retained Agent data because its complete tree could not be verified: " + path)
                continue
            }
            items.append(.init(record: path, identity: identity, metadata: metadata))
            fingerprints[path] = fingerprint
        }
        return Plan(agentIDs: agentIDs, items: items, retainedPaths: scope.retained.sorted(),
                    messages: scope.messages, fingerprints: fingerprints,
                    home: DeletionPlan.normalizedPathLiteral(home))
    }

    static func execute(_ plan: Plan, running: RunningApplicationSnapshot, home: String,
                        presence: AgentPresenceContext? = nil, core: NativeCore = .shared,
                        trashHandler: ((URL) throws -> Void)? = nil) -> NativeCore.ApplySummary {
        var retained = Set(plan.retainedPaths)
        var messages = plan.messages
        var removed = Set<String>()
        var failed = 0
        func refuse(_ paths: [String], _ message: String) {
            retained.formUnion(paths)
            messages.append(message)
        }
        let paths = plan.items.map(\.record)
        guard DeletionPlan.isLexicallySafePath(home),
              DeletionPlan.normalizedPathLiteral(home) == plan.home,
              running.isComplete else {
            refuse(paths, "Retained Agent data because the home or running-process state could not be verified.")
            return summary()
        }
        let definitions = AgentCatalog.definitions.filter { plan.agentIDs.contains($0.id) }
        let owners = Set(definitions.flatMap { AgentCatalog.runtimeOwners(for: $0, home: home, presence: presence) })
        guard !owners.contains(where: { running.contains(processName: $0) || running.contains(bundleIdentifier: $0) }) else {
            refuse(paths, "Retained Agent data while an owning application or process is running.")
            return summary()
        }
        guard let openFiles = core.agentRemovalOpenFiles() else {
            refuse(paths, "Retained Agent data because open-file state was unavailable.")
            return summary()
        }
        let openPaths = Set(openFiles.map(CleanupRiskPolicy.canonicalOpenFilePath))
        // Operate only on the confirmed original items. Recomputing eligibility
        // may revoke authority, but can never add a newly discovered root.
        for item in plan.items {
            let path = item.record
            let fresh = eligibleRoots(agentIDs: plan.agentIDs, home: home, presence: presence)
            guard fresh.roots.contains(path) else {
                refuse([path], "Retained Agent data because its installation, shared ownership or policy changed: " + path)
                messages.append(contentsOf: fresh.messages)
                continue
            }
            guard let expectedTree = plan.fingerprints[path],
                  DeletionPlan.identity(at: path) == item.identity,
                  item.metadata != nil, DeletionPlan.Metadata.read(path) == item.metadata,
                  treeFingerprint(path) == expectedTree,
                  physicalOwnedRoot(path, home: home),
                  !openPaths.contains(where: { $0 == path || $0.hasPrefix(path + "/") }) else {
                refuse([path], "Retained Agent data because its tree changed, became aliased, or is open: " + path)
                continue
            }
            // Refresh the policy after tree verification; a newly protected
            // child keeps its whole root. No recursive deletion is performed.
            let whitelist = core.loadWhitelist(homeDirectory: home)
            guard let finalOpenFiles = core.agentRemovalOpenFiles(),
                  !finalOpenFiles.map(CleanupRiskPolicy.canonicalOpenFilePath).contains(where: {
                    $0 == path || $0.hasPrefix(path + "/")
                  }),
                  !core.matchesWhitelist(path, entries: whitelist),
                  treeMatchesWhitelist(path, entries: whitelist, core: core) == false,
                  eligibleRoots(agentIDs: plan.agentIDs, home: home, presence: presence).roots.contains(path),
                  physicalOwnedRoot(path, home: home),
                  DeletionPlan.identity(at: path) == item.identity,
                  DeletionPlan.Metadata.read(path) == item.metadata,
                  treeFingerprint(path) == expectedTree else {
                refuse([path], "Retained Agent data protected by whitelist or changed at the Trash boundary: " + path)
                continue
            }
            do {
                let url = URL(fileURLWithPath: path)
                if let trashHandler { try trashHandler(url) }
                else {
                    var destination: NSURL?
                    try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
                    if let trashPath = destination?.path {
                        messages.append("Trash restore location: " + path + " -> " + trashPath)
                    }
                }
                var remaining = stat()
                guard lstat(path, &remaining) != 0, errno == ENOENT else {
                    retained.insert(path)
                    failed += 1
                    messages.append("Trash operation left Agent data in place: " + path)
                    continue
                }
                removed.insert(path)
                messages.append("Moved Agent data to Trash: " + path)
            } catch {
                retained.insert(path)
                failed += 1
                messages.append("Could not move Agent data to Trash: " + path + ": " + error.localizedDescription)
            }
        }
        return summary()

        func summary() -> NativeCore.ApplySummary {
            let kept = retained.sorted()
            return .init(removed: removed.count, skipped: kept.count, failed: failed,
                         messages: Array(Set(messages)).sorted(), removedPaths: removed,
                         remainingPaths: kept, retainedPaths: kept, reclaimedBytes: 0)
        }
    }

    private static func eligibleRoots(agentIDs: Set<String>, home: String,
                                      presence: AgentPresenceContext?) -> Eligibility {
        var result = Eligibility()
        guard DeletionPlan.isLexicallySafePath(home), home != "/",
              !agentIDs.isEmpty else { return result }
        let definitions = AgentCatalog.definitions
        let selected = definitions.filter { agentIDs.contains($0.id) }
        let knownIDs = Set(selected.map(\.id))
        if knownIDs != agentIDs {
            result.messages.append("Unknown Agent identifiers cannot authorize data removal: "
                + agentIDs.subtracting(knownIDs).sorted().joined(separator: ", "))
        }
        let whitelist = NativeCore.shared.loadWhitelist(homeDirectory: home)
        var candidates = Set<String>()
        var removableIDs = Set<String>()
        for agent in selected {
            let roots = AgentCatalog.dataRoots(for: agent, home: home).filter(existsWithoutFollowing)
            guard AgentCatalog.installationPresence(for: agent) != nil,
                  !AgentCatalog.isInstalled(agent, home: home, presence: presence),
                  AgentCLIService.installations(for: agent, home: home, presence: presence).isEmpty else {
                result.retained.formUnion(roots)
                result.messages.append("Retained Agent data because a product is still installed or its installation ownership is unknown: " + agent.name)
                continue
            }
            removableIDs.insert(agent.id)
            candidates.formUnion(roots)
        }
        // Even another uninstalled product's retained configuration remains an
        // owner. Removing one product does not grant authority over the other.
        let otherDefinitions = definitions.filter { !removableIDs.contains($0.id) }
        let otherRoots = otherDefinitions.flatMap { agent in
            AgentCatalog.dataRoots(for: agent, home: home)
                + agent.implicitSkillDirectories.map { AgentCatalog.absolute($0, home: home) }
        }.filter(existsWithoutFollowing)
        let sharing = sharedReferences(otherDefinitions: otherDefinitions, selectedIDs: removableIDs,
                                       home: home, presence: presence)
        result.messages.append(contentsOf: sharing.unknownPaths.sorted().map {
            "Shared Skill or MCP ownership could not be verified at: " + $0
        })
        for root in DeletionPlan.nonOverlappingPaths(Array(candidates)).sorted() {
            let reason: String?
            if !safeProductRoot(root, home: home) || !physicalOwnedRoot(root, home: home) {
                reason = "its root is generic, outside the home, aliased, inaccessible or not owned by this user"
            } else if otherRoots.contains(where: { overlaps(root, $0) }) {
                reason = "another product owns data within the same root"
            } else if sharing.unknown {
                reason = "shared Skill or MCP ownership could not be verified"
            } else if sharing.paths.contains(where: { overlaps(root, $0) }) {
                reason = "another product references shared Skill or MCP content in this root"
            } else if sharing.literalReferences.contains(where: { text in
                text.contains(root) || text.contains("~" + root.dropFirst(home.count))
            }) {
                reason = "another product's MCP configuration references this root"
            } else if NativeCore.shared.matchesWhitelist(root, entries: whitelist) {
                reason = "the root or a child is protected by whitelist"
            } else if let matches = treeMatchesWhitelist(root, entries: whitelist, core: .shared) {
                reason = matches ? "the root or a child is protected by whitelist" : nil
            } else {
                reason = "its complete metadata tree could not be verified safely"
            }
            if let reason {
                result.retained.insert(root)
                result.messages.append("Retained Agent data because " + reason + ": " + root)
            } else { result.roots.insert(root) }
        }
        return result
    }

    private struct References {
        var paths = Set<String>()
        var literalReferences: [String] = []
        var unknown = false
        var unknownPaths = Set<String>()
    }

    private static func sharedReferences(otherDefinitions: [AgentDefinition], selectedIDs: Set<String>,
                                         home: String, presence: AgentPresenceContext?) -> References {
        var references = References()
        let directories = Set(otherDefinitions.flatMap {
            ($0.skillDirectories + $0.implicitSkillDirectories).map { AgentCatalog.absolute($0, home: home) }
        })
        for directory in directories where existsWithoutFollowing(directory) {
            if AgentCatalog.isSymlink(directory) {
                references.paths.insert(URL(fileURLWithPath: directory).resolvingSymlinksInPath().path)
                continue
            }
            guard physicalOwnedRoot(directory, home: home),
                  walkTree(directory, visit: { path, metadata in
                    if metadata.st_mode & S_IFMT == S_IFLNK {
                        references.paths.insert(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
                    }
                  }) else {
                references.unknown = true
                references.unknownPaths.insert(directory)
                continue
            }
        }
        // Inspect only known MCP configuration files, never authentication or
        // session files. Keep the decoded strings in memory; never log values.
        for source in otherDefinitions.flatMap(\.mcpSources) {
            let path = AgentCatalog.absolute(source.path, home: home)
            guard existsWithoutFollowing(path) else { continue }
            guard let data = readConfiguration(path, home: home),
                  let text = String(data: data, encoding: .utf8) else {
                references.unknown = true
                references.unknownPaths.insert(path)
                continue
            }
            // Several products leave an empty placeholder before the first
            // MCP is configured. A complete, readable empty file proves there
            // are no registrations; malformed nonempty files remain unknown.
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            let entries: [(scope: String?, name: String, config: [String: Any])]?
            switch source.format {
            case .json(let keyPath): entries = AgentInventory.jsonServers(data: data, keyPath: keyPath)
            case .toml(let table): entries = AgentInventory.tomlServers(text: text, table: table)
            }
            guard let entries else {
                references.unknown = true
                references.unknownPaths.insert(path)
                continue
            }
            var strings: [String] = []
            func visit(_ value: Any) {
                if let string = value as? String { strings.append(string) }
                else if let values = value as? [Any] { values.forEach(visit) }
                else if let values = value as? [String: Any] { values.values.forEach(visit) }
            }
            for entry in entries {
                visit(entry.config)
                if let scope = entry.scope, scope.hasPrefix(home + "/"),
                   DeletionPlan.isLexicallySafePath(scope) {
                    references.paths.insert(URL(fileURLWithPath: scope).resolvingSymlinksInPath().path)
                }
                let command: String?
                var arguments: [String] = []
                switch entry.config["command"] {
                case let value as String: command = value
                case let values as [String]: command = values.first; arguments = Array(values.dropFirst())
                case let nested as [String: Any]:
                    command = nested["path"] as? String
                    arguments = nested["args"] as? [String] ?? []
                default: command = nil
                }
                arguments += entry.config["args"] as? [String] ?? []
                if let command,
                   let installation = AgentInventory.mcpInstallationPath(command: command, arguments: arguments,
                        searchPath: presence?.searchPath ?? AgentCatalog.executableSearchPath(home: home), home: home) {
                    references.paths.insert(installation)
                }
            }
            if !selectedIDs.contains("codex"), path == AgentCatalog.absolute(".codex/config.toml", home: home) {
                guard let skills = configuredSkillReferences(text: text, home: home) else {
                    references.unknown = true
                    references.unknownPaths.insert(path)
                    continue
                }
                references.paths.formUnion(skills)
            }
            for value in strings {
                let expanded = value.replacingOccurrences(of: "${HOME}", with: home)
                    .replacingOccurrences(of: "$HOME", with: home)
                references.literalReferences.append(expanded)
                let pathValue = expanded.hasPrefix("~/") ? home + expanded.dropFirst() : expanded
                if DeletionPlan.isLexicallySafePath(pathValue), !pathValue.contains("\n") {
                    let resolved = URL(fileURLWithPath: pathValue).resolvingSymlinksInPath().path
                    // A generic HOME/cwd value is not an ownership declaration
                    // over every product directory below the user's home.
                    if resolved.hasPrefix(home + "/") { references.paths.insert(resolved) }
                }
            }
        }
        // Read-only reference sources are broader than editable registrations:
        // Goose/Hermes YAML and Continue's multi-file configurations still may
        // consume resources in another product's data root.
        let editablePaths = Set(otherDefinitions.flatMap(\.mcpSources).map {
            AgentCatalog.absolute($0.path, home: home)
        })
        let configurationExtensions: Set<String> = ["json", "jsonc", "yaml", "yml", "toml"]
        var readOnlyPaths = Set(otherDefinitions.flatMap { agent in
            agent.targets.filter { $0.labelKey == "agents.label.configuration" }.compactMap { target -> String? in
                guard case .path(let relative) = target.kind else { return nil }
                let path = AgentCatalog.absolute(relative, home: home)
                return configurationExtensions.contains((path as NSString).pathExtension.lowercased()) ? path : nil
            }
        }).subtracting(editablePaths)
        if otherDefinitions.contains(where: { $0.id == "continue" }) {
            let directory = AgentCatalog.absolute(".continue/mcpServers", home: home)
            if existsWithoutFollowing(directory) {
                let complete = physicalOwnedRoot(directory, home: home) && walkTree(directory, visit: { path, metadata in
                    if metadata.st_mode & S_IFMT == S_IFLNK {
                        references.unknown = true
                        references.unknownPaths.insert(path)
                    } else if metadata.st_mode & S_IFMT == S_IFREG,
                              configurationExtensions.contains((path as NSString).pathExtension.lowercased()) {
                        readOnlyPaths.insert(path)
                    }
                })
                if !complete { references.unknown = true; references.unknownPaths.insert(directory) }
            }
        }
        for path in readOnlyPaths where existsWithoutFollowing(path) {
            guard let data = readConfiguration(path, home: home),
                  let text = String(data: data, encoding: .utf8),
                  let decoded = decodedConfigurationEscapes(text) else {
                references.unknown = true
                references.unknownPaths.insert(path)
                continue
            }
            let ext = (path as NSString).pathExtension.lowercased()
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if ext == "json" || ext == "jsonc" {
                guard (try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed])) != nil else {
                    references.unknown = true; references.unknownPaths.insert(path); continue
                }
            } else if ext == "toml", AgentTOMLStatements.read(text) == nil {
                references.unknown = true; references.unknownPaths.insert(path); continue
            }
            // Literal and decoded forms also protect references in YAML plain
            // scalars and block values. Unknown includes/escaped continuations
            // cannot be proven independent and conservatively keep the roots.
            if (ext == "yaml" || ext == "yml") && (text.contains("!!binary") || text.contains("!include")) {
                references.unknown = true; references.unknownPaths.insert(path); continue
            }
            for value in [text, decoded] {
                references.literalReferences.append(value.replacingOccurrences(of: "${HOME}", with: home)
                    .replacingOccurrences(of: "$HOME", with: home))
            }
            let pattern = #"(?:"(?:\\.|[^"\\])*"|'(?:''|[^'])*'|(?:~|\$\{?HOME\}?|/)[^\s,\[\]{}"']+)"#
            guard let tokens = try? NSRegularExpression(pattern: pattern) else { continue }
            for sourceText in [text, decoded] {
                for match in tokens.matches(in: sourceText, range: NSRange(sourceText.startIndex..., in: sourceText)) {
                    guard let range = Range(match.range, in: sourceText) else { continue }
                    var token = String(sourceText[range])
                    if token.hasPrefix("\"") {
                        guard let value = decodedConfigurationEscapes(String(token.dropFirst().dropLast())) else {
                            references.unknown = true; references.unknownPaths.insert(path); continue
                        }
                        token = value
                    } else if token.hasPrefix("'") {
                        token = String(token.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
                    }
                    token = token.replacingOccurrences(of: "${HOME}", with: home).replacingOccurrences(of: "$HOME", with: home)
                    let candidate = token.hasPrefix("~/") ? home + token.dropFirst() : token
                    guard DeletionPlan.isLexicallySafePath(candidate) else { continue }
                    let resolved = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
                    if resolved.hasPrefix(home + "/") { references.paths.insert(resolved) }
                }
            }
        }
        return references
    }

    /// Decode path-relevant escapes without evaluating configuration or reading
    /// referenced files. This covers JSON/TOML unicode and YAML \x/\u/\U forms.
    private static func decodedConfigurationEscapes(_ text: String) -> String? {
        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            index = text.index(after: index)
            guard character == "\\", index < text.endIndex else { output.append(character); continue }
            let escaped = text[index]
            index = text.index(after: index)
            if escaped == "\n" || escaped == "\r" { return nil }
            let length = escaped == "x" ? 2 : escaped == "u" ? 4 : escaped == "U" ? 8 : 0
            if length > 0 {
                guard let end = text.index(index, offsetBy: length, limitedBy: text.endIndex),
                      let value = UInt32(text[index..<end], radix: 16), let scalar = UnicodeScalar(value) else { return nil }
                output.unicodeScalars.append(scalar)
                index = end
            } else if escaped == "/" || escaped == "\\" || escaped == "\"" || escaped == "'" || escaped == " " {
                output.append(escaped)
            } else {
                output.append("\\"); output.append(escaped)
            }
        }
        return output
    }

    private static func configuredSkillReferences(text: String, home: String) -> Set<String>? {
        guard let statements = AgentTOMLStatements.read(text) else { return nil }
        var paths = Set<String>()
        var table: [String] = []
        var inSkill = false
        for statement in statements {
            if let header = AgentTOMLStatements.header(statement.text) {
                table = header.path
                if Array(table.prefix(2)) == ["skills", "config"] {
                    guard table == ["skills", "config"], header.array else { return nil }
                    inSkill = true
                } else { inSkill = false }
            } else {
                guard let assignment = AgentTOMLStatements.assignment(statement.text) else { return nil }
                if !inSkill, assignment.path.first == "skills" || table == ["skills"] && assignment.path.first == "config" {
                    return nil
                }
                guard inSkill, assignment.path == ["path"] else { continue }
                guard let value = AgentTOMLStatements.stringValue(assignment.value) else { return nil }
                let path = value.hasPrefix("~/") ? home + value.dropFirst() : value
                guard DeletionPlan.isLexicallySafePath(path) else { return nil }
                paths.insert(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
            }
        }
        return paths
    }

    /// Read one regular file through verified physical directory descriptors.
    /// O_NONBLOCK prevents a raced FIFO from hanging a background preview.
    private static func readConfiguration(_ path: String, home: String) -> Data? {
        guard DeletionPlan.isLexicallySafePath(path), path.hasPrefix(home + "/") else { return nil }
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { return nil }
        defer { close(parent) }
        let components = path.split(separator: "/").map(String.init)
        guard let leaf = components.last else { return nil }
        for component in components.dropLast() {
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return nil }
            close(parent)
            parent = next
        }
        let descriptor = openat(parent, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == getuid(), before.st_size >= 0, before.st_size <= 1_048_576 else { return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0, data.count + count <= 1_048_576 else { return nil }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        var linked = stat()
        let expected = DeletionPlan.Metadata(before)
        guard fstat(descriptor, &after) == 0, fstatat(parent, leaf, &linked, AT_SYMLINK_NOFOLLOW) == 0,
              expected == DeletionPlan.Metadata(after), expected == DeletionPlan.Metadata(linked),
              physicalOwnedRoot(path, home: home), DeletionPlan.Metadata.read(path) == expected else { return nil }
        return data
    }

    private static func overlaps(_ first: String, _ second: String) -> Bool {
        first == second || first.hasPrefix(second + "/") || second.hasPrefix(first + "/")
    }

    private static func safeProductRoot(_ path: String, home: String) -> Bool {
        guard DeletionPlan.isLexicallySafePath(path), path.hasPrefix(home + "/"),
              path == DeletionPlan.normalizedPathLiteral(path) else { return false }
        let relative = String(path.dropFirst(home.count + 1))
        let generic: Set<String> = [".config", ".cache", ".local", ".local/share", ".local/state", ".local/bin",
            ".vscode", ".vscode/extensions", ".vscode-insiders", ".vscode-insiders/extensions",
            ".agents", ".agents/skills", ".config/agents", ".config/agents/skills",
            "Library", "Library/Application Support", "Library/Caches", "Library/Logs", "Library/Containers",
            "Library/Group Containers", "Library/Application Support/Code", "Library/Application Support/Code/User",
            "Library/Application Support/Code/User/globalStorage", "Library/Application Support/Code - Insiders",
            "Library/Application Support/Code - Insiders/User", "Library/Application Support/Code - Insiders/User/globalStorage",
            "Documents", "Desktop", "Downloads", "Public", "Pictures", "Movies", "Music", "Applications"]
        guard !generic.contains(relative) else { return false }
        return ![".Trash", ".ssh", ".gnupg", ".config/mole", "Library/Keychains", "Library/LaunchAgents",
                 "Library/Application Support/Nori"].contains { relative == $0 || relative.hasPrefix($0 + "/") }
    }

    private static func existsWithoutFollowing(_ path: String) -> Bool {
        var metadata = stat()
        return lstat(path, &metadata) == 0
    }

    /// Open every parent component with O_NOFOLLOW. A lexical prefix or a
    /// resolved URL alone cannot establish ownership of the original path.
    private static func physicalOwnedRoot(_ path: String, home: String) -> Bool {
        guard DeletionPlan.isLexicallySafePath(path), path.hasPrefix(home + "/") else { return false }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        let parts = path.split(separator: "/").map(String.init)
        for component in parts.dropLast() {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return false }
            close(descriptor)
            descriptor = next
        }
        guard let leaf = parts.last else { return false }
        var metadata = stat()
        guard fstatat(descriptor, leaf, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
              metadata.st_uid == getuid(), metadata.st_mode & S_IFMT != S_IFLNK,
              [S_IFDIR, S_IFREG].contains(metadata.st_mode & S_IFMT) else { return false }
        return true
    }

    private static func treeFingerprint(_ root: String) -> TreeFingerprint? {
        var digest = SHA256()
        var entries = 0
        guard walkTree(root, visit: { path, metadata in
            entries += 1
            let fields = [String(path.dropFirst(root.count)), String(metadata.st_dev), String(metadata.st_ino),
                String(metadata.st_mode), String(metadata.st_uid), String(metadata.st_gid), String(metadata.st_flags),
                String(metadata.st_size), String(metadata.st_nlink), String(metadata.st_mtimespec.tv_sec),
                String(metadata.st_mtimespec.tv_nsec), String(metadata.st_ctimespec.tv_sec),
                String(metadata.st_ctimespec.tv_nsec)]
            for field in fields { digest.update(data: Data(field.utf8)); digest.update(data: Data([0])) }
        }) else { return nil }
        return TreeFingerprint(digest: Data(digest.finalize()), entries: entries)
    }

    private static func treeMatchesWhitelist(_ root: String, entries: [String], core: NativeCore) -> Bool? {
        var matches = false
        let complete = walkTree(root, visit: { path, _ in
            if core.matchesWhitelist(path, entries: entries) { matches = true }
        })
        return complete ? matches : nil
    }

    /// Metadata-only traversal. Internal symbolic links are fingerprinted as
    /// links and moved with their root; their destination is never traversed.
    private static func walkTree(_ root: String, visit: (String, stat) -> Void) -> Bool {
        let deadline = Date().addingTimeInterval(8)
        var count = 0
        guard DeletionPlan.isLexicallySafePath(root) else { return false }
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { return false }
        defer { close(parent) }
        let components = root.split(separator: "/").map(String.init)
        guard let rootName = components.last else { return false }
        for component in components.dropLast() {
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return false }
            close(parent)
            parent = next
        }
        func walk(parent: Int32, name: String, path: String, depth: Int) -> Bool {
            count += 1
            guard count <= 200_000, depth <= 128, Date() < deadline else { return false }
            var before = stat()
            // The movable product root must belong to the user, but readable
            // installer-created children may belong to root. Their uid/gid are
            // still fingerprinted; this move neither follows links nor changes
            // ownership or permissions anywhere in the tree.
            guard fstatat(parent, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
            visit(path, before)
            if before.st_mode & S_IFMT == S_IFDIR {
                let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else { return false }
                defer { close(descriptor) }
                var opened = stat()
                guard fstat(descriptor, &opened) == 0,
                      DeletionPlan.Metadata(before) == DeletionPlan.Metadata(opened) else { return false }
                let listingDescriptor = dup(descriptor)
                guard listingDescriptor >= 0 else { return false }
                guard let stream = fdopendir(listingDescriptor) else {
                    close(listingDescriptor)
                    return false
                }
                var names: [String] = []
                var enumerationFailed = false
                while true {
                    errno = 0
                    guard let entry = readdir(stream) else {
                        enumerationFailed = errno != 0
                        break
                    }
                    let child = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                        pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                            String(validatingCString: $0)
                        }
                    }
                    guard let child else { enumerationFailed = true; break }
                    if child != "." && child != ".." { names.append(child) }
                    if names.count + count > 200_000 || Date() >= deadline { enumerationFailed = true; break }
                }
                closedir(stream)
                guard !enumerationFailed else { return false }
                for name in names.sorted() {
                    guard walk(parent: descriptor, name: name, path: path + "/" + name, depth: depth + 1) else { return false }
                }
                var after = stat()
                guard fstat(descriptor, &after) == 0,
                      DeletionPlan.Metadata(before) == DeletionPlan.Metadata(after) else { return false }
            } else if before.st_mode & S_IFMT != S_IFREG && before.st_mode & S_IFMT != S_IFLNK {
                return false
            }
            var after = stat()
            return fstatat(parent, name, &after, AT_SYMLINK_NOFOLLOW) == 0
                && DeletionPlan.Metadata(before) == DeletionPlan.Metadata(after)
        }
        return walk(parent: parent, name: rootName, path: root, depth: 0)
    }
}
