import AppKit
import Darwin
import Foundation

/// 系统优化：Mole `mo optimize` 的完整任务表。每项先做只读预检
/// （是否需要、将改动什么），用户勾选后才执行；执行时只作用于预检记录
/// 下来的证据（路径 + 身份、bundle ID、偏好键），不会顺带处理新出现的项。
extension NativeCore {
    typealias OptimizePreview = OptimizeTask.Preview

    static let sqliteMaxBytes: UInt64 = 100 * 1024 * 1024
    static let notificationThresholdBytes: UInt64 = 50 * 1024 * 1024
    static let knowledgeThresholdBytes: UInt64 = 100 * 1024 * 1024
    /// Cocoa 参考时间（2001-01-01）相对 Unix 纪元的秒数。
    static let cocoaEpochOffset: Double = 978_307_200

    func initialOptimizeTasks() -> [OptimizeTask] {
        [
            OptimizeTask(id: "dns", title: "DNS cache",
                         detail: "Flush the resolver cache and restart mDNSResponder.", kind: .admin),
            OptimizeTask(id: "quicklook", title: "Quick Look cache", detail: "Refresh Quick Look thumbnails."),
            OptimizeTask(id: "iconservices", title: "Icon services", detail: "Restart the Finder icon service."),
            OptimizeTask(id: "launchservices", title: "LaunchServices",
                         detail: "Rebuild app and document associations."),
            OptimizeTask(id: "saved-state", title: "Saved application state",
                         detail: "Move saved window states older than 30 days to Trash."),
            OptimizeTask(id: "broken-configs", title: "Broken preferences",
                         detail: "Move corrupt third-party preference files to Trash; Apple and login settings are never touched."),
            OptimizeTask(id: "shared-file-list", title: "Shared file lists",
                         detail: "Move corrupt Finder favorites and recent-item lists to Trash; recent documents are kept."),
            OptimizeTask(id: "finder-dsstore", title: "Network .DS_Store",
                         detail: "Stop Finder writing .DS_Store on network and USB volumes."),
            OptimizeTask(id: "legacy-overrides", title: "Legacy overrides",
                         detail: "Remove old App Nap and disk-image verification overrides."),
            OptimizeTask(id: "spotlight-orphans", title: "Spotlight orphan rules",
                         detail: "Drop Spotlight search rules left behind by uninstalled apps."),
            OptimizeTask(id: "sqlite-vacuum", title: "SQLite databases",
                         detail: "Compact Mail, Messages and Safari databases after an integrity check."),
            OptimizeTask(id: "network-stack", title: "Network stack",
                         detail: "Flush routes and ARP only when the network is unhealthy and no VPN is active.",
                         kind: .admin),
            OptimizeTask(id: "periodic", title: "Periodic maintenance",
                         detail: "Run daily, weekly and monthly scripts when they are more than 7 days old.",
                         kind: .admin),
            OptimizeTask(id: "permissions", title: "User permissions",
                         detail: "Reset home directory permissions only when ownership or write access is wrong.",
                         kind: .admin),
            OptimizeTask(id: "spotlight", title: "Spotlight index",
                         detail: "Rebuild the index only when searches are measurably slow on AC power.",
                         kind: .admin, defaultOn: false),
            OptimizeTask(id: "disk-verify", title: "Disk health",
                         detail: "Verify the startup volume read-only; may take minutes.",
                         kind: .admin, defaultOn: false),
            OptimizeTask(id: "quarantine", title: "Quarantine history",
                         detail: "Clear the download history; files and Gatekeeper checks are unaffected.",
                         defaultOn: false),
            OptimizeTask(id: "notifications", title: "Notification history",
                         detail: "Delete delivered notifications older than 30 days when the database exceeds 50 MB.",
                         defaultOn: false),
            OptimizeTask(id: "coreduet", title: "Usage history",
                         detail: "Delete Screen Time usage records older than 90 days when the database exceeds 100 MB.",
                         defaultOn: false),
            OptimizeTask(id: "launch-agents", title: "Launch agents",
                         detail: "Report user launch agents whose program is missing; nothing is removed.",
                         kind: .report),
            OptimizeTask(id: "login-items", title: "Login items",
                         detail: "Review login items in System Settings.", kind: .report)
        ]
    }

    // MARK: Inspect

