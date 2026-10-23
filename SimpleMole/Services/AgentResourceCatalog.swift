import Foundation

/// One resource per physical Skill source or MCP installation/endpoint. Names
/// are display text; they never determine which installation is deleted.
enum AgentResourceCatalog {
    struct SkillBinding: Identifiable, Sendable {
        let id: String
        let agentIDs: Set<String>
        let names: [String]
        let link: AgentSkill?
        let registration: AgentSkillConfigEditor.Registration?
        var removable: Bool { link != nil || registration != nil }
    }
    struct Skill: Identifiable, Sendable {
        let id: String
        let name: String
        let summary: String
        let body: AgentSkill?
        let bindings: [SkillBinding]
        var canDelete: Bool { body?.bodyDeletionSupported == true && !(body?.identity.isEmpty ?? true) }
        var hasOnlyDanglingLinks: Bool {
            body == nil && !bindings.isEmpty && bindings.allSatisfy { $0.link?.isDangling == true }
        }
    }
    struct MCP: Identifiable, Sendable {
        let id: String
        let name: String
        let installation: AgentMCPInstallation?
        let servers: [AgentMCPServer]
        var canDelete: Bool { !(installation?.identity.isEmpty ?? true) }
    }

    static func skills(_ entries: [AgentSkill]) -> [Skill] {
        let definitions = AgentCatalog.definitions
        let idsByName = Dictionary(definitions.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        let codexName = definitions.first { $0.id == "codex" }?.name ?? "Codex"
        return Dictionary(grouping: entries, by: { $0.linkTarget ?? $0.path }).map { path, rows in
            let body = rows.first { !$0.linked && $0.path == path }
            let representative = body ?? rows[0]
            var bindings: [SkillBinding] = []
            for link in rows where link.linked {
                let names = Array(Set((link.directUsers.isEmpty ? link.usedBy : link.directUsers)
                    + (link.registrations.isEmpty ? [] : [codexName]))).sorted()
                bindings.append(.init(id: "link|" + link.path,
                    agentIDs: Set(names.compactMap { idsByName[$0] }), names: names,
                    link: link, registration: nil))
            }
            let registrations = rows.flatMap(\.registrations).reduce(into: [AgentSkillConfigEditor.Registration]()) { result, registration in
                if !result.contains(where: { $0.id == registration.id }) { result.append(registration) }
            }
            for registration in registrations {
                bindings.append(.init(id: "config|" + registration.id, agentIDs: ["codex"],
                    names: [codexName], link: nil, registration: registration))
            }
            for name in body?.directUsers ?? [] {
                bindings.append(.init(id: "implicit|" + path + "|" + name,
                    agentIDs: Set(idsByName[name].map { [$0] } ?? []), names: [name], link: nil, registration: nil))
            }
            return Skill(id: path, name: representative.name, summary: representative.summary, body: body,
                bindings: bindings.sorted { $0.names.joined() < $1.names.joined() })
        }.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func mcps(servers: [AgentMCPServer], installations: [AgentMCPInstallation]) -> [MCP] {
        let bodies = Dictionary(installations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var grouped = Dictionary(grouping: servers) { server in
            server.installationID.map { "body|" + $0 }
                ?? (server.issues.contains(.unreadableConfig) ? "unreadable|" + server.configPath
                    : (server.remote ? "remote|" : "command|" + server.name + "|") + server.endpoint)
        }
        for body in installations where grouped["body|" + body.id] == nil { grouped["body|" + body.id] = [] }
        return grouped.map { key, rows in
            let body = key.hasPrefix("body|") ? bodies[String(key.dropFirst(5))] : nil
            return MCP(id: key, name: body?.name ?? rows.first?.name ?? "MCP", installation: body,
                       servers: rows.sorted { $0.agentName == $1.agentName ? $0.id < $1.id : $0.agentName < $1.agentName })
        }.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct AgentResourceChanges: Sendable {
    var skills: [AgentSkill] = []
    var registrations: [AgentSkillConfigEditor.Registration] = []
    var servers: [AgentMCPServer] = []
    var installations: [AgentMCPInstallation] = []
    var count: Int { skills.count + registrations.count + servers.count + installations.count }
    var deletesBodies: Bool { skills.contains { !$0.linked } || !installations.isEmpty }
    var cleansOnlyDanglingLinks: Bool {
        !skills.isEmpty && skills.allSatisfy { $0.linked && $0.isDangling }
            && registrations.isEmpty && servers.isEmpty && installations.isEmpty
    }

    func retainedSkillSelection(_ selectedPaths: Set<String>, afterRefreshing current: [AgentSkill]) -> Set<String> {
        let danglingPaths = Set(skills.filter(\.isDangling).map(\.path))
        return selectedPaths.intersection(current.filter {
            !danglingPaths.contains($0.path) || $0.isDangling
        }.map(\.path))
    }
}
