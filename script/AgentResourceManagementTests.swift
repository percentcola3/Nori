import Foundation

@main
struct AgentResourceManagementTests {
    static func main() throws {
        let fm = FileManager.default
        let home = CommandLine.arguments[1]
        let presence = AgentPresenceContext(applicationDirs: [], searchPath: [])
        let idle = RunningApplicationSnapshot()
        func write(_ relative: String, _ text: String) throws {
            let path = home + "/" + relative
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
        func scan() -> [AgentSkill] {
            AgentInventory.scanSkills(home: home, control: CleanupScanControl(mode: .deep),
                agents: AgentCatalog.definitions.filter { ["codex", "claude-code", "shared"].contains($0.id) })
        }
        let body = home + "/.agents/skills/shared"
        let claudeLink = home + "/.claude/skills/shared"
        let codexLink = home + "/.codex/skills/shared"
        try write(".agents/skills/shared/SKILL.md", "---\nname: Same name\ndescription: Shared source\n---\nFixture\n")
        try write(".agents/skills/other/SKILL.md", "---\nname: Same name\n---\nOther source\n")
        for path in [claudeLink, codexLink] {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: path, withDestinationPath: body)
        }
        try write(".codex/config.toml", "model = \"fixture\"\n[[skills.config]]\npath = \"\(body)/SKILL.md\"\nenabled = true\n[mcp_servers.keep]\ncommand = \"fixture-server\"\n")
        let scanned = scan()
        let resources = AgentResourceCatalog.skills(scanned)
        let shared = resources.first { $0.id == body }!
        precondition(resources.filter { $0.name == "Same name" }.count == 2,
                     "Same-name sources must remain distinct; links must group by their source path")
        precondition(shared.body != nil && shared.bindings.filter { $0.link != nil }.count == 2
                     && shared.bindings.filter { $0.registration != nil }.count == 1,
                     "Shared sources must retain every independently editable binding")
        let unlink = AgentResourceMutator.execute(.init(skills: [scanned.first { $0.path == claudeLink }!]),
            running: idle, home: home, presence: presence)
        precondition(unlink.summary.removed > 0 && AgentCatalog.exists(body)
                     && !AgentCatalog.exists(claudeLink) && AgentCatalog.exists(codexLink),
                     "Unlinking one Agent must preserve its source and other Agent bindings")
        let registration = AgentSkillConfigEditor.scan(home: home)[0]
        let running = AgentResourceMutator.execute(.init(registrations: [registration]),
            running: .init(processNames: ["Codex"]), home: home, presence: presence)
        precondition(running.refused == 1 && AgentSkillConfigEditor.scan(home: home).count == 1,
                     "A running consumer must block selective Skill configuration edits")
        try write(".codex/config.toml", "# externally changed\n" + (try String(contentsOfFile: home + "/.codex/config.toml")))
        let changed = AgentResourceMutator.execute(.init(registrations: [registration]),
            running: idle, home: home, presence: presence)
        precondition(changed.refused == 1, "A changed registration cannot inherit a fresh identity")
        let fresh = AgentSkillConfigEditor.scan(home: home)[0]
        let removed = AgentResourceMutator.execute(.init(registrations: [fresh]), running: idle, home: home, presence: presence)
        let config = try String(contentsOfFile: home + "/.codex/config.toml")
        precondition(removed.summary.removed == 1 && !config.contains("[[skills.config]]")
                     && config.contains("[mcp_servers.keep]") && AgentCatalog.exists(body)
                     && AgentCatalog.exists(home + "/.codex/config.toml.nori-backup"),
                     "Selective configuration unlink must back up the file and preserve its other sections and Skill body")

        try write(".codex/config.toml", "model = \"fixture\"\n[[skills.config]]\npath = \"\(body)/SKILL.md\"\n[mcp_servers.keep]\ncommand = \"fixture-server\"\n[mcp_servers.stay]\ncommand = \"other-server\"\n")
        let codex = AgentCatalog.definitions.first { $0.id == "codex" }!
        let keep = AgentInventory.scanMCP(agents: [codex], home: home, presence: presence).first { $0.name == "keep" }!
        let combined = AgentResourceMutator.execute(.init(registrations: AgentSkillConfigEditor.scan(home: home), servers: [keep]),
            running: idle, home: home, presence: presence)
        let combinedConfig = try String(contentsOfFile: home + "/.codex/config.toml")
        precondition(combined.summary.removed == 2 && combined.summary.failed == 0
                     && !combinedConfig.contains("[[skills.config]]") && !combinedConfig.contains("[mcp_servers.keep]")
                     && combinedConfig.contains("[mcp_servers.stay]") && combinedConfig.contains("model = \"fixture\""),
                     "One batch must safely unlink Skill and MCP registrations sharing a config file")
        let delete = AgentResourceMutator.execute(.init(skills: [scan().first { $0.path == body && !$0.linked }!]),
            running: idle, home: home, presence: presence)
        precondition(delete.summary.removed > 0 && !AgentCatalog.exists(body) && !AgentCatalog.exists(codexLink)
                     && AgentCatalog.exists(home + "/.agents/skills/other"),
                     "Deleting a shared body must remove its bindings and preserve other sources")

        let serverA = AgentMCPServer(id: "a", agentName: "Codex", agentID: "codex", configPath: home + "/a.json",
            format: .json(keyPath: "mcpServers"), scope: nil, name: "Shared MCP", remote: true,
            endpoint: "https://fixture.invalid/mcp", disabled: false, issues: [])
        var serverB = AgentMCPServer(id: "b", agentName: "Claude Code", agentID: "claude-code", configPath: home + "/b.json",
            format: .json(keyPath: "mcpServers"), scope: nil, name: "Shared MCP", remote: true,
            endpoint: "https://fixture.invalid/mcp", disabled: false, issues: [])
        precondition(AgentResourceCatalog.mcps(servers: [serverA, serverB], installations: []).count == 1,
                     "One remote endpoint must present all Agent registrations together")
        serverB.installationID = body
        precondition(AgentResourceCatalog.mcps(servers: [serverA, serverB], installations: []).count == 2,
                     "A different local installation must not merge merely because its name matches")
        print("Agent resource management: source grouping, selective unlink, backups, changed/running guards and MCP identity passed")
    }
}
