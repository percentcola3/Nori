import SwiftUI

@MainActor
struct AgentHistoryView: View {
    @ObservedObject var state: AppState
    @ObservedObject var store: AgentHistoryStore
    @ObservedObject private var l10n = L10n.shared
    @State private var provider = AgentHistoryProvider.opencode
    @State private var search = ""

    private var page: AgentHistoryPageState { store.page(provider) }
    private var blocked: Bool {
        store.busy != nil || state.isAgentTaskBusy || state.isCleanupMutationBusy || state.uninstallQueue.activeJob != nil
    }
    private var sessions: [AgentHistorySession] {
        let rows = page.inventory?.sessions ?? []
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? rows : rows.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.sessionID.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controls
            Text(l10n.t("agents.history.notice"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if !AgentHistoryService.interfacesEnabled {
                Text(l10n.t("agents.history.pendingValidation"))
                    .font(.system(size: 11)).foregroundStyle(Color.warning)
            }
            if let key = page.statusKey, !key.hasPrefix("agents.history.error"), page.failureKeys.isEmpty {
                Text(statusText(key))
                    .font(.system(size: 11))
                    .foregroundStyle(key.hasPrefix("agents.history.error") ? Color.warning : Color.textSecondary)
                    .textSelection(.enabled)
            }
            if store.busy == provider {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    if store.total > 0 {
                        Text("\(store.completed) / \(store.total)").monospacedDigit()
                    }
                    Text(l10n.t(page.statusKey ?? "agents.history.loading"))
                    Spacer()
                }.font(.system(size: 11))
            }
            if page.inventory != nil {
                TextField(l10n.t("agents.history.search"), text: $search)
                    .textFieldStyle(.roundedBorder).disabled(blocked)
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(sessions) { row in sessionRow(row) }
                    }.padding(.vertical, 2)
                }
                .frame(maxHeight: .infinity)
            } else {
                Spacer()
                Text(l10n.t("agents.history.start"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            }
            Divider()
            HStack {
                if !page.backupDirectories.isEmpty {
                    Button(l10n.t("agents.history.backups")) { store.revealBackups(provider) }
                        .buttonStyle(SecondaryButtonStyle())
                }
                if let version = page.inventory?.version {
                    Text(version).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(l10n.tf("agents.history.selected", page.selection.count))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button { store.requestDelete(provider, state: state) } label: {
                    Label(l10n.t("agents.history.delete"), systemImage: "trash")
                }
                .buttonStyle(DangerButtonStyle())
                .disabled(!AgentHistoryService.interfacesEnabled || blocked || page.selection.isEmpty || page.selection.count > 100)
            }
        }
        .padding(16)
        .onChange(of: page.failureKeys) { failures in
            guard !failures.isEmpty else { return }
            state.presentTaskFailure(details: failures.sorted { $0.key < $1.key }.map { l10n.t($0.value) },
                                     detailsAreLocalized: true)
        }
        .onChange(of: page.statusKey) { key in
            if let key, key.hasPrefix("agents.history.error") { state.presentTaskFailure(message: statusText(key)) }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker(l10n.t("agents.history.provider"), selection: Binding(get: { provider }, set: {
                    provider = $0
                    search = ""
                })) {
                    ForEach(AgentHistoryProvider.allCases, id: \.self) { item in Text(item.name).tag(item) }
                }.pickerStyle(.menu).frame(width: 180).disabled(blocked)
                Spacer()
                Button(l10n.t("agents.history.project.choose")) { store.chooseProject(provider, state: state) }
                    .buttonStyle(SecondaryButtonStyle()).disabled(blocked)
                Button { store.list(provider, state: state) } label: {
                    Label(l10n.t("agents.history.load"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(PrimaryButtonStyle()).disabled(!AgentHistoryService.interfacesEnabled || blocked || page.project.isEmpty)
            }
            if !page.project.isEmpty {
                Text(page.project).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(page.project)
            }
        }
    }

    private func sessionRow(_ row: AgentHistorySession) -> some View {
        Button { store.toggle(row, state: state) } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: page.selection.contains(row.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(row.canSelect ? Color.moleAccentText : Color.textSecondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    Text(row.sessionID).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    if let reason = row.protection {
                        Text(l10n.t(reason)).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if let date = row.updatedAt {
                    Text(date, format: .dateTime.year().month().day().hour().minute())
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(blocked || !row.canSelect)
        .modifier(ListRowSurface(selected: page.selection.contains(row.id)))
        .accessibilityAddTraits(page.selection.contains(row.id) ? .isSelected : [])
    }

    private func statusText(_ key: String) -> String {
        if page.statusArguments.count == 2 { return l10n.tf(key, page.statusArguments[0], page.statusArguments[1]) }
        return l10n.t(key)
    }
}
