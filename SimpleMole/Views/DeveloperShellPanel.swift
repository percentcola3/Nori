import SwiftUI
import AppKit

/// Structured editor for the four zsh startup files: PATH as directories, variables as
/// name/value forms, and everything else listed read-only with a link to an external editor.
struct DeveloperShellPanel: View {
    @ObservedObject var model: DeveloperShellModel
    @State private var selectedFileIndex = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.inventory?.kind == .unsupported {
                DevNotice(symbol: "terminal", text: L10n.shared.t("dev.shell.unsupported"), color: .warning)
            } else {
                PillPicker(items: fileNames, selection: $selectedFileIndex, alignment: .leading)
                    .accessibilityLabel(L10n.shared.t("dev.shell.shell.configuration.file.0ba2d7"))
                    .accessibilityIdentifier("dev-shell-files")
            }
            ForEach(fileNames, id: \.self) { fileName in
                DeveloperShellFilePanel(model: model, fileName: fileName)
                    .modifier(DeveloperShellFileVisibility(isVisible: fileName == selectedFile))
                    .frame(height: fileName == selectedFile ? nil : 0, alignment: .top)
                    .clipped()
                    .allowsHitTesting(fileName == selectedFile)
                    .accessibilityHidden(fileName != selectedFile)
            }
        }
        .onChange(of: model.inventory?.names) { _ in
            if let inventory = model.inventory, inventory.kind == .bash {
                selectedFileIndex = inventory.names.firstIndex(of: inventory.loginFile ?? ".bashrc") ?? 0
            } else { selectedFileIndex = 2 }
        }
    }

    private var fileNames: [String] { model.inventory?.names ?? DeveloperShellService.fileNames }
    private var selectedFile: String { fileNames.indices.contains(selectedFileIndex) ? fileNames[selectedFileIndex] : fileNames.first ?? "" }
}

private struct DeveloperShellFileVisibility: ViewModifier {
    let isVisible: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if isVisible {
            content
        } else {
            content.hidden()
        }
    }
}

private struct DeveloperShellFilePanel: View {
    @ObservedObject var model: DeveloperShellModel
    @ObservedObject private var l10n = L10n.shared
    @State private var selectedFile = ".zshrc"
    @State private var editingVariable: String?
    @State private var addingVariable: DeveloperShellVariableDraft?
    @State private var pendingRemoval: String?
    @State private var revealedValues: Set<String> = []
    @State private var showsOtherLines = false
    @State private var showsBackups = false

    private typealias Shell = DeveloperShellService

    private var profile: Shell.Profile? { model.profiles.first { $0.name == selectedFile } }

    init(model: DeveloperShellModel, fileName: String) {
        self.model = model
        // Each file has a stable editor identity and retains its unsaved form state.
        _selectedFile = State(initialValue: fileName)
    }

    var body: some View {
        DevCard(id: "dev-shell-\(selectedFile)") {
            header
        } content: {
            if model.isRefreshing && model.profiles.isEmpty {
                DevDivider()
                ProgressView(L10n.shared.t("dev.shell.reading.shell.configuration.bab926"))
                    .controlSize(.small).font(.system(size: 11))
                    .frame(maxWidth: .infinity, minHeight: 64)
            } else if let profile {
                DevDivider()
                if let problem = profile.problem {
                    DevNotice(symbol: "exclamationmark.triangle", text: DeveloperShellCopy.failure(problem), color: .warning)
                } else {
                    startupNotice(profile)
                    pathSection(profile)
                    DevDivider()
                    variableSection(profile)
                    DeveloperShellAliasSection(profile: profile, model: model)
                    includedSection(profile)
                    otherSection(profile)
                }
                if let failure = model.failure {
                    DevDivider()
                    DevNotice(symbol: "exclamationmark.triangle", text: DeveloperShellCopy.failure(failure), color: .danger)
                }
                if let savedName = model.savedName {
                    DevDivider()
                    savedNotice(savedName)
                }
            }
        }
        .sheet(isPresented: $showsBackups) {
            if let profile { DeveloperShellBackupPanel(profile: profile, model: model) }
        }
        .onChange(of: selectedFile) { _ in
            editingVariable = nil
            addingVariable = nil
            pendingRemoval = nil
            showsOtherLines = false
        }
    }

    // MARK: Header

    private var header: some View {
        Group {
            Image(systemName: "terminal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentText)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(profile.map { DevFiles.abbreviate($0.path) } ?? "~/\(selectedFile)")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
            Text(sourcePurpose(selectedFile)).font(.system(size: 11)).foregroundStyle(.secondary)
            if let profile, !profile.exists {
                DevTag(text: L10n.shared.t("dev.shell.not.created.97bbb8"), color: .warning)
            }
            Spacer(minLength: 8)
            if model.isSaving || model.isRefreshing { ProgressView().controlSize(.small) }
            if let profile, profile.exists {
                Button { DevFiles.openInEditor(path(of: profile)) } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(MoleIconButtonStyle())
                .help(L10n.shared.t("dev.shell.open.in.default.editor.e6de97"))
                .accessibilityLabel(L10n.shared.t("dev.shell.open.in.default.editor.e6de97"))
            }
            DevLinkButton(title: L10n.shared.t("dev.shell.backups"), symbol: "clock.arrow.circlepath") { showsBackups = true }
            addMenu
        }
    }

    private var addMenu: some View {
        Menu {
            Button(L10n.shared.t("dev.shell.environment.variable.c4c662")) { startAdding(.empty) }
            Button(L10n.shared.t("dev.shell.path.directory.3407e9")) { addPathDirectory() }
            Divider()
            Section(L10n.shared.t("dev.shell.common.variables.f2062f")) {
                Menu("JAVA_HOME") {
                    ForEach(model.javaHomes, id: \.self) { home in
                        Button(DevFiles.abbreviate(home)) {
                            startAdding(.init(name: "JAVA_HOME", value: DevFiles.abbreviate(home), usesReferences: true))
                        }
                    }
                    if !model.javaHomes.isEmpty { Divider() }
                    Button(L10n.shared.t("dev.shell.choose.folder.f0b6f7")) {
                        if let directory = DevFiles.chooseDirectory(startingAt: "/Library/Java/JavaVirtualMachines") {
                            startAdding(.init(name: "JAVA_HOME", value: DevFiles.abbreviate(directory), usesReferences: true))
                        }
                    }
                }
                ForEach(DeveloperShellVariableDraft.templates, id: \.name) { template in
                    Button(template.name) { startAdding(template) }
                }
            }
        } label: {
            Label(L10n.shared.t("dev.shell.add.61cc55"), systemImage: "plus").font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!(profile?.canEdit ?? false) || model.isSaving)
        .accessibilityLabel(L10n.shared.t("dev.shell.add.configuration.a86ba3"))
    }

    // MARK: PATH

    @ViewBuilder private func pathSection(_ profile: Shell.Profile) -> some View {
        let declarations = Shell.pathDeclarations(in: profile)
        let unsupported = profile.variables.filter { $0.name == "PATH" && Shell.pathDeclaration($0) == nil }
        DevSubheader(title: L10n.shared.t("dev.shell.command.search.folders.323658")) {
            DevLinkButton(title: L10n.shared.t("dev.shell.add.folder.03eb1a"), symbol: "folder.badge.plus") { addPathDirectory() }
                .disabled(!profile.canEdit || model.isSaving)
        }
        if declarations.isEmpty && unsupported.isEmpty {
            Text(L10n.shared.t("dev.shell.this.file.does.not.change.07ec1a"))
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.bottom, 10)
        }
        ForEach(declarations) { declaration in
            DeveloperPathDeclarationView(declaration: declaration, profile: profile, model: model)
        }
        ForEach(unsupported) { variable in
            dynamicRow(variable, profile: profile)
        }
    }

