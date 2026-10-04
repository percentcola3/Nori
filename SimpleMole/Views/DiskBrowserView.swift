import SwiftUI

/// Directory navigation reads the saved index; opening a column never starts a scan.
struct DiskBrowserView: View {
    @ObservedObject var state: AppState
    let scanning: Bool
    let onPreview: (String) -> Void
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var currentPath: String {
        state.diskBrowserNavigation.last ?? state.diskBrowserRootPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    if let parent = state.diskBrowserNavigation.dropLast().last {
                        state.navigateDiskBrowser(to: parent)
                    }
                } label: { Image(systemName: "chevron.left") }
                .buttonStyle(MoleIconButtonStyle(showsBackground: false))
                .disabled(state.diskBrowserNavigation.count <= 1)
                .help(l10n.t("analyze.browser.back"))
                .accessibilityLabel(l10n.t("analyze.browser.back"))
                Button { state.navigateDiskBrowser(to: state.diskBrowserRootPath) } label: {
                    Image(systemName: "house")
                }
                .buttonStyle(MoleIconButtonStyle(showsBackground: false))
                .help(l10n.t("analyze.section.disk"))
                .accessibilityLabel(l10n.t("analyze.section.disk"))
                Text(abbreviate(currentPath))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 20)

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(state.diskBrowserNavigation, id: \.self) { path in
                            DiskBrowserColumn(
                                path: path,
                                title: title(for: path),
                                entries: entries(for: path),
                                totalSize: directorySize(path),
                                isPartial: directoryIsPartial(path),
                                isOverview: path == state.diskBrowserRootPath,
                                openedPath: openedPath(after: path),
                                selectedPaths: state.analysisSelection(for: .disk),
                                disabled: state.isBusy || scanning,
                                canSelect: { path == currentPath && state.diskBrowserCanSelect($0) },
                                onOpen: { state.openDiskBrowserDirectory($0, in: path) },
                                onToggle: {
                                    guard path == currentPath else { return }
                                    state.toggleAnalysisFileSelection(.init(name: $0.name, path: $0.path, size: $0.size))
                                },
                                onPreview: onPreview, onReveal: state.revealPath)
                                .frame(width: 270)
                                .id(path)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .task(id: currentPath) {
                    withAnimation(reduceMotion ? nil : MoleMotion.panel) {
                        proxy.scrollTo(currentPath, anchor: .trailing)
                    }
                }
            }
        }
        .padding(.top, 14)
        .accessibilityIdentifier("analysis-disk-browser")
    }

    private func openedPath(after path: String) -> String? {
        guard let index = state.diskBrowserNavigation.firstIndex(of: path),
              state.diskBrowserNavigation.indices.contains(index + 1) else { return nil }
        return state.diskBrowserNavigation[index + 1]
    }

    private func abbreviate(_ path: String) -> String {
        if path == state.diskBrowserRootPath { return l10n.t("analyze.section.disk") }
        let home = state.diskBrowserHomePath
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private func title(for path: String) -> String {
        if path == state.diskBrowserRootPath { return l10n.t("analyze.section.disk") }
        if path == state.diskBrowserHomePath { return l10n.t("analyze.browser.home") }
        return scopeTitle(for: path) ?? (path as NSString).lastPathComponent
    }

    private func entries(for path: String) -> [AnalyzeEntry] {
        let entries = state.diskBrowserEntries(at: path)
        guard path == state.diskBrowserRootPath else { return entries }
        return entries.map { entry in
            let name = entry.path == state.diskBrowserHomePath ? l10n.t("analyze.browser.home")
                : scopeTitle(for: entry.path) ?? entry.name
            return AnalyzeEntry(name: name, path: entry.path,
                                size: entry.size, isDir: true, isPartial: entry.isPartial)
        }
    }

    private func scopeTitle(for path: String) -> String? {
        let key: String
        switch path {
        case "/private/var/log": key = "analyze.browser.scope.logs"
        case "/private/var/db/diagnostics": key = "analyze.browser.scope.systemLogs"
        case "/private/var/db/powerlog": key = "analyze.browser.scope.power"
        case "/private/var/folders": key = "analyze.browser.scope.systemTemporary"
        case "/private/tmp": key = "analyze.browser.scope.temporary"
        case "/private/var/tmp": key = "analyze.browser.scope.persistentTemporary"
        case "/private/var/vm", "/System/Volumes/VM": key = "analyze.browser.scope.swap"
        case "/Library/Caches": key = "analyze.browser.scope.systemCaches"
        default: return nil
        }
        return l10n.t(key)
    }

    private func directoryIsPartial(_ path: String) -> Bool {
        if path == state.diskBrowserRootPath { return state.analysisReportsByMode[.disk]?.isPartial == true }
        guard let index = state.diskBrowserNavigation.firstIndex(of: path), index > 0 else { return false }
        let parent = state.diskBrowserNavigation[index - 1]
        return state.diskBrowserEntries(at: parent).first(where: { $0.path == path })?.isPartial == true
    }

    private func directorySize(_ path: String) -> UInt64 {
        if path == state.diskBrowserRootPath { return state.analysisReportsByMode[.disk]?.totalSize ?? 0 }
        guard let index = state.diskBrowserNavigation.firstIndex(of: path), index > 0 else { return 0 }
        let parent = state.diskBrowserNavigation[index - 1]
        return state.diskBrowserEntries(at: parent).first(where: { $0.path == path })?.size ?? 0
    }
}

