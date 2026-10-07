import Darwin
import Foundation

/// Read-only preview policy. It cannot remove files, stop processes or elevate.
/// The cleanup engine supplies only the small access/identity checks it owns.
struct UninstallPlanningService: Sendable {
    struct Dependencies: Sendable {
        let inventory: any ApplicationInventoryReading
        let allocatedBytes: @Sendable (URL) -> UInt64
        let isPhysicalPath: @Sendable (URL, URL) -> Bool
        let requiresAdministrator: @Sendable (String) -> Bool
        let commandOutput: @Sendable (String, [String]) -> String?
    }
    let dependencies: Dependencies
    private var fileManager: FileManager { .default }
    private var inventory: any ApplicationInventoryReading { dependencies.inventory }
    private func applicationMetadata(at url: URL) -> ApplicationBundleMetadata? { inventory.metadata(at: url) }
    private func applicationRoots(home: URL) -> [(URL, String)] { inventory.roots(home: home) }
    private func applicationDirectoryIdentity(_ url: URL) -> String? { inventory.directoryIdentity(url) }
    private func directChildren(of url: URL) -> [URL] { inventory.children(of: url) }
    private func directorySize(_ url: URL) -> UInt64 { dependencies.allocatedBytes(url) }
    private func isSymlink(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true }
    private func isDirectory(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    private func cleanupPathIsPhysical(_ url: URL, home: URL) -> Bool { dependencies.isPhysicalPath(url, home) }
    private func uninstallRequiresAdministrator(_ path: String) -> Bool { dependencies.requiresAdministrator(path) }
    private func runCommandOutput(_ executable: String, _ arguments: [String]) -> String? { dependencies.commandOutput(executable, arguments) }

    func plan(for app: UninstallApp, homeDirectory: String) -> UninstallPlan? {
        let appURL = URL(fileURLWithPath: app.path).standardizedFileURL
        guard applicationMetadata(at: appURL)?.bundleID == app.bundleID,
              DeletionPlan.identity(at: app.path) == app.appIdentity,
              DeletionPlan.identity(at: app.path + "/Contents/Info.plist") == app.infoIdentity else {
            return nil
        }
        let home = URL(fileURLWithPath: homeDirectory, isDirectory: true).standardizedFileURL
        var files = [UninstallFile(
            bytes: directorySize(appURL), label: "app", path: appURL.path)]
        // Bundle-ID caches are shared by sibling installs. Keep them when
        // another bundle with the same ID is still present.
        let siblingRoots = applicationRoots(home: home).map(\.0)
            + [appURL.deletingLastPathComponent()]
        let appDirectoryIdentity = applicationDirectoryIdentity(appURL)
        let otherApps = siblingRoots.flatMap { directChildren(of: $0) }.filter { candidate in
            candidate.path != appURL.path && candidate.pathExtension.lowercased() == "app"
                && applicationDirectoryIdentity(candidate) != appDirectoryIdentity
                && !isSymlink(candidate)
        }
        let hasSibling = otherApps.contains {
            applicationMetadata(at: $0)?.bundleID == app.bundleID
        }
        files.append(contentsOf: relatedUninstallCandidates(
            app: app, home: home, hasSibling: hasSibling, otherApps: otherApps))
        let caskToken = nativeBrewCaskToken(for: app)
        return UninstallPlan(files: files, needsAdmin: uninstallRequiresAdministrator(app.path),
                             isBrewCask: caskToken != nil,
                             caskToken: caskToken ?? "-", includesProtectedAppData: true,
                             scannedAt: Date())
    }

    /// Resolve a Homebrew cask without depending on Mole's uninstall bridge.
    /// `brew list --cask <token>` reports the installed artifact paths, which
    /// gives us a stronger match than comparing display names alone.
    private func nativeBrewCaskToken(for app: UninstallApp) -> String? {
        let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .filter { fileManager.isExecutableFile(atPath: $0) }
        guard let brew = candidates.first,
              let tokenList = runCommandOutput(brew, ["list", "--cask", "--full-name"]) else {
            return nil
        }
        let appName = URL(fileURLWithPath: app.path).lastPathComponent.lowercased()
        guard appName.hasSuffix(".app") else { return nil }
        let tokens = tokenList.split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { $0.range(of: "^[A-Za-z0-9@._+/-]+$", options: .regularExpression) != nil }
        // Avoid a potentially expensive `brew list` call for every cask by
        // checking only tokens whose spelling overlaps the app name.
        let appStem = appName.dropLast(4).filter { $0.isLetter || $0.isNumber }
            .lowercased()
        guard !appStem.isEmpty else { return nil }
        for token in tokens {
            let tokenStem = token.filter { $0.isLetter || $0.isNumber }.lowercased()
            guard tokenStem.contains(appStem) || appStem.contains(tokenStem) else { continue }
            guard let listing = runCommandOutput(brew, ["list", "--cask", token]) else { continue }
            if listing.split(whereSeparator: \.isNewline).contains(where: {
                URL(fileURLWithPath: String($0)).lastPathComponent.lowercased() == appName
            }) {
                return token
            }
        }
        return nil
    }

    /// Mixed app data stays review-only. Named app-support locations contribute
    /// only known disposable leaves, never their parent or a vendor-wide root.
    /// 没有登记在 Agent 目录里的 App 也常把数据放在 `~/.name`、`~/.config/name` 等处
    /// （例如 WorkBuddy 的 `~/.workbuddy`）。按 App 名和 Bundle ID 末段关联，名字太短、
    /// 太通用或与其他已安装 App 重名的不关联；Agent 目录已登记的根交给 Agent 规则。
    static let genericDotNames: Set<String> = [
        "config", "local", "cache", "share", "state", "apps", "code", "git", "ssh", "npm",
        "node", "python", "java", "rust", "cargo", "docker", "aws", "azure", "google", "apple",
        "macos", "system", "library", "data", "tools", "home", "user", "users",
        "test", "demo", "default", "lite", "beta", "studio", "desktop", "mail",
        "music", "photos", "notes", "files", "cloud", "sync", "update", "updater", "helper"
    ]

    func dotDirectoryCandidates(for app: UninstallApp, home: URL, otherApps: [URL]) -> [URL] {
        let appURL = URL(fileURLWithPath: app.path)
        var names = Set(uninstallSupportNames(at: appURL, bundleID: app.bundleID).map { $0.lowercased() })
        names.insert(app.name.lowercased())
        names.insert(app.name.lowercased().replacingOccurrences(of: " ", with: ""))
        names.insert(app.name.lowercased().replacingOccurrences(of: " ", with: "-"))
        if let last = app.bundleID.split(separator: ".").last { names.insert(String(last).lowercased()) }
        let shared = Set(otherApps.flatMap { other -> [String] in
            guard let metadata = applicationMetadata(at: other) else { return [] }
            var tokens = uninstallSupportNames(at: other, bundleID: metadata.bundleID).map { $0.lowercased() }
            tokens.append(metadata.name.lowercased())
            if let last = metadata.bundleID.split(separator: ".").last { tokens.append(String(last).lowercased()) }
            return tokens
        })
        let agentRoots = AgentCatalog.definitions.flatMap { AgentCatalog.dataRoots(for: $0, home: home.path) }
        var result: [URL] = []
        for name in names.sorted() where name.count >= 4 && !Self.genericDotNames.contains(name)
            && !shared.contains(name) && name.range(of: #"^[a-z0-9][a-z0-9._-]*$"#, options: .regularExpression) != nil {
            for relative in ["." + name, ".config/" + name, ".local/share/" + name, ".local/state/" + name, ".cache/" + name] {
                let url = home.appendingPathComponent(relative, isDirectory: true)
                guard cleanupPathIsPhysical(url, home: home), isDirectory(url),
                      !agentRoots.contains(where: { url.path == $0 || url.path.hasPrefix($0 + "/") || $0.hasPrefix(url.path + "/") })
                else { continue }
                result.append(url)
            }
        }
        return result
    }

    private func relatedUninstallCandidates(app: UninstallApp, home: URL,
                                            hasSibling: Bool, otherApps: [URL]) -> [UninstallFile] {
        var candidates: [UninstallFile] = []
        var seen = Set<String>()
        func append(_ url: URL, label: String) {
            let path = CleanupRiskPolicy.normalizedPathLiteral(url.path)
            guard seen.insert(path).inserted,
                  fileManager.fileExists(atPath: path), !isSymlink(url) else { return }
            if label == "related" {
                guard cleanupPathIsPhysical(url, home: home),
                      !CleanupRiskPolicy.isProtectedContent(path, homeDirectory: home.path) else { return }
            }
            let bytes = directorySize(url)
            candidates.append(UninstallFile(bytes: bytes, label: label, path: path))
        }

        if CleanupRiskPolicy.isValidReverseDNSOwner(app.bundleID) {
            let cacheLabel = hasSibling ? "review" : "related"
            append(home.appendingPathComponent("Library/Caches/\(app.bundleID)", isDirectory: true),
                   label: cacheLabel)
            append(home.appendingPathComponent("Library/Logs/\(app.bundleID)", isDirectory: true),
                   label: cacheLabel)
            for relative in [
                "Library/Caches/\(app.bundleID).ShipIt",
                "Library/Caches/com.apple.nsurlsessiond/Downloads/\(app.bundleID)",
                "Library/Containers/\(app.bundleID)/Data/Library/Caches",
                "Library/Containers/\(app.bundleID)/Data/Library/Logs",
                "Library/Containers/\(app.bundleID)/Data/tmp",
                "Library/WebKit/\(app.bundleID)/WebsiteData/NetworkCache"
            ] {
                append(home.appendingPathComponent(relative, isDirectory: true), label: cacheLabel)
            }

            let appURL = URL(fileURLWithPath: app.path)
            let supportNames = uninstallSupportNames(at: appURL, bundleID: app.bundleID)
            let sharedNames = Set(otherApps.flatMap { other -> [String] in
                guard let metadata = applicationMetadata(at: other) else { return [] }
                return uninstallSupportNames(at: other, bundleID: metadata.bundleID)
                    .map { $0.lowercased() }
            })
            let leaves = ["Cache", "Caches", "Code Cache", "GPUCache", "DawnCache",
                          "ShaderCache", "GrShaderCache", "CachedData", "CachedExtensionVSIXs",
                          "logs", "Crashpad/completed", "Service Worker/CacheStorage",
                          "Service Worker/ScriptCache"]
            for name in supportNames.sorted() {
                let root = home.appendingPathComponent("Library/Application Support/" + name)
                append(root, label: "review")
                let namedCache = home.appendingPathComponent("Library/Caches/" + name)
                let shared = hasSibling || sharedNames.contains(name.lowercased())
                if CleanupRiskPolicy.core(section: "Uninstall cache", path: namedCache.path,
                                          homeDirectory: home.path).risk == .safe {
                    append(namedCache, label: shared ? "review" : "related")
                }
                guard !shared else { continue }
                // Chromium/Electron profiles are bounded to known direct children.
                // Do not recursively search arbitrary user data for cache-like names.
                var profileRoots = [root]
                if cleanupPathIsPhysical(root, home: home) {
                    profileRoots += directChildren(of: root).filter {
                        $0.lastPathComponent == "Default"
                            || $0.lastPathComponent.range(of: "^Profile [0-9]+$", options: .regularExpression) != nil
                    }
                }
                for profile in profileRoots {
                    for leaf in leaves {
                        let url = profile.appendingPathComponent(leaf)
                        guard CleanupRiskPolicy.core(section: "Uninstall cache", path: url.path,
                                                     homeDirectory: home.path).risk == .safe else { continue }
                        append(url, label: "related")
                    }
                }
            }
        }

        let reviewRoots = [
            ("Library/Application Support/\(app.bundleID)", true),
            ("Library/Preferences/\(app.bundleID).plist", false),
            ("Library/Containers/\(app.bundleID)", true),
            ("Library/Group Containers/\(app.bundleID)", true),
            ("Library/Saved Application State/\(app.bundleID).savedState", true),
            ("Library/WebKit/\(app.bundleID)", true),
            ("Library/HTTPStorages/\(app.bundleID)", true),
            ("Library/Caches/com.apple.nsurlsessiond/Downloads/\(app.bundleID)", true)
        ]
        for (relative, isDirectory) in reviewRoots {
            append(home.appendingPathComponent(relative, isDirectory: isDirectory), label: "review")
        }
        if !hasSibling {
            for root in AgentCatalog.uninstallDataRoots(appPath: app.path, appName: app.name, home: home.path) {
                append(URL(fileURLWithPath: root), label: "review")
            }
            for url in dotDirectoryCandidates(for: app, home: home, otherApps: otherApps) {
                append(url, label: "review")
            }
        }

        // LaunchAgent/Daemon plists and privileged helpers are surfaced with
        // exact bundle evidence. They are intentionally informational until a
        // native administrator route is available; an unrelated system item
        // must never be removed as a side effect of uninstalling an app.
        let identityTokens = [app.bundleID, app.name, app.path,
                              URL(fileURLWithPath: app.path).deletingPathExtension().path]
            .map { $0.lowercased() }
        func matchesApp(_ url: URL) -> Bool {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            let lower = text.lowercased()
            return identityTokens.contains { !$0.isEmpty && lower.contains($0) }
        }
        let plistRoots = [
            home.appendingPathComponent("Library/LaunchAgents", isDirectory: true),
            URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true),
            URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true)
        ]
        for root in plistRoots {
            for plist in directChildren(of: root)
                where plist.pathExtension.lowercased() == "plist" && matchesApp(plist) {
                append(plist, label: "manual")
            }
        }

