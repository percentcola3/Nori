import SwiftUI
import AppKit

@MainActor
final class DeveloperCLIModel: ObservableObject {
    @Published private(set) var snapshot: DeveloperCLISnapshot?
    @Published private(set) var isChecking = false
    @Published private(set) var completedRefreshToken: Int?
    private var refreshTask: Task<Void, Never>?
    private var lastRefreshToken: Int?

    func refresh(for token: Int, environment: [String: String]? = nil) {
        guard lastRefreshToken != token else { return }
        lastRefreshToken = token
        refreshTask?.cancel()
        isChecking = true
        refreshTask = Task {
            let discovered = await Task.detached(priority: .utility) { DeveloperCLIService.discover(environment: environment ?? ProcessInfo.processInfo.environment) }.value
            guard !Task.isCancelled else { return }
            snapshot = discovered
            let inspected = await DeveloperCLIService.inspectVersions(in: discovered)
            guard !Task.isCancelled else { return }
            snapshot = inspected
            completedRefreshToken = token
            isChecking = false
        }
    }

    func openDiagnostic(for tool: DeveloperCLITool) {
        guard let script = DeveloperCLIService.terminalScript(for: tool) else {
            TaskFeedbackNotice.reportFailure(messageKey: "task.reason.terminal")
            return
        }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nori-cli-diagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent(tool.id + ".command")
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                TaskFeedbackNotice.reportFailure(messageKey: "task.reason.terminal")
                return
            }
            NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: .init()) { _, error in
                if error != nil {
                    Task { @MainActor in
                        TaskFeedbackNotice.reportFailure(messageKey: "task.reason.terminal")
                    }
                }
            }
        } catch { TaskFeedbackNotice.reportFailure(messageKey: "task.reason.terminal") }
    }
}

/// Independent from the cleanup inventory. The workspace's refresh token invalidates
/// the model's inexpensive discovery, and version probes stay off the UI thread.
struct DeveloperCLIPanel: View {
    @ObservedObject var model: DeveloperCLIModel
    @ObservedObject private var l10n = L10n.shared
    @State private var onlyIssues = false
    @State private var expandedSources: Set<String> = []

    private var filteredEntries: [DeveloperCLIEntry] {
        guard let snapshot = model.snapshot else { return [] }
        return snapshot.entries.filter { entry in
            !onlyIssues || (entry.isFound && (!entry.isInPATH || entry.hasPATHShadowing || entry.version == .timedOut || entry.version == .unavailable))
        }
    }

    var body: some View {
        DevCard(id: "dev-cli") {
            DevCardTitle(symbol: "terminal", title: L10n.shared.t("dev.cli.title"),
                         subtitle: model.snapshot.map {
                             L10n.shared.tf("dev.cli.found", $0.entries.filter(\.isFound).count)
                         })
            Spacer(minLength: 8)
            if model.isChecking {
                ProgressView().controlSize(.small).help(L10n.shared.t("dev.cli.checking"))
            }
            Toggle(L10n.shared.t("dev.cli.issuesOnly"), isOn: $onlyIssues)
                .toggleStyle(.checkbox).font(.system(size: 11)).fixedSize()
            if let snapshot = model.snapshot {
                DevLinkButton(title: L10n.shared.t("dev.cli.copyPath"), symbol: "doc.on.doc") {
                    DeveloperCLIText.copy(snapshot.pathDirectories.joined(separator: ":"))
                }
                .help(L10n.shared.t("dev.cli.copyPath.help"))
            }
        } content: {
            DevDivider()
            if let snapshot = model.snapshot {
                DeveloperCLIContextView(snapshot: snapshot)
                if filteredEntries.isEmpty {
                    DevDivider()
                    DevNotice(symbol: "checkmark.circle", text: L10n.shared.t("dev.cli.empty"))
                } else {
                    ForEach(DeveloperCLICategory.allCases) { category in
                        let entries = filteredEntries.filter { $0.tool.category == category }
                        if !entries.isEmpty {
                            DevDivider()
                            DeveloperCLICategoryView(category: category, entries: entries,
                                                     expandedSources: $expandedSources,
                                                     openDiagnostic: model.openDiagnostic)
                        }
                    }
                }
            } else {
                ProgressView(L10n.shared.t("dev.cli.discovering"))
                    .controlSize(.small).font(.system(size: 11))
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
        }
    }
}

private struct DeveloperCLIContextView: View {
    @ObservedObject private var l10n = L10n.shared
    let snapshot: DeveloperCLISnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DevNotice(symbol: "info.circle",
                      text: L10n.shared.t("dev.cli.environment.help"))
            if !snapshot.duplicatePATHDirectories.isEmpty {
                DevNotice(symbol: "exclamationmark.triangle",
                          text: L10n.shared.tf("dev.cli.duplicatePath", snapshot.duplicatePATHDirectories.count),
                          color: .warning)
            }
            if snapshot.hasRelativePATHEntry {
                DevNotice(symbol: "exclamationmark.triangle",
                          text: L10n.shared.t("dev.cli.relativePath"),
                          color: .warning)
            }
        }
    }
}

