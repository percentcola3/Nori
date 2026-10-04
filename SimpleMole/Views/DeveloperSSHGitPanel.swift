import SwiftUI
import AppKit

@MainActor
final class DeveloperSSHGitModel: ObservableObject {
    @Published private(set) var keys: [DeveloperSSHGitService.Key] = []
    @Published private(set) var config: DeveloperSSHGitService.SSHConfig?
    @Published private(set) var git: [String: String] = [:]
    @Published private(set) var agentFingerprints: Set<String> = []
    @Published private(set) var gitAudited = false
    @Published private(set) var agentSocketAvailable = false
    @Published private(set) var agentLoadedKeys: Int?
    @Published private(set) var hasRefreshed = false
    @Published private(set) var isRefreshing = false
    @Published var failure: String?
    @Published var repositoryIdentity = ""

    var issues: [DeveloperEnvironmentIssue] {
        guard hasRefreshed else { return [] }
        var result: [DeveloperEnvironmentIssue] = []
        let loose = keys.filter(\.privatePermissionsLoose)
        if !loose.isEmpty {
            result.append(.init(id: "ssh-private-permissions", titleKey: "dev.sshgit.issue.permissions", detail: loose.map { URL(fileURLWithPath: $0.publicPath).deletingPathExtension().lastPathComponent }.joined(separator: ", "), section: .sshGit, severity: .attention))
        }
        let weak = keys.filter { $0.type == "ssh-rsa" && ($0.bits ?? 0) < 2048 }
        if !weak.isEmpty {
            result.append(.init(id: "ssh-weak-keys", titleKey: "dev.sshgit.issue.weakKeys", detail: weak.map { URL(fileURLWithPath: $0.publicPath).deletingPathExtension().lastPathComponent + " · " + String($0.bits ?? 0) }.joined(separator: ", "), section: .sshGit, severity: .suggestion))
        }
        if gitAudited, (git["user.name"] ?? "").isEmpty || (git["user.email"] ?? "").isEmpty {
            result.append(.init(id: "git-global-identity", titleKey: "dev.sshgit.issue.gitIdentity", detail: L10n.shared.t("dev.sshgit.issue.gitIdentity.detail"), section: .sshGit, severity: .suggestion))
        }
        if !agentSocketAvailable {
            result.append(.init(id: "ssh-agent-socket", titleKey: "dev.sshgit.issue.agentSocket", detail: L10n.shared.t("dev.sshgit.issue.agent.detail"), section: .sshGit, severity: .information))
        } else if agentLoadedKeys == 0 {
            result.append(.init(id: "ssh-agent-empty", titleKey: "dev.sshgit.issue.agentEmpty", detail: L10n.shared.t("dev.sshgit.issue.agent.detail"), section: .sshGit, severity: .information))
        }
        return result
    }

