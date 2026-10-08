import SwiftUI
import AppKit

struct DeveloperOverviewPanel: View {
    @ObservedObject var workspace: DeveloperWorkspaceModel
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    let issues: [DeveloperEnvironmentIssue]
    let navigate: (DeveloperWorkspaceSection) -> Void
    @State private var restoreManifest: DeveloperSnapshotService.Manifest?
    @State private var selectedRestoreItems: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DevCard(id: "dev-health") {
                DevCardTitle(symbol: "checkmark.shield", title: l10n.t("dev.overview.title"), subtitle: l10n.tf(issues.count == 1 ? "dev.overview.count.single" : "dev.overview.count", issues.count))
                Spacer()
                if workspace.isRefreshing { ProgressView().controlSize(.small) }
            } content: {
                if issues.isEmpty {
                    DevNotice(symbol: "checkmark.circle", text: l10n.t(workspace.isRefreshing ? "dev.overview.pending" : "dev.overview.empty"), color: .success)
                } else {
                    DeveloperIssueList(issues: issues, navigate: navigate)
                }
            }
            DevCard(id: "dev-terminal-environment") {
                DevCardTitle(symbol: "terminal", title: l10n.t("dev.environment.title"), subtitle: environmentStatus)
                Spacer()
                DevLinkButton(title: l10n.t(workspace.terminal.isSampled ? "dev.environment.refresh" : "dev.environment.connect"), symbol: "arrow.clockwise") { connectEnvironment() }
                    .disabled(workspace.isRefreshing || workspace.commandRunning)
            } content: {
                DevDivider()
                HStack {
                    Text(workspace.terminal.shell).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    if let sampledAt = workspace.terminal.sampledAt { Text(sampledAt, style: .time).font(.system(size: 10)).foregroundStyle(.tertiary) }
                    Spacer()
                    if UserDefaults.standard.bool(forKey: DeveloperTerminalEnvironmentService.enabledKey) {
                        DevLinkButton(title: l10n.t("dev.environment.disconnect"), symbol: "pause.circle") {
                            UserDefaults.standard.set(false, forKey: DeveloperTerminalEnvironmentService.enabledKey)
                            Task { await workspace.refresh(forceEnvironment: true); workspace.didChangeEnvironment() }
                        }
                    }
                }.padding(14)
            }
            DevCard(id: "dev-snapshot") {
                DevCardTitle(symbol: "doc.on.doc", title: l10n.t("dev.snapshot.title"))
                Spacer()
                DevLinkButton(title: l10n.t("dev.snapshot.export"), symbol: "square.and.arrow.up", action: exportSnapshot)
                DevLinkButton(title: l10n.t("dev.snapshot.import"), symbol: "square.and.arrow.down", action: importSnapshot)
            } content: { EmptyView() }
        }
        .sheet(isPresented: Binding(get: { restoreManifest != nil }, set: { if !$0 { restoreManifest = nil } })) { restoreSheet }
    }

    private var environmentStatus: String { l10n.t(workspace.terminal.failed ? "dev.environment.failed" : workspace.terminal.isSampled ? "dev.environment.sampled" : "dev.environment.fallback") }

    private func connectEnvironment() {
        if UserDefaults.standard.bool(forKey: DeveloperTerminalEnvironmentService.enabledKey) {
            Task { await workspace.refresh(forceEnvironment: true); workspace.didChangeEnvironment() }
        } else {
            state.confirmation = .init(title: l10n.t("dev.environment.connect"), message: l10n.t("dev.environment.confirm"), confirmLabel: l10n.t("dev.environment.connect")) {
                UserDefaults.standard.set(true, forKey: DeveloperTerminalEnvironmentService.enabledKey)
                Task { await workspace.refresh(forceEnvironment: true); workspace.didChangeEnvironment() }
            }
        }
    }

    private func exportSnapshot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        Task {
            do {
                if workspace.packages.packages.isEmpty { await workspace.loadPackages() }
                let url = try await DeveloperSnapshotService.export(to: directory, versions: workspace.versions,
                                                                    packages: workspace.packages.packages, environment: workspace.terminal.environment)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { workspace.operationError = l10n.t("dev.snapshot.failed") }
        }
    }

    private func importSnapshot() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let manifest = try DeveloperSnapshotService.read(from: url)
            restoreManifest = manifest
            selectedRestoreItems = Set(manifest.items.map(\.id))
        } catch { workspace.operationError = l10n.t("dev.snapshot.failed") }
    }

    private var restoreSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l10n.t("dev.snapshot.preview")).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(restoreManifest?.items ?? []) { item in
                        Toggle(isOn: Binding(get: { selectedRestoreItems.contains(item.id) }, set: { if $0 { selectedRestoreItems.insert(item.id) } else { selectedRestoreItems.remove(item.id) } })) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.manager + " · " + item.name + " " + item.version)
                                if item.isDefault { Text(l10n.t("dev.toolchain.default")).font(.system(size: 10)).foregroundStyle(.secondary) }
                                if item.command(environment: workspace.terminal.environment) == nil { Text(l10n.t("dev.operation.unavailable")).font(.system(size: 10)).foregroundStyle(.secondary) }
                            }
                        }
                        .disabled(item.command(environment: workspace.terminal.environment) == nil)
                    }
                }
            }.frame(maxHeight: 340)
            ScrollView {
                Text(restoreCommands.map(\.display).joined(separator: "\n"))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 120)
            HStack {
                Spacer()
                Button(l10n.t("common.cancel")) { restoreManifest = nil }.buttonStyle(SecondaryButtonStyle())
                Button(l10n.t("dev.snapshot.restore")) {
                    let commands = restoreCommands
                    restoreManifest = nil
                    for command in commands { workspace.enqueue(command) }
                }.buttonStyle(PrimaryButtonStyle()).disabled(restoreCommands.isEmpty)
            }
        }.padding(20).frame(width: 570).modifier(ListRowSurface())
    }
    private var restoreCommands: [DeveloperCommand] {
        DeveloperSnapshotService.restoreCommands((restoreManifest?.items ?? []).filter { selectedRestoreItems.contains($0.id) && $0.command(environment: workspace.terminal.environment) != nil }, environment: workspace.terminal.environment, installed: workspace.versions)
    }
}