    func inspectOptimize(tasks: [OptimizeTask],
                         homeDirectory: String = NSHomeDirectory()) async -> [OptimizeTask] {
        await Task.detached(priority: .utility) { [self] in
            tasks.map { task in
                var task = task
                task.state = .pending
                task.message = ""
                task.preview = isOptimizeWhitelisted(task, homeDirectory: homeDirectory)
                    ? .init(need: .blocked, summary: "Skipped by whitelist.")
                    : inspectOptimizeTask(task.id, homeDirectory: homeDirectory)
                task.selected = task.selectable && task.defaultOn
                return task
            }
        }.value
    }

    func inspectOptimizeTask(_ id: String, homeDirectory home: String) -> OptimizePreview {
        switch id {
        case "dns":
            return .init(need: .needed, summary: "Flush DNS caches and restart mDNSResponder.")
        case "quicklook":
            return .init(need: .needed, summary: "Reset the Quick Look thumbnail cache.")
        case "iconservices":
            return .init(need: .needed, summary: "Restart iconservicesagent so Finder redraws icons.")
        case "launchservices":
            let tool = Self.lsregister
            return fileManager.isExecutableFile(atPath: tool)
                ? .init(need: .needed, summary: "Garbage-collect and re-register app associations.")
                : .init(need: .unavailable, summary: "lsregister is unavailable on this macOS version.")
        case "saved-state":
            let targets = oldSavedStates(homeDirectory: home)
            return targets.isEmpty
                ? .init(need: .clean, summary: "No saved states older than 30 days.")
                : .init(need: .needed, summary: "\(targets.count) saved state(s) older than 30 days.",
                        items: targets.map { URL(fileURLWithPath: $0.path).lastPathComponent },
                        plan: targets.map(Self.planEntry))
        case "broken-configs":
            let result = repairBrokenPreferences(homeDirectory: home, dryRun: true)
            let targets = result.corrupt.compactMap { path in
                DeletionPlan.identity(at: path).map { (path: path, identity: $0) }
            }
            if targets.isEmpty {
                return .init(need: .clean, summary: result.partial
                    ? "No corrupt preference file found before the time limit."
                    : "All third-party preference files are valid.")
            }
            return .init(need: .needed, summary: "\(targets.count) corrupt preference file(s).",
                         items: targets.map { URL(fileURLWithPath: $0.path).lastPathComponent },
                         plan: targets.map(Self.planEntry))
        case "shared-file-list":
            guard let targets = corruptSharedFileLists(homeDirectory: home) else {
                return .init(need: .unavailable, summary: "Could not inspect shared file lists.")
            }
            return targets.isEmpty
                ? .init(need: .clean, summary: "Shared file lists are healthy.")
                : .init(need: .needed, summary: "\(targets.count) corrupt shared file list(s).",
                        items: targets.map { URL(fileURLWithPath: $0.path).lastPathComponent },
                        plan: targets.map(Self.planEntry))
        case "finder-dsstore":
            let missing = Self.dsStoreKeys.filter { key in
                let value = runCommandOutput("/usr/bin/defaults", ["read", "com.apple.desktopservices", key])
                return !Self.isTruthy(value)
            }
            return missing.isEmpty
                ? .init(need: .clean, summary: "Finder already skips .DS_Store on network and USB volumes.")
                : .init(need: .needed, summary: "Set \(missing.joined(separator: ", ")).",
                        items: missing, plan: missing)
        case "legacy-overrides":
            let found = Self.legacyOverrides.filter { domain, key in
                Self.isTruthy(runCommandOutput("/usr/bin/defaults", ["read", domain, key]))
            }
            return found.isEmpty
                ? .init(need: .clean, summary: "No legacy overrides found.")
                : .init(need: .needed, summary: "\(found.count) legacy override(s) set.",
                        items: found.map { "\($0.0) \($0.1)" },
                        plan: found.map { "\($0.0)\t\($0.1)" })
        case "spotlight-orphans":
            let orphans = orphanSpotlightRules()
            return orphans.isEmpty
                ? .init(need: .clean, summary: "Spotlight search rules are clean.")
                : .init(need: .needed, summary: "\(orphans.count) rule(s) for uninstalled apps.",
                        items: orphans, plan: orphans)
        case "sqlite-vacuum":
            return inspectSQLiteVacuum(homeDirectory: home)
        case "network-stack":
            return inspectNetworkStack()
        case "periodic":
            guard fileManager.isExecutableFile(atPath: "/usr/sbin/periodic") else {
                return .init(need: .unavailable, summary: "periodic is not available on this macOS version.")
            }
            let log = "/var/log/daily.out"
            if let modified = (try? fileManager.attributesOfItem(atPath: log))?[.modificationDate] as? Date {
                let days = Int(Date().timeIntervalSince(modified) / 86_400)
                if days < 7 { return .init(need: .clean, summary: "Last ran \(days) day(s) ago.") }
                return .init(need: .needed, summary: "Last ran \(days) day(s) ago.")
            }
            return .init(need: .needed, summary: "No record of a previous run.")
        case "permissions":
            let problems = permissionProblems(homeDirectory: home)
            return problems.isEmpty
                ? .init(need: .clean, summary: "Home directory ownership and write access are correct.")
                : .init(need: .needed, summary: "Permission problems found.", items: problems)
        case "spotlight":
            return inspectSpotlight()
        case "disk-verify":
            return .init(need: .needed,
                         summary: "Read-only check of the startup volume, bounded to 10 minutes.")
        case "quarantine":
            let database = home + "/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"
            guard fileManager.fileExists(atPath: database) else {
                return .init(need: .clean, summary: "No quarantine database found.")
            }
            guard let raw = sqlite(database, "SELECT COUNT(*) FROM LSQuarantineEvent;", readOnly: true),
                  let count = Int(raw) else {
                return .init(need: .unavailable, summary: "Could not read the quarantine database.")
            }
            return count == 0
                ? .init(need: .clean, summary: "Quarantine history is empty.")
                : .init(need: .needed, summary: "\(count) download record(s).")
        case "notifications":
            guard let database = notificationDatabase(homeDirectory: home) else {
                return .init(need: .unavailable, summary: "Notification Center database is unavailable.")
            }
            let bytes = sqliteFamilyBytes(database)
            return bytes < Self.notificationThresholdBytes
                ? .init(need: .clean, summary: "Database is \(Self.byteText(bytes)); below 50 MB.")
                : .init(need: .needed, summary: "Database is \(Self.byteText(bytes)).", plan: [database])
        case "coreduet":
            let database = home + "/Library/Application Support/Knowledge/knowledgeC.db"
            guard fileManager.fileExists(atPath: database) else {
                return .init(need: .clean, summary: "Usage database not found.")
            }
            let bytes = sqliteFamilyBytes(database)
            return bytes < Self.knowledgeThresholdBytes
                ? .init(need: .clean, summary: "Database is \(Self.byteText(bytes)); below 100 MB.")
                : .init(need: .needed, summary: "Database is \(Self.byteText(bytes)).", plan: [database])
        case "launch-agents":
            let report = brokenLaunchAgents(homeDirectory: home)
            if report.broken.isEmpty {
                return .init(need: .clean, summary: report.scanned == 0
                    ? "No user launch agents installed."
                    : "All \(report.scanned) user launch agent(s) point to existing programs.")
            }
            return .init(need: .blocked,
                         summary: "\(report.broken.count) agent(s) point at a missing program; left in place.",
                         items: report.broken.map {
                             "\(URL(fileURLWithPath: $0.plist).lastPathComponent) → \($0.program)"
                         },
                         plan: report.broken.map(\.plist))
        case "login-items":
            return .init(need: .blocked,
                         summary: "macOS only exposes login items to System Settings; review them there.")
        default:
            return .init(need: .unavailable, summary: "Unknown task.")
        }
    }

