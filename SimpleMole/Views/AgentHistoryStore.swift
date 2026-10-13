import AppKit
import Combine
import Foundation

/// Owned by the Agent page; large history payloads stay in provider storage or
/// on disk. The shared AppState gate prevents cleanup/uninstall overlap.
@MainActor
final class AgentHistoryStore: ObservableObject {
    @Published private(set) var pages: [AgentHistoryProvider: AgentHistoryPageState] = [:]
    @Published private(set) var busy: AgentHistoryProvider?
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    private var generation = UUID()

    func page(_ provider: AgentHistoryProvider) -> AgentHistoryPageState { pages[provider] ?? .init() }

    func chooseProject(_ provider: AgentHistoryProvider, state: AppState) {
        guard !state.isAgentTaskBusy, busy == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.shared.t("agents.history.project.choose")
        if !page(provider).project.isEmpty { panel.directoryURL = URL(fileURLWithPath: page(provider).project) }
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        var next = AgentHistoryPageState()
        next.project = selected.resolvingSymlinksInPath().standardizedFileURL.path
        pages[provider] = next
    }

    func toggle(_ row: AgentHistorySession, state: AppState) {
        guard busy == nil, !state.isAgentTaskBusy, row.canSelect else { return }
        var next = page(row.provider)
        guard next.inventory?.sessions.contains(row) == true else { return }
        if !next.selection.insert(row.id).inserted { next.selection.remove(row.id) }
        pages[row.provider] = next
    }

    func list(_ provider: AgentHistoryProvider, state: AppState) {
        guard canStart(state), AgentHistoryService.interfacesEnabled, !page(provider).project.isEmpty else { return }
        let token = begin(provider, state: state)
        let project = page(provider).project
        update(provider) { $0.statusKey = "agents.history.loading"; $0.statusArguments = []; $0.failureKeys = [:] }
        Task {
            defer { end(token, state: state) }
            do {
                let inventory = try await Task.detached(priority: .utility) {
                    let context = try AgentHistoryContext.make(provider: provider, project: project, home: NSHomeDirectory())
                    return try await AgentHistoryService.list(context: context)
                }.value
                guard generation == token else { return }
                update(provider) {
                    $0.inventory = inventory
                    $0.selection = []
                    $0.statusKey = inventory.sessions.isEmpty ? "agents.history.empty" : nil
                }
            } catch {
                guard generation == token else { return }
                update(provider) {
                    // Old metadata cannot authorize a retry after a failed list.
                    $0.inventory = nil
                    $0.selection = []
                    $0.statusKey = (error as? AgentHistoryFailure)?.key ?? "agents.history.error.api"
                }
            }
        }
    }

    func requestDelete(_ provider: AgentHistoryProvider, state: AppState) {
        guard canStart(state), AgentHistoryService.interfacesEnabled, let inventory = page(provider).inventory else { return }
        let selected = inventory.sessions.filter { page(provider).selection.contains($0.id) && $0.canSelect }
        guard !selected.isEmpty, selected.count <= 100 else { return }
        let l10n = L10n.shared
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = l10n.tf("agents.history.confirm.title", selected.count)
        alert.informativeText = l10n.tf("agents.history.confirm.message", provider.name, inventory.context.project)
            + "\n\n" + selected.prefix(5).map { "• " + $0.title }.joined(separator: "\n")
        alert.addButton(withTitle: l10n.t("agents.history.delete"))
        alert.addButton(withTitle: l10n.t("agents.history.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn, canStart(state) else { return }
        let token = begin(provider, state: state)
        total = selected.count
        completed = 0
        update(provider) { $0.statusKey = "agents.history.deleting"; $0.statusArguments = []; $0.failureKeys = [:] }
        Task {
            defer { end(token, state: state) }
            let result = await Task.detached(priority: .utility) {
                await AgentHistoryService.delete(inventory: inventory, selected: selected) { [weak self] done, count in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token else { return }
                        self.completed = done
                        self.total = count
                    }
                }
            }.value
            guard generation == token else { return }
            update(provider) {
                if let remaining = result.remaining {
                    $0.inventory = .init(context: inventory.context, sessions: remaining, version: inventory.version)
                }
                $0.selection = []
                $0.failureKeys = result.failed
                $0.backupDirectories += result.backups
                $0.backupDirectories = Array($0.backupDirectories.suffix(100))
                $0.statusKey = "agents.history.result"
                $0.statusArguments = [String(result.deleted.count), String(result.failed.count)]
            }
            if !result.deleted.isEmpty {
                // Keep the history page and its failed records visible while the
                // existing inventory route refreshes disk sizes in the background.
                end(token, state: state)
                state.scanAgents()
            }
        }
    }

    func revealBackups(_ provider: AgentHistoryProvider) {
        guard let path = page(provider).backupDirectories.last else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    private func canStart(_ state: AppState) -> Bool {
        busy == nil && !state.isAgentTaskBusy && !state.isCleanupMutationBusy
            && state.uninstallQueue.activeJob == nil && state.commandLineToolBusyID == nil && state.softwareUpdatingID == nil
    }

    private func begin(_ provider: AgentHistoryProvider, state: AppState) -> UUID {
        generation = UUID()
        busy = provider
        completed = 0
        total = 0
        state.agentProgramBusyID = "history-" + generation.uuidString
        return generation
    }

    private func end(_ token: UUID, state: AppState) {
        guard generation == token else { return }
        if state.agentProgramBusyID == "history-" + token.uuidString { state.agentProgramBusyID = nil }
        busy = nil
    }

    private func update(_ provider: AgentHistoryProvider, _ edit: (inout AgentHistoryPageState) -> Void) {
        var next = page(provider)
        edit(&next)
        pages[provider] = next
    }
}
