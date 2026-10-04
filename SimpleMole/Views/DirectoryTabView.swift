import AppKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// Small, direct file enhancements; Finder remains the destination for advanced work.
struct DirectoryTabView: View {
    @ObservedObject var model: DirectoryBrowserModel
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var dragNamespace
    @Namespace private var dialogNamespace
    @State private var dialog: DirectoryDialog?
    @State private var dialogText = ""
    @State private var isDropTarget = false
    @FocusState private var focusedField: DirectoryInput?

    private enum DirectoryInput: Hashable { case files, query, dialog }
    private enum DirectoryDialog: String { case path, rename }

    var body: some View {
        ZStack {
            VStack(spacing: 10) {
                toolbar
                fileList
                footer
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .disabled(dialog != nil)

            if let dialog {
                Button { dismissDialog() } label: {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(l10n.t("dir.cancel"))
                dialogContent(dialog)
                    .padding(22)
                    .frame(width: 410)
                    .liquidSurface("directory-dialog-" + dialog.rawValue)
                    .environment(\.liquidNamespace, dialogNamespace)
                    .transition(.opacity)
            }
        }
        .background { keyboardCommands }
        .onAppear { model.start() }
        .onDisappear { model.suspend() }
        .animation(reduceMotion ? nil : MoleMotion.panel, value: dialog)
        .accessibilityIdentifier("directory-tab")
    }

    private var breadcrumbs: some View {
        DirectoryPathBar(
            url: model.breadcrumbDirectory,
            isPathCopied: model.isBreadcrumbPathCopied,
            isRefreshing: model.isLoading || model.isWorking,
            onNavigate: model.navigate,
            onCopy: model.copyBreadcrumbPath,
            onGoToPath: { presentDialog(.path, text: model.breadcrumbDirectory.path) },
            onRefresh: model.refresh)
    }

    /// 两行工具栏：第一行搜索 + 常用目录快捷方式；第二行面包屑 + 复制/刷新/显示隐藏。
    private var toolbar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                searchField
                Spacer(minLength: 8)
                quickPlaces
            }
            HStack(spacing: 4) {
                breadcrumbs
                    .frame(minWidth: 120, maxWidth: .infinity)
                pathControls
            }
        }
    }

    private var quickPlaces: some View {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let places: [(String, String, URL)] = [
            ("dir.place.desktop", "menubar.dock.rectangle", home.appendingPathComponent("Desktop", isDirectory: true)),
            ("dir.downloads", "arrow.down.circle", home.appendingPathComponent("Downloads", isDirectory: true)),
            ("dir.place.documents", "doc.text", home.appendingPathComponent("Documents", isDirectory: true)),
            ("dir.home", "house", home),
            ("dir.place.applications", "square.grid.2x2", URL(fileURLWithPath: "/Applications", isDirectory: true)),
            ("dir.path.root", "internaldrive", URL(fileURLWithPath: "/", isDirectory: true))
        ]
        return HStack(spacing: 4) {
            ForEach(places, id: \.0) { key, symbol, url in
                let current = model.breadcrumbDirectory.standardizedFileURL.path == url.standardizedFileURL.path
                Button { model.navigate(to: url) } label: {
                    Label(l10n.t(key), systemImage: symbol)
                        .labelStyle(.iconOnly)
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(MoleIconButtonStyle(isActive: current, size: 30))
                .help(l10n.t(key))
                .accessibilityLabel(l10n.t(key))
                .accessibilityAddTraits(current ? .isSelected : [])
            }
        }
        .accessibilityIdentifier("directory-quick-places")
    }

    private var pathControls: some View {
        HStack(spacing: 4) {
            Button(action: model.copyBreadcrumbPath) {
                Image(systemName: model.isBreadcrumbPathCopied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(model.isBreadcrumbPathCopied ? Color.success : Color.secondary)
            }
            .buttonStyle(MoleIconButtonStyle(size: 30))
            .help(l10n.t(model.isBreadcrumbPathCopied ? "dir.path.copied" : "dir.path.copy"))
            .accessibilityLabel(l10n.t(model.isBreadcrumbPathCopied ? "dir.path.copied" : "dir.path.copy"))
            .accessibilityIdentifier("directory-copy-path")
            Button(action: model.refresh) {
                Group {
                    if model.isLoading || model.isWorking {
                        ProgressView().controlSize(.mini).scaleEffect(0.65)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .buttonStyle(MoleIconButtonStyle(size: 30))
            .disabled(model.isLoading || model.isWorking)
            .help(l10n.t("dir.refresh"))
            .accessibilityLabel(l10n.t("dir.refresh"))
            Button { model.showHidden.toggle() } label: {
                Image(systemName: model.showHidden ? "eye" : "eye.slash")
            }
            .buttonStyle(MoleIconButtonStyle(isActive: model.showHidden, size: 30))
            .help(l10n.t("dir.hidden.hint"))
            .accessibilityLabel(l10n.t("dir.hidden"))
            .accessibilityAddTraits(model.showHidden ? .isSelected : [])
            .accessibilityIdentifier("directory-hidden-toggle")
        }
    }

    private var searchField: some View {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(l10n.t("dir.search.placeholder"), text: $model.query)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .query)
                    .help(l10n.t("dir.search.hint"))
                    .accessibilityIdentifier("directory-search")
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help(l10n.t("dir.search.clear"))
                        .accessibilityLabel(l10n.t("dir.search.clear"))
                }
                if model.isSearching { ProgressView().controlSize(.small).scaleEffect(0.7) }
                indexMenu
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12).frame(height: 30)
            .modifier(DirectoryControlSurface())
            .frame(minWidth: 220, maxWidth: 420)
    }

    private var indexMenu: some View {
        Menu {
            Text(model.indexStatus)
            Divider()
            if model.isIndexing {
                Button(l10n.t("dir.index.cancel"), action: model.cancelIndexing)
            } else {
                Button(l10n.t("dir.index.update"), action: model.rebuildIndex)
                Button(l10n.t("dir.index.choose"), action: model.chooseIndexFolder)
            }
        } label: {
            Group {
                if model.isIndexing { ProgressView().controlSize(.mini) }
                else { Image(systemName: "externaldrive.badge.magnifyingglass") }
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .fixedSize()
        .help(l10n.t("dir.index.hint"))
        .accessibilityLabel(l10n.t("dir.index.menu"))
        .accessibilityIdentifier("directory-search-index")
    }

    private var fileList: some View {
        VStack(spacing: 5) {
            if model.isPathQuery {
                Text(l10n.t("dir.path.match.hint"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                Text(l10n.t("dir.column.name")).frame(maxWidth: .infinity, alignment: .leading)
                Text(l10n.t("dir.column.kind")).frame(width: 76, alignment: .leading)
                Text(l10n.t(model.isPathQuery ? "dir.path.match" : "dir.column.modified")).frame(width: 122, alignment: .leading)
                Text(l10n.t("dir.column.disk")).frame(width: 112, alignment: .trailing)
                Color.clear.frame(width: 28, height: 1).accessibilityHidden(true)
            }
            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 4)
            Rectangle().fill(Color.hairline).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.entries) { entry in
                        DirectoryFileRow(
                            entry: entry,
                            selected: model.selectedIDs.contains(entry.id),
                            sizeState: model.sizeStates[entry.id] ?? .pending,
                            sizeUpdatedAt: model.sizeUpdatedAt[entry.id],
                            isPartialSize: model.sizePartialIDs.contains(entry.id),
                            showParent: model.hasSearchQuery,
                            pathMatch: model.pathMatchScores[entry.id],
                            dragNamespace: dragNamespace,
                            onSelect: {
                                focusedField = .files
                                let flags = NSEvent.modifierFlags
                                withAnimation(reduceMotion ? nil : MoleMotion.selection) {
                                    model.select(entry: entry, extending: flags.contains(.command), range: flags.contains(.shift))
                                }
                            },
                            onOpen: { if model.isPathQuery { model.reveal([entry.url]) } else { model.open(entry: entry) } },
                            onDrop: { urls in model.importFiles(urls, into: entry.url) },
                            menu: { rowMenu(for: entry) })
                    }
                }
                .padding(.vertical, 4)
                .modifier(DirectoryDragContainer(entries: model.entries,
                                                 selectedIDs: model.selectedIDs,
                                                 namespace: dragNamespace))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .focusable()
            .modifier(DirectoryListFocus())
            .focused($focusedField, equals: .files)
            .onMoveCommand(perform: moveSelection)
            .overlay {
                if model.entries.isEmpty {
                    DirectoryEmptyState(
                        isLoading: model.isLoading || model.isSearching,
                        hasQuery: !model.query.isEmpty,
                        hasError: model.errorMessage != nil)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if isDropTarget {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentText, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTarget) { providers in
                guard !model.isWorking else { return false }
                return DirectoryFileDrop.load(providers) { urls in model.importFiles(urls, into: nil) }
            }
            .contextMenu {
                Button(l10n.t("dir.paste")) { focusedField = .files; model.paste() }
                    .disabled(!model.canPaste || model.isWorking)
                Divider()
                Button(l10n.t("dir.path.copy"), action: model.copyBreadcrumbPath)
            }
        }
        .frame(maxHeight: .infinity)
        .accessibilityIdentifier("directory-file-list")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let error = model.errorMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Color.warning)
                    Text(error).foregroundStyle(Color.warning).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button(action: model.clearError) { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help(l10n.t("dir.dismiss"))
                        .accessibilityLabel(l10n.t("dir.dismiss"))
                }
                .font(.system(size: 10))
            }
            if let status = model.statusMessage {
                Text(status).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 6) {
                Text(l10n.tf("dir.items.count", model.entries.count))
                if !model.selectedIDs.isEmpty { Text(l10n.tf("dir.selection.count", model.selectedIDs.count)) }
                Spacer(minLength: 4)
                Text(l10n.t("dir.size.hint")).lineLimit(1)
            }
            .font(.system(size: 9)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if model.isCalculatingSizes {
                    ProgressView().controlSize(.mini).scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                        .accessibilityHidden(true)
                }
                Text(model.sizeBackgroundStatus)
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func rowMenu(for entry: DirectoryEntry) -> some View {
        Button(l10n.t(entry.isDirectory ? "dir.open.folder" : "dir.open")) {
            focusedField = .files
            model.open(entry: entry)
        }
        Button(l10n.t("dir.finder")) {
            selectForAction(entry)
            model.revealSelectionInFinder()
        }
        Button(l10n.t("dir.path.copy")) { focusedField = .files; model.copyPath(entry.url) }
        Divider()
        Button(l10n.t("dir.copy")) { selectForAction(entry); model.copySelection() }
            .disabled(model.isWorking)
        Button(l10n.t("dir.cut")) { selectForAction(entry); model.cutSelection() }
            .disabled(model.isWorking)
        Button(l10n.t("dir.paste")) {
            focusedField = .files
            model.paste(into: entry.isDirectory ? entry.url : entry.url.deletingLastPathComponent())
        }
        .disabled(!model.canPaste || model.isWorking)
        Button(l10n.t("dir.rename")) { model.select(entry: entry, extending: false); beginRename() }
            .disabled(model.isWorking)
        Button(l10n.t("dir.trash"), role: .destructive) { selectForAction(entry); model.trashSelection() }
            .disabled(model.isWorking)
    }

    private func selectForAction(_ entry: DirectoryEntry) {
        focusedField = .files
        if !model.selectedIDs.contains(entry.id) { model.select(entry: entry, extending: false) }
    }

    private func beginRename() {
        guard let entry = model.selectedEntries.first, model.selectedEntries.count == 1 else { return }
        presentDialog(.rename, text: entry.name)
    }

    private func presentDialog(_ next: DirectoryDialog, text: String = "") {
        dialogText = text
        dialog = next
        focusedField = .dialog
    }

    private func dismissDialog() { dialog = nil; focusedField = .files }

    private var dialogTitleKey: String {
        switch dialog {
        case .path: "dir.path.go"
        case .rename: "dir.rename"
        case .none: "dir.rename"
        }
    }

    private func dialogContent(_ kind: DirectoryDialog) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Label(l10n.t(dialogTitleKey), systemImage: kind == .path ? "folder" : "pencil")
                .font(.system(size: 15, weight: .semibold))
            TextField(l10n.t(kind == .path ? "dir.path.placeholder" : "dir.name"), text: $dialogText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) { Rectangle().fill(Color.hairline).frame(height: 1) }
                .focused($focusedField, equals: .dialog)
                .onSubmit { if !dialogText.isEmpty { submitDialog(kind) } }
            HStack(spacing: 16) {
                Spacer()
                Button(l10n.t("dir.cancel"), action: dismissDialog)
                    .keyboardShortcut(.cancelAction)
                Button(l10n.t(kind == .path ? "dir.path.go" : "dir.save")) { submitDialog(kind) }
                    .foregroundStyle(Color.accentText)
                    .fontWeight(.semibold)
                    .disabled(dialogText.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
            .font(.system(size: 12))
            .buttonStyle(MolePlainButtonStyle())
        }
    }

    private func submitDialog(_ kind: DirectoryDialog) {
        let text = dialogText
        dismissDialog()
        switch kind {
        case .path: model.go(to: text)
        case .rename: model.renameSelected(to: text)
        }
    }

    private var keyboardCommands: some View {
        Group {
            Button("") { focusedField = .query }.keyboardShortcut("f", modifiers: .command)
            Button("") { presentDialog(.path, text: model.breadcrumbDirectory.path) }.keyboardShortcut("g", modifiers: [.command, .shift])
            Button("", action: model.goBack).keyboardShortcut("[", modifiers: .command).disabled(!model.canGoBack)
            Button("", action: model.goForward).keyboardShortcut("]", modifiers: .command).disabled(!model.canGoForward)
            Button("", action: model.goUp).keyboardShortcut(.upArrow, modifiers: .command)
            Group {
                Button("", action: model.copySelection).keyboardShortcut("c", modifiers: .command).disabled(model.selectedIDs.isEmpty)
                Button("", action: model.cutSelection).keyboardShortcut("x", modifiers: .command).disabled(model.selectedIDs.isEmpty)
                Button("") { model.paste() }.keyboardShortcut("v", modifiers: .command).disabled(!model.canPaste)
                Button("", action: model.selectAll).keyboardShortcut("a", modifiers: .command)
                Button("", action: model.trashSelection).keyboardShortcut(.delete, modifiers: .command).disabled(model.selectedIDs.isEmpty)
                Button("") { beginRename() }.keyboardShortcut(.return, modifiers: []).disabled(model.selectedEntries.count != 1)
            }
            .disabled(focusedField != .files || dialog != nil || model.isWorking)
        }
        .disabled(dialog != nil)
        .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard focusedField == .files, !model.entries.isEmpty else { return }
        let selectedIndex = model.entries.firstIndex { model.selectedIDs.contains($0.id) }
        let next: Int
        switch direction {
        case .up: next = max(0, (selectedIndex ?? 1) - 1)
        case .down: next = min(model.entries.count - 1, (selectedIndex ?? -1) + 1)
        default: return
        }
        model.select(entry: model.entries[next], extending: false, range: NSEvent.modifierFlags.contains(.shift))
    }
}

private struct DirectoryFileRow<MenuContent: View>: View {
    let entry: DirectoryEntry
    let selected: Bool
    let sizeState: DirectorySizeState
    let sizeUpdatedAt: Date?
    let isPartialSize: Bool
    let showParent: Bool
    let pathMatch: Int?
    let dragNamespace: Namespace.ID
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onDrop: ([URL]) -> Void
    @ViewBuilder let menu: () -> MenuContent
    @ObservedObject private var l10n = L10n.shared
    @State private var isDropTarget = false

    private var kind: String {
        if entry.isSymbolicLink { return l10n.t("dir.kind.link") }
        if entry.isDirectory { return l10n.t("dir.kind.folder") }
        let fileExtension = entry.url.pathExtension
        return fileExtension.isEmpty ? l10n.t("dir.kind.file") : fileExtension.uppercased()
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSelect) {
                columns
                    .padding(.vertical, showParent ? 10 : 9)
                    .contentShape(Rectangle())
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .buttonStyle(MolePlainButtonStyle(pressedScale: 0.995))
            .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen() })
            .modifier(DirectoryRowDrag(entry: entry, namespace: dragNamespace))
            .accessibilityLabel(entry.name)
            .accessibilityValue(entry.url.path)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityAction(named: Text(l10n.t("dir.open")), onOpen)
            .accessibilityIdentifier("directory-entry-" + entry.id)

            Menu(content: menu) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(l10n.t("dir.item.actions"))
            .accessibilityLabel(l10n.t("dir.item.actions"))
            .accessibilityValue(entry.name)
            .accessibilityIdentifier("directory-entry-actions-" + entry.id)
        }
        .padding(.horizontal, 12)
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .modifier(DirectorySelectionSurface(selected: selected || isDropTarget))
        .contextMenu(menuItems: menu)
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTarget) { providers in
            guard entry.isDirectory else { return false }
            return DirectoryFileDrop.load(providers, completion: onDrop)
        }
    }

    private var columns: some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: entry.isSymbolicLink ? "arrowshape.turn.up.right" : entry.isDirectory ? "folder.fill" : "doc")
                    .foregroundStyle(entry.isDirectory ? Color.accentText : Color.secondary)
                    .font(.system(size: 16)).frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name).font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                    if showParent {
                        Text(entry.url.deletingLastPathComponent().path)
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(kind).font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(1).frame(width: 76, alignment: .leading)
            Group {
                if let pathMatch {
                    Text(pathMatch == 100 ? l10n.t("dir.path.exact") : l10n.tf("dir.path.similarity", pathMatch))
                        .foregroundStyle(pathMatch == 100 ? Color.success : Color.secondary)
                } else if let modified = entry.modifiedAt {
                    Text(modified, format: .dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute())
                } else { Text("—") }
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .lineLimit(1).frame(width: 122, alignment: .leading)
            DirectoryDiskSize(bytes: entry.allocatedBytes, state: sizeState,
                              updatedAt: sizeUpdatedAt, isPartial: isPartialSize)
                .frame(width: 112, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct DirectoryDiskSize: View {
    let bytes: Int64?
    let state: DirectorySizeState
    let updatedAt: Date?
    let isPartial: Bool
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.locale) private var locale

    private var showsLowerBound: Bool { isPartial || state == .partial }

    private var helpText: String {
        var lines: [String] = []
        if showsLowerBound, let bytes {
            lines.append(l10n.tf("dir.size.partial", ByteFormat.format(UInt64(max(0, bytes)))))
        } else { lines.append(l10n.t("dir.size.hint")) }
        switch state {
        case .updating: lines.append(l10n.t("dir.size.updating"))
        case .stale: lines.append(l10n.t("dir.size.stale"))
        default:
            if updatedAt != nil { lines.append(l10n.t("dir.size.cached")) }
        }
        if let updatedAt {
            let timestamp = updatedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
            lines.append(l10n.tf("dir.size.updated", timestamp))
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        HStack(spacing: 4) {
            if state == .pending || state == .updating {
                ProgressView().controlSize(.mini).scaleEffect(0.55).frame(width: 12, height: 12)
                    .accessibilityHidden(true)
            } else if state == .stale {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 9)).accessibilityHidden(true)
            }
            if let bytes {
                Text((showsLowerBound ? "≥ " : "") + ByteFormat.format(UInt64(max(0, bytes))))
            } else {
                Text(l10n.t(state == .unavailable ? "dir.size.unavailable" : "dir.size.pending"))
            }
        }
        .font(.system(size: 10).monospacedDigit()).foregroundStyle(showsLowerBound ? Color.warning : Color.secondary)
        .lineLimit(1)
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityHint(helpText)
    }
}

private struct DirectoryEmptyState: View {
    let isLoading: Bool
    let hasQuery: Bool
    let hasError: Bool
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        VStack(spacing: 9) {
            if isLoading { ProgressView().controlSize(.small) }
            else {
                Image(systemName: hasError ? "folder.badge.questionmark" : hasQuery ? "magnifyingglass" : "folder")
                    .font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
            }
            Text(l10n.t(isLoading ? "dir.loading" : hasError ? "dir.empty.error" : hasQuery ? "dir.empty.search" : "dir.empty.folder"))
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Glass directly carries its content, with one opaque accessibility fallback.
private struct DirectoryListFocus: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
    }
}

/// 搜索框等工具控件的底色：内容层不用玻璃，surface2 实底。
private struct DirectoryControlSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.surface2))
    }
}

