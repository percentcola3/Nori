import Foundation
import Darwin

enum AutoCleanupPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case sizeLimit
    case retentionDays

    var id: String { rawValue }
}

struct AutoCleanupRoot: Codable, Equatable, Sendable {
    let directory: String
    var authorizedIdentity: String?
}

/// One scheduled task with a shared policy across all of its cache roots.
struct AutoCleanupRule: Identifiable, Codable, Equatable, Sendable {
    static let currentSafetyVersion = 4
    static let safetyToken = "safe-trash-v4"
    static let minimumSizeLimitBytes: UInt64 = 100_000_000 // 0.1 GB.
    static let maximumSizeLimitBytes: UInt64 = 1_024_000_000_000 // 1024 GB.

    var id: UUID
    var directory: String
    var sourceName: String?
    var additionalRoots: [AutoCleanupRoot]
    var policy: AutoCleanupPolicy
    var sizeLimitBytes: UInt64
    var retentionDays: Int
    var isEnabled: Bool
    /// 用户明确确认该目录只保存可再生内容；旧版本规则迁移时一律为 false。
    var isRegenerable: Bool
    var safetyVersion: Int
    /// Device/inode/birth time of the directory when the user authorizes it.
    /// Recreating a directory at the same pathname never inherits consent.
    var authorizedRootIdentity: String?
    var lastRunAt: Date?
    var lastReclaimedBytes: UInt64
    /// 历史执行统计：累计执行次数与累计清理量，随每次执行递增。
    var executionCount: Int
    var totalReclaimedBytes: UInt64

    var isSafetyAuthorized: Bool {
        isRegenerable && safetyVersion == Self.currentSafetyVersion
            && roots.allSatisfy { Self.isCurrentRootIdentity($0.authorizedIdentity) }
    }

    var roots: [AutoCleanupRoot] {
        [AutoCleanupRoot(directory: directory, authorizedIdentity: authorizedRootIdentity)]
            + additionalRoots
    }

    var directories: [String] { roots.map(\.directory) }

    init(id: UUID = UUID(),
         directory: String,
         sourceName: String? = nil,
         additionalRoots: [AutoCleanupRoot] = [],
         policy: AutoCleanupPolicy,
         sizeLimitBytes: UInt64,
         retentionDays: Int,
         isEnabled: Bool = true,
         isRegenerable: Bool = false,
         safetyVersion: Int = AutoCleanupRule.currentSafetyVersion,
         authorizedRootIdentity: String? = nil,
         lastRunAt: Date? = nil,
         lastReclaimedBytes: UInt64 = 0,
         executionCount: Int = 0,
         totalReclaimedBytes: UInt64 = 0) {
        self.id = id
        self.directory = directory
        self.sourceName = sourceName
        self.additionalRoots = additionalRoots
        self.policy = policy
        self.sizeLimitBytes = sizeLimitBytes
        self.retentionDays = retentionDays
        self.isRegenerable = isRegenerable
        self.safetyVersion = safetyVersion
        let resolvedRootIdentity = isRegenerable
            ? (authorizedRootIdentity ?? Self.rootIdentity(at: directory))
            : nil
        self.authorizedRootIdentity = resolvedRootIdentity
        self.lastRunAt = lastRunAt
        self.lastReclaimedBytes = lastReclaimedBytes
        self.executionCount = executionCount
        self.totalReclaimedBytes = totalReclaimedBytes
        self.isEnabled = isEnabled && isRegenerable
            && Self.isCurrentRootIdentity(resolvedRootIdentity)
            && additionalRoots.allSatisfy { Self.isCurrentRootIdentity($0.authorizedIdentity) }
    }