private struct DeveloperIssueList: View {
    let issues: [DeveloperEnvironmentIssue]
    let navigate: (DeveloperWorkspaceSection) -> Void
    @ObservedObject private var l10n = L10n.shared
    var body: some View {
        ForEach(DeveloperEnvironmentIssue.Severity.allCases, id: \.rawValue) { severity in
            let group = issues.filter { $0.severity == severity }
            if !group.isEmpty {
                DevDivider()
                DevSubheader(title: l10n.t(severity.titleKey))
                ForEach(group) { issue in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: severity == .attention ? "exclamationmark.triangle" : "info.circle")
                            .foregroundStyle(severity == .attention ? Color.warning : Color.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(l10n.t(issue.titleKey)).font(.system(size: 12, weight: .medium))
                            if !issue.detail.isEmpty { Text(issue.detail).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                        Spacer(minLength: 8)
                        DevLinkButton(title: l10n.t("dev.overview.open"), symbol: "arrow.right") { navigate(issue.section) }
                    }.padding(14)
                }
            }
        }
    }
}

struct DeveloperToolchainPanel: View {
    @ObservedObject var workspace: DeveloperWorkspaceModel
    @ObservedObject var state: AppState
    @ObservedObject var shell: DeveloperShellModel
    @ObservedObject private var l10n = L10n.shared
    @State private var installManager: DeveloperManager?
    @State private var installVersion = ""
    @State private var candidate = "java"
    @State private var ltsOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(l10n.t("dev.section.toolchains")).font(.system(size: 15, weight: .semibold))
                Spacer()
                Menu(l10n.t("dev.toolchain.install")) {
                    ForEach(DeveloperManager.allCases) { manager in
                        Button(manager.displayName) { installManager = manager; installVersion = ""; candidate = manager == .asdf ? "nodejs" : "java" }
                    }
                }.menuStyle(.borderlessButton).fixedSize()
            }
            if workspace.versions.isEmpty { DevNotice(symbol: "hammer", text: l10n.t("dev.toolchain.empty")) }
            ForEach(DeveloperManager.allCases.filter { manager in workspace.versions.contains { $0.manager == manager } }) { manager in
                DevCard(id: "dev-manager-" + manager.id) {
                    DevCardTitle(symbol: "shippingbox", title: manager.displayName)
                    Spacer()
                    if DeveloperToolchainService.command(manager: manager, operation: .available, environment: workspace.terminal.environment) != nil {
                        DevLinkButton(title: l10n.t("dev.toolchain.available"), symbol: "list.bullet") {
                            candidate = workspace.versions.first(where: { $0.manager == manager })?.candidate ?? (manager == .asdf ? "nodejs" : "java")
                            installManager = manager
                            installVersion = ""
                        }
                    }
                    if DeveloperToolchainService.command(manager: manager, operation: .update, environment: workspace.terminal.environment) != nil {
                        DevLinkButton(title: l10n.t("dev.action.update"), symbol: "arrow.up") { propose(manager, .update) }
                    }
                } content: {
                    ForEach(workspace.versions.filter { $0.manager == manager }) { item in
                        DevDivider()
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(item.candidate + " " + item.version).font(.system(size: 12, weight: .medium, design: .monospaced))
                                    if item.isDefault { DevTag(text: l10n.t("dev.toolchain.default"), color: .success) }
                                    if item.isActive { DevTag(text: l10n.t("dev.toolchain.active"), color: .success) }
                                }
                                Text(item.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 10)).foregroundStyle(.tertiary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 6)
                            if let bytes = state.devEnvEntries.first(where: { $0.path == item.path })?.bytes, bytes > 0 {
                                Text(ByteFormat.format(bytes)).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            DevLinkButton(title: l10n.t("dev.action.setDefault"), symbol: "checkmark") { propose(manager, .setDefault, item.version, item.candidate) }.disabled(item.isDefault)
                            DevLinkButton(title: l10n.t("dev.action.uninstall"), symbol: "trash") { propose(manager, .uninstall, item.version, item.candidate) }.disabled(item.isDefault || item.isActive)
                        }.padding(14)
                    }
                }
            }
            xcodeCard
            javaCard
        }
        .sheet(isPresented: Binding(get: { installManager != nil }, set: { if !$0 { installManager = nil } })) { installSheet }
        .onChange(of: workspace.availableQuery?.id) { _ in
            guard let result = workspace.availableQuery else { return }
            installManager = result.manager
            candidate = result.candidate
            ltsOnly = false
        }
    }

    private func propose(_ manager: DeveloperManager, _ operation: DeveloperToolchainOperation, _ version: String = "", _ candidate: String = "java") {
        workspace.propose(DeveloperToolchainService.command(manager: manager, operation: operation, version: version, candidate: candidate, environment: workspace.terminal.environment), state: state)
    }

    private var installSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text((installManager?.displayName ?? "") + " · " + l10n.t("dev.toolchain.install")).font(.headline)
            if installManager == .sdkman || installManager == .asdf { TextField(l10n.t("dev.toolchain.candidate"), text: $candidate).textFieldStyle(.roundedBorder) }
            TextField(l10n.t("dev.toolchain.version"), text: $installVersion).textFieldStyle(.roundedBorder)
            if installManager == .rustup {
                Picker(l10n.t("dev.toolchain.version"), selection: $installVersion) {
                    ForEach(["stable", "beta", "nightly"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented)
            }
            if let result = workspace.availableQuery, result.manager == installManager, result.candidate == candidate {
                if result.versions.contains(where: \.isLTS) {
                    Toggle(l10n.t("dev.toolchain.ltsOnly"), isOn: $ltsOnly).toggleStyle(.checkbox)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(result.versions.filter { !ltsOnly || $0.isLTS }.prefix(200)) { version in
                            Button { installVersion = version.version } label: {
                                HStack {
                                    Text(version.version).font(.system(size: 11, design: .monospaced))
                                    if version.isLTS { DevTag(text: "LTS", color: .success) }
                                    Spacer()
                                    if installVersion == version.version { Image(systemName: "checkmark").foregroundStyle(Color.success) }
                                }.padding(6).contentShape(Rectangle())
                                    .modifier(DevSelectionSurface(selected: installVersion == version.version))
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(maxHeight: 230)
            }
            HStack {
                if let manager = installManager, DeveloperToolchainService.command(manager: manager, operation: .available, candidate: candidate, environment: workspace.terminal.environment) != nil {
                    Button(l10n.t("dev.toolchain.available")) { propose(manager, .available, "", candidate); installManager = nil }.buttonStyle(SecondaryButtonStyle())
                }
                Spacer()
                Button(l10n.t("common.cancel")) { installManager = nil }.buttonStyle(SecondaryButtonStyle())
                Button(l10n.t("dev.action.install")) { if let manager = installManager { propose(manager, .install, installVersion, candidate); installManager = nil } }
                    .buttonStyle(PrimaryButtonStyle()).disabled(!DeveloperToolchainService.validIdentifier(installVersion))
            }
        }.padding(20).frame(width: 470).modifier(ListRowSurface())
    }

    private var xcodeCard: some View {
        DevCard(id: "dev-xcode") {
            DevCardTitle(symbol: "hammer", title: l10n.t("dev.xcode.title"))
            Spacer()
            if workspace.selectedXcode.isEmpty { DevLinkButton(title: l10n.t("dev.xcode.install"), symbol: "arrow.down") { workspace.propose(DeveloperToolchainService.xcodeCommand("install"), state: state) } }
        } content: {
            if workspace.xcodeLicenseRequired {
                DevDivider()
                HStack {
                    DevNotice(symbol: "exclamationmark.triangle", text: l10n.t("dev.issue.xcode"), color: .warning)
                    Spacer()
                    DevLinkButton(title: l10n.t("dev.xcode.license"), symbol: "lock") { workspace.propose(DeveloperToolchainService.xcodeCommand("license"), state: state) }
                        .help(l10n.t("dev.xcode.admin"))
                }.padding(.trailing, 14)
            }
            ForEach(workspace.xcodes, id: \.self) { path in
                DevDivider()
                HStack {
                    Text(URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent().lastPathComponent).font(.system(size: 12))
                    Spacer()
                    if path == workspace.selectedXcode { Image(systemName: "checkmark").foregroundStyle(Color.success) }
                    else { DevLinkButton(title: l10n.t("dev.xcode.select"), symbol: "lock") { workspace.propose(DeveloperToolchainService.xcodeCommand("select", path: path), state: state) }.help(l10n.t("dev.xcode.admin")) }
                }.padding(14)
            }
            if !workspace.selectedXcode.isEmpty {
                DevDivider()
                Text(workspace.selectedXcode).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).padding(14)
            }
        }
    }

    private var javaCard: some View {
        DevCard(id: "dev-java") { DevCardTitle(symbol: "cup.and.saucer", title: l10n.t("dev.java.title")) } content: {
            let homes = workspace.javaHomes
            if homes.isEmpty { DevNotice(symbol: "cup.and.saucer", text: l10n.t("dev.java.empty")) }
            ForEach(homes, id: \.self) { home in
                DevDivider()
                HStack {
                    Text(home).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    DevLinkButton(title: l10n.t("dev.java.default"), symbol: "checkmark") { setJavaHome(home) }
                        .disabled(workspace.terminal.environment["JAVA_HOME"] == home || state.isDeveloperTaskBusy || shell.isSaving)
                }.padding(14)
            }
        }
    }

    private func setJavaHome(_ home: String) {
        guard state.confirmation == nil else { return }
        if let sdk = workspace.versions.first(where: { $0.manager == .sdkman && $0.candidate == "java" && home == $0.path }) { propose(.sdkman, .setDefault, sdk.version, "java"); return }
        let name = shell.inventory?.kind == .bash ? (shell.inventory?.loginFile ?? ".bash_profile") : ".zshrc"
        guard let profile = shell.profiles.first(where: { $0.name == name }),
              let text = try? DeveloperShellService.settingVariable(in: profile, variable: profile.variables.last(where: { $0.name == "JAVA_HOME" && $0.literalValue != nil }), name: "JAVA_HOME", value: home) else { workspace.operationError = l10n.t("dev.operation.unavailable"); return }
        state.confirmation = .init(title: l10n.t("dev.java.default"), message: profile.path + "\nJAVA_HOME=" + home, confirmLabel: l10n.t("common.save")) {
            guard !state.isDeveloperTaskBusy else { workspace.operationError = l10n.t("dev.operation.unavailable"); return }
            Task { _ = await shell.save(text, replacing: profile) }
        }
    }
}

struct DeveloperPackagesPanel: View {
    @ObservedObject var workspace: DeveloperWorkspaceModel
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DevCard(id: "dev-brew") {
                DevCardTitle(symbol: "shippingbox", title: "Homebrew")
                Spacer()
                Menu { ForEach(["update", "doctor", "autoremovePreview", "autoremove", "upgradeAll"], id: \.self) { action in
                    Button(l10n.t("dev.package." + action)) { propose(action) }
                } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
            } content: { EmptyView() }
            DevCard(id: "dev-global-packages") {
                DevCardTitle(symbol: "shippingbox", title: l10n.t("dev.packages.title"), subtitle: l10n.tf(workspace.packages.packages.count == 1 ? "dev.overview.count.single" : "dev.overview.count", workspace.packages.packages.count))
                Spacer()
                if workspace.isLoadingPackages { ProgressView().controlSize(.small) }
                DevLinkButton(title: l10n.t("dev.packages.check"), symbol: "arrow.clockwise") { Task { await workspace.loadPackages(checkUpdates: true) } }.disabled(workspace.isLoadingPackages)
            } content: {
                if !workspace.packages.failures.isEmpty {
                    DevNotice(symbol: "exclamationmark.triangle", text: l10n.tf("dev.packages.partial", Array(Set(workspace.packages.failures)).sorted().joined(separator: " · ")), color: .warning)
                }
                if workspace.packages.packages.isEmpty { DevNotice(symbol: "shippingbox", text: l10n.t("dev.packages.empty")) }
                ForEach(workspace.packages.packages) { package in
                    DevDivider()
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(package.name).font(.system(size: 12, weight: .medium))
                            Text(package.manager + " · " + (package.available.map { l10n.tf("dev.packages.versions", package.version, $0) } ?? package.version)).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        DevLinkButton(title: l10n.t("dev.package.upgrade"), symbol: "arrow.up") { propose("upgrade", package.manager, package.name) }
                        DevLinkButton(title: l10n.t("dev.package.uninstall"), symbol: "trash") { propose("uninstall", package.manager, package.name) }
                    }.padding(14)
                }
            }
            DevCard(id: "dev-brew-services") { DevCardTitle(symbol: "gearshape.2", title: l10n.t("dev.services.title")) } content: {
                if workspace.packages.services.isEmpty { DevNotice(symbol: "gearshape.2", text: l10n.t("dev.services.empty")) }
                ForEach(workspace.packages.services) { service in
                    DevDivider()
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(service.name).font(.system(size: 12, weight: .medium))
                            Text(l10n.t("dev.services." + (["started", "stopped", "error"].contains(service.status) ? service.status : "unknown")))
                                .font(.system(size: 10)).foregroundStyle(service.status == "error" ? Color.warning : Color.secondary)
                            if let pid = service.pid {
                                let ports = Array(Set(state.portRows.filter { $0.pid == pid }.map(\.port))).sorted().joined(separator: ", ")
                                Text(ports.isEmpty ? l10n.tf("dev.services.pid", Int(pid)) : l10n.tf("dev.services.pidPorts", Int(pid), ports))
                                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            if service.status == "error", let port = service.defaultPort,
                               let occupant = state.portRows.first(where: { $0.port == port && $0.pid != service.pid }) {
                                Text(l10n.tf("dev.services.portOccupied", port, occupant.command, Int(occupant.pid)))
                                    .font(.system(size: 10)).foregroundStyle(Color.warning)
                            }
                        }
                        Spacer()
                        Menu {
                            ForEach(["start", "stop", "restart"], id: \.self) { action in Button(l10n.t("dev.package." + action)) { propose(action, "brew", service.name) } }
                            if !service.file.isEmpty { Button(l10n.t("dev.services.file")) { NSWorkspace.shared.open(URL(fileURLWithPath: service.file)) } }
                            ForEach(service.logPaths, id: \.self) { path in
                                Button(l10n.t("dev.services.log") + " · " + URL(fileURLWithPath: path).lastPathComponent) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                            }
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                    }.padding(14)
                }
            }
        }.task { state.refreshPorts(); await workspace.loadPackages() }
    }
    private func propose(_ action: String, _ manager: String = "brew", _ name: String = "") {
        workspace.propose(DeveloperPackageService.command(action, manager: manager, name: name, environment: workspace.terminal.environment), state: state)
    }
}

