import SwiftUI
import AppKit

/// Network overview, hosts as a table of switchable mappings, and explicit repairs.
/// Entering the tab refreshes the read-only snapshot; hosts edits are staged and saved together.
struct DeveloperNetworkPanel: View {
    @ObservedObject var state: AppState
    @ObservedObject var model: DeveloperNetworkModel
    @ObservedObject var workspace: DeveloperWorkspaceModel
    @ObservedObject private var l10n = L10n.shared

    private var chinese: Bool { l10n.resolved == .zhHans || l10n.resolved == .zhHant }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isLoading && model.snapshot == nil {
                ProgressView(L10n.shared.t("dev.network.reading.network.configuration"))
                    .controlSize(.small).font(.system(size: 11))
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
            if let snapshot = model.snapshot {
                DeveloperHostsCard(state: state, model: model, chinese: chinese)
                DeveloperNetworkServicesCard(state: state, model: model, workspace: workspace, snapshot: snapshot, chinese: chinese)
            }
            DeveloperNetworkRepairsCard(state: state, chinese: chinese)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: workspace.refreshRevision) { await model.refresh() }
    }
}

// MARK: - hosts

private struct DeveloperHostsCard: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject var state: AppState
    @ObservedObject var model: DeveloperNetworkModel
    let chinese: Bool
    @State private var editingEntry: Int?
    @State private var adding: DeveloperHostsDraft?
    @State private var showsSystem = false

    private typealias Network = DeveloperNetworkService

    var body: some View {
        DevCard(id: "dev-hosts") {
            DevCardTitle(symbol: "list.bullet.rectangle", title: "hosts", subtitle: subtitle)
            Spacer(minLength: 8)
            if model.isSaving { ProgressView().controlSize(.small) }
            DevLinkButton(title: L10n.shared.t("dev.network.add.mapping"), symbol: "plus") {
                editingEntry = nil
                adding = DeveloperHostsDraft(groupID: groups.first { $0.kind != .system }?.id ?? "ungrouped")
            }
            .disabled(model.document == nil || model.isSaving || adding != nil)
        } content: {
            DevDivider()
            if model.document == nil {
                DevNotice(symbol: "exclamationmark.triangle",
                          text: L10n.shared.t("dev.network.hosts.cannot.be.read.safely"),
                          color: .warning)
            } else {
                if !(model.snapshot?.effectiveProxies.isEmpty ?? true), !model.enabledCustomHostnames.isEmpty {
                    DevNotice(symbol: "network", text: L10n.shared.t("dev.network.hostsProxyNotice"), color: .warning)
                    HStack {
                        Text(model.enabledCustomHostnames.joined(separator: " · "))
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        DevLinkButton(title: L10n.shared.t("dev.network.copyClashRules"), symbol: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.clashDirectRules, forType: .string)
                        }
                    }.padding(.horizontal, 14).padding(.bottom, 8)
                    DevDivider()
                }
                if model.externalChange {
                    HStack {
                        DevNotice(symbol: "exclamationmark.triangle",
                                  text: L10n.shared.t("dev.network.hosts.changed.outside.nori.redo"),
                                  color: .warning)
                        DevLinkButton(title: L10n.shared.t("dev.network.reload"), symbol: "arrow.clockwise") { model.reloadHosts() }
                            .padding(.trailing, 14)
                    }
                    DevDivider()
                }
                if let draft = adding {
                    DeveloperHostsEntryEditor(draft: draft, groups: groups, isNew: true, chinese: chinese) { result in
                        apply {
                            try Network.addingHostsEntry($0, address: result.address, hostnames: result.hostnames,
                                                         comment: result.comment, to: group(for: result.groupID),
                                                         newGroupTitle: result.newGroupTitle)
                        }
                        adding = nil
                    } cancel: { adding = nil }
                    DevDivider()
                }
                if groups.allSatisfy({ $0.kind == .system }) && adding == nil {
                    Text(L10n.shared.t("dev.network.no.custom.mappings.yet.add"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                }
                ForEach(groups.filter { $0.kind != .system }) { group in
                    groupView(group)
                    DevDivider()
                }
                if let system = groups.first(where: { $0.kind == .system }) {
                    systemGroup(system)
                }
                if model.draft != nil {
                    DevDivider()
                    pendingBar
                }
            }
            if let error = model.hostsError {
                DevDivider()
                DevNotice(symbol: "exclamationmark.triangle", text: errorMessage(error), color: .danger)
            }
            if !model.status.isEmpty {
                DevDivider()
                DevNotice(symbol: "checkmark.circle", text: model.status + (model.backupPath.map { "  ·  " + L10n.shared.t("dev.network.backup") + $0 } ?? ""),
                          color: .success)
            }
        }
    }

    private var groups: [Network.HostsGroup] { model.hostsGroups }

    private var subtitle: String {
        let custom = groups.filter { $0.kind != .system }.reduce(0) { $0 + $1.entries.count }
        let enabled = groups.filter { $0.kind != .system }.reduce(0) { $0 + $1.enabledCount }
        return "/etc/hosts · " + L10n.shared.tf("dev.network.mappings.on", String(enabled), String(custom))
    }

    private func group(for id: String) -> Network.HostsGroup? {
        if id == "new" { return nil }
        return groups.first { $0.id == id } ?? Network.HostsGroup(kind: .ungrouped, headerLineIndex: nil, entries: [])
    }

    // MARK: Groups

    @ViewBuilder private func groupView(_ group: Network.HostsGroup) -> some View {
        let allEnabled = group.enabledCount == group.entries.count
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { group.enabledCount > 0 }, set: { on in
                apply { Network.settingHostsEntries($0, entries: group.entries, enabled: on) }
            })) { EmptyView() }
                .toggleStyle(MoleSwitchToggleStyle()).controlSize(.small)
                .disabled(model.isSaving)
                .accessibilityLabel(L10n.shared.tf("dev.network.enable.group", String(title(group))))
            Text(title(group)).font(.system(size: 12, weight: .semibold))
            Text(allEnabled ? L10n.shared.tf("dev.network.count", String(group.entries.count))
                 : L10n.shared.tf("dev.network.on", String(group.enabledCount), String(group.entries.count)))
                .font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer()
            Button {
                editingEntry = nil
                adding = DeveloperHostsDraft(groupID: group.id)
            } label: { Image(systemName: "plus") }
                .buttonStyle(MoleIconButtonStyle(size: 22))
                .help(L10n.shared.t("dev.network.add.to.this.group"))
                .accessibilityLabel(L10n.shared.tf("dev.network.add.to", String(title(group))))
                .disabled(model.isSaving || adding != nil)
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
        ForEach(group.entries) { entry in
            if editingEntry == entry.id {
                DeveloperHostsEntryEditor(
                    draft: DeveloperHostsDraft(address: entry.address, hostnames: entry.hostnames.joined(separator: " "),
                                               comment: entry.comment, groupID: group.id),
                    groups: groups, isNew: false, chinese: chinese) { result in
                    apply {
                        try Network.settingHostsEntry($0, entry: entry, address: result.address,
                                                      hostnames: result.hostnames, comment: result.comment)
                    }
                    editingEntry = nil
                } cancel: { editingEntry = nil }
            } else {
                entryRow(entry)
            }
        }
        Color.clear.frame(height: 6)
    }

    private func systemGroup(_ group: Network.HostsGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(MoleMotion.panel) { showsSystem.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "lock").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Text(L10n.shared.t("dev.network.system.defaults")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Text(L10n.shared.tf("dev.network.read.only", String(group.entries.count)))
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showsSystem ? 0 : -90))
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(MolePlainButtonStyle(pressedScale: 0.995))
            if showsSystem {
                ForEach(group.entries) { entry in
                    HStack(spacing: 10) {
                        Text(entry.address).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                        Text(entry.hostnames.joined(separator: " ")).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 3)
                }
                Color.clear.frame(height: 8)
            }
        }
    }

    private func entryRow(_ entry: Network.HostsEntry) -> some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { entry.enabled }, set: { on in
                apply { Network.settingHostsEntries($0, entries: [entry], enabled: on) }
            })) { EmptyView() }
                .toggleStyle(MoleSwitchToggleStyle()).controlSize(.mini)
                .disabled(model.isSaving)
                .accessibilityLabel(L10n.shared.tf("dev.network.enable", String(entry.hostnames.joined(separator: " "))))
            Text(entry.address)
                .font(.system(size: 12, design: .monospaced))
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
            Image(systemName: "arrow.left").font(.system(size: 9)).foregroundStyle(.tertiary)
            Text(entry.hostnames.joined(separator: "  "))
                .font(.system(size: 11, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if !entry.comment.isEmpty {
                Text(entry.comment).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                adding = nil
                editingEntry = entry.id
            } label: { Image(systemName: "pencil") }
                .buttonStyle(MoleIconButtonStyle(size: 22))
                .help(L10n.shared.t("dev.network.edit"))
                .accessibilityLabel(L10n.shared.t("dev.network.edit.mapping"))
                .disabled(model.isSaving)
            Button {
                apply { Network.removingHostsEntry($0, entry: entry) }
            } label: { Image(systemName: "trash") }
                .buttonStyle(MoleIconButtonStyle(tint: .danger, size: 22))
                .help(L10n.shared.t("dev.network.delete"))
                .accessibilityLabel(L10n.shared.t("dev.network.delete.mapping"))
                .disabled(model.isSaving)
        }
        .opacity(entry.enabled ? 1 : 0.55)
        .padding(.leading, 14).padding(.trailing, 14).padding(.vertical, 4)
    }

    // MARK: Saving

    private var pendingBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "pencil.circle").foregroundStyle(Color.accentText)
            Text(L10n.shared.tf("dev.network.unsaved.change.s", String(model.pendingChanges)))
                .font(.system(size: 12, weight: .medium))
            Toggle(L10n.shared.t("dev.network.flush.dns.after.saving"), isOn: $model.flushAfterSave)
                .toggleStyle(.checkbox).font(.system(size: 11))
            Spacer()
            Button(L10n.shared.t("dev.network.discard")) { model.discard() }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.isSaving)
            Button(L10n.shared.t("dev.network.save")) { requestSave() }
                .buttonStyle(SecondaryButtonStyle(tint: .accentText))
                .disabled(model.isSaving || model.externalChange)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func requestSave() {
        guard let draft = model.draft else { return }
        do { try Network.validateHosts(draft) }
        catch {
            let failure = error as? Network.HostsError ?? .saveFailed
            model.hostsError = failure
            return
        }
        state.confirmation = AppState.Confirmation(
            title: L10n.shared.t("dev.network.save.hosts"),
            message: L10n.shared.t("dev.network.this.affects.name.resolution.in")
                + (model.flushAfterSave ? L10n.shared.t("dev.network.the.dns.cache.is.flushed") : ""),
            confirmLabel: L10n.shared.t("dev.network.back.up.save")) {
                Task { @MainActor in
                    if let message = await model.save(chinese: chinese) { state.log(message) }
                }
            }
    }

    /// Editors validate their own fields first, so a failing transform leaves the draft unchanged.
    private func apply(_ transform: (String) throws -> String) {
        try? model.apply(transform)
    }

    private func title(_ group: Network.HostsGroup) -> String {
        switch group.kind {
        case .system: return L10n.shared.t("dev.network.system.defaults")
        case .ungrouped: return L10n.shared.t("dev.network.ungrouped")
        case .named(let name): return name
        }
    }

    private func errorMessage(_ error: Network.HostsError) -> String {
        let message = L10n.shared.t(DeveloperNetworkModel.failureKey(error))
        if case .invalidLine(let line) = error { return message + "  /etc/hosts:\(line)" }
        return message
    }
}