    private func addPathDirectory() {
        guard let profile, let directory = DevFiles.chooseDirectory(startingAt: NSHomeDirectory()) else { return }
        Task { await model.addPathDirectory(directory, to: profile) }
    }

    // MARK: Variables

    @ViewBuilder private func variableSection(_ profile: Shell.Profile) -> some View {
        let variables = profile.variables.filter { $0.name != "PATH" }
        DevSubheader(title: L10n.shared.t("dev.shell.environment.variables.1173b2"), detail: variables.isEmpty ? nil : "\(variables.count)") {
            DevLinkButton(title: L10n.shared.t("dev.shell.add.variable.2969ff"), symbol: "plus") { startAdding(.empty) }
                .disabled(!profile.canEdit || model.isSaving || addingVariable != nil)
        }
        if let draft = addingVariable {
            DeveloperVariableEditor(draft: draft, environment: model.environment, isSaving: model.isSaving,
                                    isNew: true) { result in
                Task {
                    if await model.setVariable(nil, name: result.name, parts: result.parts, in: profile) {
                        addingVariable = nil
                    }
                }
            } cancel: { addingVariable = nil }
            DevDivider(inset: 14)
        }
        if variables.isEmpty && addingVariable == nil {
            Text(L10n.shared.t("dev.shell.no.export.declarations.b2f286"))
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.bottom, 10)
        }
        ForEach(Array(variables.enumerated()), id: \.element.id) { offset, variable in
            if offset > 0 { DevDivider(inset: 14) }
            if !variable.isStructured {
                dynamicRow(variable, profile: profile)
            } else if editingVariable == variable.id, let parts = variable.structuredParts {
                DeveloperVariableEditor(
                    draft: .init(name: variable.name, value: usesReferences(parts) ? Shell.editableText(parts) : literalText(parts),
                                 usesReferences: usesReferences(parts)),
                    environment: model.environment, isSaving: model.isSaving, isNew: false) { result in
                    Task {
                        if await model.setVariable(variable, name: result.name, parts: result.parts, in: profile) {
                            editingVariable = nil
                        }
                    }
                } cancel: { editingVariable = nil }
            } else {
                variableRow(variable, profile: profile)
            }
        }
    }

    private func variableRow(_ variable: Shell.Variable, profile: Shell.Profile) -> some View {
        let parts = variable.structuredParts ?? []
        let secret = DeveloperShellVariableDraft.isSecret(variable.name)
        let revealed = !secret || revealedValues.contains(variable.id)
        let expanded = Shell.expand(parts, environment: model.environment)
        let missingDirectory = expanded.map { $0.hasPrefix("/") && !model.directoryExists($0) } ?? false
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(variable.name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .textSelection(.enabled)
                Text(L10n.shared.tf("dev.shell.line.577efa", String(describing: variable.lineNumber)))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .frame(width: 170, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(revealed ? displayValue(parts) : "••••••••")
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                if revealed, usesReferences(parts), let expanded {
                    Text("= " + DevFiles.abbreviate(expanded))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if missingDirectory { DevTag(text: L10n.shared.t("dev.shell.missing.folder.89d3df"), color: .warning) }
            if pendingRemoval == variable.id {
                removalConfirmation {
                    Task {
                        if await model.removeVariable(variable, in: profile) { pendingRemoval = nil }
                    }
                }
            } else {
                if secret {
                    Button {
                        if revealedValues.contains(variable.id) { revealedValues.remove(variable.id) }
                        else { revealedValues.insert(variable.id) }
                    } label: { Image(systemName: revealed ? "eye.slash" : "eye") }
                        .buttonStyle(MoleIconButtonStyle())
                        .help(L10n.shared.t("dev.shell.show.or.hide.the.value.4b4989"))
                        .accessibilityLabel(L10n.shared.t("dev.shell.show.or.hide.the.value.4b4989"))
                }
                Button { editingVariable = variable.id; addingVariable = nil } label: { Image(systemName: "pencil") }
                    .buttonStyle(MoleIconButtonStyle())
                    .help(L10n.shared.t("dev.shell.edit.this.line.95efd4"))
                    .accessibilityLabel(L10n.shared.tf("dev.shell.edit.361199", String(describing: variable.name)))
                    .disabled(model.isSaving)
                Button { pendingRemoval = variable.id } label: { Image(systemName: "trash") }
                    .buttonStyle(MoleIconButtonStyle(tint: .danger))
                    .help(L10n.shared.t("dev.shell.delete.this.line.31b65c"))
                    .accessibilityLabel(L10n.shared.tf("dev.shell.delete.1a3779", String(describing: variable.name)))
                    .disabled(model.isSaving)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func dynamicRow(_ variable: Shell.Variable, profile: Shell.Profile) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(variable.name).font(.system(size: 12, weight: .medium, design: .monospaced))
                Text(L10n.shared.tf("dev.shell.line.577efa", String(describing: variable.lineNumber)))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .frame(width: 170, alignment: .leading)
            Label(L10n.shared.t("dev.shell.uses.commands.or.complex.syntax.2129e1"),
                  systemImage: "function")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button { DevFiles.openInEditor(path(of: profile)) } label: { Image(systemName: "arrow.up.forward.app") }
                .buttonStyle(MoleIconButtonStyle())
                .help(L10n.shared.tf("dev.shell.open.in.editor.line.b24736", String(describing: variable.lineNumber)))
                .accessibilityLabel(L10n.shared.t("dev.shell.open.in.editor.d47c85"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: Other lines

    @ViewBuilder private func startupNotice(_ profile: Shell.Profile) -> some View {
        if let inventory = model.inventory {
            if inventory.kind == .bash {
                let key = profile.name == ".bashrc" ? "dev.shell.bashrcInfo" : "dev.shell.bashLoginInfo"
                DevNotice(symbol: "info.circle", text: L10n.shared.tf(key, inventory.loginFile ?? "~/.profile"))
            } else if inventory.usesCustomZdotdir {
                DevNotice(symbol: "folder", text: L10n.shared.tf("dev.shell.zdotdirInfo", DevFiles.abbreviate(inventory.directory)))
            }
        }
    }

    @ViewBuilder private func includedSection(_ profile: Shell.Profile) -> some View {
        let files = model.includedFiles(for: profile)
        if !files.isEmpty {
            DevDivider()
            DevSubheader(title: L10n.shared.t("dev.shell.included"), detail: L10n.shared.t("dev.shell.readOnly"))
            ForEach(files) { file in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(DevFiles.abbreviate(file.path)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        if let problem = file.problem {
                            Text(DeveloperShellCopy.failure(problem)).font(.system(size: 10)).foregroundStyle(Color.warning)
                        } else {
                            DevLinkButton(title: L10n.shared.t("dev.shell.openFile"), symbol: "arrow.up.forward.app") { DevFiles.openInEditor(file.path) }
                        }
                    }
                    Text(L10n.shared.tf("dev.shell.fromFile", DevFiles.abbreviate(file.parentPath), file.lineNumber))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                    if let included = file.profile {
                        ForEach(included.variables) { variable in
                            Text(DeveloperShellBackupStore.redactedLine(variable.originalLine))
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder private func otherSection(_ profile: Shell.Profile) -> some View {
        let structuredLines = Set(Shell.pathDeclarations(in: profile).map { $0.variable.lineNumber } + Shell.aliasDeclarations(in: profile).map(\.lineNumber))
        let lines = Shell.otherLines(in: profile).filter { !structuredLines.contains($0.lineNumber) }
        if !lines.isEmpty {
            DevDivider()
            Button {
                withAnimation(MoleMotion.panel) { showsOtherLines.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text(L10n.shared.t("dev.shell.other.configuration.56770f")).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(L10n.shared.tf("dev.shell.lines.read.only.cc4457", String(describing: lines.count)))
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showsOtherLines ? 0 : -90))
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(MolePlainButtonStyle(pressedScale: 0.995))
            .accessibilityValue(showsOtherLines ? L10n.shared.t("dev.shell.expanded.6d1704") : L10n.shared.t("dev.shell.collapsed.0084e8"))
            if showsOtherLines {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.shared.t("dev.shell.aliases.functions.conditionals.and.init.257f45"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 6)
                    ForEach(lines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(line.lineNumber)")
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                                .frame(width: 28, alignment: .trailing)
                            Text(line.text.trimmingCharacters(in: .whitespaces))
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.tail)
                                .textSelection(.enabled)
                        }
                    }
                    DevLinkButton(title: L10n.shared.tf("dev.shell.open.in.editor.6fd1c3", String(describing: profile.name)),
                                  symbol: "arrow.up.forward.app") { DevFiles.openInEditor(path(of: profile)) }
                        .padding(.top, 6)
                }
                .padding(.horizontal, 14).padding(.bottom, 12)
                .transition(.molePanelReveal)
            }
        }
    }

    // MARK: Shared

    private func removalConfirmation(_ confirm: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text(L10n.shared.t("dev.shell.delete.this.line.44d04c")).font(.system(size: 11)).foregroundStyle(.secondary)
            Button(L10n.shared.t("dev.shell.cancel.77dfd2")) { pendingRemoval = nil }
                .buttonStyle(SecondaryButtonStyle())
            Button(L10n.shared.t("dev.shell.delete.f6fdbe"), action: confirm)
                .buttonStyle(DangerButtonStyle())
                .disabled(model.isSaving)
        }
    }

    private func savedNotice(_ name: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle").foregroundStyle(Color.success)
            Text(L10n.shared.tf("dev.shell.saved.new.shells.pick.it.443896", String(describing: name)))
                .font(.system(size: 11))
            Spacer(minLength: 8)
            if let backupPath = model.backupPath {
                DevLinkButton(title: L10n.shared.t("dev.shell.show.backup.f0e26b"), symbol: "clock.arrow.circlepath") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: backupPath)])
                }
            }
            DevLinkButton(title: L10n.shared.t("dev.shell.open.new.shell.6e5bb4"), symbol: "terminal") { model.openNewLoginShell() }
                .help(L10n.shared.t("dev.shell.runs.exec.bin.zsh.l.4db6fd"))
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private func startAdding(_ draft: DeveloperShellVariableDraft) {
        editingVariable = nil
        pendingRemoval = nil
        addingVariable = draft
    }

    private func usesReferences(_ parts: [Shell.ValuePart]) -> Bool {
        parts.contains { if case .reference = $0 { return true } else { return false } }
    }

    private func literalText(_ parts: [Shell.ValuePart]) -> String {
        parts.map { if case .literal(let value) = $0 { return value } else { return "" } }.joined()
    }

    private func displayValue(_ parts: [Shell.ValuePart]) -> String {
        usesReferences(parts) ? Shell.editableText(parts) : literalText(parts)
    }

    private func path(of profile: Shell.Profile) -> String {
        profile.path
    }

    private func sourcePurpose(_ name: String) -> String {
        switch name {
        case ".zshenv": return L10n.shared.t("dev.shell.every.zsh.1d9580")
        case ".zprofile": return L10n.shared.t("dev.shell.login.startup.24ddba")
        case ".bashrc", ".zshrc": return L10n.shared.t("dev.shell.interactive.shells.6709d1")
        case ".bash_profile", ".bash_login", ".profile": return L10n.shared.t("dev.shell.login")
        default: return L10n.shared.t("dev.shell.after.login.2a348a")
        }
    }

}

// MARK: - PATH declaration

/// One PATH line. Reordering and deletions are staged until "Save" so a reorder writes once.
private struct DeveloperPathDeclarationView: View {
    private struct EditableItem: Identifiable {
        let id = UUID()
        let value: DeveloperShellService.PathItem
    }

    let declaration: DeveloperShellService.PathDeclaration
    let profile: DeveloperShellService.Profile
    @ObservedObject var model: DeveloperShellModel
    @State private var editableItems: [EditableItem]

    // Seed once per declaration. Row identities travel with directories during reordering,
    // including duplicate directories, so command expansion stays with the right row.
    init(declaration: DeveloperShellService.PathDeclaration, profile: DeveloperShellService.Profile,
         model: DeveloperShellModel) {
        self.declaration = declaration
        self.profile = profile
        self.model = model
        _editableItems = State(initialValue: model.pathDraft(for: declaration).map { EditableItem(value: $0) })
    }

    private var items: [DeveloperShellService.PathItem] { editableItems.map(\.value) }
    private var hasChanges: Bool { items != declaration.items }


    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(L10n.shared.tf("dev.shell.line.577efa", String(describing: declaration.variable.lineNumber)))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                Spacer()
                if hasChanges {
                    Button(L10n.shared.t("dev.shell.revert.272607")) { restore() }
                        .buttonStyle(SecondaryButtonStyle())
                    Button(L10n.shared.t("dev.shell.save.efc007")) {
                        let items = items
                        Task { _ = await model.setPath(declaration, items: items, in: profile) }
                    }
                    .buttonStyle(SecondaryButtonStyle(tint: .accentText))
                    .disabled(model.isSaving)
                }
            }
            .padding(.horizontal, 14).padding(.top, 2).padding(.bottom, 4)
            ForEach(editableItems.filter { $0.value != .inherited }) { item in
                row(item)
            }
        }
        .padding(.bottom, 8)
        .onChange(of: declaration) { _ in restore() }
    }

    private func row(_ item: EditableItem) -> some View {
        let index = editableItems.firstIndex { $0.id == item.id } ?? 0
        return HStack(spacing: 10) {
            switch item.value {
            case .inherited:
                EmptyView()
            case .directory(let parts):
                let expanded = model.resolvePathDirectory(parts, in: declaration)
                let missing = expanded.map { !model.directoryExists($0) } ?? false
                Image(systemName: missing ? "exclamationmark.triangle" : "folder")
                    .font(.system(size: 11)).foregroundStyle(missing ? Color.warning : Color.accentText)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(DeveloperShellService.editableText(parts))
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                        if missing { DevTag(text: L10n.shared.t("dev.shell.missing.92185d"), color: .warning) }
                        if let expanded, model.isDuplicate(expanded) {
                            DevTag(text: L10n.shared.t("dev.shell.duplicate.972d57"), color: .warning)
                        }
                    }
                    DeveloperPathCommandsView(inventory: expanded.flatMap(model.commandInventory),
                                              aliases: expanded.map(model.commandAliases) ?? [],
                                              canResolveDirectory: expanded != nil)
                }
            }
            Spacer(minLength: 8)
            Button { move(item.id, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(MoleIconButtonStyle(size: 22))
                .disabled(!canMove(at: index, by: -1) || model.isSaving)
                .accessibilityLabel(L10n.shared.t("dev.shell.move.up.b4f57c"))
                .help(L10n.shared.t("dev.shell.move.up.b4f57c"))
            Button { move(item.id, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(MoleIconButtonStyle(size: 22))
                .disabled(!canMove(at: index, by: 1) || model.isSaving)
                .accessibilityLabel(L10n.shared.t("dev.shell.move.down.260ff8"))
                .help(L10n.shared.t("dev.shell.move.down.260ff8"))
            if case .directory = item.value {
                Button { remove(item.id) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(MoleIconButtonStyle(tint: .danger, size: 22))
                    .disabled(model.isSaving)
                    .accessibilityLabel(L10n.shared.t("dev.shell.remove.e96390"))
            }
        }
        .padding(.leading, 22).padding(.trailing, 14).padding(.vertical, 7)
    }

    private func canMove(at index: Int, by offset: Int) -> Bool {
        let target = index + offset
        return items.indices.contains(target) && items[index] != .inherited && items[target] != .inherited
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let index = editableItems.firstIndex(where: { $0.id == id }),
              canMove(at: index, by: offset) else { return }
        editableItems.swapAt(index, index + offset)
        model.rememberPathDraft(items, for: declaration)
    }

    private func remove(_ id: UUID) {
        editableItems.removeAll { $0.id == id }
        model.rememberPathDraft(items, for: declaration)
    }

    private func restore() {
        editableItems = declaration.items.map { EditableItem(value: $0) }
        model.rememberPathDraft(items, for: declaration)
    }

}

/// Command discovery is supplied by the model; rendering never starts a tool or reads a directory.
private struct DeveloperPathCommandsView: View {
    let inventory: DeveloperPathCommandService.Inventory?
    let aliases: [DeveloperShellService.CommandAlias]
    let canResolveDirectory: Bool
    @ObservedObject private var l10n = L10n.shared
    @State private var showsAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !canResolveDirectory {
                status(L10n.shared.t("dev.shell.unresolved.reference.commands.unavailable.bcdf13"))
            } else if let inventory {
                switch inventory.status {
                case .available:
                    if inventory.names.isEmpty {
                        status(L10n.shared.t("dev.shell.no.executable.commands.found.dbcf04"))
                    } else {
                        Text(L10n.shared.t("dev.shell.directory.commands.d1a209")
                             + (showsAll ? inventory.names : Array(inventory.names.prefix(8))).joined(separator: " · "))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .help(L10n.shared.t("dev.shell.executables.in.this.directory.your.51b5e1"))
                        if inventory.names.count > 8 {
                            Button(showsAll ? L10n.shared.t("dev.shell.show.less.4c852b")
                                   : L10n.shared.tf("dev.shell.show.all.commands.05b57c", String(describing: inventory.names.count))) {
                                showsAll.toggle()
                            }
                            .buttonStyle(MolePlainButtonStyle())
                            .font(.system(size: 11)).foregroundStyle(Color.accentText)
                        }
                        if !aliases.isEmpty {
                            Text(L10n.shared.t("dev.shell.configured.aliases.1f549c")
                                 + aliases.map { "\($0.name) → \($0.targetCommand)" }.joined(separator: " · "))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .help(L10n.shared.t("dev.shell.simple.aliases.declared.in.configuration.f489ed"))
                        }
                    }
                case .missingDirectory, .notDirectory:
                    status(L10n.shared.t("dev.shell.directory.unavailable.commands.unavailable.547aba"))
                case .unavailable:
                    status(L10n.shared.t("dev.shell.cannot.read.commands.in.this.0ad554"))
                }
            } else {
                status(L10n.shared.t("dev.shell.discovering.commands.ad95dd"))
            }
        }
        .accessibilityIdentifier("dev-path-commands")
    }

    private func status(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
    }

}

// MARK: - Variable editor

struct DeveloperShellVariableDraft: Equatable {
    var name: String
    var value: String
    var usesReferences: Bool

    static let empty = DeveloperShellVariableDraft(name: "", value: "", usesReferences: false)
    static let templates: [DeveloperShellVariableDraft] = [
        .init(name: "ANDROID_HOME", value: "~/Library/Android/sdk", usesReferences: true),
        .init(name: "GOPATH", value: "~/go", usesReferences: true),
        .init(name: "HOMEBREW_NO_AUTO_UPDATE", value: "1", usesReferences: false),
        .init(name: "LANG", value: "en_US.UTF-8", usesReferences: false),
        .init(name: "EDITOR", value: "vim", usesReferences: false),
    ]

    static func isSecret(_ name: String) -> Bool {
        let upper = name.uppercased()
        return ["TOKEN", "SECRET", "PASSWORD", "PASSWD", "API_KEY", "ACCESS_KEY", "PRIVATE", "CREDENTIAL"]
            .contains { upper.contains($0) } || upper.hasSuffix("_KEY")
    }
}

private struct DeveloperVariableEditor: View {
    struct Result {
        let name: String
        let parts: [DeveloperShellService.ValuePart]
    }

    let isSaving: Bool
    let isNew: Bool
    let environment: [String: String]
    let save: (Result) -> Void
    let cancel: () -> Void
    @State private var name: String
    @State private var value: String
    @State private var usesReferences: Bool
    @State private var revealed = false
    @State private var problem: String?

    init(draft: DeveloperShellVariableDraft, environment: [String: String], isSaving: Bool, isNew: Bool,
         save: @escaping (Result) -> Void, cancel: @escaping () -> Void) {
        // Seeded once from the line being edited; the row is recreated for another line.
        _name = State(initialValue: draft.name)
        _value = State(initialValue: draft.value)
        _usesReferences = State(initialValue: draft.usesReferences)
        self.environment = environment
        self.isSaving = isSaving
        self.isNew = isNew
        self.save = save
        self.cancel = cancel
    }

    private var parts: [DeveloperShellService.ValuePart]? {
        usesReferences ? DeveloperShellService.parseEditableText(value) : [.literal(value)]
    }

    private var preview: String? {
        guard usesReferences, let parts else { return nil }
        guard let expanded = DeveloperShellService.expand(parts, environment: environment) else {
            return L10n.shared.t("dev.shell.references.a.variable.nori.cannot.146b5c")
        }
        return "= " + expanded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isNew ? L10n.shared.t("dev.shell.new.environment.variable.c3bf6f") : L10n.shared.t("dev.shell.edit.this.line.95efd4"))
                .font(.system(size: 12, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text(L10n.shared.t("dev.shell.name.709a23")).font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("JAVA_HOME", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: 280)
                }
                GridRow {
                    Text(L10n.shared.t("dev.shell.value.8dce17")).font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Group {
                            if DeveloperShellVariableDraft.isSecret(name) && !revealed {
                                SecureField("", text: $value)
                            } else {
                                TextField(usesReferences ? "~/sdk/bin" : "", text: $value)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        if DeveloperShellVariableDraft.isSecret(name) {
                            Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye") }
                                .buttonStyle(MoleIconButtonStyle())
                                .accessibilityLabel(L10n.shared.t("dev.shell.show.or.hide.the.value.4b4989"))
                        }
                        Button {
                            if let directory = DevFiles.chooseDirectory() {
                                value = DevFiles.abbreviate(directory)
                                usesReferences = true
                            }
                        } label: { Image(systemName: "folder") }
                            .buttonStyle(MoleIconButtonStyle())
                            .help(L10n.shared.t("dev.shell.choose.a.folder.0df0b0"))
                            .accessibilityLabel(L10n.shared.t("dev.shell.choose.a.folder.0df0b0"))
                    }
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(L10n.shared.t("dev.shell.expand.and.references.like.home.c3642d"), isOn: $usesReferences)
                            .toggleStyle(.checkbox).font(.system(size: 11))
                        if let preview {
                            Text(preview).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        } else if !usesReferences {
                            Text(L10n.shared.t("dev.shell.saved.exactly.as.typed.and.0eaf48"))
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            if let problem {
                Text(problem).font(.system(size: 11)).foregroundStyle(Color.danger)
            }
            HStack(spacing: 8) {
                Spacer()
                Button(L10n.shared.t("dev.shell.cancel.77dfd2"), action: cancel)
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(L10n.shared.t("dev.shell.check.save.9c2a4c")) { submit() }
                    .buttonStyle(SecondaryButtonStyle(tint: .accentText))
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || name.isEmpty)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard DeveloperShellService.isValidReference(trimmed) else {
            problem = L10n.shared.t("dev.shell.use.letters.digits.and.underscores.10ba64")
            return
        }
        guard trimmed != "PATH" else {
            problem = L10n.shared.t("dev.shell.manage.path.in.this.file.505bb3")
            return
        }
        guard let parts else {
            problem = L10n.shared.t("dev.shell.a.must.start.a.variable.c520cc")
            return
        }
        guard !value.contains("\n") else {
            problem = L10n.shared.t("dev.shell.values.cannot.contain.line.breaks.b10455")
            return
        }
        problem = nil
        save(Result(name: trimmed, parts: parts))
    }

}

// MARK: - Model

@MainActor
final class DeveloperShellModel: ObservableObject {
    // Match the original declaration so a changed file never receives an obsolete draft.
    private var pathDrafts: [String: (original: [DeveloperShellService.PathItem], edited: [DeveloperShellService.PathItem])] = [:]

    func pathDraft(for declaration: DeveloperShellService.PathDeclaration) -> [DeveloperShellService.PathItem] {
        guard let draft = pathDrafts[declaration.id], draft.original == declaration.items else {
            return declaration.items
        }
        return draft.edited
    }

    func rememberPathDraft(_ items: [DeveloperShellService.PathItem],
                           for declaration: DeveloperShellService.PathDeclaration) {
        if items == declaration.items {
            pathDrafts.removeValue(forKey: declaration.id)
        } else {
            pathDrafts[declaration.id] = (declaration.items, items)
        }
        pendingChanges = pathDrafts.count
    }

    @Published private(set) var inventory: DeveloperShellService.Inventory?
    @Published private(set) var pendingChanges = 0
    @Published private(set) var revision = 0
    @Published private(set) var included: [DeveloperShellService.IncludedFile] = []
    @Published var profiles: [DeveloperShellService.Profile] = [] {
        didSet { rebuildDerivedState() }
    }
    @Published var isRefreshing = false
    @Published var isSaving = false {
        didSet { savingStateChanged?(isSaving) }
    }
    var savingStateChanged: ((Bool) -> Void)?
    var canWrite: (() -> Bool)?
    @Published var failure: DeveloperShellService.Failure?
    @Published var savedName: String?
    @Published var backupPath: String?
    @Published private(set) var environment: [String: String] = [:]
    @Published private var duplicatePaths: Set<String> = []
    @Published private(set) var javaHomes: [String] = []
    @Published private var pathEnvironments: [String: [String: String]] = [:]
    @Published private var aliasesByDirectory: [String: [DeveloperShellService.CommandAlias]] = [:]
    @Published private var commandInventories: [String: DeveloperPathCommandService.Inventory] = [:]
    private var existence: [String: Bool] = [:]
    private var commandScanTask: Task<Void, Never>?
    private var commandScanGeneration = 0
    private var refreshGeneration = 0
    private var lastToken: Int?

    deinit { commandScanTask?.cancel() }

    func refresh(for token: Int) async {
        guard lastToken != token else { return }
        await refresh()
        if !Task.isCancelled { lastToken = token }
    }

    func refresh() async {
        guard !isSaving else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshing = true
        failure = nil
        let scanned = await Task.detached(priority: .utility) { () -> (DeveloperShellService.Inventory, [String]) in
            (DeveloperShellService.inventory(), DeveloperShellModel.discoverJavaHomes())
        }.value
        guard !Task.isCancelled, generation == refreshGeneration else {
            if generation == refreshGeneration { isRefreshing = false }
            return
        }
        existence.removeAll()
        javaHomes = scanned.1
        inventory = scanned.0
        included = scanned.0.included
        profiles = scanned.0.profiles
        isRefreshing = false
    }

    func directoryExists(_ path: String) -> Bool {
        if let known = existence[path] { return known }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        existence[path] = exists
        return exists
    }

    func commandInventory(_ path: String) -> DeveloperPathCommandService.Inventory? {
        guard let directory = DeveloperPathCommandService.normalizedDirectory(path) else {
            return .init(names: [], status: .unavailable)
        }
        return commandInventories[directory]
    }

    func includedFiles(for profile: DeveloperShellService.Profile) -> [DeveloperShellService.IncludedFile] {
        var parents: Set<String> = [profile.path], result: [DeveloperShellService.IncludedFile] = []
        for _ in 0..<3 {
            for file in included where parents.contains(file.parentPath) && !result.contains(where: { $0.id == file.id }) {
                result.append(file); parents.insert(file.path)
            }
        }
        return result
    }

    func resolvePathDirectory(_ parts: [DeveloperShellService.ValuePart],
                              in declaration: DeveloperShellService.PathDeclaration) -> String? {
        guard let environment = pathEnvironments[declaration.id] else { return nil }
        return DeveloperShellService.expand(parts, environment: environment)
    }

    func commandAliases(_ path: String) -> [DeveloperShellService.CommandAlias] {
        guard let directory = DeveloperPathCommandService.normalizedDirectory(path),
              let inventory = commandInventories[directory], inventory.status == .available else { return [] }
        return (aliasesByDirectory[directory] ?? []).filter { inventory.names.contains($0.targetCommand) }
    }

    func setVariable(_ variable: DeveloperShellService.Variable?, name: String,
                     parts: [DeveloperShellService.ValuePart], in profile: DeveloperShellService.Profile) async -> Bool {
        await write(profile) { try DeveloperShellService.settingVariable(in: profile, variable: variable, name: name, parts: parts) }
    }

    func removeVariable(_ variable: DeveloperShellService.Variable, in profile: DeveloperShellService.Profile) async -> Bool {
        await write(profile) { try DeveloperShellService.removingVariable(in: profile, variable: variable) }
    }

    func setAlias(_ alias: DeveloperShellService.AliasDeclaration?, name: String, command: String,
                  in profile: DeveloperShellService.Profile) async -> Bool {
        await write(profile) { try DeveloperShellService.settingAlias(in: profile, alias: alias, name: name, command: command) }
    }

    func removeAlias(_ alias: DeveloperShellService.AliasDeclaration, in profile: DeveloperShellService.Profile) async -> Bool {
        await write(profile) { try DeveloperShellService.removingAlias(in: profile, alias: alias) }
    }

    func setPath(_ declaration: DeveloperShellService.PathDeclaration, items: [DeveloperShellService.PathItem],
                 in profile: DeveloperShellService.Profile) async -> Bool {
        await write(profile) { try DeveloperShellService.settingPath(in: profile, declaration: declaration, items: items) }
    }

    func addPathDirectory(_ directory: String, to profile: DeveloperShellService.Profile) async {
        let home = NSHomeDirectory()
        let parts: [DeveloperShellService.ValuePart] = directory == home ? [.reference("HOME")]
            : directory.hasPrefix(home + "/") ? [.reference("HOME"), .literal(String(directory.dropFirst(home.count)))]
            : [.literal(directory)]
        _ = await write(profile) { try DeveloperShellService.addingPathDirectory(in: profile, directory: parts) }
    }

    private func write(_ profile: DeveloperShellService.Profile, _ makeText: () throws -> String) async -> Bool {
        do {
            return await save(try makeText(), replacing: profile)
        } catch {
            let issue = error as? DeveloperShellService.Failure ?? .writeFailed
            failure = issue
            DeveloperShellCopy.reportFailure(issue, fileName: profile.name)
            return false
        }
    }

    func save(_ text: String, replacing profile: DeveloperShellService.Profile) async -> Bool {
        guard !isSaving, canWrite?() != false else { return false }
        refreshGeneration += 1
        isRefreshing = false
        isSaving = true
        failure = nil
        defer { isSaving = false }
        let result = await Task.detached(priority: .utility) {
            Result { try DeveloperShellService.save(text, replacing: profile) }
        }.value
        switch result {
        case .success(let result):
            if let index = profiles.firstIndex(where: { $0.name == profile.name }) {
                profiles[index] = result.profile
            }
            savedName = profile.name
            backupPath = result.backupPath
            revision &+= 1
            let refreshedProfiles = profiles
            let home = result.profile.homePath ?? NSHomeDirectory()
            included = await Task.detached(priority: .utility) {
                DeveloperShellService.includedFiles(in: refreshedProfiles, home: home)
            }.value
            return true
        case .failure(let error):
            let issue = error as? DeveloperShellService.Failure ?? .writeFailed
            failure = issue
            DeveloperShellCopy.reportFailure(issue, fileName: profile.name)
            return false
        }
    }

    func openNewLoginShell() {
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nori-login-shell-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                  attributes: [.posixPermissions: 0o700])
            let command = directory.appendingPathComponent("Nori-shell.command")
            let shell = inventory?.kind == .bash ? "/bin/bash" : "/bin/zsh"
            try ("#!/bin/zsh -f\nexec " + shell + " -l\n").write(to: command, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            // A .command opens in a new Terminal window without an Apple Events entitlement.
            NSWorkspace.shared.open([command],
                                    withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                    configuration: configuration) { _, error in
                if error != nil {
                    Task { @MainActor in TaskFeedbackNotice.reportFailure(messageKey: "task.reason.terminal") }
                }
            }
        } catch {
            TaskFeedbackNotice.reportFailure(messageKey: "task.reason.terminal")
        }
    }

    private func rebuildDerivedState() {
        let declarations = profiles.flatMap(DeveloperShellService.pathDeclarations)
        pathDrafts = pathDrafts.filter { id, draft in declarations.contains { $0.id == id && $0.items == draft.original } }
        pendingChanges = pathDrafts.count
        environment = DeveloperShellService.knownEnvironment(profiles)
        var counts: [String: Int] = [:]
        var directories: Set<String> = []
        var environments: [String: [String: String]] = [:]
        for profile in profiles {
            for declaration in DeveloperShellService.pathDeclarations(in: profile) {
                let environment = DeveloperShellService.knownEnvironment(before: declaration.variable, in: profiles)
                environments[declaration.id] = environment
                for case .directory(let parts) in declaration.items {
                    guard let expanded = DeveloperShellService.expand(parts, environment: environment) else { continue }
                    counts[Self.normalized(expanded), default: 0] += 1
                    if let directory = DeveloperPathCommandService.normalizedDirectory(expanded) {
                        directories.insert(directory)
                    }
                }
            }
        }
        if pathEnvironments != environments { pathEnvironments = environments }
        let aliases = Dictionary(grouping: DeveloperShellService.commandAliases(in: profiles)) {
            Self.normalized(URL(fileURLWithPath: $0.targetPath).deletingLastPathComponent().path)
        }
        if aliasesByDirectory != aliases { aliasesByDirectory = aliases }
        duplicatePaths = Set(counts.filter { $0.value > 1 }.keys)
        refreshPathCommands(in: Array(directories))
    }

    private func refreshPathCommands(in directories: [String]) {
        commandScanTask?.cancel()
        commandScanGeneration += 1
        let generation = commandScanGeneration
        let retained = commandInventories.filter { directories.contains($0.key) }
        if retained != commandInventories { commandInventories = retained }
        commandScanTask = Task { [weak self] in
            let inventories = await Task.detached(priority: .utility) {
                DeveloperPathCommandService.scan(directories: directories)
            }.value
            guard !Task.isCancelled, let self, generation == self.commandScanGeneration else { return }
            if self.commandInventories != inventories { self.commandInventories = inventories }
            self.commandScanTask = nil
        }
    }

    func isDuplicate(_ path: String) -> Bool { duplicatePaths.contains(Self.normalized(path)) }

    private nonisolated static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    nonisolated static func discoverJavaHomes() -> [String] {
        let roots = ["/Library/Java/JavaVirtualMachines",
                     NSHomeDirectory() + "/Library/Java/JavaVirtualMachines"]
        return roots.flatMap { root -> [String] in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            return names.filter { !$0.hasPrefix(".") }.sorted().reversed().compactMap { name in
                let home = root + "/" + name + "/Contents/Home"
                return FileManager.default.fileExists(atPath: home + "/bin/java") ? home : nil
            }
        }
    }
}

enum DeveloperShellCopy {
    static func failure(_ failure: DeveloperShellService.Failure) -> String {
        let message = L10n.shared.t(failureKey(failure))
        if case .syntax(let line) = failure, !line.isEmpty { return message + "\n" + line }
        return message
    }

    static func reportFailure(_ failure: DeveloperShellService.Failure, fileName: String) {
        let location: String
        if case .syntax(let line) = failure, !line.isEmpty { location = "~/" + fileName + ":" + line }
        else { location = "~/" + fileName }
        TaskFeedbackNotice.reportFailure(messageKey: failureKey(failure), details: [location], detailsAreLocalized: true)
    }

    private static func failureKey(_ failure: DeveloperShellService.Failure) -> String {
        switch failure {
        case .unsupportedFile, .unsafeFile: return "task.reason.path"
        case .tooLarge: return "task.reason.shellTooLarge"
        case .unreadable: return "task.reason.config"
        case .invalidEncoding: return "task.reason.shellEncoding"
        case .changedOnDisk: return "task.reason.configChanged"
        case .invalidVariable: return "task.reason.shellInvalidVariable"
        case .dynamicVariable: return "task.reason.shellDynamicVariable"
        case .syntax, .validationUnavailable: return "task.reason.shellSyntax"
        case .writeFailed: return "task.reason.config"
        }
    }
}

private struct DeveloperShellAliasSection: View {
    let profile: DeveloperShellService.Profile
    @ObservedObject var model: DeveloperShellModel
    @ObservedObject private var l10n = L10n.shared
    @State private var editing: DeveloperShellService.AliasDeclaration?
    @State private var isEditing = false
    @State private var name = ""
    @State private var command = ""
    @State private var pendingRemoval: DeveloperShellService.AliasDeclaration?
    private var aliases: [DeveloperShellService.AliasDeclaration] { DeveloperShellService.aliasDeclarations(in: profile) }

    var body: some View {
        DevDivider()
        DevSubheader(title: l10n.t("dev.shell.aliases"), detail: aliases.isEmpty ? nil : String(aliases.count)) {
            DevLinkButton(title: l10n.t("dev.shell.addAlias"), symbol: "plus") { begin(nil) }
                .disabled(model.isSaving || !profile.canEdit)
        }
        if isEditing {
            VStack(alignment: .leading, spacing: 8) {
                TextField(l10n.t("dev.shell.aliasName"), text: $name).textFieldStyle(.roundedBorder)
                TextField(l10n.t("dev.shell.aliasCommand"), text: $command).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button(l10n.t("common.cancel")) { isEditing = false }.buttonStyle(SecondaryButtonStyle())
                    Button(l10n.t("dev.shell.saveAlias")) {
                        Task {
                            if await model.setAlias(editing, name: name, command: command, in: profile) { isEditing = false }
                        }
                    }.buttonStyle(SecondaryButtonStyle(tint: .accentText)).disabled(model.isSaving || name.isEmpty || command.isEmpty)
                }
            }
            .font(.system(size: 11, design: .monospaced)).padding(.horizontal, 14).padding(.vertical, 8)
        }
        ForEach(aliases) { alias in
            HStack(spacing: 10) {
                Text(alias.name).font(.system(size: 12, weight: .medium, design: .monospaced))
                Text(DeveloperShellBackupStore.redactedLine(alias.command)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Button { begin(alias) } label: { Image(systemName: "pencil") }
                    .buttonStyle(MoleIconButtonStyle()).accessibilityLabel(l10n.tf("dev.shell.editAlias", alias.name))
                Button { pendingRemoval = alias } label: { Image(systemName: "trash") }
                    .buttonStyle(MoleIconButtonStyle(tint: .danger)).accessibilityLabel(l10n.tf("dev.shell.deleteAlias", alias.name))
            }
            .padding(.horizontal, 14).padding(.vertical, 8).disabled(model.isSaving)
        }
        .alert(l10n.t("dev.shell.deleteAliasConfirm"), isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
                Button(l10n.t("common.cancel"), role: .cancel) { pendingRemoval = nil }
                Button(l10n.t("dev.shell.delete"), role: .destructive) {
                    guard let alias = pendingRemoval else { return }
                    pendingRemoval = nil
                    Task { _ = await model.removeAlias(alias, in: profile) }
                }
            }
    }
    private func begin(_ alias: DeveloperShellService.AliasDeclaration?) {
        editing = alias; name = alias?.name ?? ""; command = alias?.command ?? ""; isEditing = true
    }
}

private struct DeveloperShellBackupPanel: View {
    let profile: DeveloperShellService.Profile
    @ObservedObject var model: DeveloperShellModel
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.dismiss) private var dismiss
    @State private var history: [DeveloperShellBackupStore.Entry] = []
    @State private var selected: DeveloperShellBackupStore.Entry?
    @State private var text: String?
    @State private var failure: String?
    @State private var confirmsRestore = false
    private var home: String { profile.homePath ?? NSHomeDirectory() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(l10n.t("dev.shell.backups")).font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(l10n.t("common.done")) { dismiss() }.buttonStyle(SecondaryButtonStyle())
            }
            Text(DevFiles.abbreviate(profile.path)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            DevCard(id: "dev-shell-backup-history") {
                DevCardTitle(symbol: "clock.arrow.circlepath", title: l10n.t("dev.shell.history"))
            } content: {
                if history.isEmpty {
                    DevNotice(symbol: "info.circle", text: l10n.t("dev.shell.noBackups"))
                }
                ForEach(history) { entry in
                    Button {
                        selected = entry
                        do { text = try DeveloperShellBackupStore.read(entry, targetPath: profile.path, home: home); failure = nil }
                        catch { text = nil; failure = DeveloperShellCopy.failure(error as? DeveloperShellService.Failure ?? .unreadable) }
                    } label: {
                        HStack {
                            Text(entry.date, format: .dateTime.year().month().day().hour().minute().second())
                            Spacer()
                            Image(systemName: selected?.id == entry.id ? "checkmark.circle" : "circle")
                        }.font(.system(size: 11)).padding(.horizontal, 14).padding(.vertical, 8)
                    }.buttonStyle(MolePlainButtonStyle())
                }
            }
            if let text {
                DevCard(id: "dev-shell-backup-diff") {
                    DevCardTitle(symbol: "doc.text", title: l10n.t("dev.shell.diff"))
                } content: {
                    ScrollView {
                        Text(DeveloperShellBackupStore.redactedDiff(current: profile.text, backup: text,
                                                                     hidden: l10n.t("dev.shell.hiddenLine")))
                            .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    }.frame(maxHeight: 180)
                }
                Text(l10n.t("dev.shell.backupPrivacy")).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let failure { Text(failure).font(.system(size: 11)).foregroundStyle(Color.danger) }
            HStack {
                Spacer()
                Button(l10n.t("dev.shell.restore")) { confirmsRestore = true }
                    .buttonStyle(SecondaryButtonStyle(tint: .accentText)).disabled(text == nil || model.isSaving)
            }
        }
        .padding(20).frame(width: 620)
        .task { await reload() }
        .alert(l10n.t("dev.shell.restoreConfirm"), isPresented: $confirmsRestore) {
            Button(l10n.t("common.cancel"), role: .cancel) {}
            Button(l10n.t("dev.shell.restore")) {
                guard let text, let selected else { return }
                do {
                    guard try DeveloperShellBackupStore.read(selected, targetPath: profile.path, home: home) == text else {
                        throw DeveloperShellService.Failure.changedOnDisk
                    }
                    Task {
                        if await model.save(text, replacing: profile) { dismiss() }
                        else { failure = model.failure.map(DeveloperShellCopy.failure) }
                    }
                } catch { failure = DeveloperShellCopy.failure(error as? DeveloperShellService.Failure ?? .unreadable) }
            }
        } message: { Text(l10n.t("dev.shell.restoreMessage")) }
    }
    private func reload() async {
        do { history = try DeveloperShellBackupStore.history(targetPath: profile.path, home: home) }
        catch { failure = DeveloperShellCopy.failure(error as? DeveloperShellService.Failure ?? .unreadable) }
    }
}
