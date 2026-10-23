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
        var brewExecutables: [String] = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
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
        UninstallResidueStore.remember([dataOwner(for: app)], home: home.path)
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
        let candidates = dependencies.brewExecutables
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
            // A downloaded copy can have the same filename as a cask. Only
            // the physical bundle owned by Homebrew may use its remover.
            let appIdentity = applicationDirectoryIdentity(URL(fileURLWithPath: app.path))
            if let appIdentity, listing.split(whereSeparator: \.isNewline).contains(where: {
                let artifact = URL(fileURLWithPath: String($0)).resolvingSymlinksInPath().standardizedFileURL
                return artifact.pathExtension.lowercased() == "app"
                    && applicationDirectoryIdentity(artifact) == appIdentity
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
        let managedPaths = AgentCatalog.managedCleanupPaths(home: home.path)
        let basePresence = AgentCatalog.defaultPresenceContext(home: home.path)
        var presence = AgentPresenceContext(applicationDirs: Array(Set(basePresence.applicationDirs
            + applicationRoots(home: home).map { $0.0.path })), searchPath: basePresence.searchPath)
        for url in otherApps {
            if let metadata = applicationMetadata(at: url) {
                presence.applicationPathsByName[metadata.name, default: []].append(url.path)
            }
        }
        let agentData = dataCandidates(for: dataOwner(for: app), home: home.path,
            presence: presence, excludingApplication: app.path)
        func append(_ url: URL, label: String) {
            let path = CleanupRiskPolicy.normalizedPathLiteral(url.path)
            if label != "related" && agentData.contains(where: { $0.path.hasPrefix(path + "/") }) { return }
            guard seen.insert(path).inserted,
                  fileManager.fileExists(atPath: path), !isSymlink(url) else { return }
            if label == "related" {
                guard cleanupPathIsPhysical(url, home: home),
                      !CleanupRiskPolicy.isProtectedContent(path, homeDirectory: home.path) else { return }
            }
            let bytes = directorySize(url)
            // Match the execution boundary before offering a checkbox. A
            // parent containing history cannot be removed as ordinary data.
            let role: String
            if label == "shared" || hasSibling && label != "manual" { role = "shared" }
            else if let candidate = agentData.first(where: { $0.path == path }) {
                role = candidate.removable ? (label == "related" ? "related" : "agentData") : "protected"
            }
            else if label != "manual" && AgentCatalog.isManagedCleanupPath(path, protectedPaths: managedPaths) {
                role = "protected"
            } else if label == "review" {
                role = "protected"
            } else { role = label }
            candidates.append(UninstallFile(bytes: bytes, label: role, path: path))
        }

        if CleanupRiskPolicy.isValidReverseDNSOwner(app.bundleID) {
            let cacheLabel = hasSibling ? "shared" : "related"
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
                let shared = hasSibling || sharedNames.contains(name.lowercased())
                append(root, label: shared ? "shared" : "review")
                let namedCache = home.appendingPathComponent("Library/Caches/" + name)
                if CleanupRiskPolicy.core(section: "Uninstall cache", path: namedCache.path,
                                          homeDirectory: home.path).risk == .safe {
                    append(namedCache, label: shared ? "shared" : "related")
                }
                append(home.appendingPathComponent("Library/Logs/" + name),
                       label: shared ? "shared" : "related")
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
            ("Library/Saved Application State/\(app.bundleID).savedState", true),
            ("Library/WebKit/\(app.bundleID)", true),
            ("Library/HTTPStorages/\(app.bundleID)", true),
            ("Library/HTTPStorages/\(app.bundleID).binarycookies", false),
            ("Library/Caches/com.apple.nsurlsessiond/Downloads/\(app.bundleID)", true)
        ]
        for (relative, isDirectory) in reviewRoots {
            append(home.appendingPathComponent(relative, isDirectory: isDirectory), label: "review")
        }
        if CleanupRiskPolicy.isValidReverseDNSOwner(app.bundleID) {
            let identifier = NSRegularExpression.escapedPattern(for: app.bundleID)
            let groups = inventory.applicationGroups(at: URL(fileURLWithPath: app.path))
            let sharedGroups: Set<String> = groups.isEmpty ? [] : Set(otherApps.flatMap {
                inventory.applicationGroups(at: $0).intersection(groups)
            })
            // Team-prefixed containers are common. Match the complete owner,
            // never a vendor prefix that could include another product.
            let groupPattern = "^([A-Z0-9]{10}\\.)?(group\\.)?" + identifier + "$"
            for relative in ["Library/Group Containers", "Library/Application Scripts"] {
                for url in directChildren(of: home.appendingPathComponent(relative))
                    where groups.contains(url.lastPathComponent)
                        || url.lastPathComponent.range(of: groupPattern, options: .regularExpression) != nil {
                    append(url, label: sharedGroups.contains(url.lastPathComponent) ? "shared" : "review")
                }
            }
            let hostPattern = "^" + identifier + "\\.[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\\.plist$"
            for url in directChildren(of: home.appendingPathComponent("Library/Preferences/ByHost"))
                where url.lastPathComponent.range(of: hostPattern, options: .regularExpression) != nil {
                append(url, label: "review")
            }
        }
        if !hasSibling {
            for candidate in agentData {
                append(URL(fileURLWithPath: candidate.path), label: candidate.removable ? "agentData" : "protected")
            }
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

    /// Exact, owner-named single files only; no globbing beyond these names.
    static func singleFileConfigNames(_ slug: String) -> [String] {
        let extensions = ["toml", "yaml", "yml", "json", "conf", "ini"]
        return extensions.map { ".config/" + slug + "." + $0 }
            + extensions.map { "." + slug + "." + $0 }
            + ["." + slug + "rc", ".config/" + slug + "rc"]
    }

    /// Homebrew keeps per-formula/cask downloads and logs outside the Cellar.
    /// Only entries whose name is exactly the package (plus Homebrew's own
    /// `--version` suffix or `<hash>--<name>` download form) are offered.
    func homebrewResidues(for owner: UninstallDataOwner, home: String) -> [String] {
        guard owner.kind == .cli || owner.kind == .application else { return [] }
        let names = Set(([owner.name] + owner.names).map { $0.split(separator: "/").last.map(String.init) ?? $0 }
            .filter { $0.count >= 3 && $0.range(of: #"^[A-Za-z0-9][A-Za-z0-9@._+-]*$"#, options: .regularExpression) != nil })
        guard !names.isEmpty else { return [] }
        var result: [String] = []
        for name in names {
            result.append("Library/Logs/Homebrew/" + name)
        }
        let cache = "Library/Caches/Homebrew"
        for relativeRoot in [cache, cache + "/downloads", cache + "/Cask"] {
            for url in directChildren(of: URL(fileURLWithPath: home + "/" + relativeRoot)) {
                let file = url.lastPathComponent
                let matches = names.contains { name in
                    file.hasPrefix(name + "--") || file == name
                        || file.range(of: "^[0-9a-f]{64}--" + NSRegularExpression.escapedPattern(for: name) + "--",
                                      options: .regularExpression) != nil
                }
                if matches { result.append(relativeRoot + "/" + file) }
            }
        }
        return result
    }

    func dataOwner(for app: UninstallApp) -> UninstallDataOwner {
        .init(kind: .application, name: app.name, bundleID: app.bundleID, installationPath: app.path,
              names: uninstallSupportNames(at: URL(fileURLWithPath: app.path), bundleID: app.bundleID).sorted(),
              groups: applicationGroups(at: URL(fileURLWithPath: app.path)).sorted(),
              agentIDs: AgentCatalog.applicationAgentIDs(appPath: app.path, appName: app.name))
    }

    func ownerIsInstalled(_ owner: UninstallDataOwner, home: String, presence: AgentPresenceContext,
                          excludingApplication: String? = nil) -> Bool {
        if owner.kind == .agent {
            return AgentCatalog.definitions.contains {
                owner.agentIDs.contains($0.id) && AgentCatalog.isInstalled($0, home: home, presence: presence)
            }
        }
        if !owner.installationPath.isEmpty, owner.installationPath != excludingApplication,
           fileManager.fileExists(atPath: owner.installationPath) { return true }
        if owner.commands.contains(where: {
            AgentCatalog.resolveExecutable($0, searchPath: presence.searchPath, home: home) != nil
        }) { return true }
        for root in presence.applicationDirs {
            for app in directChildren(of: URL(fileURLWithPath: root))
                where app.pathExtension.lowercased() == "app" && !isSymlink(app) && app.path != excludingApplication {
                if let excluded = excludingApplication,
                   applicationDirectoryIdentity(app) == applicationDirectoryIdentity(URL(fileURLWithPath: excluded)) { continue }
                let metadata = applicationMetadata(at: app)
                if !owner.bundleID.isEmpty && metadata?.bundleID == owner.bundleID { return true }
                let names = [app.deletingPathExtension().lastPathComponent, metadata?.name ?? ""].map { $0.lowercased() }
                if owner.kind == .cli && names.contains(owner.name.lowercased()) { return true }
            }
        }
        return false
    }

    /// The same derived roots serve application, generic CLI and leftover scans.
    /// A persisted owner is metadata only; it cannot grant permission to a path.
    func dataCandidates(for owner: UninstallDataOwner, home: String, presence: AgentPresenceContext,
                        excludingApplication: String? = nil, protectedRoots: [String] = []) -> [AgentCatalog.UninstallDataCandidate] {
        if owner.kind == .agent {
            return AgentCatalog.fullUninstallDataCandidates(agentIDs: owner.agentIDs, home: home,
                presence: presence, excludingApplication: excludingApplication, protectedRoots: protectedRoots)
        }
        var relative: [String] = []
        let aliases = [owner.name, owner.name.replacingOccurrences(of: " ", with: ""),
                      owner.name.replacingOccurrences(of: " ", with: "-"), owner.bundleID.split(separator: ".").last.map(String.init) ?? ""]
        let tokens = Set(owner.names + aliases).filter { name in
            name.count >= 3 && (owner.kind == .application || !Self.genericDotNames.contains(name.lowercased()))
                && !["app", "electron", "google", "microsoft", "adobe", "shared"].contains(name.lowercased())
                && !["Nori", "ForgeSweep"].contains(name)
                && name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                    !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(where: { $0.asciiValue.map { $0 < 32 || $0 == 127 } ?? false })
                }
        }
        for token in tokens {
            for root in ["Library/Application Support", "Library/Caches", "Library/Logs"] {
                relative.append(root + "/" + token)
            }
            let slug = token.lowercased()
            if !Self.genericDotNames.contains(slug),
               slug.range(of: #"^[a-z0-9][a-z0-9._-]*$"#, options: .regularExpression) != nil {
                relative += ["." + slug, ".config/" + slug, ".local/share/" + slug, ".local/state/" + slug, ".cache/" + slug]
                // Single-file configs (e.g. ~/.config/starship.toml, ~/.foorc)
                // are as much a tool's data as its directories.
                relative += Self.singleFileConfigNames(slug)
            }
        }
        relative += homebrewResidues(for: owner, home: home)
        if owner.kind == .application, CleanupRiskPolicy.isValidReverseDNSOwner(owner.bundleID),
           !owner.bundleID.hasPrefix("com.apple.") {
            let identifier = owner.bundleID
            relative += ["Library/Preferences/" + identifier + ".plist", "Library/Containers/" + identifier,
                         "Library/Saved Application State/" + identifier + ".savedState",
                         "Library/WebKit/" + identifier, "Library/HTTPStorages/" + identifier,
                         "Library/HTTPStorages/" + identifier + ".binarycookies",
                         "Library/Caches/" + identifier + ".ShipIt",
                         "Library/Caches/com.apple.nsurlsessiond/Downloads/" + identifier]
            let pattern = "^([A-Z0-9]{10}\\.)?(group\\.)?" + NSRegularExpression.escapedPattern(for: identifier) + "$"
            for root in ["Library/Group Containers", "Library/Application Scripts"] {
                for url in directChildren(of: URL(fileURLWithPath: home + "/" + root))
                    where owner.groups.contains(url.lastPathComponent)
                        || url.lastPathComponent.range(of: pattern, options: .regularExpression) != nil {
                    relative.append(root + "/" + url.lastPathComponent)
                }
            }
            let hostPattern = "^" + NSRegularExpression.escapedPattern(for: identifier)
                + "\\.[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\\.plist$"
            for url in directChildren(of: URL(fileURLWithPath: home + "/Library/Preferences/ByHost"))
                where url.lastPathComponent.range(of: hostPattern, options: .regularExpression) != nil {
                relative.append("Library/Preferences/ByHost/" + url.lastPathComponent)
            }
        }
        var blocked = protectedRoots
        let agentRoots = AgentCatalog.definitions.filter { !owner.agentIDs.contains($0.id) }
            .flatMap { AgentCatalog.dataRoots(for: $0, home: home) }
            .filter { AgentCatalog.isPhysical($0, home: home) }
        // Split parents around other Agent data rather than letting a legacy
        // broad review row bypass the ownership/project checks.
        blocked += agentRoots
        let roots = Set(relative.map { home + "/" + $0 })
        for root in presence.applicationDirs {
            for app in directChildren(of: URL(fileURLWithPath: root))
                where app.pathExtension.lowercased() == "app" && !isSymlink(app) && app.path != excludingApplication {
                if let excluded = excludingApplication,
                   applicationDirectoryIdentity(app) == applicationDirectoryIdentity(URL(fileURLWithPath: excluded)) { continue }
                guard let metadata = applicationMetadata(at: app) else { continue }
                let sharedNames = uninstallSupportNames(at: app, bundleID: metadata.bundleID)
                for name in tokens where sharedNames.contains(where: { $0.lowercased() == name.lowercased() }) {
                    for parent in ["Library/Application Support", "Library/Caches", "Library/Logs"] { blocked.append(home + "/" + parent + "/" + name) }
                }
                for group in (owner.groups.isEmpty ? [] : applicationGroups(at: app).intersection(owner.groups)) {
                    blocked += [home + "/Library/Group Containers/" + group, home + "/Library/Application Scripts/" + group]
                }
            }
        }
        let candidates = AgentCatalog.fullUninstallDataCandidates(agentIDs: owner.agentIDs, home: home,
            presence: presence, excludingApplication: excludingApplication,
            additionalRoots: Array(roots), protectedRoots: blocked)
        guard !ownerIsInstalled(owner, home: home, presence: presence, excludingApplication: excludingApplication) else {
            return candidates.map { .init(path: $0.path, removable: false) }
        }
        return candidates
    }

    private func uninstallSupportNames(at appURL: URL, bundleID: String) -> Set<String> {
        UninstallResidueMemo.value("supportNames\u{1F}" + appURL.path + "\u{1F}" + bundleID) {
            uncachedUninstallSupportNames(at: appURL, bundleID: bundleID)
        }
    }

    private func applicationGroups(at url: URL) -> Set<String> {
        UninstallResidueMemo.value("groups\u{1F}" + url.path) { inventory.applicationGroups(at: url) }
    }

    private func uncachedUninstallSupportNames(at appURL: URL, bundleID: String) -> Set<String> {
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

/// Retain names/IDs after external uninstall, including after Trash is emptied.
/// This file stores no selection or deletion permission.
enum UninstallResidueStore {
    private static let lock = NSLock()
    private static func url(home: String) -> URL {
        URL(fileURLWithPath: home + "/Library/Application Support/Nori/uninstall-owners.json")
    }
    private static func read(home: String) -> [UninstallDataOwner] {
        guard let data = try? Data(contentsOf: url(home: home)), data.count <= 4 * 1024 * 1024,
              let owners = try? JSONDecoder().decode([UninstallDataOwner].self, from: data) else { return [] }
        return owners
    }
    static func owners(home: String) -> [UninstallDataOwner] {
        lock.lock(); defer { lock.unlock() }
        return read(home: home)
    }
    static func remember(_ owners: [UninstallDataOwner], home: String) {
        guard !owners.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var records = Dictionary(read(home: home).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for var owner in owners {
            if let prior = records[owner.id] {
                owner.names = Array(Set(owner.names + prior.names)).sorted()
                owner.groups = Array(Set(owner.groups + prior.groups)).sorted()
            }
            records[owner.id] = owner
        }
        guard let data = try? JSONEncoder().encode(Array(records.values).sorted { $0.id < $1.id }) else { return }
        let target = url(home: home)
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: target, options: .atomic)
    }
}