    private enum CodingKeys: String, CodingKey {
        case id, directory, sourceName, policy, sizeLimitBytes, retentionDays, isEnabled
        case additionalRoots
        case isRegenerable, safetyVersion, authorizedRootIdentity
        case lastRunAt, lastReclaimedBytes
        case executionCount, totalReclaimedBytes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        directory = try values.decode(String.self, forKey: .directory)
        sourceName = try values.decodeIfPresent(String.self, forKey: .sourceName)
        additionalRoots = try values.decodeIfPresent([AutoCleanupRoot].self, forKey: .additionalRoots) ?? []
        policy = try values.decode(AutoCleanupPolicy.self, forKey: .policy)
        sizeLimitBytes = try values.decode(UInt64.self, forKey: .sizeLimitBytes)
        retentionDays = try values.decode(Int.self, forKey: .retentionDays)
        let requestedRegenerable = try values.decodeIfPresent(
            Bool.self, forKey: .isRegenerable) ?? false
        let decodedSafetyVersion = try values.decodeIfPresent(
            Int.self, forKey: .safetyVersion) ?? 0
        let decodedRootIdentity = try values.decodeIfPresent(
            String.self, forKey: .authorizedRootIdentity)
        let identityFormatValid = Self.isCurrentRootIdentity(decodedRootIdentity)
        let hasCurrentAuthorization = requestedRegenerable
            && decodedSafetyVersion == Self.currentSafetyVersion
            && identityFormatValid
            && additionalRoots.allSatisfy { Self.isCurrentRootIdentity($0.authorizedIdentity) }
        // 运行时授权保持保守：安全版本或身份过期时规则一律视为未确认。
        // 但存储中的授权数据按原样保留——升级（或回滚）后重新勾选
        // “仅可再生内容”即可恢复规则，不需要重建，也不因中途保存而销毁。
        isRegenerable = hasCurrentAuthorization
        safetyVersion = decodedSafetyVersion
        authorizedRootIdentity = identityFormatValid ? decodedRootIdentity : nil
        let requestedEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        let validSizeLimit = policy != .sizeLimit
            || (Self.minimumSizeLimitBytes...Self.maximumSizeLimitBytes).contains(sizeLimitBytes)
        isEnabled = requestedEnabled && hasCurrentAuthorization && validSizeLimit
        lastRunAt = try values.decodeIfPresent(Date.self, forKey: .lastRunAt)
        lastReclaimedBytes = try values.decodeIfPresent(UInt64.self, forKey: .lastReclaimedBytes) ?? 0
        // 旧数据没有统计字段：从 0 开始累计。
        executionCount = try values.decodeIfPresent(Int.self, forKey: .executionCount) ?? 0
        totalReclaimedBytes = try values.decodeIfPresent(UInt64.self, forKey: .totalReclaimedBytes) ?? 0
    }

    static func rootIdentity(at path: String) -> String? {
        var metadata = stat()
        guard Darwin.lstat(path, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return nil }
        return "\(metadata.st_dev):\(metadata.st_ino):\(metadata.st_birthtimespec.tv_sec)"
    }

    private static func isCurrentRootIdentity(_ identity: String?) -> Bool {
        let fields = identity?.split(separator: ":") ?? []
        return fields.count == 3 && fields.allSatisfy { UInt64($0) != nil }
    }
}

/// Identifies sources when migrating older directory rules to a single task.
struct AutoCleanupRuleGroup: Identifiable, Equatable, Sendable {
    let id: String
    let sourceName: String?
    var rules: [AutoCleanupRule]

    static func groups(for rules: [AutoCleanupRule]) -> [Self] {
        var groups: [Self] = []
        var indices: [String: Int] = [:]
        for rule in rules {
            let explicitName = rule.sourceName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let sourceName = explicitName.flatMap { $0.isEmpty ? nil : $0 }
                ?? legacySourceName(for: rule.directory)
            let id = sourceName.map { "source:" + $0 } ?? "directory:" + rule.id.uuidString
            if let index = indices[id] {
                groups[index].rules.append(rule)
            } else {
                indices[id] = groups.count
                groups.append(Self(id: id, sourceName: sourceName, rules: [rule]))
            }
        }
        return groups
    }

    private static func legacySourceName(for directory: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let path = URL(fileURLWithPath: directory).standardizedFileURL.path
        // Older category rules omitted their source. Recognize only Chrome roots
        // in this user's Library, with a component boundary after Chrome.
        for relativeRoot in ["Library/Caches/Google/Chrome",
                             "Library/Application Support/Google/Chrome"] {
            let root = home.appendingPathComponent(relativeRoot).path
            if path == root || path.hasPrefix(root + "/") { return "Google" }
        }
        return nil
    }
}

struct AutoCleanupCandidate: Identifiable, Equatable, Sendable {
    let path: String
    let bytes: UInt64
    let modifiedAt: Date
    /// 扫描时的文件身份，交给最终删除桥接再次核对，避免路径在扫描后被替换。
    let identity: String
    let risk: CleanupRisk
    let disposal: CleanupDisposal

