import Darwin
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
        exit(1)
    }
}

@main
struct OptimizeTests {
    static func main() async throws {
        if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--probe" {
            let inspected = await NativeCore.shared.inspectOptimize(tasks: NativeCore.shared.initialOptimizeTasks())
            for task in inspected {
                let preview = task.preview!
                print("[\(preview.need.rawValue)\(task.selected ? " ✓" : "")] \(task.id) (\(task.kind.rawValue)): \(preview.summary)")
                for item in preview.items.prefix(5) { print("      \(item)") }
            }
            return
        }
        let fm = FileManager.default
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let home = fixture.appendingPathComponent("home").path
        let core = NativeCore.shared

        func write(_ relative: String, _ text: String = "x") throws {
            let url = URL(fileURLWithPath: home + "/" + relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        func age(_ relative: String, days: Double) throws {
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86_400)],
                                 ofItemAtPath: home + "/" + relative)
        }
        let validPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Label</key><string>ok</string></dict></plist>
        """

        // --- 目录：Mole 的 21 项全部在列，报告类不可执行，提权集合一致。
        let tasks = core.initialOptimizeTasks()
        let ids = tasks.map(\.id)
        expect(Set(ids).count == ids.count && ids.count == 21, "optimize catalog is not the 21 Mole tasks: \(ids)")
        for mole in ["dns", "quicklook", "iconservices", "launchservices", "saved-state", "broken-configs",
                     "shared-file-list", "finder-dsstore", "legacy-overrides", "spotlight-orphans",
                     "sqlite-vacuum", "network-stack", "periodic", "permissions", "spotlight", "disk-verify",
                     "quarantine", "notifications", "coreduet", "launch-agents", "login-items"] {
            expect(ids.contains(mole), "Mole task \(mole) missing")
        }
        expect(Set(tasks.filter { $0.kind == .admin }.map(\.id)) == NativeCore.adminTaskIDs,
               "admin kinds and the bridge allowlist drifted")
        expect(tasks.first { $0.id == "launch-agents" }?.kind == .report, "launch agents must be report-only")
        for history in ["quarantine", "notifications", "coreduet", "spotlight", "disk-verify"] {
            expect(tasks.first { $0.id == history }?.defaultOn == false, "\(history) must not be preselected")
        }
        let bridge = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
        for id in NativeCore.adminTaskIDs {
            expect(bridge.contains("        \(id))"), "admin bridge does not implement \(id)")
        }

        // --- 可选规则：报告项、不需要项、未预检项都不可执行。
        var report = tasks.first { $0.id == "launch-agents" }!
        report.preview = .init(need: .needed, summary: "")
        expect(!report.selectable, "a report-only task became selectable")
        var clean = tasks.first { $0.id == "quicklook" }!
        expect(!clean.selectable, "an uninspected task is selectable")
        clean.preview = .init(need: .clean, summary: "")
        expect(!clean.selectable, "a not-needed task is selectable")

        // --- 保存状态：只列 30 天前的，执行时身份不符即拒绝。
        try write("Library/Saved Application State/com.old.savedState/data.data")
        try write("Library/Saved Application State/com.new.savedState/data.data")
        try age("Library/Saved Application State/com.old.savedState", days: 45)
        let saved = core.inspectOptimizeTask("saved-state", homeDirectory: home)
        expect(saved.need == .needed && saved.items == ["com.old.savedState"] && saved.plan.count == 1,
               "saved-state preview wrong: \(saved)")
        let forged = NativeCore.OptimizeTask.Preview(
            need: .needed, summary: "",
            plan: ["1:2:3\t" + home + "/Library/Saved Application State/com.old.savedState",
                   saved.plan[0].replacingOccurrences(of: "com.old", with: "com.new")])
        let refused = core.applyOptimizeTask("saved-state", preview: forged, homeDirectory: home)
        expect(refused.state == .unchanged
               && fm.fileExists(atPath: home + "/Library/Saved Application State/com.old.savedState")
               && fm.fileExists(atPath: home + "/Library/Saved Application State/com.new.savedState"),
               "saved-state acted on evidence that did not match the preview: \(refused)")

        // --- 损坏的偏好：只收第三方且 lint 失败的文件，Apple 域永远排除。
        try write("Library/Preferences/com.vendor.good.plist", validPlist)
        try write("Library/Preferences/com.vendor.bad.plist", "{ not a plist")
        try write("Library/Preferences/com.apple.bad.plist", "{ not a plist")
        let prefs = core.inspectOptimizeTask("broken-configs", homeDirectory: home)
        expect(prefs.need == .needed && prefs.items == ["com.vendor.bad.plist"],
               "broken preference preview wrong: \(prefs.items)")
        try write("Library/Preferences/com.vendor.bad.plist", validPlist)
        let repaired = core.applyOptimizeTask("broken-configs", preview: prefs, homeDirectory: home)
        expect(repaired.state == .unchanged && fm.fileExists(atPath: home + "/Library/Preferences/com.vendor.bad.plist"),
               "a preference that became valid was still trashed")

        // --- 共享文件列表：最近文档列表属于用户数据，即使损坏也不收。
        try write("Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.FavoriteItems.sfl3", "{ not a plist")
        try write("Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/x.sfl3", "{ not a plist")
        let lists = core.inspectOptimizeTask("shared-file-list", homeDirectory: home)
        expect(lists.items == ["com.apple.LSSharedFileList.FavoriteItems.sfl3"],
               "shared file list preview wrong: \(lists.items)")

        // --- 启动代理：只报告，执行后文件原样保留。
        try write("Library/LaunchAgents/com.vendor.broken.plist", """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Label</key><string>b</string>
        <key>ProgramArguments</key><array><string>/Applications/Gone.app/Contents/MacOS/gone</string></array></dict></plist>
        """)
        try write("Library/LaunchAgents/com.vendor.relative.plist", """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Label</key><string>r</string><key>Program</key><string>node</string></dict></plist>
        """)
        let agents = core.inspectOptimizeTask("launch-agents", homeDirectory: home)
        expect(agents.need == .blocked && agents.plan == [home + "/Library/LaunchAgents/com.vendor.broken.plist"],
               "launch agent report wrong: \(agents)")
        var agentTask = tasks.first { $0.id == "launch-agents" }!
        agentTask.preview = agents
        agentTask.selected = true
        let ran = await core.runOptimize(tasks: [agentTask], homeDirectory: home)
        expect(ran.tasks[0].state == .pending
               && fm.fileExists(atPath: home + "/Library/LaunchAgents/com.vendor.broken.plist"),
               "report-only launch agents were acted on")

        // --- SQLite：只收真实 SQLite 文件，符号链接与伪造头拒绝；未勾选不执行。
        try write("Library/Safari/History.db", "not sqlite")
        try fm.createDirectory(atPath: home + "/Library/Messages", withIntermediateDirectories: true)
        let outside = fixture.appendingPathComponent("outside.db").path
        _ = core.sqlite(outside, "CREATE TABLE t(x); INSERT INTO t VALUES (1);")
        try fm.createSymbolicLink(atPath: home + "/Library/Messages/chat.db", withDestinationPath: outside)
        let topSites = home + "/Library/Safari/TopSites.db"
        _ = core.sqlite(topSites, "CREATE TABLE t(x); INSERT INTO t VALUES (1);")
        expect(core.vacuumCandidates(homeDirectory: home) == [topSites],
               "vacuum candidates accepted a symlink or a non-SQLite file")

        // --- 权限：可写的个人目录无需修复。
        expect(core.permissionProblems(homeDirectory: home).isEmpty, "writable fixture home reported broken")

        // --- 提权结果合并：只接受请求过的任务，未回报的按失败/未授权处理。
        let merged = NativeCore.mergeAdminResults(
            "dns\tapplied\tDNS ok\nperiodic\tpending\tbogus\nspotlight\tapplied\tnot requested\n",
            succeeded: true, requested: ["dns", "periodic"], into: tasks)
        expect(merged.first { $0.id == "dns" }?.state == .applied, "admin result not merged")
        expect(merged.first { $0.id == "periodic" }?.state == .failed, "missing admin result not failed")
        expect(merged.first { $0.id == "spotlight" }?.state == .pending, "unrequested admin result merged")
        let denied = NativeCore.mergeAdminResults("", succeeded: false, requested: ["dns"], into: tasks)
        expect(denied.first { $0.id == "dns" }?.state == .unavailable, "denied authorization not reported")

        // --- 通知时间戳：Unix 与 Cocoa 纪元都要得到 30 天前的截止点。
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let unixCut = NativeCore.notificationCutoff(maxDelivered: 1_799_999_000, now: now)
        let cocoaCut = NativeCore.notificationCutoff(maxDelivered: 821_000_000, now: now)
        expect(unixCut == 1_800_000_000 - 30 * 86_400, "Unix notification cutoff wrong")
        expect(cocoaCut == unixCut - NativeCore.cocoaEpochOffset,
               "Cocoa notification cutoff would delete every notification")

        expect(NativeCore.isReverseDNS("com.vendor.app") && !NativeCore.isReverseDNS("System.iphoneApps")
               && !NativeCore.isReverseDNS("com..app"), "reverse-DNS filter wrong")
        print("Optimize: catalog, previews, evidence binding, report-only agents and admin merge passed")
    }
}
