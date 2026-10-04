"""Patch temporary renderer inputs only; never the product checkout or user home."""
from pathlib import Path
import sys

root = Path(sys.argv[1]) / "SimpleMole"


def replace_body(source, marker, body):
    start = source.index(marker)
    opening = source.index("{", start)
    depth, closing = 1, opening + 1
    while depth:
        depth += (source[closing] == "{") - (source[closing] == "}")
        closing += 1
    return source[:opening + 1] + "\n" + body + "\n    " + source[closing - 1:]


def patch(relative, replacements):
    path = root / relative
    source = path.read_text()
    for marker, body in replacements:
        source = replace_body(source, marker, body)
    path.write_text(source)


patch("Services/DeveloperWorkspaceModel.swift", [
    ("    func refresh(forceEnvironment:", """        terminal = ReadmeFixture.terminal
        versions = ReadmeFixture.managedVersions
        javaHomes = ["/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home"]
        xcodes = ["/Applications/Xcode.app/Contents/Developer"]
        selectedXcode = xcodes[0]
        xcodeLicenseRequired = false
        environmentIssues = [.init(id: "fixture-path", titleKey: "dev.issue.path.dead", detail: "/Users/demo/.local/legacy/bin", section: .shell, severity: .suggestion)]
        isRefreshing = false"""),
    ("    func loadPackages(checkUpdates:", """        packages = ReadmeFixture.packages
        isLoadingPackages = false"""),
])

patch("Views/DeveloperShellPanel.swift", [
    ("    func refresh() async {", """        inventory = ReadmeFixture.shellInventory
        included = inventory?.included ?? []
        javaHomes = ["/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home"]
        profiles = inventory?.profiles ?? []
        if ReadmeFixture.shellDraft, let profile = profiles.first(where: { $0.name == ".zshrc" }), let declaration = DeveloperShellService.pathDeclarations(in: profile).first {
            var items = declaration.items
            items.insert(.directory([.literal("/Users/demo/new/bin")]), at: 0)
            rememberPathDraft(items, for: declaration)
        }
        isRefreshing = false"""),
    ("    private func refreshPathCommands(in directories:", """        commandInventories = Dictionary(uniqueKeysWithValues: directories.map { ($0, .init(names: ["git", "node", "npm", "python3", "uv"], status: .available)) })"""),
    ("    func directoryExists(_ path:", "        true"),
    ("    private func reload() async {", """        do {
            history = try DeveloperShellBackupStore.history(targetPath: profile.path, home: home)
            selected = history.first
            if let selected { text = try DeveloperShellBackupStore.read(selected, targetPath: profile.path, home: home) }
        } catch { failure = DeveloperShellCopy.failure(error as? DeveloperShellService.Failure ?? .unreadable) }"""),
])

path = root / "Views/DeveloperShellPanel.swift"
source = path.read_text().replace("@State private var selectedFileIndex = 2", "@State private var selectedFileIndex = ReadmeFixture.shellFileIndex")
source = source.replace("else { selectedFileIndex = 2 }", "else { selectedFileIndex = ReadmeFixture.shellFileIndex }")
source = source.replace("DeveloperShellService.knownEnvironment(profiles)", "DeveloperShellService.knownEnvironment(profiles, home: ReadmeFixture.shellDirectory.path)")
source = source.replace("DeveloperShellService.knownEnvironment(before: declaration.variable, in: profiles)", "DeveloperShellService.knownEnvironment(before: declaration.variable, in: profiles, home: ReadmeFixture.shellDirectory.path)")
source += '''
struct ReadmeShellBackupSheetScreenshot: View {
    let profile: DeveloperShellService.Profile
    @ObservedObject var model: DeveloperShellModel
    @State private var presented = false
    var body: some View {
        ScrollView { DeveloperShellPanel(model: model).padding(16) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { GlassSurface().ignoresSafeArea() }
            .sheet(isPresented: $presented) { DeveloperShellBackupPanel(profile: profile, model: model) }
            .onAppear { presented = true }
    }
}
'''
path.write_text(source)

patch("Views/DeveloperWorkspaceComponents.swift", [
    ("    static func abbreviate(_ path:", '''        let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NORI_README_FIXTURE_ROOT"]!).appendingPathComponent("demo-shell").path
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path'''),
])

patch("Views/DeveloperCLIPanel.swift", [
    ("    func refresh(for token:", """        snapshot = ReadmeFixture.cliSnapshot
        completedRefreshToken = token
        isChecking = false"""),
])