/// 选中行只染 selectionFill；未选中行保持面板透明。
private struct DirectorySelectionSurface: ViewModifier {
    let selected: Bool

    func body(content: Content) -> some View {
        content.background {
            if selected {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.selectionFill)
            }
        }
    }
}

/// Export file URL data rather than a filename or the file's contents.
private struct DirectoryDraggedFile: Identifiable, Transferable {
    let url: URL
    var id: String { url.path }
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .fileURL) { file in file.url.dataRepresentation }
    }
}

private struct DirectoryDragContainer: ViewModifier {
    let entries: [DirectoryEntry]
    let selectedIDs: Set<String>
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .dragContainer(for: DirectoryDraggedFile.self, in: namespace) { (ids: [String]) in
                    let draggedIDs = Set(ids)
                    return entries.filter { draggedIDs.contains($0.id) }.map { DirectoryDraggedFile(url: $0.url) }
                }
                .dragContainerSelection(Array(selectedIDs), containerNamespace: namespace)
                .dragConfiguration(DragConfiguration(
                    operationsWithinApp: .init(allowCopy: true, allowMove: false),
                    operationsOutsideApp: .init(allowCopy: true, allowMove: false)))
        } else { content }
    }
}

private struct DirectoryRowDrag: ViewModifier {
    let entry: DirectoryEntry
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.draggable(containerItemID: entry.id, containerNamespace: namespace)
        } else {
            content.onDrag { NSItemProvider(object: entry.url as NSURL) }
        }
    }
}

private enum DirectoryFileDrop {
    /// External apps may offer NSURL objects or raw public.file-url data.
    static func load(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) -> Bool {
        let accepted = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !accepted.isEmpty else { return false }
        let result = DirectoryDropResult()
        let group = DispatchGroup()
        for provider in accepted {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let value = item as? URL { url = value }
                else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let string = item as? String { url = URL(string: string) }
                else { url = nil }
                if let url, url.isFileURL { result.append(url) }
            }
        }
        group.notify(queue: .main) {
            let urls = result.urls
            if !urls.isEmpty { completion(urls) }
        }
        return true
    }
}

private final class DirectoryDropResult: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URL] = []
    func append(_ url: URL) { lock.lock(); defer { lock.unlock() }; values.append(url) }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return values }
}