    func refresh(environment: [String: String]) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let scanned = await Task.detached(priority: .utility) {
            (DeveloperSSHGitService.keys(), try? DeveloperSSHGitService.readConfig())
        }.value
        keys = scanned.0; config = scanned.1
        let engine = MoleEngine(), env = DeveloperSSHGitService.commandEnvironment(environment)
        gitAudited = false
        git = [:]
        if let executable = DeveloperToolchainService.executable("git", environment: environment) {
            var values: [String: String] = [:]
            var audited = true
            for key in DeveloperSSHGitService.gitReadKeys {
                let result = await engine.run(executable: URL(fileURLWithPath: executable), arguments: ["config", "--global", "--includes", "--get", key], environment: env, timeout: 4)
                if result.exitCode != 0 && result.exitCode != 1 { audited = false }
                if result.succeeded { values[key] = DeveloperSecretRedactor.redact(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            git = values
            gitAudited = audited
        }
        var agentEnvironment = env
        if agentEnvironment["SSH_AUTH_SOCK"] == nil, let socket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] { agentEnvironment["SSH_AUTH_SOCK"] = socket }
        agentSocketAvailable = !(agentEnvironment["SSH_AUTH_SOCK"] ?? "").isEmpty
        let agent = await engine.run(executable: URL(fileURLWithPath: "/usr/bin/ssh-add"), arguments: ["-l"], environment: agentEnvironment, timeout: 3)
        agentFingerprints = Set(agent.output.split(whereSeparator: { $0.isWhitespace }).filter { $0.hasPrefix("SHA256:") }.map(String.init))
        agentLoadedKeys = agent.exitCode == 0 ? agent.output.split(separator: "\n").count : agent.exitCode == 1 ? 0 : nil
        hasRefreshed = true
    }
    func inspectRepository(_ path: String, environment: [String: String]) async {
        guard path.hasPrefix("/"), !path.contains("\0"), let git = DeveloperToolchainService.executable("git", environment: environment) else { return }
        let engine = MoleEngine()
        let repository = await engine.run(executable: URL(fileURLWithPath: git), arguments: ["-C", path, "rev-parse", "--git-dir"],
                                          environment: DeveloperSSHGitService.commandEnvironment(environment), timeout: 5)
        guard repository.succeeded else { repositoryIdentity = L10n.shared.t("dev.sshgit.noIdentity"); return }
        let result = await engine.run(executable: URL(fileURLWithPath: git), arguments: ["-C", path, "config", "--show-origin", "--get", "user.email"],
                                      environment: DeveloperSSHGitService.commandEnvironment(environment), timeout: 5)
        repositoryIdentity = result.succeeded ? DeveloperSecretRedactor.redact(result.output) : L10n.shared.t("dev.sshgit.noIdentity")
    }
    func saveHost(_ text: String, snapshot: DeveloperSSHGitService.SSHConfig) async throws {
        config = try await Task.detached(priority: .utility) {
            try DeveloperSSHGitService.saveConfig(text, replacing: snapshot)
            return try DeveloperSSHGitService.readConfig()
        }.value
        failure = nil
    }
}

struct DeveloperSSHGitPanel: View {
    @ObservedObject var workspace: DeveloperWorkspaceModel
    @ObservedObject var state: AppState
    @ObservedObject var model: DeveloperSSHGitModel
    @ObservedObject private var l10n = L10n.shared
    @State private var name = ""
    @State private var email = ""
    @State private var identitySeeded = false
    @State private var keyName = "id_ed25519_nori"
    @State private var keyComment = ""
    @State private var showsKeyGenerator = false
    @State private var selectedHost: DeveloperSSHGitService.HostBlock?
    @State private var editsHost = false
    @State private var showsAccountWizard = false
    @State private var workKey = "~/.ssh/id_ed25519_work"
    @State private var personalKey = "~/.ssh/id_ed25519_personal"
    @State private var host = "github-work"
    @State private var hostname = "github.com"
    @State private var user = "git"
    @State private var port = "22"
    @State private var identityFile = "~/.ssh/id_ed25519"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            keysCard
            configCard
            gitCard
            if let failure = model.failure { DevNotice(symbol: "exclamationmark.triangle", text: failure, color: .danger) }
        }
        .task(id: workspace.refreshRevision) {
            await model.refresh(environment: workspace.terminal.environment)
            if !identitySeeded { name = model.git["user.name"] ?? ""; email = model.git["user.email"] ?? ""; keyComment = email; identitySeeded = true }
        }
    }
    private var keysCard: some View {
        DevCard(id: "dev-ssh-keys") {
            DevCardTitle(symbol: "key", title: l10n.t("dev.sshgit.keys"))
            Spacer()
            if model.isRefreshing { ProgressView().controlSize(.small) }
            DevLinkButton(title: l10n.t("dev.sshgit.generate"), symbol: "plus") { showsKeyGenerator.toggle() }
        } content: {
            DevDivider()
            if model.keys.isEmpty { DevNotice(symbol: "key", text: l10n.t("dev.sshgit.noKeys")) }
            ForEach(model.keys) { key in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(URL(fileURLWithPath: key.publicPath).lastPathComponent).font(.system(size: 12, weight: .semibold, design: .monospaced))
                        Text(key.type + (key.bits.map { " · \($0)" } ?? "")).font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer()
                        Button(l10n.t("dev.sshgit.copyPublic")) { copyPublic(key) }.buttonStyle(SecondaryButtonStyle())
                        if key.needsPermissionRepair { Button(l10n.t("dev.sshgit.repairPermissions")) { repair(key) }.buttonStyle(SecondaryButtonStyle(tint: .warning)) }
                    }
                    Text(key.fingerprint).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    if !key.comment.isEmpty { Text(DeveloperSecretRedactor.redact(key.comment)).font(.system(size: 10)).foregroundStyle(.secondary) }
                    HStack {
                        DevTag(text: model.agentFingerprints.contains(key.fingerprint) ? l10n.t("dev.sshgit.inAgent") : l10n.t("dev.sshgit.notInAgent"))
                        if key.type == "ssh-rsa", let bits = key.bits, bits < 2048 { DevTag(text: l10n.t("dev.sshgit.weakKey"), color: .warning) }
                        if key.privatePath == nil { DevTag(text: l10n.t("dev.sshgit.publicOnly")) }
                    }
                }.padding(.horizontal, 14).padding(.vertical, 10)
                DevDivider(inset: 14)
            }
            if showsKeyGenerator {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(l10n.t("dev.sshgit.keyName"), text: $keyName).textFieldStyle(.roundedBorder)
                    TextField(l10n.t("dev.sshgit.keyComment"), text: $keyComment).textFieldStyle(.roundedBorder)
                    Text(l10n.t("dev.sshgit.passphraseTerminal")).font(.system(size: 11)).foregroundStyle(.secondary)
                    Button(l10n.t("dev.sshgit.openTerminal")) { generate() }.buttonStyle(SecondaryButtonStyle())
                }.padding(14)
            }
            DevNotice(symbol: "lock", text: l10n.t("dev.sshgit.keychainUnknown"))
            DevSubheader(title: l10n.t("dev.sshgit.testConnection"))
            HStack {
                ForEach(["github.com", "gitlab.com", "gitee.com"], id: \.self) { target in
                    Button(target) { workspace.propose(DeveloperSSHGitService.connectionCommand(host: target, environment: workspace.terminal.environment), state: state) }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }.padding(.horizontal, 14).padding(.bottom, 10)
            DevNotice(symbol: "lock.shield", text: l10n.t("dev.sshgit.hostTrust"))
            HStack {
                Link(l10n.t("dev.sshgit.githubFingerprints"), destination: URL(string: "https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints")!)
                Spacer()
                Menu(l10n.t("dev.sshgit.trustInTerminal")) {
                    ForEach(["github.com", "gitlab.com", "gitee.com"], id: \.self) { target in
                        Button(target) {
                            guard let script = DeveloperSSHGitService.trustConnectionScript(host: target) else { return }
                            state.confirmation = .init(title: l10n.t("dev.sshgit.trustInTerminal"), message: l10n.t("dev.sshgit.trustConfirm") + "\n" + target,
                                                       confirmLabel: l10n.t("dev.sshgit.openTerminal")) { openTerminalScript(script) }
                        }
                    }
                }.menuStyle(.borderlessButton).fixedSize()
                DevLinkButton(title: l10n.t("dev.sshgit.openKnownHosts"), symbol: "arrow.up.forward.app") { DevFiles.openInEditor(NSHomeDirectory() + "/.ssh/known_hosts") }
            }.font(.system(size: 11)).padding(.horizontal, 14).padding(.bottom, 10)
        }
    }
    private var configCard: some View {
        DevCard(id: "dev-ssh-config") {
            DevCardTitle(symbol: "server.rack", title: "~/.ssh/config")
            Spacer()
            DevLinkButton(title: l10n.t("dev.sshgit.newHost"), symbol: "plus") { beginHost(nil) }
            DevLinkButton(title: l10n.t("dev.sshgit.twoAccounts"), symbol: "person.2") { showsAccountWizard.toggle() }
            DevLinkButton(title: l10n.t("dev.sshgit.openConfig"), symbol: "arrow.up.forward.app") { DevFiles.openInEditor(NSHomeDirectory() + "/.ssh/config") }
        } content: {
            DevDivider()
            if let config = model.config {
                ForEach(config.blocks) { block in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(block.host).font(.system(size: 12, weight: .medium, design: .monospaced))
                            Text(DeveloperSecretRedactor.redact([block.fields["hostname"], block.fields["user"], block.fields["port"]].compactMap { $0 }.joined(separator: " · ")))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                            if !block.isEditable {
                                Text(block.fields.keys.sorted().map { key in
                                    DeveloperShellBackupStore.redactedLine(key + " " + (block.fields[key] ?? ""))
                                }.joined(separator: "\n"))
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        Spacer()
                        if block.isEditable {
                            Button(l10n.t("dev.sshgit.editHost")) { beginHost(block) }.buttonStyle(SecondaryButtonStyle())
                            if DeveloperSSHGitService.hostConnectionCommand(block, environment: workspace.terminal.environment, knownKeys: model.keys) != nil {
                                Button(l10n.t("dev.sshgit.testConnection")) { workspace.propose(DeveloperSSHGitService.hostConnectionCommand(block, environment: workspace.terminal.environment), state: state) }.buttonStyle(SecondaryButtonStyle())
                            }
                        }
                        else { DevTag(text: l10n.t("dev.sshgit.complexReadOnly")) }
                    }.padding(.horizontal, 14).padding(.vertical, 8)
                }
                if editsHost { hostEditor(config) }
                if showsAccountWizard {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField(l10n.t("dev.sshgit.workKey"), text: $workKey).textFieldStyle(.roundedBorder)
                        TextField(l10n.t("dev.sshgit.personalKey"), text: $personalKey).textFieldStyle(.roundedBorder)
                        Text(l10n.t("dev.sshgit.accountAliases")).font(.system(size: 11)).foregroundStyle(.secondary)
                        Button(l10n.t("dev.sshgit.saveAccounts")) { saveAccounts(config) }.buttonStyle(SecondaryButtonStyle(tint: .accentText))
                    }.padding(14)
                }
                DevNotice(symbol: "info.circle", text: l10n.t("dev.sshgit.configSafety"))
            } else { DevNotice(symbol: "exclamationmark.triangle", text: l10n.t("dev.sshgit.configUnavailable"), color: .warning) }
        }
    }
    private func hostEditor(_ snapshot: DeveloperSSHGitService.SSHConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(l10n.t("dev.sshgit.hostAlias"), text: $host).textFieldStyle(.roundedBorder)
            TextField(l10n.t("dev.sshgit.hostname"), text: $hostname).textFieldStyle(.roundedBorder)
            HStack {
                TextField(l10n.t("dev.sshgit.username"), text: $user).textFieldStyle(.roundedBorder)
                TextField(l10n.t("dev.sshgit.port"), text: $port).textFieldStyle(.roundedBorder).frame(width: 90)
            }
            TextField(l10n.t("dev.sshgit.identityFile"), text: $identityFile).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(l10n.t("common.cancel")) { editsHost = false }.buttonStyle(SecondaryButtonStyle())
                Button(l10n.t("dev.sshgit.saveHost")) {
                    do {
                        let draft = try DeveloperSSHGitService.settingHost(in: snapshot, block: selectedHost, host: host, hostname: hostname, user: user, port: port, identityFile: identityFile)
                        state.confirmation = .init(title: l10n.t("dev.sshgit.saveHost"), message: l10n.t("dev.sshgit.configWriteConfirm") + "\n" + DeveloperSecretRedactor.redact([host, hostname, user, port, identityFile].joined(separator: " · ")), confirmLabel: l10n.t("dev.sshgit.saveHost")) {
                            workspace.runConfigurationWrite(titleKey: "dev.sshgit.saveHost", failureKey: "dev.sshgit.writeFailed") {
                                try await model.saveHost(draft, snapshot: snapshot)
                                editsHost = false
                            }
                        }
                    } catch { model.failure = l10n.t("dev.sshgit.invalidHost") }
                }.buttonStyle(SecondaryButtonStyle(tint: .accentText))
            }
        }.font(.system(size: 11, design: .monospaced)).padding(14)
    }
    private var gitCard: some View {
        DevCard(id: "dev-git-identity") {
            DevCardTitle(symbol: "person.crop.circle", title: l10n.t("dev.sshgit.gitIdentity"))
        } content: {
            DevDivider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField(l10n.t("dev.sshgit.name"), text: $name).textFieldStyle(.roundedBorder)
                    Button(l10n.t("dev.sshgit.saveName")) { workspace.propose(DeveloperSSHGitService.gitCommand(field: .name, value: name, environment: workspace.terminal.environment), state: state) }.buttonStyle(SecondaryButtonStyle())
                }
                HStack {
                    TextField(l10n.t("dev.sshgit.email"), text: $email).textFieldStyle(.roundedBorder)
                    Button(l10n.t("dev.sshgit.saveEmail")) { workspace.propose(DeveloperSSHGitService.gitCommand(field: .email, value: email, environment: workspace.terminal.environment), state: state) }.buttonStyle(SecondaryButtonStyle())
                }
                ForEach(["credential.helper", "commit.gpgsign", "gpg.format", "user.signingkey"], id: \.self) { key in
                    Text(key + ": " + (model.git[key] ?? "—")).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }
                HStack {
                    Button(l10n.t("dev.sshgit.directoryIdentity")) { configureDirectoryIdentity() }.buttonStyle(SecondaryButtonStyle())
                    Button(l10n.t("dev.sshgit.inspectRepository")) {
                        if let path = DevFiles.chooseDirectory() { Task { await model.inspectRepository(path, environment: workspace.terminal.environment) } }
                    }.buttonStyle(SecondaryButtonStyle())
                }
                if !model.repositoryIdentity.isEmpty { Text(model.repositoryIdentity).font(.system(size: 10, design: .monospaced)).textSelection(.enabled) }
                DevNotice(symbol: "info.circle", text: l10n.t("dev.sshgit.directoryInfo"))
            }.padding(14)
        }
    }
    private func beginHost(_ block: DeveloperSSHGitService.HostBlock?) {
        selectedHost = block; host = block?.host ?? "github-work"; hostname = block?.fields["hostname"] ?? "github.com"
        user = block?.fields["user"] ?? "git"; port = block?.fields["port"] ?? "22"
        identityFile = block?.fields["identityfile"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? "~/.ssh/id_ed25519"
        editsHost = true
    }
    private func saveAccounts(_ snapshot: DeveloperSSHGitService.SSHConfig) {
        do {
            let first = try DeveloperSSHGitService.settingHost(in: snapshot, block: nil, host: "github-work", hostname: "github.com", user: "git", port: "22", identityFile: workKey)
            let intermediate = DeveloperSSHGitService.SSHConfig(text: first, data: snapshot.data, path: snapshot.path, identity: snapshot.identity, blocks: DeveloperSSHGitService.parseConfig(first))
            let draft = try DeveloperSSHGitService.settingHost(in: intermediate, block: nil, host: "github-personal", hostname: "github.com", user: "git", port: "22", identityFile: personalKey)
            state.confirmation = .init(title: l10n.t("dev.sshgit.saveAccounts"), message: l10n.t("dev.sshgit.configWriteConfirm") + "\ngithub-work → " + DeveloperSecretRedactor.redact(workKey) + "\ngithub-personal → " + DeveloperSecretRedactor.redact(personalKey), confirmLabel: l10n.t("dev.sshgit.saveAccounts")) {
                workspace.runConfigurationWrite(titleKey: "dev.sshgit.saveAccounts", failureKey: "dev.sshgit.writeFailed") {
                    try await model.saveHost(draft, snapshot: snapshot)
                    showsAccountWizard = false
                }
            }
        } catch { model.failure = l10n.t("dev.sshgit.invalidHost") }
    }
    private func copyPublic(_ key: DeveloperSSHGitService.Key) {
        guard let text = try? DeveloperSSHGitService.publicKeyText(key) else { model.failure = l10n.t("dev.sshgit.keyChanged"); return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text.trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)
    }
    private func repair(_ key: DeveloperSSHGitService.Key) {
        state.confirmation = .init(title: l10n.t("dev.sshgit.repairPermissions"), message: l10n.t("dev.sshgit.permissionConfirm") + "\n" + (key.privatePath ?? key.publicPath), confirmLabel: l10n.t("dev.sshgit.repairPermissions")) {
            workspace.runConfigurationWrite(titleKey: "dev.sshgit.repairPermissions", failureKey: "dev.sshgit.writeFailed") {
                try await Task.detached(priority: .utility) { try DeveloperSSHGitService.repairPermissions(key) }.value
            }
        }
    }
    private func generate() {
        guard let script = DeveloperSSHGitService.keyGenerationScript(name: keyName, comment: keyComment) else { model.failure = l10n.t("dev.sshgit.invalidKeyName"); return }
        state.confirmation = .init(title: l10n.t("dev.sshgit.generate"), message: l10n.t("dev.sshgit.passphraseTerminal") + "\n\n" + (script.components(separatedBy: "\n").first { $0.hasPrefix("exec ") } ?? ""), confirmLabel: l10n.t("dev.sshgit.openTerminal")) { openTerminalScript(script) }
    }
    private func openTerminalScript(_ script: String) {
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nori-keygen-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("Generate SSH Key.command")
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { throw DeveloperSSHGitService.Failure.write }
            NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if error != nil { Task { @MainActor in model.failure = l10n.t("dev.sshgit.writeFailed") } }
            }
        } catch { model.failure = l10n.t("dev.sshgit.writeFailed") }
    }
    private func configureDirectoryIdentity() {
        guard let directory = DevFiles.chooseDirectory(), let commands = DeveloperSSHGitService.directoryIdentityCommands(directory: directory, name: name, email: email, environment: workspace.terminal.environment) else { model.failure = l10n.t("dev.sshgit.invalidIdentity"); return }
        state.confirmation = .init(title: l10n.t("dev.sshgit.directoryIdentity"), message: l10n.t("dev.sshgit.directoryConfirm") + "\n\n" + commands.map(\.display).joined(separator: "\n"), confirmLabel: l10n.t("dev.command.run")) {
            workspace.runConfigurationWrite(titleKey: "dev.sshgit.directoryIdentity", failureKey: "dev.sshgit.writeFailed") {
                try await Task.detached(priority: .utility) { try DeveloperSSHGitService.createIdentityFile(commands[0].arguments[2]) }.value
                for command in commands { workspace.enqueue(command) }
            }
        }
    }
}