patch("Views/DeveloperSSHGitPanel.swift", [
    ("    func refresh(environment:", """        keys = ReadmeFixture.sshKeys
        config = ReadmeFixture.sshConfig
        git = ["user.name": "Demo Developer", "user.email": "demo@example.com", "credential.helper": "osxkeychain", "commit.gpgsign": "true", "gpg.format": "ssh"]
        gitAudited = true
        agentSocketAvailable = true
        agentFingerprints = Set(keys.map(\\.fingerprint))
        agentLoadedKeys = keys.count
        hasRefreshed = true
        isRefreshing = false"""),
])

patch("Views/DeveloperNetworkPanel.swift", [
    ("    func refresh() async {", """        snapshot = ReadmeFixture.networkSnapshot
        isLoading = false"""),
])

patch("Views/DeveloperNetworkToolsPanel.swift", [
    ("    func refresh() async {", """        snapshot = ReadmeFixture.networkToolsSnapshot
        probes = [.init(url: "https://github.com", route: "dev.network.direct", status: 200, milliseconds: 238),
                  .init(url: "https://github.com", route: "dev.network.viaProxy", status: 200, milliseconds: 82),
                  .init(url: "https://raw.githubusercontent.com", route: "dev.network.direct", status: 0, milliseconds: nil),
                  .init(url: "https://raw.githubusercontent.com", route: "dev.network.viaProxy", status: 200, milliseconds: 95),
                  .init(url: "https://registry-1.docker.io/v2/", route: "dev.network.direct", status: 401, milliseconds: 135)]
        mirrorProbes = ["npm": .init(url: "https://registry.npmjs.org", route: "dev.network.direct", status: 200, milliseconds: 164)]
        isLoading = false"""),
])

# The real root workspace makes these read-only refreshes on entry. A fixture
# capture must never start real audits, subprocesses, or filesystem inventories.
patch("AppState.swift", [
    ("    func runConfigAudits(force:", "        return"),
    ("    func scanDevEnv(announce:", "        return"),
    ("    func scanGc(force:", "        return"),
    ("    func refreshPorts() {", "        return"),
])

path = root / "Views/DevEnvTabView.swift"
source = path.read_text()
marker = '@AppStorage("devWorkspaceSectionID") private var selection = DeveloperWorkspaceSection.overview.rawValue'
assert marker in source
source = source.replace(marker, '@State private var selection = ReadmeFixture.section.rawValue')
source = source.replace("            DeveloperNetworkPanel(state: state, model: networkModel, workspace: workspace)", "            if ReadmeFixture.detail != \"tools\" { DeveloperNetworkPanel(state: state, model: networkModel, workspace: workspace) }")
path.write_text(source)

# Fallback initializers also carry synthetic paths, before async tasks settle.
patch("Services/DeveloperTerminalEnvironment.swift", [
    ("    static func fallback() -> DeveloperTerminalSnapshot {", '        .init(environment: ["HOME": "/Users/demo", "PATH": "/opt/homebrew/bin:/usr/bin:/bin"], shell: "/bin/zsh", sampledAt: nil, duration: nil, failed: false)'),
])

# These accessibility environment keys are read-only in SwiftUI. Override the
# consumers in the isolated compile copy, without changing system preferences.
import re
for path in root.rglob("*.swift"):
    source = path.read_text()
    for key, fixture in [("accessibilityReduceMotion", "reducesMotion"),
                         ("accessibilityReduceTransparency", "reducesTransparency")]:
        pattern = r"@Environment\(\\\." + key + r"\)\s+(private\s+)?var\s+(\w+)"
        source = re.sub(pattern, lambda match: (match[1] or "") + "var " + match[2] + ": Bool { ReadmeFixture." + fixture + " }", source)
    path.write_text(source)

# The renderer has no updater lifecycle and does not link or start Sparkle.
(root / "Services/AppUpdateController.swift").write_text('''import AppKit
import Combine
@MainActor final class AppUpdateController: NSObject, ObservableObject, NSMenuItemValidation {
    static let shared = AppUpdateController()
    enum Status: Equatable { case idle, checking, updateAvailable(String), upToDate, deferred, failed(String) }
    @Published var status: Status = .idle
    @Published var canCheckForUpdates = false
    @Published var automaticallyUpdates = false
    func start(isSafeToRelaunch: @escaping () -> Bool) {}
    func stop() {}
    func checkForUpdates() {}
    @objc func checkForUpdatesFromMenu(_ sender: Any?) {}
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { false }
}
''')
