import Darwin
import Foundation

private final class CountingAgentApplicationSizer: ApplicationSizeMeasuring, @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    func allocatedBytes(at root: URL) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        paths.append(root.path)
        return 8192
    }

    var measuredPaths: [String] {
        lock.lock(); defer { lock.unlock() }
        return paths
    }
}

@main
struct AgentSoftwareInventoryTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func main() throws {
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath().standardizedFileURL
        expect(fixture.lastPathComponent.hasPrefix(".agent-software-fixture."), "Unowned fixture")
        try testCatalogMatching()
        try testApplicationScope(at: fixture)
        try testCLIConversion(at: fixture)
        print("Agent software inventory: catalog matching, physical installs, scoped sizing and shared CLI conversion passed")
    }

    static func app(name: String, bundleID: String, path: String) -> UninstallApp {
        .init(name: name, bundleID: bundleID, source: "Fixture", path: path,
              size: "", appIdentity: "fixture", infoIdentity: "fixture")
    }

    static func testCatalogMatching() throws {
        for agent in AgentCatalog.definitions {
            for name in AgentCatalog.installationPresence(for: agent)?.bundleNames ?? [] {
                let named = app(name: name, bundleID: "com.fixture.agent", path: "/fixture/Renamed.app")
                expect(AgentSoftwareInventory.agentIDs(for: named).contains(agent.id),
                       "Catalog display-name match missing for \(agent.id)")
                let filename = app(name: "Renamed", bundleID: "com.fixture.agent", path: "/fixture/\(name).app")
                expect(AgentSoftwareInventory.agentIDs(for: filename).contains(agent.id),
                       "Catalog bundle-name match missing for \(agent.id)")
            }
            for owner in agent.owners where CleanupRiskPolicy.isValidReverseDNSOwner(owner) {
                let integrated = app(name: "Other host", bundleID: owner, path: "/fixture/Other host.app")
                expect(AgentSoftwareInventory.agentIDs(for: integrated).contains(agent.id),
                       "Catalog bundle ID match missing for \(agent.id)")
            }
        }
        for host in [app(name: "Code", bundleID: "com.microsoft.VSCode", path: "/fixture/Visual Studio Code.app"),
                     app(name: "Google Chrome", bundleID: "com.google.Chrome", path: "/fixture/Google Chrome.app"),
                     app(name: "copilot", bundleID: "copilot", path: "/fixture/Extension host.app")] {
            expect(AgentSoftwareInventory.agentIDs(for: host).isEmpty,
                   "An extension host or process name was mistaken for an Agent application")
        }
    }

    static func testApplicationScope(at fixture: URL) throws {
        let fm = FileManager.default
        let applications = fixture.appendingPathComponent("Applications")
        let otherRoot = fixture.appendingPathComponent("Other Applications")
        try fm.createDirectory(at: applications, withIntermediateDirectories: true)
        try fm.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        func make(_ filename: String, name: String, bundleID: String, root: URL) throws -> URL {
            let app = root.appendingPathComponent(filename + ".app")
            try fm.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleName": name, "CFBundleIdentifier": bundleID,
                "CFBundlePackageType": "APPL", "CFBundleExecutable": filename]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
            return app
        }
        let cursor = try make("Cursor", name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92", root: applications)
        let claude = try make("Claude", name: "Claude", bundleID: "com.anthropic.claudefordesktop", root: applications)
        let integrated = try make("ChatGPT", name: "ChatGPT", bundleID: "com.openai.codex", root: applications)
        let copy = try make("Cursor copy", name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92", root: otherRoot)
        for number in 0..<24 {
            _ = try make("Unrelated \(number)", name: "Unrelated \(number)",
                         bundleID: "com.fixture.unrelated\(number)", root: applications)
        }
        _ = try make("Visual Studio Code", name: "Code", bundleID: "com.microsoft.VSCode", root: applications)
        let alias = fixture.appendingPathComponent("Applications alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: applications)
        try fm.createSymbolicLink(at: applications.appendingPathComponent("Linked Cursor.app"), withDestinationURL: cursor)
        let sizer = CountingAgentApplicationSizer()
        let presence = AgentPresenceContext(applicationDirs: [applications.path, alias.path, otherRoot.path,
                                                             fixture.appendingPathComponent("Missing").path], searchPath: [])
        let apps = AgentSoftwareInventory.applications(home: fixture.path, presence: presence, sizer: sizer)
        expect(Set(apps["cursor", default: []].map(\.path)) == [cursor.path, copy.path],
               "Distinct physical installations must survive Bundle ID/name overlap")
        expect(apps["claude-code"]?.first?.path == claude.path && apps["claude-desktop"]?.first?.path == claude.path,
               "Shared catalog application evidence must be available to each Agent")
        expect(apps["codex"]?.first?.path == integrated.path && apps["codex-app"]?.first?.path == integrated.path,
               "Integrated hosts use catalog Bundle ID evidence")
        expect(Set(sizer.measuredPaths) == [cursor.path, claude.path, integrated.path, copy.path]
               && sizer.measuredPaths.count == 4,
               "Only matched physical Agent bundles may be measured, once each")
        for app in apps.values.flatMap({ $0 }) {
            expect(app.appIdentity == DeletionPlan.identity(at: app.path)
                   && app.infoIdentity == DeletionPlan.identity(at: app.path + "/Contents/Info.plist")
                   && app.size == ByteFormat.format(8192),
                   "Application rows must carry bounded size and captured bundle evidence")
        }
    }

    static func testCLIConversion(at fixture: URL) throws {
        let fm = FileManager.default
        let package = fixture.appendingPathComponent("owned-prefix/lib/node_modules/owned-fixture")
        let launcher = fixture.appendingPathComponent("owned-prefix/bin/fixture")
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        try fm.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"name":"owned-fixture","version":"4.2.1"}"#.utf8)
            .write(to: package.appendingPathComponent("package.json"))
        try Data("fixture".utf8).write(to: launcher)
        let mapping: [(AgentCLIInstallation.Manager, CommandLineTool.Manager)] = [
            (.npm, .npm), (.pnpm, .pnpm), (.homebrew, .homebrew), (.pipx, .pipx), (.uv, .uv),
            (.native, .local), (.bun, .local)
        ]
        for (manager, expected) in mapping {
            let installation = AgentCLIInstallation(id: "owned-\(manager.rawValue)", agentID: "fixture",
                name: "Fixture Agent", executablePaths: [launcher.path], managedPaths: [package.path],
                manager: manager, managerExecutable: fixture.path + "/owned-manager", packageName: "owned-fixture",
                identities: [package.path: DeletionPlan.identity(at: package.path)!], detail: "Owned fixture")
            let unknown = AgentSoftwareInventory.commandLineTool(for: installation)
            let tool = AgentSoftwareInventory.commandLineTool(for: installation, bytes: 24576, sizeIsKnown: true)
            expect(tool.manager == expected && tool.path == package.path && tool.version == "4.2.1",
                   "Manager, managed path and version changed during CLI projection")
            expect(tool.agentID == installation.agentID && tool.agentInstallation == installation
                   && tool.executablePaths == installation.executablePaths && tool.canUninstall,
                   "The shared workflow must retain the reviewed Agent installation")
            expect(tool.managerExecutable == installation.managerExecutable && tool.bytes == 24576 && tool.sizeIsKnown
                   && unknown.bytes == 0 && !unknown.sizeIsKnown,
                   "Projection must preserve capacity evidence without doing its own scan")
            expect(tool.supportsPublicRegistryUpdates == (expected != .local),
                   "Native and bun removers cannot become generic registry updates")
        }
        let native = AgentCLIInstallation(id: "owned-native", agentID: "fixture", name: "Fixture Agent",
            executablePaths: [launcher.path], managedPaths: [], manager: .native, managerExecutable: nil,
            packageName: nil, identities: [:], detail: "Owned launcher")
        let fallback = AgentSoftwareInventory.commandLineTool(for: native)
        expect(fallback.path == launcher.path && fallback.version.isEmpty && fallback.name == native.name
               && fallback.canUninstall, "A native Agent launcher is distinct from a read-only runtime")
        let runtime = CommandLineTool(manager: .local, name: "python", version: "", path: launcher.path,
            bytes: 0, dependents: [], installedOnRequest: true)
        expect(!runtime.canUninstall, "Projection must not enable arbitrary local runtime removal")
        try Data(#"{"name":"another-package","version":"99.0"}"#.utf8)
            .write(to: package.appendingPathComponent("package.json"))
        let mismatch = AgentCLIInstallation(id: "mismatch", agentID: "fixture", name: "Fixture Agent",
            executablePaths: [launcher.path], managedPaths: [package.path], manager: .npm,
            managerExecutable: nil, packageName: "owned-fixture", identities: [:], detail: "Owned fixture")
        expect(AgentSoftwareInventory.commandLineTool(for: mismatch).version.isEmpty,
               "A different package manifest cannot supply the displayed version")
    }
}
