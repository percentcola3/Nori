import SwiftUI
import AppKit

@MainActor
private final class DeveloperCLIModel: ObservableObject {
    @Published private(set) var snapshot: DeveloperCLISnapshot?
    @Published private(set) var isChecking = false
    @Published private(set) var completedRefreshToken: Int?
    private var refreshTask: Task<Void, Never>?
    private var lastRefreshToken: Int?

    func refresh(for token: Int) {
        guard lastRefreshToken != token else { return }
        lastRefreshToken = token
        refreshTask?.cancel()
        isChecking = true
        refreshTask = Task {
            let discovered = await Task.detached(priority: .utility) { DeveloperCLIService.discover() }.value
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

/// Independent from the cleanup inventory. A navigation refresh token invalidates
/// this panel's own inexpensive discovery, and version probes stay off the UI thread.
struct DeveloperCLIPanel: View {
    let refreshToken: Int
    var isExpanded = true
    @StateObject private var model = DeveloperCLIModel()
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
        DeveloperWorkspaceContent(isExpanded: isExpanded) {
            visibleContent
        }
        .preference(key: DeveloperWorkspaceSearchKey.self,
                    value: [.cli: DeveloperWorkspaceSearchState(
                        refreshToken: refreshToken,
                        isSearching: model.completedRefreshToken != refreshToken || model.isChecking)])
        .task(id: refreshToken) { model.refresh(for: refreshToken) }
    }

    private var visibleContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let snapshot = model.snapshot {
                DeveloperCLIContextView(snapshot: snapshot, onlyIssues: $onlyIssues, isChecking: model.isChecking)
                if filteredEntries.isEmpty {
                    Text(DeveloperCLIText.choose("没有符合条件的工具。", "No matching tools."))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(DeveloperCLICategory.allCases) { category in
                            let entries = filteredEntries.filter { $0.tool.category == category }
                            if !entries.isEmpty {
                                DeveloperCLICategoryView(category: category, entries: entries,
                                                         expandedSources: $expandedSources,
                                                         openDiagnostic: model.openDiagnostic)
                            }
                        }
                    }
                }
            } else {
                ProgressView(DeveloperCLIText.choose("读取常见工具来源…", "Discovering common tool sources…"))
                    .font(.system(size: 11)).padding(.vertical, 8)
            }
        }
    }
}

private struct DeveloperCLIContextView: View {
    let snapshot: DeveloperCLISnapshot
    @Binding var onlyIssues: Bool
    let isChecking: Bool
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "info.circle").foregroundStyle(Color.accentText)
                Text(DeveloperCLIText.choose("已发现 \(snapshot.entries.filter(\.isFound).count) 个工具", "\(snapshot.entries.filter(\.isFound).count) tools found"))
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if isChecking {
                    ProgressView().controlSize(.small)
                        .help(DeveloperCLIText.choose("检查中", "Checking"))
                }
                Toggle(DeveloperCLIText.choose("仅看问题", "Issues only"), isOn: $onlyIssues)
                    .toggleStyle(.checkbox).font(.system(size: 11)).fixedSize()
                Button {
                    DeveloperCLIText.copy(snapshot.pathDirectories.joined(separator: ":"))
                } label: {
                    Label(DeveloperCLIText.choose("复制 Nori PATH", "Copy Nori PATH"), systemImage: "doc.on.doc")
                }
                .font(.system(size: 11)).buttonStyle(.plain)
                .help(DeveloperCLIText.choose("复制当前应用继承的 PATH", "Copy the PATH inherited by this application"))
            }
            Text(DeveloperCLIText.choose("Nori PATH 与终端可能不同；未发现不等于未安装。", "Nori and Terminal PATHs may differ; undetected does not mean uninstalled."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !snapshot.duplicatePATHDirectories.isEmpty {
                Label(DeveloperCLIText.choose("PATH 重复目录：\(snapshot.duplicatePATHDirectories.count)", "Duplicate PATH directories: \(snapshot.duplicatePATHDirectories.count)"), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(Color.warning)
            }
            if snapshot.hasRelativePATHEntry {
                Text(DeveloperCLIText.choose("已跳过 PATH 的空值与相对路径。", "Empty and relative PATH entries were skipped."))
                    .font(.system(size: 11)).foregroundStyle(Color.warning)
            }
        }
    }
}

