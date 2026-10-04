import AppKit
import Darwin
import Foundation

/// 系统数据库维护项：原系统优化页分流到硬盘清理的能力（DR-11）。
enum SystemMaintenanceItem: String, CaseIterable, Identifiable {
    case sqliteVacuum = "sqlite-vacuum"
    case notifications = "notifications"
    case coreduet = "coreduet"
    case quarantine = "quarantine"
    case savedState = "saved-state"

    var id: String { rawValue }
    var titleKey: String { "sysmaint.item.\(rawValue)" }
    var detailKey: String { "sysmaint.item.\(rawValue).detail" }
}

/// 维护行：清理页卡片展示与执行的最小载体（只读体检产出）。
struct SystemMaintenanceRow: Identifiable, Equatable {
    let item: SystemMaintenanceItem
    let preview: NativeCore.OptimizePreview
    var id: String { item.rawValue }
}

/// 原系统优化页的执行层保留：系统数据库维护（清理页卡片）与
/// QuickLook/图标/LaunchServices 服务修复（开发环境页按钮）。
/// DNS 与网络栈的管理员任务由 bridge/app_optimize_admin.sh 直接承载。
extension NativeCore {
    typealias OptimizePreview = OptimizeTask.Preview

    static let sqliteMaxBytes: UInt64 = 100 * 1024 * 1024
    static let notificationThresholdBytes: UInt64 = 50 * 1024 * 1024
    static let knowledgeThresholdBytes: UInt64 = 100 * 1024 * 1024

    /// Cocoa 参考时间（2001-01-01）相对 Unix 纪元的秒数。
    static let cocoaEpochOffset: Double = 978_307_200

    // MARK: 体检

    /// 体检系统数据库维护项（`only` 为空时体检全部），在后台线程执行。
    func inspectSystemMaintenance(homeDirectory home: String = NSHomeDirectory(),
                                  only: String? = nil) async -> [SystemMaintenanceRow] {
        await Task.detached(priority: .utility) { [self] in
            let ids = only.map { [$0] } ?? SystemMaintenanceItem.allCases.map(\.rawValue)
            return ids.compactMap { id -> SystemMaintenanceRow? in
                guard let item = SystemMaintenanceItem(rawValue: id) else { return nil }
                return SystemMaintenanceRow(item: item,
                                             preview: inspectMaintenanceItem(id, homeDirectory: home))
            }
        }.value
    }

    func inspectMaintenanceItem(_ id: String, homeDirectory home: String) -> OptimizePreview {
        switch id {
        case "sqlite-vacuum":
            return inspectSQLiteVacuum(homeDirectory: home)
        case "saved-state":
            let targets = oldSavedStates(homeDirectory: home)
            return targets.isEmpty
                ? .init(need: .clean, summaryKey: "audit.maintenance.savedStates.empty")
                : .init(need: .needed, summaryKey: "audit.maintenance.savedStates.found", summaryArguments: [.integer(targets.count)],
                        items: targets.map { URL(fileURLWithPath: $0.path).lastPathComponent },
                        plan: targets.map(Self.planEntry),
                        bytes: targets.reduce(UInt64(0)) { $0 &+ CleanupScanWorker.measure($1.path, control: CleanupScanControl(mode: .deep)).bytes })
        case "quarantine":
            let database = home + "/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"
            guard fileManager.fileExists(atPath: database) else {
                return .init(need: .clean, summaryKey: "audit.maintenance.quarantine.missing")
            }
            guard let raw = sqlite(database, "SELECT COUNT(*) FROM LSQuarantineEvent;", readOnly: true),
                  let count = Int(raw) else {
                return .init(need: .unavailable, summaryKey: "audit.maintenance.quarantine.unreadable")
            }
            return count == 0
                ? .init(need: .clean, summaryKey: "audit.maintenance.quarantine.empty")
                : .init(need: .needed, summaryKey: "audit.maintenance.downloads", summaryArguments: [.integer(count)],
                        bytes: sqliteFamilyBytes(database))
        case "notifications":
            guard let database = notificationDatabase(homeDirectory: home) else {
                return .init(need: .unavailable, summaryKey: "audit.maintenance.notifications.unavailable")
            }
            let bytes = sqliteFamilyBytes(database)
            return bytes < Self.notificationThresholdBytes
                ? .init(need: .clean, summaryKey: "audit.maintenance.database.below50", summaryArguments: [.text(Self.byteText(bytes))])
                : .init(need: .needed, summaryKey: "audit.maintenance.database.size", summaryArguments: [.text(Self.byteText(bytes))], plan: [database], bytes: bytes)
        case "coreduet":
            let database = home + "/Library/Application Support/Knowledge/knowledgeC.db"
            guard fileManager.fileExists(atPath: database) else {
                return .init(need: .clean, summaryKey: "audit.maintenance.usage.missing")
            }
            let bytes = sqliteFamilyBytes(database)
            return bytes < Self.knowledgeThresholdBytes
                ? .init(need: .clean, summaryKey: "audit.maintenance.database.below100", summaryArguments: [.text(Self.byteText(bytes))])
                : .init(need: .needed, summaryKey: "audit.maintenance.database.size", summaryArguments: [.text(Self.byteText(bytes))], plan: [database], bytes: bytes)
        default:
            return .init(need: .unavailable, summaryKey: "audit.maintenance.unknown")
        }
    }