struct DeveloperHostsDraft: Equatable {
    var address = "127.0.0.1"
    var hostnames = ""
    var comment = ""
    var groupID: String
}

private struct DeveloperHostsEntryEditor: View {
    @ObservedObject private var l10n = L10n.shared
    struct Result {
        let address: String
        let hostnames: [String]
        let comment: String
        let groupID: String
        let newGroupTitle: String?
    }

    let groups: [DeveloperNetworkService.HostsGroup]
    let isNew: Bool
    let chinese: Bool
    let save: (Result) -> Void
    let cancel: () -> Void
    @State private var address: String
    @State private var hostnames: String
    @State private var comment: String
    @State private var groupID: String
    @State private var newGroupTitle = ""
    @State private var problem: String?

    init(draft: DeveloperHostsDraft, groups: [DeveloperNetworkService.HostsGroup], isNew: Bool, chinese: Bool,
         save: @escaping (Result) -> Void, cancel: @escaping () -> Void) {
        // Seeded once per opened editor.
        _address = State(initialValue: draft.address)
        _hostnames = State(initialValue: draft.hostnames)
        _comment = State(initialValue: draft.comment)
        _groupID = State(initialValue: draft.groupID)
        self.groups = groups
        self.isNew = isNew
        self.chinese = chinese
        self.save = save
        self.cancel = cancel
    }


    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isNew ? L10n.shared.t("dev.network.new.mapping") : L10n.shared.t("dev.network.edit.mapping"))
                .font(.system(size: 12, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text(L10n.shared.t("dev.network.ip.address")).font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        TextField("127.0.0.1", text: $address)
                            .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                            .frame(width: 200)
                        ForEach(["127.0.0.1", "::1", "0.0.0.0"], id: \.self) { preset in
                            Button(preset) { address = preset }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }
                GridRow {
                    Text(L10n.shared.t("dev.network.hostnames")).font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField(L10n.shared.t("dev.network.api.local.dashboard.test.space"), text: $hostnames)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                }
                GridRow {
                    Text(L10n.shared.t("dev.network.note")).font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField(L10n.shared.t("dev.network.optional"), text: $comment)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12))
                }
                if isNew {
                    GridRow {
                        Text(L10n.shared.t("dev.network.group")).font(.system(size: 11)).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Picker("", selection: $groupID) {
                                Text(L10n.shared.t("dev.network.ungrouped")).tag("ungrouped")
                                ForEach(groups.filter { if case .named = $0.kind { return true } else { return false } }) { group in
                                    if case .named(let name) = group.kind { Text(name).tag(group.id) }
                                }
                                Divider()
                                Text(L10n.shared.t("dev.network.new.group")).tag("new")
                            }
                            .labelsHidden().frame(width: 180)
                            if groupID == "new" {
                                TextField(L10n.shared.t("dev.network.group.name.e.g.local"), text: $newGroupTitle)
                                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
                            }
                        }
                    }
                }
            }
            if let problem {
                Text(problem).font(.system(size: 11)).foregroundStyle(Color.danger)
            }
            HStack(spacing: 8) {
                Text(L10n.shared.t("dev.network.changes.are.staged.until.you"))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button(L10n.shared.t("dev.network.cancel"), action: cancel)
                    .buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button(isNew ? L10n.shared.t("dev.network.add") : L10n.shared.t("dev.network.done")) { submit() }
                    .buttonStyle(SecondaryButtonStyle(tint: .accentText)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private func submit() {
        let names = DeveloperNetworkService.hostnameList(hostnames)
        let trimmedAddress = address.trimmingCharacters(in: .whitespaces)
        do {
            try DeveloperNetworkService.validateHostsEntry(address: trimmedAddress, hostnames: names, comment: comment)
        } catch let issue as DeveloperNetworkService.HostsEntryProblem {
            switch issue {
            case .invalidAddress: problem = L10n.shared.t("dev.network.invalid.ip.address.e.g")
            case .missingHostname: problem = L10n.shared.t("dev.network.enter.at.least.one.hostname")
            case .invalidHostname(let name): problem = L10n.shared.tf("dev.network.invalid.hostname", String(name))
            case .protectedHostname: problem = L10n.shared.t("dev.network.localhost.and.broadcasthost.are.managed")
            case .invalidComment: problem = L10n.shared.t("dev.network.notes.cannot.contain.line.breaks")
            }
            return
        } catch { return }
        if groupID == "new", newGroupTitle.trimmingCharacters(in: .whitespaces).isEmpty {
            problem = L10n.shared.t("dev.network.enter.a.group.name")
            return
        }
        problem = nil
        save(Result(address: trimmedAddress, hostnames: names, comment: comment, groupID: groupID,
                    newGroupTitle: groupID == "new" ? newGroupTitle : nil))
    }
}

// MARK: - Services

private struct DeveloperNetworkServicesCard: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject var state: AppState
    @ObservedObject var model: DeveloperNetworkModel
    @ObservedObject var workspace: DeveloperWorkspaceModel
    let snapshot: DeveloperNetworkService.Snapshot
    let chinese: Bool

    var body: some View {
        DevCard(id: "dev-network-services") {
            DevCardTitle(symbol: "point.3.connected.trianglepath.dotted", title: L10n.shared.t("dev.network.network.services"),
                         subtitle: snapshot.resolverServers.isEmpty ? nil
                            : (L10n.shared.t("dev.network.resolvers")) + snapshot.resolverServers.joined(separator: " · "))
            Spacer()
        } content: {
            if snapshot.services.isEmpty {
                DevDivider()
                DevNotice(symbol: "info.circle", text: L10n.shared.t("dev.network.no.readable.network.services"))
            }
            ForEach(snapshot.services) { service in
                DevDivider()
                DeveloperNetworkServiceRow(state: state, model: model, workspace: workspace, service: service, chinese: chinese)
            }
            if !snapshot.warnings.isEmpty {
                DevDivider()
                DevNotice(symbol: "exclamationmark.triangle", text: L10n.shared.t("dev.network.some.settings.are.unavailable"),
                          color: .warning)
            }
        }
    }
}