private struct DeveloperCLICategoryView: View {
    let category: DeveloperCLICategory
    let entries: [DeveloperCLIEntry]
    @Binding var expandedSources: Set<String>
    let openDiagnostic: (DeveloperCLITool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: DeveloperCLIText.symbol(category)).foregroundStyle(Color.accentText)
                Text(DeveloperCLIText.category(category)).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(entries.filter(\.isFound).count) / \(entries.count)")
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }.padding(.top, 4)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(entries) { entry in
                    DeveloperCLIRow(entry: entry,
                                    showsLocations: Binding(
                                        get: { expandedSources.contains(entry.id) },
                                        set: { visible in
                                            if visible { expandedSources.insert(entry.id) }
                                            else { expandedSources.remove(entry.id) }
                                        }),
                                    openDiagnostic: openDiagnostic)
                }
            }
            .padding(.leading, 16)
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
                        Button(DeveloperCLIText.choose("复制路径", "Copy path")) { copy(location.path) }
                    }
                    Button(DeveloperCLIText.choose("复制诊断命令", "Copy diagnostic command")) {
                        copy(DeveloperCLIService.diagnosticCommand(for: entry.tool))
                    }
                    Button(DeveloperCLIText.choose("在 Terminal 检查来源", "Check sources in Terminal")) {
                        openDiagnostic(entry.tool)
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "ellipsis.circle")
                        .font(.system(size: 14))
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel(DeveloperCLIText.choose("\(entry.tool.name) 工具操作", "Actions for \(entry.tool.name)"))
            }
            if let preferred = entry.preferredLocation {
                HStack(spacing: 6) {
                    Text(preferred.source).font(.system(size: 10, weight: .medium)).foregroundStyle(Color.accentText)
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
                            Label(DeveloperCLIText.choose("\(entry.locations.count) 个来源", "\(entry.locations.count) sources"), systemImage: showsLocations ? "chevron.up" : "chevron.down")
                        }
                        .font(.system(size: 10)).buttonStyle(.plain)
                    }
                }
                if entry.hasPATHShadowing {
                    explanation(DeveloperCLIText.choose("PATH 首个来源优先，可展开比较。", "The first PATH source wins. Expand to compare."))
                } else if !entry.isInPATH {
                    explanation(DeveloperCLIText.choose("未在 Nori PATH 中，可在终端检查来源。", "Outside Nori PATH. Check sources in Terminal."))
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
        .padding(10)
        .clipped()
        .modifier(ListRowGlass())
    }

    private var versionLabel: String {
        switch entry.version {
        case .pending: return DeveloperCLIText.choose("读取版本…", "Reading version…")
        case .value(let value): return value
        case .deferred: return DeveloperCLIText.choose("仅查来源", "Source only")
        case .timedOut: return DeveloperCLIText.choose("版本读取超时", "Version lookup timed out")
        case .unavailable: return entry.isFound ? DeveloperCLIText.choose("版本不可用", "Version unavailable") : ""
        }
    }
    private var versionHelp: String {
        switch entry.version {
        case .deferred: return DeveloperCLIText.choose("为避免 SDK 下载、安装或初始化，未运行版本命令。", "Version commands were skipped to avoid SDK downloads, installation, or initialization.")
        case .timedOut: return DeveloperCLIText.choose("已停止检查，可复制诊断命令检查来源。", "Lookup stopped. Copy the diagnostic command to check sources.")
        case .unavailable: return DeveloperCLIText.choose("版本不可读，请检查链接、权限或工具依赖。", "Version unavailable. Check links, permissions, or dependencies.")
        default: return versionLabel
        }
    }
    private var statusLabel: String {
        if entry.hasPATHShadowing { return DeveloperCLIText.choose("PATH 多来源", "Multiple PATH sources") }
        if entry.isInPATH { return "Nori PATH" }
        return entry.isFound ? DeveloperCLIText.choose("额外安装", "Extra installation") : DeveloperCLIText.choose("未发现", "Not found")
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
    let location: DeveloperCLILocation
    let isPreferred: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isPreferred ? "arrow.right.circle" : "circle")
                .font(.system(size: 10)).foregroundStyle(isPreferred ? Color.accentText : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(DeveloperCLIText.abbreviate(location.path)).font(.system(size: 10).monospaced()).textSelection(.enabled)
                Text(location.source + " · " + (location.isInPATH ? "Nori PATH" : DeveloperCLIText.choose("不在 Nori PATH", "Outside Nori PATH")))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { DeveloperCLIText.copy(location.path) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.plain).font(.system(size: 10))
                .accessibilityLabel(DeveloperCLIText.choose("复制 \(location.path)", "Copy \(location.path)"))
        }
    }
}

private enum DeveloperCLIText {
    static func choose(_ chinese: String, _ english: String) -> String {
        [.zhHans, .zhHant].contains(L10n.shared.resolved) ? chinese : english
    }
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
    static func category(_ category: DeveloperCLICategory) -> String {
        switch category {
        case .web: return choose("Web 与 JavaScript", "Web & JavaScript")
        case .python: return "Python"
        case .jvm: return "Java / JVM"
        case .mobile: return choose("Apple 与移动开发", "Apple & mobile development")
        case .systems: return "Rust / Go"
        case .utilities: return choose("开发基础工具", "Developer utilities")
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