struct DeveloperCommandPanel: View {
    @ObservedObject var workspace: DeveloperWorkspaceModel
    @ObservedObject private var l10n = L10n.shared
    var body: some View {
        if let title = workspace.commandTitleKey {
            DevCard(id: "dev-command-task") {
                DevCardTitle(symbol: "terminal", title: l10n.t(title), subtitle: workspace.commandSucceeded.map { l10n.t($0 ? "dev.command.success" : "dev.command.failure") })
                Spacer()
                if let start = workspace.commandStarted {
                    if let end = workspace.commandFinished {
                        Text(l10n.tf("dev.command.elapsed", end.timeIntervalSince(start))).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    } else {
                        TimelineView(.periodic(from: start, by: 1)) { context in
                            Text(l10n.tf("dev.command.elapsed", context.date.timeIntervalSince(start)))
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
                if workspace.queuedCount > 0 { Text(l10n.tf("dev.command.queued", workspace.queuedCount)).font(.system(size: 10)).foregroundStyle(.secondary) }
                if workspace.commandRunning {
                    ProgressView().controlSize(.small)
                    DevLinkButton(title: l10n.t("dev.command.cancel"), symbol: "stop.circle") { workspace.cancel() }
                }
            } content: {
                DevDivider()
                ScrollView {
                    Text(workspace.commandOutput).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }.frame(maxHeight: 200)
            }
        }
    }
}

struct DeveloperShellDiagnosticsPanel: View {
    @ObservedObject var workspace: DeveloperWorkspaceModel
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    var body: some View {
        DevCard(id: "dev-shell-profile") {
            DevCardTitle(symbol: "timer", title: l10n.t("dev.shell.profile"))
            Spacer()
            DevLinkButton(title: l10n.t("dev.command.run"), symbol: "play") { workspace.proposeShellProfile(state: state) }
                .disabled(workspace.commandRunning || state.isDeveloperTaskBusy)
        } content: {
            if let median = workspace.shellProfile?.median {
                DevDivider()
                Text(l10n.tf("dev.shell.profile.median", median)).font(.system(size: 11)).foregroundStyle(.secondary).padding(14)
            }
        }
    }
}
