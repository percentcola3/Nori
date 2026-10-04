import AppKit
import SwiftUI

/// This entry point is compiled only by capture_readme_screenshots.sh.
/// It never launches Nori's AppDelegate or any real scan/cleanup/monitor.
@MainActor
enum ReadmeFixture {
    static let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NORI_README_FIXTURE_ROOT"]!)
    static let defaults: UserDefaults = {
        let defaults = UserDefaults(suiteName: "com.nori.readme-fixtures")!
        defaults.removePersistentDomain(forName: "com.nori.readme-fixtures")
        return defaults
    }()
    static let sampleDate = Date(timeIntervalSince1970: 1_790_827_200)
    static var section: DeveloperWorkspaceSection = .overview
    static var reducesTransparency = false
    static var reducesMotion = false
    static var detail = ""
    static var shellDraft = false
    static var shellFileIndex = 2
    static var shellDirectory: URL { root.appendingPathComponent("demo-shell") }

    static var terminal: DeveloperTerminalSnapshot {
        .init(environment: ["HOME": "/Users/demo", "PATH": "/opt/homebrew/bin:/Users/demo/.local/bin:/usr/bin:/bin", "JAVA_HOME": "/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home", "http_proxy": "http://127.0.0.1:7890", "https_proxy": "http://127.0.0.1:7890", "SSH_AUTH_SOCK": "/fixture/agent.sock"], shell: "/bin/zsh", sampledAt: sampleDate, duration: 0.28, failed: false)
    }
    static var managedVersions: [DeveloperManagedVersion] {
        [.init(manager: .nvm, candidate: "node", version: "v22.14.0", path: "/Users/demo/.nvm/versions/node/v22.14.0", isDefault: true, isActive: true),
         .init(manager: .nvm, candidate: "node", version: "v20.18.0", path: "/Users/demo/.nvm/versions/node/v20.18.0", isDefault: false, isActive: false),
         .init(manager: .pyenv, candidate: "python", version: "3.13.2", path: "/Users/demo/.pyenv/versions/3.13.2", isDefault: true, isActive: true),
         .init(manager: .rustup, candidate: "rust", version: "stable-aarch64-apple-darwin", path: "/Users/demo/.rustup/toolchains/stable-aarch64-apple-darwin", isDefault: true, isActive: true)]
    }
    static var packages: DeveloperPackageService.Inventory {
        .init(packages: [.init(manager: "brew", name: "git", version: "2.48.1", available: "2.49.0"),
                         .init(manager: "brew", name: "ripgrep", version: "14.1.1", available: nil),
                         .init(manager: "npm", name: "typescript", version: "5.7.3", available: "5.8.2"),
                         .init(manager: "pipx", name: "ruff", version: "0.9.6", available: nil)],
              services: [.init(name: "postgresql@17", status: "started", user: "demo", file: "~/Library/LaunchAgents/homebrew.mxcl.postgresql@17.plist"),
                         .init(name: "redis", status: "none", user: "", file: "")], failures: [])
    }
    static var cliSnapshot: DeveloperCLISnapshot {
        let versions = ["node": "22.14.0", "npm": "10.9.2", "python3": "3.13.2", "uv": "0.6.3", "git": "2.48.1", "swift": "6.2", "brew": "4.4.20"]
        return .init(entries: DeveloperCLIService.tools.map { tool in
            let version = versions[tool.id]
            let path = "/opt/homebrew/bin/" + tool.id
            return .init(tool: tool, locations: version == nil ? [] : [.init(path: path, resolvedPath: path, source: "Homebrew", isInPATH: true)], version: version.map(DeveloperCLIVersion.value) ?? .unavailable)
        }, pathDirectories: ["/opt/homebrew/bin", "/Users/demo/.local/bin", "/usr/bin", "/bin"], duplicatePATHDirectories: [], hasRelativePATHEntry: false, homePath: "/Users/demo")
    }
    static let shellInventory: DeveloperShellService.Inventory = {
        let texts = [".zprofile": "# Command search folders\npath=(\"$HOME/tools/bin\" \"/opt/homebrew/bin\" $path)\n",
                     ".zshrc": "# Developer environment\nexport PATH=\"$HOME/tools/bin:/opt/homebrew/bin:$PATH\"\nexport JAVA_HOME=\"/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home\"\nexport EDITOR=\"code --wait\"\nalias gs='git status'\nalias ll='ls -lah'\n"]
        let directory = shellDirectory
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for (name, text) in texts {
            let file = directory.appendingPathComponent(name)
            try! text.write(to: file, atomically: false, encoding: .utf8)
            try! FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        let profiles = DeveloperShellService.fileNames.map { name in
            var profile = try! DeveloperShellService.readProfile(name, home: directory.path)
            profile.directoryPath = directory.path; profile.homePath = directory.path
            return profile
        }
        let current = profiles.first { $0.name == ".zshrc" }!
        _ = try! DeveloperShellBackupStore.create(Data(current.text.replacingOccurrences(of: "code --wait", with: "vim").utf8), targetPath: current.path, home: directory.path)
        return .init(shellPath: "/bin/zsh", kind: .zsh, directory: directory.path, names: DeveloperShellService.fileNames, profiles: profiles, loginFile: nil, usesCustomZdotdir: false, included: [])
    }()
    static var sshKeys: [DeveloperSSHGitService.Key] {
        [.init(publicPath: "/Users/demo/.ssh/id_ed25519_work.pub", privatePath: "/Users/demo/.ssh/id_ed25519_work", type: "ssh-ed25519", bits: 256, fingerprint: "SHA256:sFk0m3IXoTqDgN2lzyJ7B1Ec8ZwVu6adUfQA9CxP5Ks", comment: "demo@example.com", needsPermissionRepair: false, privatePermissionsLoose: false),
         .init(publicPath: "/Users/demo/.ssh/id_ed25519_personal.pub", privatePath: "/Users/demo/.ssh/id_ed25519_personal", type: "ssh-ed25519", bits: 256, fingerprint: "SHA256:kQ8wBbFjCzGTuVsE7mhMpyXA6Re5uHnVd9NpS02YolI", comment: "personal@example.com", needsPermissionRepair: false, privatePermissionsLoose: false)]
    }
    static var sshConfig: DeveloperSSHGitService.SSHConfig {
        let text = "Host github-work\n    HostName github.com\n    User git\n    Port 22\n    IdentityFile ~/.ssh/id_ed25519_work\n    IdentitiesOnly yes\n\nHost github-personal\n    HostName github.com\n    User git\n    IdentityFile ~/.ssh/id_ed25519_personal\n    IdentitiesOnly yes\n"
        return .init(text: text, data: Data(text.utf8), path: "/Users/demo/.ssh/config", identity: nil, blocks: DeveloperSSHGitService.parseConfig(text))
    }
    static var networkSnapshot: DeveloperNetworkService.Snapshot {
        let proxy = DeveloperNetworkService.Proxy(kind: "HTTP", endpoint: "127.0.0.1:7890")
        let hosts = "127.0.0.1 localhost\n::1 localhost\n\n# Nori group: Development\n127.0.0.1 api.local dashboard.local # Local development\n# 10.10.0.8 staging.local # Staging service\n"
        return .init(services: [.init(name: "Wi-Fi", enabled: true, address: "192.168.1.42", dnsServers: ["1.1.1.1", "8.8.8.8"], proxies: [proxy], dnsReadable: true, proxiesReadable: true, readable: true)], resolverServers: ["1.1.1.1", "8.8.8.8"], hosts: .init(text: hosts, fingerprint: "readme-fixture", customEntryCount: 2), warnings: [], effectiveProxies: [proxy])
    }
    static var networkToolsSnapshot: DeveloperNetworkToolsService.Snapshot {
        .init(proxies: DeveloperNetworkToolsService.ProxyLayer.allCases.map { .init(layer: $0, values: $0 == .terminal ? ["http_proxy": "http://127.0.0.1:7890", "https_proxy": "http://127.0.0.1:7890"] : [:], available: true) },
              mirrors: DeveloperNetworkToolsService.MirrorTool.allCases.map { .init(tool: $0, current: $0.official, available: true) }, terminal: terminal)
    }

    static func choose(_ english: String, _ chinese: String) -> String {
        L10n.shared.resolved == .en ? english : chinese
    }

    static func category(_ english: String, _ chinese: String, path: String, gb: Double,
                         source: CleanupSource = .core, risk: CleanupRisk = .safe,
                         reason: String = "cleanup.risk.rebuildableCache") -> CleanupCategory {
        CleanupCategory(name: choose(english, chinese), paths: [path], bytes: UInt64(gb * 1_000_000_000),
                        pathIdentities: [path: "readme-fixture"], selected: risk == .safe,
                        source: source, risk: risk, disposal: .permanentDelete,
                        applyRoute: source == .core ? .genericTrash : .developerCacheTrash,
                        activityGuard: .openFile, reasonKey: reason)
    }

    static func makeState() -> AppState {
        let state = AppState()
        state.mainWindowVisible = true
        state.metrics = MetricsSnapshot(cpuPercent: 14.2, logicalCPUCount: 12, physicalCPUCount: 12,
            memoryPercent: 48, memoryUsedBytes: 15_360_000_000, memoryTotalBytes: 32_000_000_000,
            memoryAvailableBytes: 16_640_000_000, memoryPressure: "normal", diskFreeBytes: 236_000_000_000,
            diskUsedPercent: 54, batteryPercent: 84, batteryHealthPercent: 99, batteryCycleCount: 62,
            networkRxMBps: 3.6, networkTxMBps: 0.8, healthScore: 96)
        state.islandItems = [.cpu, .memory, .network]
        state.topMemoryApps = [
            ("Xcode", 2.4), ("Safari", 1.3), ("Terminal", 0.6), ("Finder", 0.3)
        ].enumerated().map { index, value in
            ProcessRow(pid: Int32(100 + index), startIdentity: "readme", name: value.0,
                       detail: "", isNativeApp: true, cpu: 2, mem: value.1 / 32 * 100,
                       memBytes: UInt64(value.1 * 1_000_000_000))
        }
        state.networkHistory = [0.3, 0.8, 0.5, 1.1, 0.4, 0.7, 1.5, 1.2, 2.1, 1.7, 3.0, 2.2, 2.8, 3.6]
        state.networkUploadHistory = [0.2, 0.3, 0.1, 0.4, 0.2, 0.3, 0.6, 0.4, 0.7, 0.3, 0.6, 0.5, 0.7, 0.8]
        state.categories = [
            category("Xcode Derived Data", "Xcode 构建缓存", path: "/Users/demo/Library/Developer/Xcode/DerivedData", gb: 18.4, source: .xcodeCache),
            category("npm cache", "npm 缓存", path: "/Users/demo/.npm/_cacache", gb: 5.8, source: .developerCache),
            category("pip cache", "pip 缓存", path: "/Users/demo/Library/Caches/pip", gb: 2.3, source: .developerCache),
            category("Browser caches", "浏览器缓存", path: "/Users/demo/Library/Caches/com.apple.Safari", gb: 3.2),
            category("Application caches", "应用缓存", path: "/Users/demo/Library/Caches", gb: 2.1),
            category("Old application logs", "旧应用日志", path: "/Users/demo/Library/Logs", gb: 0.8),
            category("Removed app caches", "已卸载应用缓存", path: "/Users/demo/Library/Caches/com.example.OldApp", gb: 1.6, source: .appLeftover),
        ]
        state.devEnvEntries = [
            DevEnvEntry(bytes: 210_000_000, kind: "current", name: "nvm · v22.14.0", path: "/Users/demo/.nvm/versions/node/v22.14.0", relatedBytes: 0, relatedPath: nil),
            DevEnvEntry(bytes: 480_000_000, kind: "runtime", name: "nvm · v20.18.0", path: "/Users/demo/.nvm/versions/node/v20.18.0", relatedBytes: 160_000_000, relatedPath: "/Users/demo/.nvm/versions/node/v20.18.0/lib/node_modules"),
        ]
        state.devEnvSelection = [state.devEnvEntries[1].path]
        state.gcActions = [
            GcAction(id: "Homebrew", command: "brew cleanup --prune=all", bytes: 1_900_000_000),
            GcAction(id: "npm", command: "npm cache clean --force", bytes: 5_800_000_000),
            GcAction(id: "pip", command: "pip cache purge", bytes: 2_300_000_000),
        ]

        let codex = category("Codex logs", "Codex 日志", path: "/Users/demo/.codex/log", gb: 0.42,
                             source: .aiCache, reason: "agents.reason.rebuildable")
        let claude = category("Claude Code session history", "Claude Code 会话历史", path: "/Users/demo/.claude/projects/demo-project/session.jsonl", gb: 1.8,
                              source: .aiSession, risk: .warning, reason: "agents.reason.review")
        let cursor = category("Cursor caches", "Cursor 缓存", path: "/Users/demo/Library/Caches/com.todesktop.230313mzl4w4u92", gb: 0.86,
                              source: .aiCache, reason: "agents.reason.rebuildable")
        state.agentCategories = [codex, claude, cursor]
        state.agentGroups = [
            AgentGroupSummary(id: "codex", name: "Codex CLI", documented: true, orphaned: false, categoryIDs: [codex.id], skillIDs: [], serverIDs: [], bytes: codex.bytes),
            AgentGroupSummary(id: "claude", name: "Claude Code", documented: true, orphaned: false, categoryIDs: [claude.id], skillIDs: [], serverIDs: [], bytes: claude.bytes),
            AgentGroupSummary(id: "cursor", name: "Cursor", documented: true, orphaned: false, categoryIDs: [cursor.id], skillIDs: [], serverIDs: [], bytes: cursor.bytes),
            AgentGroupSummary(id: "shared", name: choose("Shared Skills", "共享 Skills"), documented: true, orphaned: false, categoryIDs: [], skillIDs: ["demo-skill"], serverIDs: [], bytes: 86_000),
        ]
        state.agentSkills = [AgentSkill(path: "/Users/demo/.agents/skills/swiftui-expert-skill", name: "swiftui-expert-skill",
            summary: choose("SwiftUI interface reviews and native macOS patterns.", "SwiftUI 界面审查与原生 macOS 开发。"),
            directory: "swiftui-expert-skill", usedBy: ["Codex", "Claude Code"], agentID: "shared",
            bytes: 86_000, identity: "readme", linked: false, linkTarget: nil)]
        state.agentHasScanned = true
        state.agentScanComplete = true

        state.autoCleanupRules = [
            AutoCleanupRule(directory: "/Users/demo/Library/Developer/Xcode/DerivedData", policy: .sizeLimit,
                sizeLimitBytes: 15_000_000_000, retentionDays: 14, isRegenerable: true,
                authorizedRootIdentity: "1:2:3", lastRunAt: sampleDate, lastReclaimedBytes: 6_400_000_000,
                executionCount: 8, totalReclaimedBytes: 42_700_000_000),
            AutoCleanupRule(directory: "/Users/demo/Library/Caches/pip", policy: .retentionDays,
                sizeLimitBytes: 2_000_000_000, retentionDays: 30, isRegenerable: true,
                authorizedRootIdentity: "1:2:4", lastRunAt: sampleDate, lastReclaimedBytes: 830_000_000,
                executionCount: 4, totalReclaimedBytes: 3_200_000_000),
        ]
        state.autoCleanupStatus = ""
        let manager = state.clipboardManager
        manager.record(.init(kind: .text, text: choose("Make room for your next idea.", "为下一个灵感腾出空间。"), date: sampleDate))
        manager.togglePinned(manager.entries[0].id)
        manager.record(.init(kind: .url, text: "https://github.com/tw93/Mole", date: sampleDate.addingTimeInterval(-120)))
        manager.record(.init(kind: .text, text: "swift build -c release", date: sampleDate.addingTimeInterval(-240)))
        manager.record(.init(kind: .file, filePaths: ["/Users/demo/Downloads/design-notes.pdf", "/Users/demo/Downloads/nori-icon.png"], date: sampleDate.addingTimeInterval(-360)))
        manager.record(.init(kind: .text, text: choose("Release notes\n• Native macOS experience\n• Review before cleanup\n• Keep your tools tidy", "发布说明\n• 原生 macOS 体验\n• 清理前先确认\n• 保持开发环境整洁"), date: sampleDate.addingTimeInterval(-480)))
        manager.stop()
        return state
    }
}

private struct RuntimeScreenshot: View {
    let state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(ReadmeFixture.choose("Developer workspace", "开发者工作台"))
                .font(.system(size: 15, weight: .semibold))
            ScrollView {
                DeveloperRuntimePanel(state: state)
            }
        }
        .padding(20)
        .background { GlassSurface().ignoresSafeArea() }
    }
}