private struct DeveloperCLICategoryView: View {
    @ObservedObject private var l10n = L10n.shared
    let category: DeveloperCLICategory
    let entries: [DeveloperCLIEntry]
    @Binding var expandedSources: Set<String>
    let openDiagnostic: (DeveloperCLITool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DevSubheader(title: DeveloperCLIText.category(category),
                         detail: "\(entries.filter(\.isFound).count) / \(entries.count)")
            ForEach(Array(entries.enumerated()), id: \.element.id) { offset, entry in
                if offset > 0 { DevDivider(inset: 14) }
                DeveloperCLIRow(entry: entry,
                                showsLocations: Binding(
                                    get: { expandedSources.contains(entry.id) },
                                    set: { visible in
                                        if visible { expandedSources.insert(entry.id) }
                                        else { expandedSources.remove(entry.id) }
                                    }),
                                openDiagnostic: openDiagnostic)
            }
            Color.clear.frame(height: 4)
        }
    }
}

private struct DeveloperCLIRow: View {
    let entry: DeveloperCLIEntry
    @Binding var showsLocations: Bool
    let openDiagnostic: (DeveloperCLITool) -> Void
    @State private var copied = false
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(entry.tool.name).font(.system(size: 12, weight: .semibold))
                Text(versionLabel).font(.system(size: 11).monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .help(versionHelp)
                Spacer(minLength: 5)
                Text(statusLabel).font(.system(size: 10, weight: .medium)).foregroundStyle(statusColor)
                Menu {
                    if let location = entry.preferredLocation {
                        Button(L10n.shared.t("dev.cli.copyLocation")) { copy(location.path) }
                    }
                    Button(L10n.shared.t("dev.cli.copyDiagnostic")) {
                        copy(DeveloperCLIService.diagnosticCommand(for: entry.tool))
                    }
                    Button(L10n.shared.t("dev.cli.openDiagnostic")) {
                        openDiagnostic(entry.tool)
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "ellipsis.circle")
                        .font(.system(size: 14))
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel(L10n.shared.tf("dev.cli.actions", entry.tool.name))
            }
            if let preferred = entry.preferredLocation {
                HStack(spacing: 6) {
                    Text(DeveloperCLIText.sourceLabel(preferred.source)).font(.system(size: 10, weight: .medium)).foregroundStyle(Color.accentText)
                    Text(DeveloperCLIText.abbreviate(preferred.path))
                        .font(.system(size: 10).monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer(minLength: 0)
                    if entry.locations.count > 1 {
                        Button {
                            withAnimation(reduceMotion ? nil : MoleMotion.panel) {
                                showsLocations.toggle()
                            }
                        } label: {
                            Label(L10n.shared.tf("dev.cli.sources", entry.locations.count), systemImage: showsLocations ? "chevron.up" : "chevron.down")
                        }
                        .font(.system(size: 10)).buttonStyle(.plain)
                    }
                }
                if entry.hasPATHShadowing {
                    explanation(L10n.shared.t("dev.cli.shadowing.help"))
                } else if !entry.isInPATH {
                    explanation(L10n.shared.t("dev.cli.outsidePath.help"))
                }
                if showsLocations {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(entry.locations) { location in
                            DeveloperCLILocationRow(location: location, isPreferred: location.id == preferred.id)
                        }
                    }
                    .padding(.top, 3)
                    .transition(.molePanelReveal)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .clipped()
    }

    private var versionLabel: String {
        switch entry.version {
        case .pending: return L10n.shared.t("dev.cli.version.reading")
        case .value(let value): return value
        case .deferred: return L10n.shared.t("dev.cli.version.deferred")
        case .timedOut: return L10n.shared.t("dev.cli.version.timeout")
        case .unavailable: return entry.isFound ? L10n.shared.t("dev.cli.version.unavailable") : ""
        }
    }
    private var versionHelp: String {
        switch entry.version {
        case .deferred: return L10n.shared.t("dev.cli.version.deferred.help")
        case .timedOut: return L10n.shared.t("dev.cli.version.timeout.help")
        case .unavailable: return L10n.shared.t("dev.cli.version.unavailable.help")
        default: return versionLabel
        }
    }
    private var statusLabel: String {
        if entry.hasPATHShadowing { return L10n.shared.t("dev.cli.shadowing") }
        if entry.isInPATH { return "PATH" }
        return entry.isFound ? L10n.shared.t("dev.cli.extra") : L10n.shared.t("dev.cli.notFound")
    }
    private var statusColor: Color { entry.hasPATHShadowing ? .warning : (entry.isInPATH ? .success : .secondary) }
    private func explanation(_ text: String) -> some View {
        Text(text).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func copy(_ text: String) {
        DeveloperCLIText.copy(text)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            copied = false
        }
    }
}

private struct DeveloperCLILocationRow: View {
    @ObservedObject private var l10n = L10n.shared
    let location: DeveloperCLILocation
    let isPreferred: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isPreferred ? "arrow.right.circle" : "circle")
                .font(.system(size: 10)).foregroundStyle(isPreferred ? Color.accentText : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(DeveloperCLIText.abbreviate(location.path)).font(.system(size: 10).monospaced()).textSelection(.enabled)
                Text(DeveloperCLIText.sourceLabel(location.source) + " · " + (location.isInPATH ? "PATH" : L10n.shared.t("dev.cli.outsidePath")))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { DeveloperCLIText.copy(location.path) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.plain).font(.system(size: 10))
                .accessibilityLabel(L10n.shared.tf("dev.cli.copyLocation.accessibility", location.path))
        }
    }
}

private enum DeveloperCLIText {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
    static func sourceLabel(_ source: String) -> String {
        source == "PATH / local" ? L10n.shared.t("dev.cli.source.local") : source
    }
    static func category(_ category: DeveloperCLICategory) -> String {
        switch category {
        case .web: return L10n.shared.t("dev.cli.category.web")
        case .python: return "Python"
        case .jvm: return "Java / JVM"
        case .mobile: return L10n.shared.t("dev.cli.category.mobile")
        case .systems: return "Rust / Go"
        case .utilities: return L10n.shared.t("dev.cli.category.utilities")
        }
    }
    static func symbol(_ category: DeveloperCLICategory) -> String {
        switch category {
        case .web: return "curlybraces"
        case .python: return "chevron.left.forwardslash.chevron.right"
        case .jvm: return "cup.and.saucer"
        case .mobile: return "iphone"
        case .systems: return "cpu"
        case .utilities: return "terminal"
        }
    }
}