    // MARK: Apply

    /// 执行勾选的非提权任务；`admin` 任务保持待定，由调用方交给提权桥接。
    func runOptimize(tasks: [OptimizeTask],
                     homeDirectory: String = NSHomeDirectory()) async -> OptimizeReport {
        await Task.detached(priority: .utility) { [self] in
            let output = tasks.map { task -> OptimizeTask in
                var task = task
                guard task.selected, task.selectable, task.kind == .action,
                      let preview = task.preview else { return task }
                if isOptimizeWhitelisted(task, homeDirectory: homeDirectory) {
                    task.state = .unchanged
                    task.message = "Skipped by whitelist."
                    return task
                }
                let result = applyOptimizeTask(task.id, preview: preview, homeDirectory: homeDirectory)
                task.state = result.state
                task.message = result.message
                return task
            }
            return OptimizeReport(tasks: output, finishedAt: Date())
        }.value
    }

    func applyOptimizeTask(_ id: String, preview: OptimizePreview,
                           homeDirectory home: String) -> (state: OptimizeTask.State, message: String) {
        switch id {
        case "quicklook":
            let ok = runCommand("/usr/bin/qlmanage", ["-r", "cache"])
            return ok ? (.applied, "Quick Look cache refreshed.") : (.failed, "Quick Look refresh failed.")
        case "iconservices":
            let ok = runCommand("/usr/bin/killall", ["-u", NSUserName(), "iconservicesagent"])
            return ok ? (.applied, "Finder icon service restarted.")
                : (.unchanged, "Icon service was not running; no change was needed.")
        case "launchservices":
            // `-kill` 会丢掉用户手动注册的应用，与 Mole 一样只做 gc + 重注册。
            _ = runCommand(Self.lsregister, ["-gc"])
            let full = runCommand(Self.lsregister,
                                  ["-r", "-f", "-domain", "local", "-domain", "user", "-domain", "system"])
            let partial = full || runCommand(Self.lsregister, ["-r", "-f", "-domain", "local", "-domain", "user"])
            if full { return (.applied, "LaunchServices database rebuilt.") }
            return partial ? (.applied, "LaunchServices rebuilt for user and local domains.")
                : (.failed, "LaunchServices rebuild failed.")
        case "saved-state":
            let root = home + "/Library/Saved Application State"
            let fresh = Set(oldSavedStates(homeDirectory: home).map(Self.planEntry))
            return trashPlanned(preview.plan.filter(fresh.contains), parent: root, noun: "saved state(s)")
        case "broken-configs":
            let targets = preview.plan.filter { entry in
                Self.planPath(entry).map { !runCommand("/usr/bin/plutil", ["-lint", "-s", $0]) } ?? false
            }
            return trashPlanned(targets, parent: home + "/Library/Preferences", noun: "corrupt preference file(s)")
        case "shared-file-list":
            let fresh = Set((corruptSharedFileLists(homeDirectory: home) ?? []).map(Self.planEntry))
            let result = trashPlanned(preview.plan.filter(fresh.contains),
                                      parent: home + "/Library/Application Support/com.apple.sharedfilelist",
                                      noun: "corrupt shared file list(s)")
            if result.state == .applied { _ = runCommand("/usr/bin/killall", ["sharedfilelistd"]) }
            return result
        case "finder-dsstore":
            let keys = preview.plan.filter(Self.dsStoreKeys.contains)
            let ok = keys.allSatisfy {
                runCommand("/usr/bin/defaults", ["write", "com.apple.desktopservices", $0, "-bool", "TRUE"])
            }
            return ok ? (.applied, "Finder will stop writing .DS_Store on network and USB volumes.")
                : (.failed, "Could not update Finder metadata preferences.")
        case "legacy-overrides":
            let allowed = Set(Self.legacyOverrides.map { "\($0.0)\t\($0.1)" })
            var removed = 0
            var failed = 0
            for entry in preview.plan where allowed.contains(entry) {
                let parts = entry.split(separator: "\t").map(String.init)
                guard Self.isTruthy(runCommandOutput("/usr/bin/defaults", ["read", parts[0], parts[1]])) else {
                    continue
                }
                if runCommand("/usr/bin/defaults", ["delete", parts[0], parts[1]]) { removed += 1 } else { failed += 1 }
            }
            if failed > 0 { return (.failed, "Some legacy overrides could not be removed.") }
            return removed > 0 ? (.applied, "Removed \(removed) legacy override(s).")
                : (.unchanged, "No legacy overrides found.")
        case "spotlight-orphans":
            return pruneSpotlightRules(preview.plan)
        case "sqlite-vacuum":
            return vacuumDatabases(preview.plan, homeDirectory: home)
        case "quarantine":
            let result = clearQuarantineEvents(homeDirectory: home)
            return (result.state, result.message)
        case "notifications":
            return trimNotifications(preview.plan, homeDirectory: home)
        case "coreduet":
            return trimKnowledge(preview.plan, homeDirectory: home)
        default:
            return (.unavailable, "This task is not executed by the optimizer.")
        }
    }

