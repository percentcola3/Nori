import SwiftUI
import AppKit

/// Owned state keeps shell editing separate from the workspace's runtime cleanup selection.
struct DeveloperShellPanel: View {
    let refreshToken: Int
    var isExpanded = true
    @StateObject private var model = DeveloperShellPanelModel()
    @ObservedObject private var l10n = L10n.shared
    @State private var selectedFile = ".zshrc"
    @State private var editor: DeveloperShellEditRequest?
    @State private var revealedValues: Set<String> = []
    @State private var completedRefreshToken: Int?

    private var profile: DeveloperShellService.Profile? {
        model.profiles.first { $0.name == selectedFile }
    }

    var body: some View {
        DeveloperWorkspaceContent(isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                if model.isRefreshing && model.profiles.isEmpty {
                    ProgressView(copy("读取 Shell 配置…", "Reading shell configuration…"))
                        .frame(maxWidth: .infinity, minHeight: 64)
                } else if let profile {
                    sourceHeader(profile)
                    profileContent(profile)
                }
                if let failure = model.failure {
                    Label(DeveloperShellCopy.failure(failure), systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.danger)
                }
                if let savedName = model.savedName {
                    savedNotice(savedName)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: refreshToken) {
            revealedValues.removeAll()
            await model.refresh()
            guard !Task.isCancelled else { return }
            completedRefreshToken = refreshToken
        }
        .preference(key: DeveloperWorkspaceSearchKey.self, value: [
            .shell: DeveloperWorkspaceSearchState(
                refreshToken: refreshToken,
                isSearching: completedRefreshToken != refreshToken || model.isRefreshing)
        ])
        .sheet(item: $editor) { request in
            DeveloperShellEditor(request: request, model: model)
        }
    }

    private func sourceHeader(_ profile: DeveloperShellService.Profile) -> some View {
        HStack(spacing: 10) {
            Picker(copy("配置来源", "Source file"), selection: $selectedFile) {
                ForEach(DeveloperShellService.fileNames, id: \.self) { name in
                    Text("~/\(name)").tag(name)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 240)
            .help(copy("读取 ~/ 下的四个标准配置，展示声明而非当前终端值。动态配置用「编辑配置」；自定义 ZDOTDIR 请在对应目录管理。",
                       "Reads declarations in the four standard files under ~/, not effective terminal values. Use Edit source for dynamic configuration; manage custom ZDOTDIR files in their own directory."))
            Spacer(minLength: 0)
            Button {
                editor = .init(profile: profile, operation: .add)
            } label: {
                Label(copy("新增变量", "Add variable"), systemImage: "plus")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!profile.canEdit || model.isSaving || model.isRefreshing)
            Button {
                editor = .init(profile: profile, operation: .source)
            } label: {
                Label(copy("编辑配置", "Edit source"), systemImage: "doc.text")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!profile.canEdit || model.isSaving || model.isRefreshing)
        }
    }

    private func profileContent(_ profile: DeveloperShellService.Profile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(profile.name, systemImage: "terminal")
                    .font(.system(size: 13, weight: .semibold))
                Text(sourcePurpose(profile.name))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(profile.exists ? copy("已读取", "Read") : copy("尚未创建", "Not created"))
                    .font(.system(size: 11))
                    .foregroundStyle(profile.canEdit ? Color.secondary : Color.warning)
            }
            .padding(14)
            if let problem = profile.problem {
                Text(DeveloperShellCopy.failure(problem))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.warning)
                    .padding([.horizontal, .bottom], 14)
            } else if profile.variables.isEmpty {
                Text(copy("暂无 export 声明。", "No export declarations."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding([.horizontal, .bottom], 14)
            } else {
                ForEach(profile.variables) { variable in
                    Rectangle().fill(Color.hairline).frame(height: 1)
                    variableRow(variable, profile: profile)
                }
            }
        }
        .clipped()
        .modifier(ListRowGlass())
    }

    private func variableRow(_ variable: DeveloperShellService.Variable,
                             profile: DeveloperShellService.Profile) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(variable.name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .textSelection(.enabled)
                Text("~/\(variable.fileName):\(variable.lineNumber)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 150, alignment: .leading)
            if variable.isDynamic {
                Label(copy("动态值 · 未执行", "Dynamic · not evaluated"), systemImage: "function")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.warning)
            } else {
                Text(revealedValues.contains(variable.id) ? (variable.literalValue ?? "") : "••••••••")
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !variable.isDynamic {
                Button {
                    if revealedValues.contains(variable.id) { revealedValues.remove(variable.id) }
                    else { revealedValues.insert(variable.id) }
                } label: {
                    Image(systemName: revealedValues.contains(variable.id) ? "eye.slash" : "eye")
                        .frame(width: 24, height: 26)
                }
                .buttonStyle(.plain)
                .help(copy("显示或隐藏变量值", "Show or hide the value"))
                .accessibilityLabel(copy("显示或隐藏变量值", "Show or hide the value"))
            }
            Button {
                editor = .init(profile: profile, operation: variable.isDynamic ? .source : .edit(variable))
            } label: {
                Image(systemName: "pencil").frame(width: 24, height: 26)
            }
            .buttonStyle(.plain)
            .help(copy("编辑", "Edit"))
            .accessibilityLabel(copy("编辑", "Edit"))
            .disabled(model.isSaving || model.isRefreshing)
            if !variable.isDynamic {
                Button {
                    editor = .init(profile: profile, operation: .remove(variable))
                } label: {
                    Image(systemName: "trash").foregroundStyle(Color.danger).frame(width: 24, height: 26)
                }
                .buttonStyle(.plain)
                .help(copy("删除声明", "Delete declaration"))
                .accessibilityLabel(copy("删除声明", "Delete declaration"))
                .disabled(model.isSaving || model.isRefreshing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func savedNotice(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(copy("已保存 \(name)", "Saved \(name)"), systemImage: "checkmark.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.success)
            if let backupPath = model.backupPath {
                HStack(spacing: 8) {
                    Text(copy("原文件已备份", "Original file backed up"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Button(copy("在 Finder 中查看", "Show in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: backupPath)])
                    }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.accentText)
                }
            }
            Text(copy("在新 Shell 中生效；现有终端继续运行。",
                      "Applies to new shells. Existing terminals keep running."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Button {
                model.openNewLoginShell()
            } label: {
                Label(copy("启动新的 zsh 登录 Shell", "Start a new zsh login shell"), systemImage: "terminal")
            }
            .buttonStyle(PrimaryButtonStyle())
            .help(copy("在新 Terminal 窗口执行 exec /bin/zsh -l。",
                       "Runs exec /bin/zsh -l in a new Terminal window."))
            if model.terminalFailed {
                Text(copy("无法打开 Terminal，可在新终端窗口手动执行 exec /bin/zsh -l。",
                          "Could not open Terminal. Run exec /bin/zsh -l manually in a new terminal window."))
                    .font(.system(size: 11)).foregroundStyle(Color.warning)
            }
        }
    }

    private func sourcePurpose(_ name: String) -> String {
        switch name {
        case ".zshenv": return copy("每个 zsh", "Every zsh")
        case ".zprofile": return copy("登录前配置", "Login startup")
        case ".zshrc": return copy("交互式终端", "Interactive shells")
        default: return copy("登录后配置", "After login startup")
        }
    }

    private func copy(_ chinese: String, _ english: String) -> String {
        DeveloperShellCopy.text(chinese, english)
    }
}

@MainActor
private final class DeveloperShellPanelModel: ObservableObject {
    @Published var profiles: [DeveloperShellService.Profile] = []
    @Published var isRefreshing = false
    @Published var isSaving = false
    @Published var failure: DeveloperShellService.Failure?
    @Published var savedName: String?
    @Published var backupPath: String?
    @Published var terminalFailed = false
    private var refreshGeneration = 0

    func refresh() async {
        guard !isSaving else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshing = true
        failure = nil
        let profiles = await Task.detached(priority: .utility) { DeveloperShellService.scan() }.value
        guard !Task.isCancelled, generation == refreshGeneration else {
            if generation == refreshGeneration { isRefreshing = false }
            return
        }
        self.profiles = profiles
        isRefreshing = false
    }

    func save(_ text: String, replacing profile: DeveloperShellService.Profile) async -> Bool {
        guard !isSaving else { return false }
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
            terminalFailed = false
            return true
        case .failure(let error):
            failure = error as? DeveloperShellService.Failure ?? .writeFailed
            return false
        }
    }

    func openNewLoginShell() {
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nori-login-shell-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                  attributes: [.posixPermissions: 0o700])
            let command = directory.appendingPathComponent("Nori-zsh.command")
            try "#!/bin/zsh -f\nexec /bin/zsh -l\n".write(to: command, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            // A .command opens in a new Terminal window without an Apple Events entitlement.
            NSWorkspace.shared.open([command],
                                    withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                    configuration: configuration) { [weak self] _, error in
                Task { @MainActor in self?.terminalFailed = error != nil }
            }
        } catch { terminalFailed = true }
    }
}

private struct DeveloperShellEditRequest: Identifiable {
    enum Operation {
        case add
        case edit(DeveloperShellService.Variable)
        case remove(DeveloperShellService.Variable)
        case source
    }
    let id = UUID()
    let profile: DeveloperShellService.Profile
    let operation: Operation
}

private struct DeveloperShellEditor: View {
    let request: DeveloperShellEditRequest
    @ObservedObject var model: DeveloperShellPanelModel
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var value: String
    @State private var source: String
    @State private var revealValue = false
    @State private var localFailure: DeveloperShellService.Failure?
    @State private var saving = false

    init(request: DeveloperShellEditRequest, model: DeveloperShellPanelModel) {
        self.request = request
        self.model = model
        // A sheet owns a draft seeded once from the exact file snapshot being edited.
        if case .edit(let variable) = request.operation {
            _name = State(initialValue: variable.name)
            _value = State(initialValue: variable.literalValue ?? "")
        } else {
            _name = State(initialValue: "")
            _value = State(initialValue: "")
        }
        _source = State(initialValue: request.profile.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title).font(.system(size: 18, weight: .semibold))
                Spacer()
                Text("~/\(request.profile.name)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            }
            editorContent.disabled(saving)
            Text(copy("保存前进行 zsh 语法检查，并为现有文件创建备份；若文件已被其他应用修改，将拒绝覆盖。",
                      "Save checks zsh syntax and backs up existing files. Changes made by another application will not be overwritten."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let failure = localFailure {
                Text(DeveloperShellCopy.failure(failure)).font(.system(size: 12)).foregroundStyle(Color.danger)
            }
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button(copy("取消", "Cancel")) { dismiss() }.buttonStyle(.plain).disabled(saving)
                Button(saveTitle) { Task { await save() } }
                    .buttonStyle(.plain)
                    .foregroundStyle(isRemoval ? Color.danger : Color.accentText)
                    .font(.system(size: 13, weight: .semibold))
                    .disabled(saving)
            }
        }
        .padding(24)
        .frame(minWidth: 600, idealWidth: 680)
        .clipped()
        .modifier(ListRowGlass())
        .interactiveDismissDisabled(saving)
    }

    @ViewBuilder
    private var editorContent: some View {
        switch request.operation {
        case .source:
            Text(copy("源文件可能包含密钥。此处编辑完整配置；保存不会执行其中的命令。",
                      "Source files may contain secrets. Edit the full configuration here; saving does not execute it."))
                .font(.system(size: 12)).foregroundStyle(Color.warning)
            TextEditor(text: $source)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(height: 340)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.hairline))
        case .remove(let variable):
            Text(copy("删除 \(variable.name) 在第 \(variable.lineNumber) 行的 export 声明？已有终端不会立即改变。",
                      "Delete the export declaration for \(variable.name) on line \(variable.lineNumber)? Existing shells do not change immediately."))
                .font(.system(size: 13))
        case .add, .edit:
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 14) {
                GridRow {
                    Text(copy("变量名", "Name")).font(.system(size: 12))
                    TextField("VARIABLE_NAME", text: $name).textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                }
                GridRow {
                    Text(copy("字面量值", "Literal value")).font(.system(size: 12))
                    HStack {
                        if revealValue { TextField("", text: $value).textFieldStyle(.plain) }
                        else { SecureField("", text: $value).textFieldStyle(.plain) }
                        Button { revealValue.toggle() } label: {
                            Image(systemName: revealValue ? "eye.slash" : "eye")
                        }.buttonStyle(.plain)
                            .accessibilityLabel(copy("显示或隐藏变量值", "Show or hide the value"))
                    }.font(.system(size: 13, design: .monospaced))
                }
            }
            Text(copy("值按纯文本保存并自动转义，$HOME、$(command) 等不会作为表达式执行。动态配置请使用「编辑配置」。",
                      "Values are saved as escaped literal text. $HOME and $(command) are not evaluated. Use Edit source for dynamic configuration."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var isRemoval: Bool {
        if case .remove = request.operation { return true }
        return false
    }

    private var title: String {
        switch request.operation {
        case .add: return copy("新增环境变量", "Add environment variable")
        case .edit: return copy("编辑环境变量", "Edit environment variable")
        case .remove: return copy("删除环境变量", "Delete environment variable")
        case .source: return copy("编辑 zsh 配置", "Edit zsh configuration")
        }
    }

    private var saveTitle: String {
        isRemoval ? copy("删除并保存", "Delete & save") : copy("检查并保存", "Check & save")
    }

    private func save() async {
        saving = true
        localFailure = nil
        defer { saving = false }
        do {
            let candidate: String
            switch request.operation {
            case .source: candidate = source
            case .add:
                candidate = try DeveloperShellService.settingVariable(in: request.profile, variable: nil,
                                                                     name: name, value: value)
            case .edit(let variable):
                candidate = try DeveloperShellService.settingVariable(in: request.profile, variable: variable,
                                                                     name: name, value: value)
            case .remove(let variable):
                candidate = try DeveloperShellService.removingVariable(in: request.profile, variable: variable)
            }
            if await model.save(candidate, replacing: request.profile) { dismiss() }
            else { localFailure = model.failure }
        } catch { localFailure = error as? DeveloperShellService.Failure ?? .writeFailed }
    }

    private func copy(_ chinese: String, _ english: String) -> String {
        DeveloperShellCopy.text(chinese, english)
    }
}

private enum DeveloperShellCopy {
    static func text(_ chinese: String, _ english: String) -> String {
        switch L10n.shared.resolved {
        case .zhHans, .zhHant: return chinese
        default: return english
        }
    }

    static func failure(_ failure: DeveloperShellService.Failure) -> String {
        switch failure {
        case .unsupportedFile: return text("只支持四个标准 zsh 配置文件。", "Only the four standard zsh startup files are supported.")
        case .unsafeFile: return text("拒绝读取或修改符号链接、硬链接、非普通文件及不属于当前用户的文件。", "Symlinks, hard links, nonregular files and files owned by another user are refused.")
        case .tooLarge: return text("配置文件超过 2 MB，请使用外部编辑器。", "The file exceeds 2 MB. Use an external editor.")
        case .unreadable: return text("无法读取此配置文件，请检查权限。", "Cannot read this file. Check its permissions.")
        case .invalidEncoding: return text("仅支持不含空字符的 UTF-8 配置。", "Only UTF-8 configuration without null characters is supported.")
        case .changedOnDisk: return text("文件已被其他应用修改。重新进入开发环境读取最新内容后再编辑。", "The file changed on disk. Reopen Developer workspace to read the latest content before editing.")
        case .invalidVariable: return text("变量名需为字母、数字或下划线，且不能以数字开头；值不能换行。", "Names must start with a letter or underscore and contain letters, digits or underscores. Values cannot contain newlines.")
        case .dynamicVariable: return text("动态或复杂声明请在完整配置中编辑。", "Edit dynamic or complex declarations in the source file.")
        case .syntax(let line):
            return line.isEmpty ? text("zsh 语法检查未通过，文件尚未保存。", "zsh syntax validation failed. The file was not saved.")
                : text("zsh 语法检查未通过（第 \(line) 行），文件尚未保存。", "zsh syntax validation failed on line \(line). The file was not saved.")
        case .validationUnavailable: return text("无法完成 zsh 语法检查，文件尚未保存。", "Could not complete zsh syntax validation. The file was not saved.")
        case .writeFailed: return text("无法安全保存配置，原文件未被覆盖。", "Could not safely save the configuration.")
        }
    }
}
