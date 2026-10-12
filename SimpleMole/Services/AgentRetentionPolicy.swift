import Foundation

enum AgentRetentionRule: Codable, Equatable, Sendable {
    case never
    case days(Int)

    private enum CodingKeys: String, CodingKey {
        case kind, days
    }

    private enum Kind: String, Codable {
        case never, days
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .never:
            self = .never
        case .days:
            self = .days(try container.decode(Int.self, forKey: .days))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .never:
            try container.encode(Kind.never, forKey: .kind)
        case .days(let days):
            try container.encode(Kind.days, forKey: .kind)
            try container.encode(days, forKey: .days)
        }
    }
}

enum AgentRetentionClass: String, Codable, CaseIterable, Sendable {
    case conversations, artifacts, temporary
}

struct AgentRetentionPreferences: Codable, Equatable, Sendable {
    static let storageKey = "SMAgentRetentionPreferences.v1"
    static let presetDays = [7, 30, 90, 180, 365]
    static let unusedToolThreshold: TimeInterval = 90 * 24 * 3600

    var conversations: AgentRetentionRule = .days(90)
    var artifacts: AgentRetentionRule = .days(90)
    private var agents: [String: Rules] = [:]

    private struct Rules: Codable, Equatable, Sendable {
        var conversations: AgentRetentionRule
        var artifacts: AgentRetentionRule
    }

    private enum CodingKeys: String, CodingKey {
        case conversations, artifacts, agents
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        conversations = try container.decodeIfPresent(AgentRetentionRule.self, forKey: .conversations) ?? .days(90)
        artifacts = try container.decodeIfPresent(AgentRetentionRule.self, forKey: .artifacts) ?? .days(90)
        agents = try container.decodeIfPresent([String: Rules].self, forKey: .agents) ?? [:]
    }

    func rule(for retentionClass: AgentRetentionClass, agentID: String? = nil) -> AgentRetentionRule {
        let rules = agentID.flatMap { agents[$0] }
        switch retentionClass {
        case .conversations: return rules?.conversations ?? conversations
        case .artifacts: return rules?.artifacts ?? artifacts
        case .temporary: return .days(1)
        }
    }

    mutating func set(_ rule: AgentRetentionRule, for retentionClass: AgentRetentionClass, agentID: String? = nil) {
        if let agentID {
            guard retentionClass != .temporary else { return }
            var rules = agents[agentID] ?? Rules(conversations: conversations, artifacts: artifacts)
            switch retentionClass {
            case .conversations: rules.conversations = rule
            case .artifacts: rules.artifacts = rule
            case .temporary: break
            }
            agents[agentID] = rules
            return
        }
        switch retentionClass {
        case .conversations: conversations = rule
        case .artifacts: artifacts = rule
        case .temporary: break
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return decoded
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// Agent 启动会批量读取历史用于索引和恢复列表，因此这里只用 mtime，
    /// 不把 atime 当作用户仍在使用这段历史的证据。
    func isExpired(_ retentionClass: AgentRetentionClass, agentID: String? = nil,
                   modified: Date?, now: Date = Date()) -> Bool {
        CleanupAgePolicy.isStale(modified, now: now, retention: retention(for: retentionClass, agentID: agentID))
    }

    func retention(for retentionClass: AgentRetentionClass, agentID: String? = nil) -> TimeInterval {
        switch rule(for: retentionClass, agentID: agentID) {
        case .never: return 0
        case .days(let days): return TimeInterval(max(0, days)) * 24 * 3600
        }
    }
}

enum AgentRetentionPolicy {
    static func retentionClass(forLabelKey labelKey: String) -> AgentRetentionClass? {
        switch labelKey {
        case "agents.label.sessions", "agents.label.transcripts", "agents.label.archivedSessions",
             "agents.label.history", "agents.label.conversations":
            return .conversations
        case "agents.label.fileHistory", "agents.label.shellSnapshots", "agents.label.todos",
             "agents.label.plans", "agents.label.checkpoints", "agents.label.generatedImages",
             "agents.label.pasteCache", "agents.label.browserRecordings", "agents.label.attachments",
             "agents.label.configBackups", "agents.label.worktrees":
            return .artifacts
        default:
            return nil
        }
    }
}