    // MARK: 执行

    /// 执行单个维护/修复动作；清理页卡片与开发环境按钮共用。
    /// 白名单命中的项跳过（与清理页一致的用户保护）。
    func runMaintenanceTask(id: String, preview: OptimizePreview,
                            homeDirectory home: String = NSHomeDirectory()) async
        -> (state: OptimizeTask.State, message: String) {
        await Task.detached(priority: .utility) { [self] in
            let probe = OptimizeTask(id: id, title: id, detail: "")
            if isOptimizeWhitelisted(probe, homeDirectory: home) {
                return (.unchanged, L10n.shared.t("audit.maintenance.whitelisted"))
            }
            return applyMaintenanceTask(id, preview: preview, homeDirectory: home)
        }.value
    }

    func applyMaintenanceTask(_ id: String, preview: OptimizePreview,
                              homeDirectory home: String) -> (state: OptimizeTask.State, message: String) {
        switch id {
        case "quicklook":
            let ok = runCommand("/usr/bin/qlmanage", ["-r", "cache"])
            return ok ? (.applied, L10n.shared.t("audit.maintenance.quicklook.success")) : (.failed, L10n.shared.t("audit.maintenance.quicklook.failed"))
        case "iconservices":
            let ok = runCommand("/usr/bin/killall", ["-u", NSUserName(), "iconservicesagent"])
            return ok ? (.applied, L10n.shared.t("audit.maintenance.icons.success"))
                : (.unchanged, L10n.shared.t("audit.maintenance.icons.unchanged"))
        case "launchservices":
            // `-kill` 会丢掉用户手动注册的应用，只做 gc + 重注册。
            _ = runCommand(Self.lsregister, ["-gc"])
            let full = runCommand(Self.lsregister,
                                  ["-r", "-f", "-domain", "local", "-domain", "user", "-domain", "system"])
            let partial = full || runCommand(Self.lsregister,
                                             ["-r", "-f", "-domain", "local", "-domain", "user"])
            if full { return (.applied, L10n.shared.t("audit.maintenance.launchservices.success")) }
            return partial ? (.applied, L10n.shared.t("audit.maintenance.launchservices.partial"))
                : (.failed, L10n.shared.t("audit.maintenance.launchservices.failed"))
        case "saved-state":
            let root = home + "/Library/Saved Application State"
            let fresh = Set(oldSavedStates(homeDirectory: home).map(Self.planEntry))
            return trashPlanned(preview.plan.filter(fresh.contains), parent: root)
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
            return (.unavailable, L10n.shared.t("audit.maintenance.unsupported"))
        }
    }

    // MARK: 计划与工具

    static let lsregister =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    static func planEntry(_ target: (path: String, identity: String)) -> String {
        "\(target.identity)\t\(target.path)"
    }

    static func planPath(_ entry: String) -> String? {
        entry.split(separator: "\t", maxSplits: 1).last.map(String.init)
    }

