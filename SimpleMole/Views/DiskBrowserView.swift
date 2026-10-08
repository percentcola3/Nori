import SwiftUI

/// Directory navigation reads the saved index; opening a column never starts a scan.
struct DiskBrowserView: View {
    @ObservedObject var state: AppState
    let scanning: Bool
    let onPreview: (String) -> Void
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let nav = state.diskBrowserNavigation
        let layout = DiskAnalysisWorker.diskBrowserColumnLayout(nav)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    if let parent = nav.dropLast().last {
                        state.navigateDiskBrowser(to: parent)
                    }
                } label: { Image(systemName: "chevron.left") }
                .buttonStyle(MoleIconButtonStyle(showsBackground: false))
                .disabled(nav.count <= 1)
                .help(l10n.t("analyze.browser.back"))
                .accessibilityLabel(l10n.t("analyze.browser.back"))
                Button { state.navigateDiskBrowser(to: state.diskBrowserRootPath) } label: {
                    Image(systemName: "house")
                }
                .buttonStyle(MoleIconButtonStyle(showsBackground: false))
                .help(l10n.t("analyze.section.disk"))
                .accessibilityLabel(l10n.t("analyze.section.disk"))
                DiskBreadcrumb(nav: nav, title: title(for:),
                               onNavigate: { state.navigateDiskBrowser(to: $0) })
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)

            // 层级深于两列时更早的层级折叠为窄条；横向不再滚动。
            HStack(alignment: .top, spacing: 0) {
                ForEach(layout.collapsed, id: \.self) { path in
                    DiskBrowserCollapsedColumn(path: path, title: title(for: path)) {
                        state.navigateDiskBrowser(to: path)
                    }
                }
                ForEach(layout.expanded, id: \.self) { path in
                    DiskBrowserColumn(
                        path: path,
                        title: title(for: path),
                        entries: entries(for: path),
                        totalSize: directorySize(path),
                        isPartial: directoryIsPartial(path),
                        isOverview: path == state.diskBrowserRootPath,
                        openedPath: openedPath(after: path),
                        selectedPaths: state.analysisSelection(for: .disk),
                        disabled: state.isAnalysisTaskBusy || scanning,
                        canSelect: state.diskBrowserCanSelect,
                        onOpen: { state.openDiskBrowserDirectory($0, in: path) },
                        onToggle: {
                            state.toggleDiskBrowserSelection($0, in: path)
                        },
                        onPreview: onPreview, onReveal: state.revealPath)
                        .frame(minWidth: 240, maxWidth: .infinity)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 8)
            .animation(reduceMotion ? nil : MoleMotion.panel, value: nav)
        }
        .padding(.top, 2)
        .accessibilityIdentifier("analysis-disk-browser")
    }

    private func openedPath(after path: String) -> String? {
        guard let index = state.diskBrowserNavigation.firstIndex(of: path),
              state.diskBrowserNavigation.indices.contains(index + 1) else { return nil }
        return state.diskBrowserNavigation[index + 1]
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
                LazyVStack(spacing: 4) {
                    ForEach(entries) { entry in
                        DiskBrowserRow(entry: entry,
                            isSelected: selectedPaths.contains(entry.path),
                            isOpened: entry.isDir && openedPath == entry.path,
                            canSelect: canSelect(entry), disabled: disabled,
                            showsPath: isOverview,
                            onOpen: { onOpen(entry) }, onToggle: { onToggle(entry) },
                            onPreview: { onPreview(entry.path) }, onReveal: { onReveal(entry.path) })
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 8)
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

/// 折叠的历史层级：固定 36pt 窄条，点按回到该层级。
/// 名称为 90° 旋转（自上而下）的单行文字，长名中间截断。
private struct DiskBrowserCollapsedColumn: View {
    let path: String
    let title: String
    let onOpen: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.moleAccentText)
                verticalTitle
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 12)
            .background(isHovering ? Color.surface2 : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("analysis-disk-collapsed-" + path)
        .frame(width: 36)
        .clipped()
        .overlay(alignment: .trailing) { Rectangle().fill(Color.hairline).frame(width: 1) }
        .transition(.opacity)
    }

    /// 旋转只改变绘制不改变布局：先把文字框在 140×14 的槽里，
    /// 旋转 90°（自上而下阅读）后外层再框成 14×140，竖排内容不外溢。
    private var verticalTitle: some View {
        Text(title)
            .font(.system(size: 10))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: 140, height: 14)
            .rotationEffect(.degrees(90))
            .frame(width: 14, height: 140)
    }
}

/// 路径面包屑：每个层级一个按钮，末段加粗且不可点；
/// 超过 4 段时中间层级收进「…」菜单。
private struct DiskBreadcrumb: View {
    let nav: [String]
    let title: (String) -> String
    let onNavigate: (String) -> Void

    private var visible: [String] {
        nav.count > 4 ? [nav[0]] + Array(nav.suffix(3)) : nav
    }
    private var omitted: [String] {
        nav.count > 4 ? Array(nav.dropFirst().dropLast(3)) : []
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(visible.enumerated()), id: \.element) { index, path in
                if index > 0 {
                    separator
                    if index == 1 && !omitted.isEmpty {
                        overflowMenu
                        separator
                    }
                }
                segment(path)
            }
        }
        .lineLimit(1)
    }

    private var separator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    private var overflowMenu: some View {
        Menu {
            ForEach(omitted, id: \.self) { path in
                Button(title(path)) { onNavigate(path) }
            }
        } label: {
            Text("…")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(minWidth: 14, minHeight: 14)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier("analysis-disk-breadcrumb-overflow")
    }

    private func segment(_ path: String) -> some View {
        let isLast = path == nav.last
        return Button { onNavigate(path) } label: {
            Text(title(path))
                .font(.system(size: 11, weight: isLast ? .semibold : .regular))
                .foregroundStyle(isLast ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(MolePlainButtonStyle(pressedScale: 0.98))
        .disabled(isLast)
        .accessibilityIdentifier("analysis-disk-breadcrumb-" + path)
    }
}

private struct DiskBrowserRow: View {
    let entry: AnalyzeEntry
    let isSelected: Bool
    let isOpened: Bool
    let canSelect: Bool
    let disabled: Bool
    let showsPath: Bool
    let onOpen: () -> Void
    let onToggle: () -> Void
    let onPreview: () -> Void
    let onReveal: () -> Void
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        HStack(spacing: 4) {
            if canSelect {
                Toggle(entry.name, isOn: Binding(get: { isSelected }, set: { _ in onToggle() }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(disabled)
                    .help(l10n.t("analyze.browser.select"))
                    .accessibilityLabel(l10n.t("analyze.browser.select") + ": " + entry.name)
                    .accessibilityIdentifier("analysis-disk-select-" + entry.path)
            } else {
                Image(systemName: "lock")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)
                    .help(l10n.t("analyze.browser.selection.unavailable"))
                    .accessibilityLabel(l10n.t("analyze.browser.selection.unavailable") + ": " + entry.name)
            }
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
        .modifier(DiskBrowserRowSurface(selected: isSelected, isOpened: isOpened && !isSelected))
        .accessibilityIdentifier("analysis-disk-entry-" + entry.path)
    }
}

/// 行底不再使用玻璃：勾选 selectionFill，已打开路径 surface2，其余透明。
private struct DiskBrowserRowSurface: ViewModifier {
    let selected: Bool
    let isOpened: Bool

    func body(content: Content) -> some View {
        content.background {
            if selected || isOpened {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.selectionFill : Color.surface2)
            }
        }
    }
}