private struct DeveloperScreenshot: View {
    let state: AppState
    @ObservedObject private var l10n = L10n.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(l10n.t("tab.devenv")).font(.system(size: 15, weight: .semibold)).padding(18)
            DevEnvTabView(state: state)
        }
        .background { GlassSurface().ignoresSafeArea() }
    }
}

private struct IslandScreenshot: View {
    let state: AppState
    var body: some View {
        FloatingIslandView(state: state, metricsStore: state.metricsStore, safeTop: 0, hardwareNotch: false,
                           onOpenMain: {}, onHitFrameChange: { _, _ in })
            .padding(.top, 18)
            .background {
                LinearGradient(colors: [Color.surface1, Color.surface3, Color.surface2],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
    }
}

@main
@MainActor
struct ReadmeScreenshots {
    static func settle(_ seconds: Double = 1.2) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    static func capture<V: View>(_ view: V, size: NSSize, to path: URL, borderless: Bool = false, sheetOnly: Bool = false) throws -> NSImage {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: borderless ? [.borderless] : [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Nori"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isOpaque = borderless
        window.backgroundColor = borderless
            ? NSColor(srgbRed: 0.12, green: 0.15, blue: 0.18, alpha: 1) : .clear
        window.ignoresMouseEvents = true
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: view
            .environment(\.colorScheme, .dark)
            .environment(\.locale, Locale(identifier: L10n.shared.resolved == .en ? "en_US" : L10n.shared.resolved == .zhHant ? "zh_TW" : "zh_CN"))
            .transaction { $0.animation = nil; $0.disablesAnimations = true })
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.center()
        // Native glass can sample beyond the window bounds. A dedicated
        // opaque backing window ensures that sample contains only a neutral
        // fixture color, never the user's desktop or other application text.
        let backdrop = NSWindow(contentRect: window.frame.insetBy(dx: -80, dy: -80),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false
        backdrop.isOpaque = true
        backdrop.backgroundColor = NSColor(srgbRed: 0.12, green: 0.15, blue: 0.18, alpha: 1)
        backdrop.ignoresMouseEvents = true
        backdrop.orderFront(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settle()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let capturedWindow = sheetOnly ? (window.attachedSheet ?? window) : window
        if sheetOnly, window.attachedSheet == nil { throw NSError(domain: "ReadmeScreenshot", code: 3, userInfo: [NSLocalizedDescriptionKey: "Backup fixture did not present its native sheet."]) }
        // NSView.cacheDisplay does not capture SwiftUI's window compositor
        // (including native glass) reliably. Capture this exact window only.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(capturedWindow.windowNumber), path.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let image = NSImage(contentsOf: path) else {
            throw NSError(domain: "ReadmeScreenshot", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Native own-window capture failed. Check screen capture access for the invoking terminal/app."])
        }
        window.orderOut(nil)
        window.close()
        backdrop.orderOut(nil)
        backdrop.close()
        settle(0.08)
        print("Rendered \(path.path)")
        return image
    }

    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        // The renderer has its own bundle identity and fixture suite. The
        // production com.nori.app defaults and clipboard are never read.
        UserDefaults.standard.removePersistentDomain(forName: "com.nori.readme-renderer")
        let folder = CommandLine.arguments[2]
        let language: AppLanguage = folder == "en" ? .en : folder == "zh-TW" ? .zhHant : .zhHans
        let localeIdentifier = folder == "en" ? "en_US" : folder == "zh-TW" ? "zh_TW" : "zh_CN"
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        UserDefaults.standard.set(localeIdentifier, forKey: "AppleLocale")
        try FileManager.default.createDirectory(at: ReadmeFixture.root, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: ReadmeFixture.root.appendingPathComponent("clipboard.json"))
        NSApplication.shared.setActivationPolicy(.accessory)
        do {
            L10n.shared.setLanguage(language)
            let directory = output.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let state = ReadmeFixture.makeState()
            let windowSize = NSSize(width: 1100, height: 760)
            if ProcessInfo.processInfo.environment["NORI_CAPTURE_DEVELOPER_ONLY"] != "1" {
            let allCategories = state.categories
            state.categories = []
            let overview = try capture(MainWindowView(state: state), size: windowSize,
                                       to: directory.appendingPathComponent("overview.png"))
            state.categories = allCategories
            _ = try capture(MainWindowView(state: state), size: windowSize,
                            to: directory.appendingPathComponent("cleanup.png"))
            _ = try capture(RuntimeScreenshot(state: state), size: NSSize(width: 940, height: 830),
                            to: directory.appendingPathComponent("developers.png"))
            state.jump(to: .agents)
            _ = try capture(MainWindowView(state: state), size: windowSize,
                            to: directory.appendingPathComponent("agents.png"))
            state.jump(to: .cleanup)
            state.showAutoCleanupSheet = true
            _ = try capture(MainWindowView(state: state), size: windowSize,
                            to: directory.appendingPathComponent("automation.png"))
            state.showAutoCleanupSheet = false
            state.jump(to: .clipboard)
            _ = try capture(MainWindowView(state: state), size: windowSize,
                            to: directory.appendingPathComponent("clipboard.png"))
            let preferences = ScreenshotPreferences(defaults: ReadmeFixture.defaults)
            _ = try capture(ScreenshotEditorView(image: overview, preferences: preferences, onClose: {})
                .background { GlassSurface().ignoresSafeArea() },
                size: NSSize(width: 1100, height: 760),
                to: directory.appendingPathComponent("screenshot.png"))
            _ = try capture(IslandScreenshot(state: state), size: NSSize(width: 500, height: 340),
                            to: directory.appendingPathComponent("island.png"), borderless: true)
            }
            let requestedSections = ProcessInfo.processInfo.environment["NORI_CAPTURE_SECTIONS"]?.split(separator: " ").map(String.init)
            let variants = (ProcessInfo.processInfo.environment["NORI_CAPTURE_VARIANTS"] ?? "regular narrow accessible").split(separator: " ").map(String.init)
            for section in DeveloperWorkspaceSection.allCases where requestedSections == nil || requestedSections!.contains(section.id) {
                ReadmeFixture.section = section
                for variant in variants {
                    ReadmeFixture.reducesTransparency = variant == "accessible"
                    ReadmeFixture.reducesMotion = variant == "accessible"
                    let size = NSSize(width: variant == "narrow" ? 780 : 1100, height: 860)
                    // Each scene owns a fresh session so token caches and draft
                    // state from an earlier capture cannot affect its fixture.
                    _ = try capture(DeveloperScreenshot(state: ReadmeFixture.makeState()), size: size,
                                    to: directory.appendingPathComponent("dev-" + section.id + "-" + variant + ".png"))
                }
            }
            if requestedSections == nil || requestedSections!.contains("shell") {
                ReadmeFixture.section = .shell
                ReadmeFixture.reducesTransparency = false; ReadmeFixture.reducesMotion = false
                ReadmeFixture.shellDraft = true
                _ = try capture(DeveloperScreenshot(state: ReadmeFixture.makeState()), size: NSSize(width: 1100, height: 860), to: directory.appendingPathComponent("dev-shell-draft.png"))
                ReadmeFixture.shellDraft = false
                ReadmeFixture.shellFileIndex = 1
                _ = try capture(DeveloperScreenshot(state: ReadmeFixture.makeState()), size: NSSize(width: 1100, height: 860), to: directory.appendingPathComponent("dev-shell-array.png"))
                ReadmeFixture.shellFileIndex = 2
            }
            if requestedSections == nil || requestedSections!.contains("shell") || requestedSections!.contains("backup") {
                ReadmeFixture.reducesTransparency = false; ReadmeFixture.reducesMotion = false
                let shell = DeveloperShellModel(); awaitRefresh(shell)
                let profile = shell.profiles.first { $0.name == ".zshrc" }!
                _ = try capture(ReadmeShellBackupSheetScreenshot(profile: profile, model: shell), size: NSSize(width: 1100, height: 860), to: directory.appendingPathComponent("dev-shell-backup.png"), sheetOnly: true)
            }
            if requestedSections == nil || requestedSections!.contains("network") {
                ReadmeFixture.section = .network
                ReadmeFixture.detail = "tools"
                ReadmeFixture.reducesTransparency = false; ReadmeFixture.reducesMotion = false
                _ = try capture(DeveloperScreenshot(state: ReadmeFixture.makeState()), size: NSSize(width: 780, height: 2100), to: directory.appendingPathComponent("dev-network-tools-narrow.png"))
                ReadmeFixture.detail = ""
            }
            ReadmeFixture.reducesTransparency = false
            ReadmeFixture.reducesMotion = false
        }
        UserDefaults.standard.removePersistentDomain(forName: "com.nori.readme-renderer")
        ReadmeFixture.defaults.removePersistentDomain(forName: "com.nori.readme-fixtures")
    }

    static func awaitRefresh(_ shell: DeveloperShellModel) {
        var completed = false
        Task { await shell.refresh(); completed = true }
        while !completed { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }
}