    // MARK: Administrator batch

    static let adminTaskIDs: Set<String> = ["dns", "network-stack", "periodic", "permissions",
                                            "spotlight", "disk-verify"]

    func selectedAdminTasks(_ tasks: [OptimizeTask]) -> [String] {
        tasks.filter { $0.selected && $0.selectable && $0.kind == .admin && Self.adminTaskIDs.contains($0.id) }
            .map(\.id)
    }

    /// 解析提权桥接输出：每行 `id<TAB>state<TAB>message`；未回报的任务视为失败。
    static func mergeAdminResults(_ output: String, succeeded: Bool,
                                  requested: [String], into tasks: [OptimizeTask]) -> [OptimizeTask] {
        var results: [String: (OptimizeTask.State, String)] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard fields.count == 3, requested.contains(fields[0]),
                  let state = OptimizeTask.State(rawValue: fields[1]), state != .pending else { continue }
            results[fields[0]] = (state, fields[2])
        }
        return tasks.map { task in
            guard requested.contains(task.id) else { return task }
            var task = task
            if let (state, message) = results[task.id] {
                task.state = state
                task.message = message
            } else {
                task.state = succeeded ? .failed : .unavailable
                task.message = succeeded
                    ? "No result was reported for this task."
                    : "Administrator access was not granted."
            }
            return task
        }
    }

    // MARK: Evidence helpers

    static let lsregister =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    static let dsStoreKeys = ["DSDontWriteNetworkStores", "DSDontWriteUSBStores"]
    static let legacyOverrides: [(String, String)] = [
        ("-g", "NSAppSleepDisabled"),
        ("com.apple.frameworks.diskimages", "skip-verify"),
        ("com.apple.frameworks.diskimages", "skip-verify-locked"),
        ("com.apple.frameworks.diskimages", "skip-verify-remote")
    ]

    static func planEntry(_ target: (path: String, identity: String)) -> String {
        target.identity + "\t" + target.path
    }

    static func planPath(_ entry: String) -> String? {
        entry.split(separator: "\t", maxSplits: 1).last.map(String.init)
    }

    static func isTruthy(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["1", "true", "yes"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func byteText(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func trashPlanned(_ plan: [String], parent: String,
                              noun: String) -> (state: OptimizeTask.State, message: String) {
        let targets = plan.compactMap { entry -> (path: String, identity: String)? in
            let parts = entry.split(separator: "\t", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (path: parts[1], identity: parts[0]) : nil
        }
        guard !targets.isEmpty else { return (.unchanged, "Nothing left to change since the preview.") }
        let result = trashOptimizeTargets(targets, parent: parent)
        if result.failed > 0 {
            return (result.removed > 0 ? .applied : .failed,
                    "Moved \(result.removed) \(noun) to Trash; \(result.failed) changed or could not be moved.")
        }
        return (.applied, "Moved \(result.removed) \(noun) to Trash.")
    }

    func oldSavedStates(homeDirectory home: String) -> [(path: String, identity: String)] {
        let root = URL(fileURLWithPath: home + "/Library/Saved Application State", isDirectory: true)
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        let whitelist = loadWhitelist(homeDirectory: home)
        return directChildren(of: root).sorted { $0.path < $1.path }.compactMap { item in
            guard !isSymlink(item), !matchesWhitelist(item.path, entries: whitelist),
                  let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?
                      .contentModificationDate, date < cutoff,
                  let identity = DeletionPlan.identity(at: item.path) else { return nil }
            return (item.path, identity)
        }
    }

    /// Mole `opt_shared_file_list_repair`：plutil 拒绝的 .sfl2/.sfl3，
    /// 最近文档列表属于用户数据，永远排除。nil 表示无法判定。
    func corruptSharedFileLists(homeDirectory home: String) -> [(path: String, identity: String)]? {
        let root = URL(fileURLWithPath: home + "/Library/Application Support/com.apple.sharedfilelist",
                       isDirectory: true)
        guard isDirectory(root), !isSymlink(root) else { return [] }
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return nil }
        let deadline = Date().addingTimeInterval(10)
        var found: [(path: String, identity: String)] = []
        for case let url as URL in enumerator {
            guard Date() < deadline else { return nil }
            if isSymlink(url) { enumerator.skipDescendants(); continue }
            guard ["sfl2", "sfl3"].contains(url.pathExtension),
                  !url.path.contains("ApplicationRecentDocuments"),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  !runCommand("/usr/bin/plutil", ["-lint", "-s", url.path]),
                  let identity = DeletionPlan.identity(at: url.path) else { continue }
            found.append((url.path, identity))
        }
        return found.sorted { $0.path < $1.path }
    }

    // MARK: Spotlight rules

    func orphanSpotlightRules() -> [String] {
        rawSpotlightRules().filter { rule in
            guard !rule.hasPrefix("System."), !rule.hasPrefix("com.apple."),
                  Self.isReverseDNS(rule) else { return false }
            return bundleIsInstalled(rule) == false
        }
    }

    private func rawSpotlightRules() -> [String] {
        let defaults = UserDefaults(suiteName: "com.apple.spotlight")
        return defaults?.array(forKey: "EnabledPreferenceRules")?.compactMap { $0 as? String } ?? []
    }

    /// true 已安装；false 两路证据都证明不存在；nil 无法判定（按已安装处理）。
    private func bundleIsInstalled(_ bundleID: String) -> Bool? {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil { return true }
        guard let output = SystemMetrics.commandOutput(
            "/usr/bin/mdfind", arguments: ["kMDItemCFBundleIdentifier == '\(bundleID)'"], timeoutSeconds: 5)
        else { return nil }
        return output.split(whereSeparator: \.isNewline).isEmpty ? false : true
    }

    static func isReverseDNS(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
    }

    private func pruneSpotlightRules(_ plan: [String]) -> (state: OptimizeTask.State, message: String) {
        let current = rawSpotlightRules()
        let fresh = Set(orphanSpotlightRules())
        let remove = Set(plan).intersection(fresh)
        guard !remove.isEmpty else { return (.unchanged, "Spotlight search rules are clean.") }
        let keep = current.filter { !remove.contains($0) }
        // 经 cfprefsd 写回整个数组，避免直接改 plist 被缓存覆盖。
        let ok = keep.isEmpty
            ? runCommand("/usr/bin/defaults", ["delete", "com.apple.spotlight", "EnabledPreferenceRules"])
            : runCommand("/usr/bin/defaults",
                         ["write", "com.apple.spotlight", "EnabledPreferenceRules", "-array"] + keep)
        return ok ? (.applied, "Removed \(remove.count) orphan Spotlight rule(s).")
            : (.failed, "Could not update Spotlight search rules.")
    }

    // MARK: SQLite

    static let vacuumOwners: [(bundle: String, name: String)] = [
        ("com.apple.mail", "Mail"), ("com.apple.Safari", "Safari"), ("com.apple.MobileSMS", "Messages")
    ]

    func vacuumCandidates(homeDirectory home: String) -> [String] {
        var paths: [String] = []
        let mail = URL(fileURLWithPath: home + "/Library/Mail", isDirectory: true)
        for version in directChildren(of: mail).sorted(by: { $0.path < $1.path })
        where version.lastPathComponent.hasPrefix("V") && !isSymlink(version) {
            paths.append(version.path + "/MailData/Envelope Index")
        }
        paths += [home + "/Library/Messages/chat.db",
                  home + "/Library/Safari/History.db",
                  home + "/Library/Safari/TopSites.db"]
        return paths.filter { path in
            var metadata = stat()
            return Darwin.lstat(path, &metadata) == 0 && (metadata.st_mode & S_IFMT) == S_IFREG
                && Self.hasSQLiteHeader(path)
        }
    }

    static func hasSQLiteHeader(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: 16)) ?? Data()
        return header == Data("SQLite format 3\u{0}".utf8)
    }

    private func runningVacuumOwners() -> [String] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return Self.vacuumOwners.filter { running.contains($0.bundle) }.map(\.name)
    }

    private func inspectSQLiteVacuum(homeDirectory home: String) -> OptimizePreview {
        guard fileManager.isExecutableFile(atPath: "/usr/bin/sqlite3") else {
            return .init(need: .unavailable, summary: "sqlite3 is unavailable.")
        }
        var items: [String] = []
        var plan: [String] = []
        for path in vacuumCandidates(homeDirectory: home) {
            let name = path.replacingOccurrences(of: home, with: "~")
            let bytes = fileSize(URL(fileURLWithPath: path))
            if bytes > Self.sqliteMaxBytes {
                items.append("\(name) · \(Self.byteText(bytes)) · over the 100 MB limit, skipped")
                continue
            }
            guard let raw = sqlite(path, "PRAGMA page_count; PRAGMA freelist_count;", readOnly: true) else {
                items.append("\(name) · could not be read")
                continue
            }
            let numbers = raw.split(whereSeparator: \.isNewline).compactMap { Int($0) }
            guard numbers.count == 2, numbers[0] > 0 else { continue }
            let percent = numbers[1] * 100 / numbers[0]
            guard percent >= 5 else { continue }
            items.append("\(name) · \(Self.byteText(bytes)) · \(percent)% free pages")
            plan.append(path)
        }
        guard !plan.isEmpty else {
            return .init(need: .clean, summary: "Databases are already compact.", items: items)
        }
        let busy = runningVacuumOwners()
        if !busy.isEmpty {
            return .init(need: .blocked, summary: "Quit \(busy.joined(separator: ", ")) first.", items: items)
        }
        return .init(need: .needed, summary: "\(plan.count) database(s) can be compacted.", items: items, plan: plan)
    }

    private func vacuumDatabases(_ plan: [String],
                                 homeDirectory home: String) -> (state: OptimizeTask.State, message: String) {
        let busy = runningVacuumOwners()
        guard busy.isEmpty else { return (.unchanged, "Skipped: \(busy.joined(separator: ", ")) is running.") }
        let allowed = Set(vacuumCandidates(homeDirectory: home))
        var vacuumed = 0
        var failed = 0
        for path in plan where allowed.contains(path) {
            guard sqlite(path, "PRAGMA integrity_check;", readOnly: true, timeout: 30) == "ok",
                  sqlite(path, "VACUUM;", timeout: 120) != nil else {
                failed += 1
                continue
            }
            vacuumed += 1
        }
        if failed > 0 {
            return (vacuumed > 0 ? .applied : .failed,
                    "Compacted \(vacuumed) database(s); \(failed) failed the integrity check or were busy.")
        }
        return vacuumed > 0 ? (.applied, "Compacted \(vacuumed) database(s).")
            : (.unchanged, "Nothing left to compact.")
    }

    func sqlite(_ database: String, _ statement: String, readOnly: Bool = false,
                timeout: TimeInterval = 10) -> String? {
        let arguments = (readOnly ? ["-readonly"] : []) + [database, statement]
        return SystemMetrics.commandOutput("/usr/bin/sqlite3", arguments: arguments, timeoutSeconds: timeout)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func sqliteFamilyBytes(_ database: String) -> UInt64 {
        ["", "-wal", "-shm"].reduce(UInt64(0)) { total, suffix in
            total &+ fileSize(URL(fileURLWithPath: database + suffix))
        }
    }

    func notificationDatabase(homeDirectory home: String) -> String? {
        let group = home + "/Library/Group Containers/group.com.apple.usernoted/db2/db"
        if fileManager.fileExists(atPath: group) { return group }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_DIR, &buffer, buffer.count) > 0 else { return nil }
        let legacy = String(cString: buffer) + "com.apple.notificationcenter/db2/db"
        return fileManager.fileExists(atPath: legacy) ? legacy : nil
    }

    /// `delivered_date` 在不同系统版本里可能是 Unix 或 Cocoa 时间；按最大值判定，
    /// 否则用 Unix 截止点比较 Cocoa 时间会删除全部通知。
    static func notificationCutoff(maxDelivered: Double, now: Date = Date()) -> Double {
        let unixCutoff = now.addingTimeInterval(-30 * 86_400).timeIntervalSince1970
        return maxDelivered > 1_500_000_000 ? unixCutoff : unixCutoff - cocoaEpochOffset
    }

    private func trimNotifications(_ plan: [String],
                                   homeDirectory home: String) -> (state: OptimizeTask.State, message: String) {
        guard let database = notificationDatabase(homeDirectory: home), plan == [database] else {
            return (.unchanged, "Notification database changed since the preview.")
        }
        guard let raw = sqlite(database, "SELECT MAX(delivered_date) FROM record;", readOnly: true),
              let latest = Double(raw) else {
            return (.failed, "Could not read the notification database.")
        }
        let cutoff = Self.notificationCutoff(maxDelivered: latest)
        guard sqlite(database, "DELETE FROM record WHERE delivered_date < \(Int(cutoff)); VACUUM;",
                     timeout: 60) != nil else {
            return (.failed, "Notification database is busy or locked.")
        }
        _ = runCommand("/usr/bin/killall", ["NotificationCenter"])
        return (.applied, "Removed notifications older than 30 days (now \(Self.byteText(sqliteFamilyBytes(database)))).")
    }

    private func trimKnowledge(_ plan: [String],
                               homeDirectory home: String) -> (state: OptimizeTask.State, message: String) {
        let database = home + "/Library/Application Support/Knowledge/knowledgeC.db"
        guard plan == [database], fileManager.fileExists(atPath: database) else {
            return (.unchanged, "Usage database changed since the preview.")
        }
        let cutoff = Int(Date().addingTimeInterval(-90 * 86_400).timeIntervalSince1970 - Self.cocoaEpochOffset)
        guard sqlite(database, "DELETE FROM ZOBJECT WHERE ZCREATIONDATE < \(cutoff); VACUUM;",
                     timeout: 120) != nil else {
            return (.failed, "Usage database is busy or locked.")
        }
        return (.applied, "Removed usage records older than 90 days (now \(Self.byteText(sqliteFamilyBytes(database)))).")
    }

    // MARK: Network, Spotlight, permissions

    private func inspectNetworkStack() -> OptimizePreview {
        if let services = SystemMetrics.commandOutput("/usr/sbin/scutil", arguments: ["--nc", "list"],
                                                      timeoutSeconds: 5),
           services.contains("(Connected)") {
            return .init(need: .blocked, summary: "A VPN is connected; routes are left alone.")
        }
        let route = SystemMetrics.commandOutput("/sbin/route", arguments: ["-n", "get", "default"],
                                                timeoutSeconds: 5)
        if let route, route.split(whereSeparator: \.isNewline).contains(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("interface: utun")
        }) {
            return .init(need: .blocked, summary: "A VPN owns the default route; routes are left alone.")
        }
        let dns = SystemMetrics.commandOutput("/usr/bin/dscacheutil",
                                              arguments: ["-q", "host", "-a", "name", "example.com"],
                                              timeoutSeconds: 5)
        var problems: [String] = []
        if route == nil { problems.append("No default route") }
        if dns?.contains("ip_address") != true { problems.append("DNS lookup failed") }
        return problems.isEmpty
            ? .init(need: .clean, summary: "Routing and DNS are healthy.")
            : .init(need: .needed, summary: problems.joined(separator: "; ") + ".", items: problems)
    }

    private func inspectSpotlight() -> OptimizePreview {
        guard let status = SystemMetrics.commandOutput("/usr/bin/mdutil", arguments: ["-s", "/"],
                                                       timeoutSeconds: 8) else {
            return .init(need: .unavailable, summary: "Could not read the Spotlight index status.")
        }
        if status.localizedCaseInsensitiveContains("disabled") {
            return .init(need: .clean, summary: "Spotlight indexing is disabled.")
        }
        let power = SystemMetrics.commandOutput("/usr/bin/pmset", arguments: ["-g", "ps"], timeoutSeconds: 5) ?? ""
        guard power.contains("AC Power") else {
            return .init(need: .blocked, summary: "Connect to power to measure search speed.")
        }
        var slow = 0
        for _ in 0..<2 {
            let started = Date()
            let answered = SystemMetrics.commandOutput(
                "/usr/bin/mdfind", arguments: ["kMDItemFSName == 'Applications'"], timeoutSeconds: 10) != nil
            if !answered || Date().timeIntervalSince(started) > 3 { slow += 1 }
        }
        return slow >= 2
            ? .init(need: .needed, summary: "Searches are slow; rebuilding takes 1-2 hours in the background.")
            : .init(need: .clean, summary: "Spotlight answers quickly.")
    }

    func permissionProblems(homeDirectory home: String) -> [String] {
        var problems: [String] = []
        if let owner = (try? fileManager.attributesOfItem(atPath: home))?[.ownerAccountName] as? String,
           owner != NSUserName() {
            problems.append("Home is owned by \(owner)")
        }
        for path in [home, home + "/Library", home + "/Library/Preferences"]
        where fileManager.fileExists(atPath: path) && !fileManager.isWritableFile(atPath: path) {
            problems.append("\(path.replacingOccurrences(of: home, with: "~")) is not writable")
        }
        return problems
    }
}
