import SwiftUI

struct DeveloperNetworkToolsPanel: View {
    @ObservedObject var state: AppState
    @ObservedObject var workspace: DeveloperWorkspaceModel
    @ObservedObject var network: DeveloperNetworkModel
    @ObservedObject var model: DeveloperNetworkToolsModel
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            proxyCard
            mirrorCard
            connectivityCard
        }
        .task(id: workspace.refreshRevision) {
            model.prepareProxyTarget(from: network.snapshot?.effectiveProxies ?? [])
            await model.refresh()
        }
        .onChange(of: network.snapshot?.effectiveProxies) { proxies in
            model.prepareProxyTarget(from: proxies ?? [])
        }
    }

    private var proxyCard: some View {
        DevCard(id: "dev-proxy-consistency") {
            DevCardTitle(symbol: "arrow.triangle.branch", title: l10n.t("dev.network.proxyLayers"))
            Spacer()
            if model.isLoading { ProgressView().controlSize(.small) }
            DevLinkButton(title: l10n.t("dev.network.refresh"), symbol: "arrow.clockwise") { Task { await model.refresh() } }
        } content: {
            DevDivider()
            VStack(alignment: .leading, spacing: 8) {
                Text(l10n.t("dev.network.proxyInheritance")).font(.system(size: 11)).foregroundStyle(.secondary)
                let proxies = network.snapshot?.effectiveProxies ?? []
                Text(l10n.t("dev.network.effectiveSystem") + "  " + (proxies.isEmpty ? l10n.t("dev.network.unset") : proxies.map { $0.kind + " " + $0.displayEndpoint }.joined(separator: " · ")))
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                if proxies.contains(where: { ["PAC", "WPAD"].contains($0.kind) }) {
                    Text(l10n.t("dev.network.pacManual")).font(.system(size: 11)).foregroundStyle(Color.warning)
                }
                HStack {
                    TextField(l10n.t("dev.network.proxyTarget"), text: $model.proxyTarget).textFieldStyle(.roundedBorder)
                    if let proxy = proxies.first(where: { ["HTTP", "HTTPS", "SOCKS"].contains($0.kind) }) {
                        Button(l10n.t("dev.network.useSystem")) { model.proxyTarget = (proxy.kind == "SOCKS" ? "socks5h://" : "http://") + proxy.endpoint }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
            }.padding(14)
            ForEach(model.snapshot?.proxies ?? []) { row in
                DevDivider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(row.layer.title).font(.system(size: 12, weight: .medium))
                        Spacer()
                        if row.layer.writable, row.available {
                            Button(l10n.t("dev.network.alignLayer")) { requestProxy(row.layer, clear: false) }
                                .buttonStyle(SecondaryButtonStyle()).disabled(!DeveloperNetworkToolsService.validProxyURL(model.proxyTarget) || writing)
                            Button(l10n.t("dev.network.clearLayer")) { requestProxy(row.layer, clear: true) }
                                .buttonStyle(SecondaryButtonStyle()).disabled(writing)
                        }
                    }
                    Text(!row.available ? l10n.t("dev.network.toolUnavailable") : row.display.isEmpty ? l10n.t("dev.network.inherited") : row.display)
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    Text(l10n.t(row.layer == .terminal ? "dev.network.scopeShell" : row.layer == .docker ? "dev.network.scopeDocker" : "dev.network.scopeUser"))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }.padding(.horizontal, 14).padding(.vertical, 10)
            }
            DevDivider()
            HStack {
                TextField("no_proxy", text: $model.noProxy).textFieldStyle(.roundedBorder)
                Button(l10n.t("dev.network.saveNoProxy")) { requestShell(values: ["no_proxy": model.noProxy, "NO_PROXY": model.noProxy], block: "no-proxy") }
                    .buttonStyle(SecondaryButtonStyle()).disabled(writing || model.noProxy.contains("\n") || model.noProxy.contains("\r"))
            }.padding(14)
        }
    }

    private var mirrorCard: some View {
        DevCard(id: "dev-mirror-sources") {
            DevCardTitle(symbol: "shippingbox.and.arrow.backward", title: l10n.t("dev.network.mirrors"))
            Spacer()
        } content: {
            DevDivider()
            DevNotice(symbol: "info.circle", text: l10n.t("dev.network.mirrorScope"))
            ForEach(model.snapshot?.mirrors ?? []) { row in
                DevDivider()
                DeveloperMirrorRow(row: row, busy: writing, probe: model.mirrorProbes[row.id], draft: mirrorDraft(row.id)) { value in
                    requestMirror(row, value: value)
                } test: { value in Task { await model.testMirror(row.tool, value: value) } }
            }
        }
    }

    private var connectivityCard: some View {
        DevCard(id: "dev-connectivity") {
            DevCardTitle(symbol: "network", title: l10n.t("dev.network.connectivity"))
            Spacer()
            if model.isTesting {
                Button(l10n.t("dev.network.cancel")) { model.cancelTests() }.buttonStyle(SecondaryButtonStyle())
            } else {
                Button(l10n.t("dev.network.testConnections")) { Task { await model.testConnections(proxy: model.proxyTarget) } }
                    .buttonStyle(SecondaryButtonStyle())
            }
        } content: {
            DevDivider()
            DevNotice(symbol: "info.circle", text: l10n.t("dev.network.connectionMethod"))
            ForEach(model.probes) { probe in
                HStack(spacing: 12) {
                    Text(probe.url).font(.system(size: 10, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(l10n.t(probe.route)).font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(probe.reached ? l10n.tf("dev.network.httpReached", probe.status, probe.milliseconds ?? 0) : l10n.t("dev.network.unreachable"))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(probe.reached ? Color.success : Color.warning)
                }.padding(.horizontal, 14).padding(.vertical, 5)
            }
            if !model.probes.isEmpty { Color.clear.frame(height: 6) }
        }
    }
    private var writing: Bool { model.isSaving || workspace.commandRunning || state.isDeveloperTaskBusy }

    private func mirrorDraft(_ id: String) -> Binding<DeveloperNetworkToolsModel.MirrorDraft> {
        Binding(get: { model.mirrorDrafts[id] ?? .init() }, set: { model.mirrorDrafts[id] = $0 })
    }

    private func requestProxy(_ layer: DeveloperNetworkToolsService.ProxyLayer, clear: Bool) {
        if layer == .terminal {
            let value = clear ? nil : model.proxyTarget
            requestShell(values: Dictionary(uniqueKeysWithValues: ["http_proxy", "https_proxy", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"].map { ($0, value) }), block: "proxy")
            return
        }
        do {
            let commands = try DeveloperNetworkToolsService.proxyCommand(layer: layer, target: clear ? nil : model.proxyTarget, environment: workspace.terminal.environment)
            confirmCommands(commands, scopeKey: "dev.network.scopeUser")
        } catch DeveloperNetworkToolsService.Failure.unsupportedProxy { TaskFeedbackNotice.reportFailure(messageKey: "dev.network.httpProxyOnly") }
        catch { report() }
    }
    private func requestMirror(_ row: DeveloperNetworkToolsService.MirrorRow, value: String) {
        guard DeveloperNetworkToolsService.validMirror(value, tool: row.tool) else { report(); return }
        if let key = row.overridingEnvironmentKey ?? row.tool.shellKey { requestShell(values: [key: value], block: "mirror-" + row.tool.id); return }
        if row.tool == .cargo {
            do {
                let draft = try DeveloperNetworkConfigStore.cargoDraft(target: value, cargoHome: workspace.terminal.environment["CARGO_HOME"])
                state.confirmation = .init(title: l10n.t("dev.network.applyMirror"), message: l10n.t("dev.network.scopeCargo") + "\n\n" + draft.path + "\n\n" + draft.preview, confirmLabel: l10n.t("dev.network.apply")) {
                    workspace.runConfigurationWrite(titleKey: "dev.network.applySettings") { try await model.saveCargo(draft) }
                }
            } catch {
                state.confirmation = .init(title: l10n.t("dev.network.cargoManual"), message: l10n.t("dev.network.cargoManualDetail"), confirmLabel: l10n.t("dev.network.openConfig")) {
                    DevFiles.openInEditor((workspace.terminal.environment["CARGO_HOME"] ?? NSHomeDirectory() + "/.cargo") + "/config.toml")
                }
            }
            return
        }
        do {
            let command = try DeveloperNetworkToolsService.mirrorCommand(tool: row.tool, target: value, environment: workspace.terminal.environment, yarnModern: row.yarnModern)
            confirmCommands([command], scopeKey: "dev.network.scopeUser")
        } catch { report() }
    }
    private func confirmCommands(_ commands: [DeveloperNetworkToolsService.Command], scopeKey: String) {
        state.confirmation = .init(title: l10n.t("dev.network.applySettings"), message: l10n.t(scopeKey) + "\n\n" + commands.map(\.display).joined(separator: "\n"), confirmLabel: l10n.t("dev.network.apply")) {
            let group = UUID()
            for command in commands {
                workspace.enqueue(DeveloperCommand(titleKey: "dev.network.applySettings", executable: command.executable.path,
                                                   arguments: command.arguments, environment: command.environment, timeout: 90, privilegedArguments: nil, operationGroup: group))
            }
        }
    }
    private func requestShell(values: [String: String?], block: String) {
        do {
            let draft = try DeveloperNetworkToolsModel.shellDraft(values: values, block: block, terminal: workspace.terminal)
            state.confirmation = .init(title: l10n.t("dev.network.applySettings"), message: l10n.t("dev.network.scopeShell") + "\n\n" + draft.profile.path + "\n\n" + DeveloperSecretRedactor.redact(draft.preview), confirmLabel: l10n.t("dev.network.apply")) {
                workspace.runConfigurationWrite(titleKey: "dev.network.applySettings") { try await model.saveShell(draft) }
            }
        } catch { report() }
    }
    private func report() { TaskFeedbackNotice.reportFailure(messageKey: "dev.network.invalidSettings") }
}

private struct DeveloperMirrorRow: View {
    let row: DeveloperNetworkToolsService.MirrorRow
    let busy: Bool
    let probe: DeveloperNetworkProbeService.Result?
    @Binding var draft: DeveloperNetworkToolsModel.MirrorDraft
    let apply: (String) -> Void
    let test: (String) -> Void
    @ObservedObject private var l10n = L10n.shared
    private var value: String { draft.selection == "custom" ? draft.custom : draft.selection }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(row.tool.title).font(.system(size: 12, weight: .medium))
            Text(row.display).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if let key = row.overridingEnvironmentKey {
                Text(l10n.tf("dev.network.sourceEnvironment", key)).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            HStack {
                Picker(l10n.t("dev.network.source"), selection: $draft.selection) {
                    Text(l10n.t("dev.network.chooseSource")).tag("")
                    ForEach(row.tool.presets, id: \.url) { preset in Text(l10n.t(preset.name)).tag(preset.url) }
                    Text(l10n.t("dev.network.custom")).tag("custom")
                }.labelsHidden().frame(maxWidth: 170)
                if draft.selection == "custom" { TextField("https://", text: $draft.custom).textFieldStyle(.roundedBorder) }
                Spacer(minLength: 4)
                Button(l10n.t("dev.network.measure")) { test(value) }
                    .buttonStyle(SecondaryButtonStyle()).disabled(!DeveloperNetworkToolsService.validMirror(value, tool: row.tool))
                Button(l10n.t("dev.network.apply")) { apply(value) }
                    .buttonStyle(SecondaryButtonStyle()).disabled(busy || !DeveloperNetworkToolsService.validMirror(value, tool: row.tool))
            }
            if let probe {
                Text(probe.reached ? l10n.tf("dev.network.httpReached", probe.status, probe.milliseconds ?? 0) : l10n.t("dev.network.unreachable"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 14).padding(.vertical, 10)
    }
}

@MainActor
final class DeveloperNetworkToolsModel: ObservableObject {
    struct MirrorDraft: Equatable { var selection = ""; var custom = "" }
    @Published var proxyTarget = ""
    @Published var noProxy = ""
    @Published var mirrorDrafts: [String: MirrorDraft] = [:]
    @Published private(set) var snapshot: DeveloperNetworkToolsService.Snapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var isTesting = false
    @Published private(set) var probes: [DeveloperNetworkProbeService.Result] = []
    @Published private(set) var mirrorProbes: [String: DeveloperNetworkProbeService.Result] = [:]
    private let testEngine = MoleEngine()
    private var cancelledTests = false
    private var didInitializeNoProxy = false
    struct ShellDraft { let profile: DeveloperShellService.Profile; let text: String; let preview: String }
    var environmentIssues: [DeveloperEnvironmentIssue] {
        mirrorProbes.keys.sorted().compactMap { id in
            guard let probe = mirrorProbes[id], !probe.reached else { return nil }
            let title = DeveloperNetworkToolsService.MirrorTool(rawValue: id)?.title ?? id
            return .init(id: "mirror-probe-" + id, titleKey: "dev.issue.mirrorProbe",
                         detail: title + " · " + DeveloperSecretRedactor.redact(probe.url),
                         section: .network, severity: .information)
        }
    }
    func prepareProxyTarget(from proxies: [DeveloperNetworkService.Proxy]) {
        guard proxyTarget.isEmpty, let proxy = proxies.first(where: { ["HTTP", "HTTPS", "SOCKS"].contains($0.kind) }) else { return }
        proxyTarget = (proxy.kind == "SOCKS" ? "socks5h://" : "http://") + proxy.endpoint
    }
    func refresh() async {
        guard !isLoading else { return }; isLoading = true
        let terminal = await DeveloperTerminalEnvironmentService.shared.snapshot()
        snapshot = await DeveloperNetworkToolsService.scan(terminal: terminal)
        if !didInitializeNoProxy {
            noProxy = terminal.environment["no_proxy"] ?? terminal.environment["NO_PROXY"] ?? ""
            didInitializeNoProxy = true
        }
        isLoading = false
    }
    func cancelTests() { cancelledTests = true; testEngine.cancelAll() }
    func testConnections(proxy: String) async {
        guard !isTesting else { return }
        isTesting = true; cancelledTests = false; probes = []
        defer { isTesting = false }
        let via = DeveloperNetworkToolsService.validProxyURL(proxy) ? proxy : nil
        for url in DeveloperNetworkProbeService.targets {
            guard !cancelledTests else { break }
            let direct = await DeveloperNetworkProbeService.probe(url, proxy: nil, engine: testEngine)
            guard !cancelledTests else { break }
            probes.append(direct)
            if let via {
                let proxy = await DeveloperNetworkProbeService.probe(url, proxy: via, engine: testEngine)
                guard !cancelledTests else { break }
                probes.append(proxy)
            }
        }
    }
    func testMirror(_ tool: DeveloperNetworkToolsService.MirrorTool, value: String) async {
        guard !isTesting, DeveloperNetworkToolsService.validMirror(value, tool: tool) else { return }
        isTesting = true; cancelledTests = false
        defer { isTesting = false }
        let first = String(value.split(whereSeparator: { $0 == "," || $0 == "|" }).first ?? "")
        let url = first.hasPrefix("sparse+") ? String(first.dropFirst(7)) : first
        let result = await DeveloperNetworkProbeService.probe(url, proxy: nil, engine: testEngine)
        guard !cancelledTests else { return }
        mirrorProbes[tool.id] = result
    }
    static func shellDraft(values: [String: String?], block: String, terminal: DeveloperTerminalSnapshot) throws -> ShellDraft {
        guard ["/bin/zsh", "/bin/bash"].contains(terminal.shell),
              Set(values.keys).isSubset(of: Set(["http_proxy", "https_proxy", "all_proxy", "no_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "UV_DEFAULT_INDEX", "HOMEBREW_API_DOMAIN", "HOMEBREW_BOTTLE_DOMAIN", "GOPROXY", "npm_config_registry", "YARN_NPM_REGISTRY_SERVER", "PIP_INDEX_URL"])),
              block.range(of: "^[a-z-]+$", options: .regularExpression) != nil, values.values.allSatisfy({ value in
            !(value ?? "").unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
        }) else { throw DeveloperNetworkToolsService.Failure.unsupportedShell }
        let home = terminal.shell == "/bin/zsh" ? terminal.environment["ZDOTDIR"] ?? NSHomeDirectory() : NSHomeDirectory()
        let filename = terminal.shell == "/bin/zsh" ? ".zshrc" : [".bash_profile", ".bash_login", ".profile"].first { FileManager.default.fileExists(atPath: home + "/" + $0) } ?? ".bash_profile"
        let profile = try DeveloperShellService.readProfile(filename, home: home)
        let begin = "# Nori " + block + ": begin", end = "# Nori " + block + ": end"
        var text = profile.text
        if let opening = text.range(of: begin) {
            guard let closing = text.range(of: end, range: opening.upperBound..<text.endIndex), text.range(of: begin, range: opening.upperBound..<text.endIndex) == nil else { throw DeveloperNetworkToolsService.Failure.unsafeConfig }
            var upper = closing.upperBound
            if upper < text.endIndex, text[upper] == "\n" { upper = text.index(after: upper) }
            text.removeSubrange(opening.lowerBound..<upper)
        }
        let lines = values.keys.sorted().map { key -> String in
            if let value = values[key] ?? nil { return "export " + key + "='" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            return "unset " + key
        }
        let addition = begin + "\n" + lines.joined(separator: "\n") + "\n" + end + "\n"
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += addition
        return ShellDraft(profile: profile, text: text, preview: addition)
    }
    func saveShell(_ draft: ShellDraft) async throws {
        guard !isSaving else { throw DeveloperNetworkToolsService.Failure.unavailable }; isSaving = true
        defer { isSaving = false }
        _ = try await Task.detached { try DeveloperShellService.save(draft.text, replacing: draft.profile) }.value
    }
    func saveCargo(_ draft: DeveloperNetworkConfigStore.Draft) async throws {
        guard !isSaving else { throw DeveloperNetworkToolsService.Failure.unavailable }; isSaving = true
        defer { isSaving = false }
        try await Task.detached { try DeveloperNetworkConfigStore.save(draft) }.value
    }
}