        let helperRoot = URL(fileURLWithPath: "/Library/PrivilegedHelperTools", isDirectory: true)
        for helper in directChildren(of: helperRoot) {
            let lower = helper.lastPathComponent.lowercased()
            if identityTokens.contains(where: { !$0.isEmpty && lower.contains($0) }) {
                append(helper, label: "manual")
            }
        }

        let diagnosticRoots = [
            home.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true),
            URL(fileURLWithPath: "/Library/Logs/DiagnosticReports", isDirectory: true)
        ]
        for root in diagnosticRoots {
            for report in directChildren(of: root) {
                let lower = report.lastPathComponent.lowercased()
                if identityTokens.contains(where: { !$0.isEmpty && lower.contains($0) }) {
                    append(report, label: "manual")
                }
            }
        }
        return candidates
    }

    private func uninstallSupportNames(at appURL: URL, bundleID: String) -> Set<String> {
        let bundle = Bundle(url: appURL)
        let metadataNames = [bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String,
                             bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                             appURL.deletingPathExtension().lastPathComponent]
            .compactMap { $0 }.filter {
                !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/")
                    && !$0.utf8.contains(where: { $0 < 0x20 || $0 == 0x7f })
                    && !["app", "electron", "google", "microsoft", "adobe", "shared"].contains($0.lowercased())
            }
        let knownNames: [String: String] = [
            "com.google.Chrome": "Google/Chrome",
            "com.google.Chrome.beta": "Google/Chrome Beta",
            "com.microsoft.VSCode": "Code",
            "com.microsoft.VSCodeInsiders": "Code - Insiders",
            "com.brave.Browser": "BraveSoftware/Brave-Browser",
            "company.thebrowser.Browser": "Arc/User Data"
        ]
        var names = Set(metadataNames)
        if CleanupRiskPolicy.isValidReverseDNSOwner(bundleID) { names.insert(bundleID) }
        if let name = knownNames[bundleID] { names.insert(name) }
        return names
    }

}