private struct DeveloperNetworkServiceRow: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject var state: AppState
    @ObservedObject var model: DeveloperNetworkModel
    @ObservedObject var workspace: DeveloperWorkspaceModel
    let service: DeveloperNetworkService.NetworkService
    let chinese: Bool
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(service.name).font(.system(size: 12, weight: .semibold))
                    if !service.enabled { DevTag(text: L10n.shared.t("dev.network.disabled")) }
                    if !service.readable {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(Color.warning)
                    }
                }
                Text(service.address ?? (L10n.shared.t("dev.network.no.ipv4.address")))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            }
            .frame(width: 180, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text("DNS  " + (!service.dnsReadable ? (L10n.shared.t("dev.network.unavailable"))
                                : service.dnsServers.isEmpty ? (L10n.shared.t("dev.network.automatic.dhcp"))
                                : service.dnsServers.joined(separator: " · ")))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if !service.proxiesReadable {
                    Text(L10n.shared.t("dev.network.proxy.some.settings.unavailable"))
                        .font(.system(size: 11)).foregroundStyle(Color.warning)
                } else if service.proxies.isEmpty {
                    Text(L10n.shared.t("dev.network.proxy.off")).font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ForEach(service.proxies) { proxy in
                        HStack(spacing: 8) {
                            Text("\(proxy.kind)  \(proxy.displayEndpoint)")
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Button(L10n.shared.t("dev.network.disableProxy")) { requestDisable(proxy) }
                                .buttonStyle(SecondaryButtonStyle())
                                .disabled(workspace.commandRunning)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .accessibilityElement(children: .contain)
    }

    private func requestDisable(_ proxy: DeveloperNetworkService.Proxy) {
        let options = ["HTTP": ("http", "-setwebproxystate"), "HTTPS": ("https", "-setsecurewebproxystate"),
                       "SOCKS": ("socks", "-setsocksfirewallproxystate"), "PAC": ("pac", "-setautoproxystate")]
        guard let option = options[proxy.kind] else { return }
        let command = DeveloperCommand(titleKey: "dev.network.disableProxy", executable: "/usr/sbin/networksetup",
                                       arguments: [option.1, service.name, "off"], environment: [:], timeout: 120,
                                       privilegedArguments: [service.name, option.0], privilegedBridge: .proxy)
        state.confirmation = AppState.Confirmation(
            title: L10n.shared.tf("dev.network.disableProxyTitle", proxy.kind, service.name),
            message: L10n.shared.tf("dev.network.disableProxyMessage", service.name, proxy.kind, proxy.displayEndpoint) + "\n\n" + command.display,
            confirmLabel: L10n.shared.t("dev.network.disableProxy")) {
                workspace.enqueue(command)
            }
    }
}

// MARK: - Repairs

private struct DeveloperNetworkRepairsCard: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject var state: AppState
    let chinese: Bool

    var body: some View {
        DevCard(id: "dev-network-repairs") {
            DevCardTitle(symbol: "wrench.and.screwdriver", title: L10n.shared.t("dev.network.network.repairs"),
                         subtitle: L10n.shared.t("dev.network.requires.administrator.access"))
            Spacer()
            if state.isNetworkToolRunning { ProgressView().controlSize(.small) }
        } content: {
            DevDivider()
            repairRow(title: L10n.shared.t("dev.network.a.hostname.resolves.to.an"),
                      detail: L10n.shared.t("dev.network.flush.cached.lookups.keeps.dns"),
                      action: L10n.shared.t("dev.network.flush.dns")) { state.runAdminNetworkTask("dns") }
            DevDivider(inset: 14)
            repairRow(title: L10n.shared.t("dev.network.cannot.connect.after.switching.a"),
                      detail: L10n.shared.t("dev.network.refresh.routes.and.arp.connections"),
                      action: L10n.shared.t("dev.network.refresh.stack")) { state.runAdminNetworkTask("network-stack") }
            if !state.isNetworkToolRunning, !state.networkToolStatus.isEmpty {
                DevDivider()
                DevNotice(symbol: "info.circle", text: state.networkToolStatus)
            }
        }
    }

    private func repairRow(title: String, detail: String, action: String, run: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(action, action: run)
                .buttonStyle(SecondaryButtonStyle())
                .disabled(state.isNetworkToolRunning)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

// MARK: - Model

@MainActor
final class DeveloperNetworkModel: ObservableObject {
    @Published private(set) var snapshot: DeveloperNetworkService.Snapshot? { didSet { updateHostsStructure() } }
    @Published private(set) var isLoading = false
    @Published private(set) var hostsGroups: [DeveloperNetworkService.HostsGroup] = []
    @Published private(set) var enabledCustomHostnames: [String] = []
    /// Staged hosts text; nil when nothing changed.
    @Published private(set) var draft: String? { didSet { updateHostsStructure() } }
    @Published private(set) var pendingChanges = 0
    @Published private(set) var isSaving = false
    @Published private(set) var externalChange = false
    @Published var flushAfterSave = true
    @Published var hostsError: DeveloperNetworkService.HostsError?
    @Published var status = ""
    @Published private(set) var backupPath: String?
    private var lastToken: Int?
    private var parsedHostsText: String?

    var document: DeveloperNetworkService.HostsDocument? { snapshot?.hosts }
    var hostsText: String { draft ?? document?.text ?? "" }

    var clashDirectRules: String { enabledCustomHostnames.map { "DOMAIN," + $0 + ",DIRECT" }.joined(separator: "\n") }

    private func updateHostsStructure() {
        guard parsedHostsText != hostsText else { return }
        parsedHostsText = hostsText
        let parsed = DeveloperNetworkService.hostsGroups(hostsText)
        hostsGroups = parsed
        enabledCustomHostnames = Array(Set(parsed.flatMap(\.entries).filter { $0.enabled && !$0.isSystem }
            .flatMap(\.hostnames).map { ($0.hasSuffix(".") ? String($0.dropLast()) : $0).lowercased() })).sorted()
    }

    func refresh(for token: Int) async {
        guard lastToken != token else { return }
        await refresh()
        if !Task.isCancelled { lastToken = token }
    }

    func refresh() async {
        isLoading = true
        let fresh = await DeveloperNetworkService.scan()
        guard !Task.isCancelled else { isLoading = false; return }
        if draft != nil, let old = snapshot?.hosts, fresh.hosts?.fingerprint != old.fingerprint {
            externalChange = true
            // Keep the old document as the draft's base until the person reloads.
            snapshot = .init(services: fresh.services, resolverServers: fresh.resolverServers,
                             hosts: old, warnings: fresh.warnings, effectiveProxies: fresh.effectiveProxies)
        } else {
            snapshot = fresh
        }
        isLoading = false
    }

    func apply(_ transform: (String) throws -> String) throws {
        guard document != nil, !isSaving else { return }
        let next = try transform(hostsText)
        guard next != hostsText else { return }
        status = ""
        hostsError = nil
        if next == document?.text {
            draft = nil
            pendingChanges = 0
        } else {
            draft = next
            pendingChanges += 1
        }
    }

    func discard() {
        draft = nil
        pendingChanges = 0
        hostsError = nil
        if externalChange { reloadHosts() }
    }

    func reloadHosts() {
        guard let snapshot else { return }
        do {
            let current = try DeveloperNetworkService.readHosts()
            self.snapshot = .init(services: snapshot.services, resolverServers: snapshot.resolverServers,
                                  hosts: current, warnings: snapshot.warnings.filter { $0 != "hosts" }, effectiveProxies: snapshot.effectiveProxies)
            draft = nil
            pendingChanges = 0
            externalChange = false
            hostsError = nil
        } catch {
            let failure = error as? DeveloperNetworkService.HostsError ?? .unavailable
            hostsError = failure
            Self.report(failure)
        }
    }

    /// Returns a log line on success.
    func save(chinese: Bool) async -> String? {
        guard let draft, let original = document, !isSaving else { return nil }
        isSaving = true
        hostsError = nil
        defer { isSaving = false }
        do {
            let saved = try await DeveloperNetworkService.saveHosts(draft, original: original, flushDNS: flushAfterSave)
            backupPath = saved.backupPath
            switch saved.flushedDNS {
            case true?: status = L10n.shared.t("dev.network.saved.and.flushed.dns")
            case false?: status = L10n.shared.t("dev.network.saved.but.flushing.dns.failed")
            case nil: status = L10n.shared.t("dev.network.saved.flush.dns.if.needed")
            }
            self.draft = nil
            pendingChanges = 0
            externalChange = false
            await refresh()
            return status
        } catch {
            let failure = error as? DeveloperNetworkService.HostsError ?? .saveFailed
            hostsError = failure
            externalChange = failure == .changedExternally
            Self.report(failure)
            return nil
        }
    }

    private static func report(_ failure: DeveloperNetworkService.HostsError) {
        let location: String
        if case .invalidLine(let line) = failure { location = "/etc/hosts:\(line)" }
        else { location = "/etc/hosts" }
        TaskFeedbackNotice.reportFailure(messageKey: failureKey(failure), details: [location], detailsAreLocalized: true)
    }

    static func failureKey(_ error: DeveloperNetworkService.HostsError) -> String {
        switch error {
        case .unavailable: return "task.reason.hostsUnavailable"
        case .tooLarge: return "task.reason.hostsTooLarge"
        case .invalidLine: return "task.reason.hostsInvalidLine"
        case .protectedMapping: return "task.reason.hostsProtected"
        case .changedExternally: return "task.reason.configChanged"
        case .saveFailed: return "task.reason.hostsSave"
        case .skippedInTestMode: return "task.reason.testMode"
        }
    }
}