    static func byteText(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func trashPlanned(_ plan: [String], parent: String) -> (state: OptimizeTask.State, message: String) {
        let targets = plan.compactMap { entry -> (path: String, identity: String)? in
            let parts = entry.split(separator: "\t", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (path: parts[1], identity: parts[0]) : nil
        }
        guard !targets.isEmpty else { return (.unchanged, L10n.shared.t("audit.maintenance.unchanged")) }
        let result = trashOptimizeTargets(targets, parent: parent)
        if result.failed > 0 {
            return (result.removed > 0 ? .applied : .failed,
                    L10n.shared.tf("audit.maintenance.trash.partial", result.removed, result.failed))
        }
        return (.applied, L10n.shared.tf("audit.maintenance.trash.success", result.removed))
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
            return .init(need: .unavailable, summaryKey: "audit.maintenance.sqlite.unavailable")
        }
        var items: [String] = []
        var plan: [String] = []
        for path in vacuumCandidates(homeDirectory: home) {
            let name = path.replacingOccurrences(of: home, with: "~")
            let bytes = fileSize(URL(fileURLWithPath: path))
            if bytes > Self.sqliteMaxBytes {
                items.append(L10n.shared.tf("audit.maintenance.sqlite.tooLarge", name, Self.byteText(bytes)))
                continue
            }
            guard let raw = sqlite(path, "PRAGMA page_count; PRAGMA freelist_count;", readOnly: true) else {
                items.append(L10n.shared.tf("audit.maintenance.sqlite.unreadable", name))
                continue
            }
            let numbers = raw.split(whereSeparator: \.isNewline).compactMap { Int($0) }
            guard numbers.count == 2, numbers[0] > 0 else { continue }
            let percent = numbers[1] * 100 / numbers[0]
            guard percent >= 5 else { continue }
            items.append(L10n.shared.tf("audit.maintenance.sqlite.freePages", name, Self.byteText(bytes), percent))
            plan.append(path)
        }
        guard !plan.isEmpty else {
            return .init(need: .clean, summaryKey: "audit.maintenance.sqlite.compact", items: items)
        }
        let busy = runningVacuumOwners()
        if !busy.isEmpty {
            return .init(need: .blocked, summaryKey: "audit.maintenance.quitFirst", summaryArguments: [.text(busy.joined(separator: ", "))], items: items)
        }
        return .init(need: .needed, summaryKey: "audit.maintenance.sqlite.found", summaryArguments: [.integer(plan.count)], items: items, plan: plan,
                     bytes: plan.reduce(UInt64(0)) { $0 &+ fileSize(URL(fileURLWithPath: $1)) })
    }

    private func vacuumDatabases(_ plan: [String],
                                 homeDirectory home: String) -> (state: OptimizeTask.State, message: String) {
        let busy = runningVacuumOwners()
        guard busy.isEmpty else { return (.unchanged, L10n.shared.tf("audit.maintenance.running", busy.joined(separator: ", "))) }
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
                    L10n.shared.tf("audit.maintenance.sqlite.partial", vacuumed, failed))
        }
        return vacuumed > 0 ? (.applied, L10n.shared.tf("audit.maintenance.sqlite.success", vacuumed))
            : (.unchanged, L10n.shared.t("audit.maintenance.sqlite.unchanged"))
    }

    /// 只执行固定语句；语句常量在调用点写死，永不拼接外部输入。
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
            return (.unchanged, L10n.shared.t("audit.maintenance.notifications.changed"))
        }
        guard let raw = sqlite(database, "SELECT MAX(delivered_date) FROM record;", readOnly: true),
              let latest = Double(raw) else {
            return (.failed, L10n.shared.t("audit.maintenance.notifications.unreadable"))
        }
        let cutoff = Self.notificationCutoff(maxDelivered: latest)
        guard sqlite(database, "DELETE FROM record WHERE delivered_date < \(Int(cutoff)); VACUUM;",
                     timeout: 60) != nil else {
            return (.failed, L10n.shared.t("audit.maintenance.notifications.busy"))
        }
        _ = runCommand("/usr/bin/killall", ["NotificationCenter"])
        return (.applied, L10n.shared.tf("audit.maintenance.notifications.success", Self.byteText(sqliteFamilyBytes(database))))
    }

    private func trimKnowledge(_ plan: [String],
                               homeDirectory home: String) -> (state: OptimizeTask.State, message: String) {
        let database = home + "/Library/Application Support/Knowledge/knowledgeC.db"
        guard plan == [database], fileManager.fileExists(atPath: database) else {
            return (.unchanged, L10n.shared.t("audit.maintenance.usage.changed"))
        }
        let cutoff = Int(Date().addingTimeInterval(-90 * 86_400).timeIntervalSince1970 - Self.cocoaEpochOffset)
        guard sqlite(database, "DELETE FROM ZOBJECT WHERE ZCREATIONDATE < \(cutoff); VACUUM;",
                     timeout: 120) != nil else {
            return (.failed, L10n.shared.t("audit.maintenance.usage.busy"))
        }
        return (.applied, L10n.shared.tf("audit.maintenance.usage.success", Self.byteText(sqliteFamilyBytes(database))))
    }
}