    var id: String { path }
    var automaticEligible: Bool { risk == .safe && disposal == .permanentDelete }
}

struct AutoCleanupPlan: Equatable, Sendable {
    let root: String
    let totalBytes: UInt64
    let candidates: [AutoCleanupCandidate]
    let remainingBytes: UInt64
    let reclaimableBytes: UInt64
}

enum AutoCleanupRuleStore {
    static let storageKey = "SMAutoCleanupRules"
    /// 存储无法解码时，覆盖前保留的最后一份原始快照（升级路径的恢复底牌）。
    static let backupKey = "SMAutoCleanupRulesBackup"

    /// 读取版本升级前的旧数据（同一 JSON 数组格式；新增字段必须
    /// decodeIfPresent 可选，JSONDecoder 忽略未知键，两个方向兼容）。
    /// 单条规则字段损坏时保留其余可解析的规则，而不是整批丢失。
    static func load(from defaults: UserDefaults = .standard) -> [AutoCleanupRule] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        if let rules = try? JSONDecoder().decode([AutoCleanupRule].self, from: data) {
            return migrate(rules, originalData: data, defaults: defaults)
        }
        guard let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [] }
        let decoder = JSONDecoder()
        var salvaged: [AutoCleanupRule] = []
        for entry in entries {
            guard let entryData = try? JSONSerialization.data(withJSONObject: entry),
                  let rule = try? decoder.decode(AutoCleanupRule.self, from: entryData)
            else { continue }
            salvaged.append(rule)
        }
        return migrate(salvaged, originalData: data, defaults: defaults)
    }

    static func consolidatedTasks(from rules: [AutoCleanupRule]) -> [AutoCleanupRule] {
        AutoCleanupRuleGroup.groups(for: rules).map { group in
            var task = group.rules[0]
            task.sourceName = group.sourceName
            guard group.rules.count > 1 else { return task }
            var roots: [AutoCleanupRoot] = []
            var identitiesAgree = true
            for root in group.rules.flatMap(\.roots) {
                if let existing = roots.first(where: { $0.directory == root.directory }) {
                    identitiesAgree = identitiesAgree && existing.authorizedIdentity == root.authorizedIdentity
                } else {
                    roots.append(root)
                }
            }
            task.additionalRoots = Array(roots.dropFirst())
            task.isRegenerable = identitiesAgree && group.rules.allSatisfy(\.isSafetyAuthorized)
            // Migrating never turns on a previously disabled directory. Different
            // old policies also require review of the new shared policy.
            let samePolicy = group.rules.allSatisfy {
                $0.policy == task.policy && $0.sizeLimitBytes == task.sizeLimitBytes
                    && $0.retentionDays == task.retentionDays
            }
            task.isEnabled = samePolicy && task.isRegenerable && group.rules.allSatisfy(\.isEnabled)
            task.lastRunAt = group.rules.compactMap(\.lastRunAt).max()
            task.executionCount = group.rules.map(\.executionCount).max() ?? 0
            func sum(_ values: [UInt64]) -> UInt64 {
                values.reduce(0) { result, value in
                    let (total, overflow) = result.addingReportingOverflow(value)
                    return overflow ? UInt64.max : total
                }
            }
            task.lastReclaimedBytes = sum(group.rules.map(\.lastReclaimedBytes))
            task.totalReclaimedBytes = sum(group.rules.map(\.totalReclaimedBytes))
            return task
        }
    }

    private static func migrate(_ rules: [AutoCleanupRule], originalData: Data,
                                defaults: UserDefaults) -> [AutoCleanupRule] {
        let tasks = consolidatedTasks(from: rules)
        if tasks != rules {
            defaults.set(originalData, forKey: backupKey)
            save(tasks, to: defaults)
        }
        return tasks
    }

    static func save(_ rules: [AutoCleanupRule], to defaults: UserDefaults = .standard) {
        if let existing = defaults.data(forKey: storageKey), !existing.isEmpty,
           (try? JSONDecoder().decode([AutoCleanupRule].self, from: existing)) == nil {
            defaults.set(existing, forKey: backupKey)
        }
        guard let data = try? JSONEncoder().encode(rules) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

enum AutoCleanupPlannerError: LocalizedError, Equatable {
    case invalidRoot(String)
    case protectedRoot(String)
    case symbolicLink(String)
    case notDirectory(String)
    case invalidRetentionDays(Int)
    case invalidSizeLimit(UInt64)
    case regenerableConfirmationRequired(String)
    case protectedContent(String)
    case scanFailed(String)
    case sizeOverflow(String)
    case rootChanged(String)
    case rootAuthorizationChanged(String)

    var errorDescription: String? {
        switch self {
        case .invalidRoot(let path):
            return L10n.shared.tf("audit.auto.error.invalidRoot", path)
        case .protectedRoot(let path):
            return L10n.shared.tf("audit.auto.error.protectedRoot", path)
        case .symbolicLink(let path):
            return L10n.shared.tf("audit.auto.error.symbolicLink", path)
        case .notDirectory(let path):
            return L10n.shared.tf("audit.auto.error.notDirectory", path)
        case .invalidRetentionDays(let days):
            return L10n.shared.tf("audit.auto.error.retention", days)
        case .invalidSizeLimit:
            return L10n.shared.t("audit.auto.error.sizeLimit")
        case .regenerableConfirmationRequired(let path):
            return L10n.shared.tf("audit.auto.error.confirmation", path)
        case .protectedContent(let path):
            return L10n.shared.tf("audit.auto.error.protectedContent", path)
        case .scanFailed(let path):
            return L10n.shared.tf("audit.auto.error.scanFailed", path)
        case .sizeOverflow(let path):
            return L10n.shared.tf("audit.auto.error.sizeOverflow", path)
        case .rootChanged(let path):
            return L10n.shared.tf("audit.auto.error.rootChanged", path)
        case .rootAuthorizationChanged(let path):
            return L10n.shared.tf("audit.auto.error.authorizationChanged", path)
        }
    }
}

enum AutoCleanupPlanner {
    private static let recentWriteProtection: TimeInterval = 60 * 60
    private static let protectedSystemRoots = [
        "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin",
        "/private", "/var", "/etc", "/dev"
    ]
    private static let protectedUserRootNames = [
        "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Library"
    ]
    private static let protectedDirectoryNames: Set<String> = [
        ".git", ".hg", ".svn", ".ssh", ".gnupg", "models", "sessions",
        "conversations", "userdata", "user data", "databases", "docker", "vms"
    ]
    private static let protectedFileNames: Set<String> = [
        "credentials", "credentials.json", "cookies", "history", "login data",
        "wallet.dat", "pytorch_model.bin", "adapter_model.bin", "model.bin",
        "package.json", "package-lock.json", "pnpm-lock.yaml",
        "yarn.lock", "cargo.toml", "cargo.lock", "pyproject.toml", "poetry.lock",
        "go.mod", "go.sum", "podfile", "podfile.lock", "package.swift",
        "pubspec.yaml", "pubspec.lock", "dockerfile", "docker-compose.yml"
    ]
    private static let protectedExtensions: Set<String> = [
        "pem", "key", "p12", "pfx", "mobileprovision", "sqlite", "sqlite3", "db",
        "gguf", "safetensors", "ckpt", "mlmodel", "mlmodelc",
        "pt", "pth", "onnx", "tflite"
    ]
    private static let protectedPathFragments = [
        "/.local/share/opencode/project",
        "/.gemini/tmp"
    ]

    /// 校验并返回标准化目录。路径任一层为软链接时均拒绝。
    @discardableResult
    static func validateRoot(_ url: URL) throws -> URL {
        guard url.isFileURL else {
            throw AutoCleanupPlannerError.invalidRoot(url.absoluteString)
        }

        let root = url.standardizedFileURL
        let path = root.path
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .standardizedFileURL.path

        guard !path.isEmpty else {
            throw AutoCleanupPlannerError.invalidRoot(path)
        }
        // 不允许根目录、整块卷、整个账号或系统目录树作为可再生垃圾目录。
        let comparisonPath = path.lowercased()
        let isSystemPath = protectedSystemRoots.contains { protected in
            let comparisonRoot = protected.lowercased()
            return comparisonPath == comparisonRoot
                || comparisonPath.hasPrefix(comparisonRoot + "/")
        }
        let protectedUserRoots = protectedUserRootNames.map {
            URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent($0).path
        }
        guard root.pathComponents.count > 3,
              path != home,
              !isSystemPath,
              !protectedUserRoots.contains(path),
              !CleanupRiskPolicy.isForbiddenAutomationPath(path,
                                                           homeDirectory: home) else {
            throw AutoCleanupPlannerError.protectedRoot(path)
        }

        var currentPath = "/"
        var rootMetadata: stat?
        for component in root.pathComponents.dropFirst() {
            currentPath = (currentPath as NSString).appendingPathComponent(component)
            var metadata = stat()
            guard Darwin.lstat(currentPath, &metadata) == 0 else {
                throw AutoCleanupPlannerError.invalidRoot(currentPath)
            }
            let kind = metadata.st_mode & mode_t(S_IFMT)
            guard kind != mode_t(S_IFLNK) else {
                throw AutoCleanupPlannerError.symbolicLink(currentPath)
            }
            rootMetadata = metadata
        }

        guard let metadata = rootMetadata else {
            throw AutoCleanupPlannerError.invalidRoot(path)
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw AutoCleanupPlannerError.notDirectory(path)
        }
        return root
    }

    static func validatedRoot(_ url: URL) throws -> String {
        try validateRoot(url).path
    }

    /// 扫描与计算全部放到 utility 任务中；任何不完整读取都会让整个计划失败。
    static func plan(for rule: AutoCleanupRule,
                     protecting protectedDirectories: [String] = []) async throws -> AutoCleanupPlan {
        if let invalid = rule.directories.first(where: {
            $0.isEmpty || !($0 as NSString).isAbsolutePath
        }) {
            throw AutoCleanupPlannerError.invalidRoot(invalid)
        }
        if rule.policy == .retentionDays, rule.retentionDays <= 0 {
            throw AutoCleanupPlannerError.invalidRetentionDays(rule.retentionDays)
        }
        if rule.policy == .sizeLimit,
           !(AutoCleanupRule.minimumSizeLimitBytes...AutoCleanupRule.maximumSizeLimitBytes)
            .contains(rule.sizeLimitBytes) {
            throw AutoCleanupPlannerError.invalidSizeLimit(rule.sizeLimitBytes)
        }
        guard rule.isSafetyAuthorized else {
            throw AutoCleanupPlannerError.regenerableConfirmationRequired(rule.directory)
        }

        return try await Task.detached(priority: .utility) {
            // Browsers may add/remove cache entries while the task is scanned.
            // Retry the whole snapshot; never execute a partially scanned plan.
            for attempt in 0..<3 {
                try Task.checkCancellation()
                do {
                    return try makePlan(for: rule, protecting: protectedDirectories, now: Date())
                } catch AutoCleanupPlannerError.rootChanged where attempt < 2 {
                    continue
                } catch AutoCleanupPlannerError.scanFailed where attempt < 2 {
                    continue
                }
            }
            throw AutoCleanupPlannerError.scanFailed(rule.directory)
        }.value
    }

    private static func makePlan(for rule: AutoCleanupRule,
                                 protecting protectedDirectories: [String],
                                 now: Date) throws -> AutoCleanupPlan {
        let directories = rule.directories
        // Cache roots in one task must be disjoint: overlapping roots would
        // count data twice and could move another root with its parent.
        for (index, directory) in directories.enumerated() {
            let path = URL(fileURLWithPath: directory).standardizedFileURL.path
            for other in directories.dropFirst(index + 1) {
                let otherPath = URL(fileURLWithPath: other).standardizedFileURL.path
                if path == otherPath || path.hasPrefix(otherPath + "/") || otherPath.hasPrefix(path + "/") {
                    throw AutoCleanupPlannerError.protectedRoot(otherPath)
                }
            }
        }
        var eligibleItems: [AutoCleanupCandidate] = []
        var totalBytes: UInt64 = 0
        for root in rule.roots {
            try Task.checkCancellation()
            let scan = try scanRoot(root, protecting: protectedDirectories)
            totalBytes = try adding(totalBytes, scan.totalBytes, path: root.directory)
            eligibleItems.append(contentsOf: scan.eligibleItems)
        }
        for root in rule.roots {
            guard AutoCleanupRule.rootIdentity(at: root.directory) == root.authorizedIdentity else {
                throw AutoCleanupPlannerError.rootAuthorizationChanged(root.directory)
            }
        }

        let candidates: [AutoCleanupCandidate]
        switch rule.policy {
        case .sizeLimit:
            candidates = sizeCandidates(from: eligibleItems,
                                        totalBytes: totalBytes,
                                        limit: rule.sizeLimitBytes,
                                        now: now)
        case .retentionDays:
            guard let cutoff = Calendar.current.date(byAdding: .day,
                                                     value: -rule.retentionDays,
                                                     to: now) else {
                throw AutoCleanupPlannerError.invalidRetentionDays(rule.retentionDays)
            }
            candidates = sortedByAge(eligibleItems.filter { $0.modifiedAt < cutoff })
        }

        var remainingBytes = totalBytes
        for candidate in candidates {
            remainingBytes = candidate.bytes >= remainingBytes
                ? 0
                : remainingBytes - candidate.bytes
        }
        return AutoCleanupPlan(root: rule.directory,
                               totalBytes: totalBytes,
                               candidates: candidates,
                               remainingBytes: remainingBytes,
                               reclaimableBytes: totalBytes - remainingBytes)
    }

    private static func scanRoot(_ authorizedRoot: AutoCleanupRoot,
                                 protecting protectedDirectories: [String]) throws
        -> (totalBytes: UInt64, eligibleItems: [AutoCleanupCandidate]) {
        let root = try validateRoot(URL(fileURLWithPath: authorizedRoot.directory, isDirectory: true))
        guard let authorizedIdentity = authorizedRoot.authorizedIdentity,
              AutoCleanupRule.rootIdentity(at: root.path) == authorizedIdentity else {
            throw AutoCleanupPlannerError.rootAuthorizationChanged(root.path)
        }
        guard !isProtectedAutomationContent(root) else {
            throw AutoCleanupPlannerError.protectedContent(root.path)
        }
        let initialIdentity = try identity(of: root)
        let fileManager = FileManager()
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(at: root,
                                                           includingPropertiesForKeys: nil,
                                                           options: [])
                .sorted { $0.path < $1.path }
        } catch {
            throw AutoCleanupPlannerError.scanFailed(root.path)
        }

        var items: [AutoCleanupCandidate] = []
        var totalBytes: UInt64 = 0
        for child in children {
            try Task.checkCancellation()
            guard let item = try measureItem(at: child, fileManager: fileManager) else {
                continue
            }
            totalBytes = try adding(totalBytes, item.bytes, path: child.path)
            items.append(item)
        }

        if let protected = items.first(where: { !$0.automaticEligible }) {
            throw AutoCleanupPlannerError.protectedContent(protected.path)
        }

        guard try identity(of: root) == initialIdentity else {
            throw AutoCleanupPlannerError.rootChanged(root.path)
        }

        // 若另一个规则管理当前第一层项或其后代，父规则不能把它连根移走。
        let protectedRoots = protectedDirectories.compactMap { path -> String? in
            guard (path as NSString).isAbsolutePath else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        }
        let eligibleItems = items.filter { item in
            item.automaticEligible && !protectedRoots.contains { protectedRoot in
                protectedRoot == item.path || protectedRoot.hasPrefix(item.path + "/")
            }
        }

        return (totalBytes, eligibleItems)
    }

    private static func sizeCandidates(from items: [AutoCleanupCandidate],
                                       totalBytes: UInt64,
                                       limit: UInt64,
                                       now: Date) -> [AutoCleanupCandidate] {
        guard totalBytes > limit else { return [] }

        let safeBefore = now.addingTimeInterval(-recentWriteProtection)
        let eligible = sortedByAge(items.filter { $0.modifiedAt <= safeBefore })
        var remainingBytes = totalBytes
        var selected: [AutoCleanupCandidate] = []
        for item in eligible where remainingBytes > limit {
            selected.append(item)
            remainingBytes = item.bytes >= remainingBytes ? 0 : remainingBytes - item.bytes
        }
        return selected
    }

    /// 返回 nil 表示顶层项本身是软链接；内部软链接会被跳过且不会下钻。
    private static func measureItem(at url: URL,
                                    fileManager: FileManager) throws -> AutoCleanupCandidate? {
        let rootMetadata = try metadata(at: url)
        let rootKind = rootMetadata.st_mode & mode_t(S_IFMT)
        guard rootKind != mode_t(S_IFLNK) else { return nil }

        var bytes = try allocatedBytes(of: rootMetadata, path: url.path)
        var modifiedAt = modificationDate(of: rootMetadata)
        var containsProtectedContent = isProtectedAutomationContent(url)
        guard rootKind == mode_t(S_IFDIR) else {
            return AutoCleanupCandidate(path: url.path,
                                        bytes: bytes,
                                        modifiedAt: modifiedAt,
                                        identity: deletionIdentity(of: rootMetadata),
                                        risk: containsProtectedContent ? .protected : .safe,
                                        disposal: containsProtectedContent ? .none : .permanentDelete)
        }

        var failedPath: String?
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { failedURL, _ in
                failedPath = failedURL.path
                return false
            }
        ) else {
            throw AutoCleanupPlannerError.scanFailed(url.path)
        }

        while let descendant = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let childMetadata = try metadata(at: descendant)
            let childKind = childMetadata.st_mode & mode_t(S_IFMT)
            if childKind == mode_t(S_IFLNK) {
                enumerator.skipDescendants()
                continue
            }
            if isProtectedAutomationContent(descendant) {
                containsProtectedContent = true
            }
            bytes = try adding(bytes,
                               allocatedBytes(of: childMetadata, path: descendant.path),
                               path: descendant.path)
            modifiedAt = max(modifiedAt, modificationDate(of: childMetadata))
        }
        if let failedPath {
            throw AutoCleanupPlannerError.scanFailed(failedPath)
        }

        return AutoCleanupCandidate(path: url.path,
                                    bytes: bytes,
                                    modifiedAt: modifiedAt,
                                    identity: deletionIdentity(of: rootMetadata),
                                    risk: containsProtectedContent ? .protected : .safe,
                                    disposal: containsProtectedContent ? .none : .permanentDelete)
    }

    private static func isProtectedAutomationContent(_ url: URL) -> Bool {
        if CleanupRiskPolicy.isForbiddenAutomationPath(url.path)
            || CleanupRiskPolicy.isSensitiveAutomationPath(url.path) { return true }
        let lowerPath = url.standardizedFileURL.path.lowercased()
        if protectedPathFragments.contains(where: {
            lowerPath.hasSuffix($0) || lowerPath.contains($0 + "/")
        }) {
            return true
        }
        let name = url.lastPathComponent.lowercased()
        if protectedDirectoryNames.contains(name) || protectedFileNames.contains(name) {
            return true
        }
        if name == ".env" || name.hasPrefix(".env.") { return true }
        return protectedExtensions.contains(url.pathExtension.lowercased())
    }

    private static func metadata(at url: URL) throws -> stat {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0 else {
            throw AutoCleanupPlannerError.scanFailed(url.path)
        }
        return metadata
    }

    private static func allocatedBytes(of metadata: stat, path: String) throws -> UInt64 {
        guard metadata.st_blocks >= 0 else {
            throw AutoCleanupPlannerError.sizeOverflow(path)
        }
        let (bytes, overflow) = UInt64(metadata.st_blocks).multipliedReportingOverflow(by: 512)
        guard !overflow else {
            throw AutoCleanupPlannerError.sizeOverflow(path)
        }
        return bytes
    }

    private static func modificationDate(of metadata: stat) -> Date {
        let seconds = TimeInterval(metadata.st_mtimespec.tv_sec)
        let nanoseconds = TimeInterval(metadata.st_mtimespec.tv_nsec) / 1_000_000_000
        return Date(timeIntervalSince1970: seconds + nanoseconds)
    }

    /// 与 Mole 最终删除入口的 `stat -f%d:%i:%m` 协议保持一致。
    private static func deletionIdentity(of metadata: stat) -> String {
        "\(metadata.st_dev):\(metadata.st_ino):\(metadata.st_mtimespec.tv_sec)"
    }

    private static func adding(_ lhs: UInt64, _ rhs: UInt64, path: String) throws -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw AutoCleanupPlannerError.sizeOverflow(path)
        }
        return result
    }

    private static func sortedByAge(_ items: [AutoCleanupCandidate]) -> [AutoCleanupCandidate] {
        items.sorted {
            if $0.modifiedAt == $1.modifiedAt { return $0.path < $1.path }
            return $0.modifiedAt < $1.modifiedAt
        }
    }

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
    }

    private static func identity(of url: URL) throws -> FileIdentity {
        let value = try metadata(at: url)
        guard value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw AutoCleanupPlannerError.rootChanged(url.path)
        }
        return FileIdentity(device: UInt64(value.st_dev),
                            inode: UInt64(value.st_ino),
                            modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
                            modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec))
    }
}