private struct DiskBrowserColumn: View {
    let path: String
    let title: String
    let entries: [AnalyzeEntry]
    let totalSize: UInt64
    let isPartial: Bool
    let isOverview: Bool
    let openedPath: String?
    let selectedPaths: Set<String>
    let disabled: Bool
    let canSelect: (AnalyzeEntry) -> Bool
    let onOpen: (AnalyzeEntry) -> Void
    let onToggle: (AnalyzeEntry) -> Void
    let onPreview: (String) -> Void
    let onReveal: (String) -> Void
    @ObservedObject private var l10n = L10n.shared
    @Namespace private var selectionNamespace

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text((isPartial || entries.contains { $0.isPartial == true } ? "≥ " : "")
                    + ByteFormat.format(totalSize))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            Divider()
            ScrollView {
                LiquidGlassGroup {
                    LazyVStack(spacing: 4) {
                        ForEach(entries) { entry in
                            DiskBrowserRow(entry: entry,
                                isSelected: selectedPaths.contains(entry.path),
                                isOpened: entry.isDir && openedPath == entry.path,
                                canSelect: canSelect(entry), disabled: disabled,
                                showsPath: isOverview,
                                namespace: selectionNamespace,
                                onOpen: { onOpen(entry) }, onToggle: { onToggle(entry) },
                                onPreview: { onPreview(entry.path) }, onReveal: { onReveal(entry.path) })
                        }
                    }
                    .padding(.horizontal, 6).padding(.bottom, 8)
                }
                if entries.isEmpty {
                    Text(l10n.t(isPartial ? "analyze.browser.unreadable" : "analyze.browser.empty"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 20)
                }
            }
        }
        .padding(.trailing, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.hairline).frame(width: 1) }
        .accessibilityIdentifier("analysis-disk-column-" + path)
    }
}

private struct DiskBrowserRow: View {
    let entry: AnalyzeEntry
    let isSelected: Bool
    let isOpened: Bool
    let canSelect: Bool
    let disabled: Bool
    let showsPath: Bool
    let namespace: Namespace.ID
    let onOpen: () -> Void
    let onToggle: () -> Void
    let onPreview: () -> Void
    let onReveal: () -> Void
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        HStack(spacing: 4) {
            Toggle(entry.name, isOn: Binding(get: { isSelected }, set: { _ in onToggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!canSelect || disabled)
                .help(l10n.t(canSelect ? "analyze.browser.select" : "analyze.browser.selection.unavailable"))
                .accessibilityLabel(l10n.t("analyze.browser.select") + ": " + entry.name)
                .accessibilityIdentifier("analysis-disk-select-" + entry.path)
            Button(action: entry.isDir ? onOpen : onToggle) {
                HStack(spacing: 7) {
                    Image(systemName: entry.isDir ? "folder.fill" : "doc")
                        .font(.system(size: 13))
                        .foregroundStyle(entry.isDir || isSelected ? Color.moleAccentText : Color.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).font(.system(size: 11, weight: isSelected || isOpened ? .semibold : .medium))
                            .lineLimit(1).truncationMode(.middle)
                        if showsPath {
                            Text(entry.path).font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text((entry.isPartial == true ? "≥ " : "") + ByteFormat.format(entry.size))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary).fixedSize()
                    if entry.isDir {
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(MolePlainButtonStyle(pressedScale: 0.99))
            .disabled(!entry.isDir && (!canSelect || disabled))
            .accessibilityLabel(entry.path)
            .accessibilityValue((entry.isPartial == true ? "≥ " : "") + ByteFormat.format(entry.size))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .help(entry.isDir ? l10n.t("analyze.browser.folder") : entry.path)
            if !entry.isDir {
                Button(action: onPreview) { Image(systemName: "eye") }
                    .buttonStyle(MoleIconButtonStyle(size: 22, showsBackground: false))
                    .help(l10n.t("duplicates.preview"))
                    .accessibilityLabel(l10n.t("duplicates.preview") + ": " + entry.name)
                Button(action: onReveal) { Image(systemName: "folder") }
                    .buttonStyle(MoleIconButtonStyle(size: 22, showsBackground: false))
                    .help(l10n.t("analyze.reveal"))
                    .accessibilityLabel(l10n.t("analyze.reveal") + ": " + entry.name)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .modifier(DiskBrowserRowSurface(selected: isSelected || isOpened, isOpened: isOpened && !isSelected,
                                       id: entry.path, namespace: namespace))
        .accessibilityIdentifier("analysis-disk-entry-" + entry.path)
    }
}

private struct DiskBrowserRowSurface: ViewModifier {
    let selected: Bool
    let isOpened: Bool
    let id: String
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var controlActiveState

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency, controlActiveState == .key {
            content
                .glassEffect(selected ? .regular.tint(Color.moleAccent.opacity(0.20)).interactive(!reduceMotion)
                    : .identity, in: RoundedRectangle(cornerRadius: 8))
                .glassEffectID(isOpened ? "directory-navigation" : id, in: namespace)
                .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
                .clipGlassEdge(in: RoundedRectangle(cornerRadius: 8))
        } else {
            content.background {
                if selected { GlassSurface(cornerRadius: 8, usesSystemGlass: false, highlighted: true) }
            }
        }
    }
}
