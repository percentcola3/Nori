import Foundation
import Combine

enum DeveloperWorkspaceSection: String, CaseIterable, Identifiable {
    case overview, toolchains, packages, network, sshGit, shell, cleanup
    var id: String { rawValue }
    var titleKey: String { "dev.section." + rawValue }
    var symbol: String {
        switch self {
        case .overview: return "checkmark.shield"
        case .toolchains: return "hammer"
        case .packages: return "shippingbox"
        case .network: return "network"
        case .sshGit: return "key"
        case .shell: return "terminal"
        case .cleanup: return "sparkles"
        }
    }
}

struct DeveloperEnvironmentIssue: Identifiable, Equatable {
    enum Severity: Int, CaseIterable {
        case attention, suggestion, information
        var titleKey: String {
            switch self {
            case .attention: return "dev.overview.attention"
            case .suggestion: return "dev.overview.suggestion"
            case .information: return "dev.overview.information"
            }
        }
    }
    let id: String
    let titleKey: String
    let detail: String
    let section: DeveloperWorkspaceSection
    let severity: Severity
}

@MainActor
final class DeveloperWorkspaceModel: ObservableObject {
    @Published private(set) var terminal = DeveloperTerminalEnvironmentService.fallback()
    @Published private(set) var versions: [DeveloperManagedVersion] = []
    @Published private(set) var javaHomes: [String] = []
    @Published private(set) var packages = DeveloperPackageService.Inventory()
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLoadingPackages = false
    @Published private(set) var xcodes: [String] = []
    @Published private(set) var selectedXcode = ""
    @Published private(set) var xcodeLicenseRequired = false
    @Published private(set) var commandTitleKey: String?
    @Published private(set) var commandOutput = ""
    @Published private(set) var commandRunning = false {
        didSet { appState?.isDeveloperCommandRunning = commandRunning }
    }
    @Published private(set) var commandSucceeded: Bool?
    @Published private(set) var commandStarted: Date?
    @Published private(set) var commandFinished: Date?
    @Published private(set) var queuedCount = 0
    @Published private(set) var refreshRevision = 0
    @Published private(set) var shellProfile: DeveloperShellProfiler.Result?
    @Published private(set) var environmentIssues: [DeveloperEnvironmentIssue] = []
    @Published private(set) var availableQuery: DeveloperAvailableVersionQuery?
    @Published var operationError: String?
    private let engine = MoleEngine()
    private var queue: [DeveloperCommand] = []
    private var cancelled = false
    private var activeCommandID: UUID?
    private weak var appState: AppState?
    private var stateSubscription: AnyCancellable?
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var profileTask: Task<Void, Never>?

    func attach(state: AppState) {
        guard appState !== state || stateSubscription == nil else { return }
        appState = state
        state.isDeveloperCommandRunning = commandRunning
        stateSubscription = state.objectWillChange.sink { [weak self] _ in
            // Published sends before its value changes. Read busy state on the
            // next actor turn, independently of whether the Dev view is visible.
            Task { @MainActor [weak self] in self?.runNext() }
        }
    }

    func resumeQueue() { runNext() }

    func didChangeEnvironment() { refreshRevision &+= 1 }

    func proposeShellProfile(state: AppState) {
        state.confirmation = .init(title: L10n.shared.t("dev.shell.profile"), message: L10n.shared.t("dev.shell.profile.confirm"), confirmLabel: L10n.shared.t("dev.command.run")) { [weak self, weak state] in
            guard let self, let state, !self.commandRunning, !state.isBusy else { return }
            self.commandRunning = true
            self.commandTitleKey = "dev.shell.profile"
            self.commandSucceeded = nil
            self.commandStarted = Date()
            self.commandFinished = nil
            self.commandOutput = ""
            self.cancelled = false
            self.profileTask = Task {
                let profile = await DeveloperShellProfiler.profile(engine: self.engine)
                self.shellProfile = profile
                self.commandOutput = profile.median.map { L10n.shared.tf("dev.shell.profile.median", $0) + "\n" } ?? ""
                self.commandOutput += profile.functions
                self.commandSucceeded = !profile.failed && !self.cancelled
                self.commandFinished = Date()
                self.commandRunning = false
                self.didChangeEnvironment()
                self.profileTask = nil
                self.runNext()
            }
        }
    }

    func refresh(forceEnvironment: Bool = false) async {
        if isRefreshing {
            await withCheckedContinuation { refreshWaiters.append($0) }
            guard !Task.isCancelled else { return }
            if forceEnvironment { await refresh(forceEnvironment: true) }
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            let waiters = refreshWaiters
            refreshWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        let sample = await DeveloperTerminalEnvironmentService.shared.snapshot(force: forceEnvironment)
        guard !Task.isCancelled else { return }
        terminal = sample
        let env = sample.environment
        versions = await Task.detached(priority: .utility) { DeveloperToolchainService.inventory(environment: env) }.value
        javaHomes = await Task.detached(priority: .utility) { DeveloperToolchainService.javaHomes(environment: env) }.value
        xcodes = ((try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []).filter {
            $0.hasSuffix(".app") && FileManager.default.fileExists(atPath: "/Applications/" + $0 + "/Contents/Developer/usr/bin/xcodebuild")
        }.sorted().map { "/Applications/" + $0 + "/Contents/Developer" }
        let reader = MoleEngine()
        let selection = await reader.run(executable: URL(fileURLWithPath: "/usr/bin/xcode-select"), arguments: ["-p"],
                                         environment: reader.standardEnvironment(includeHomebrew: false), timeout: 3)
        selectedXcode = selection.succeeded ? selection.output.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        // An explicitly selected developer tree can be tested without the macOS installation stub.
        if selectedXcode.hasSuffix("Contents/Developer"), FileManager.default.isExecutableFile(atPath: selectedXcode + "/usr/bin/xcodebuild") {
            let check = await reader.run(executable: URL(fileURLWithPath: selectedXcode + "/usr/bin/xcodebuild"), arguments: ["-checkFirstLaunchStatus"],
                                         environment: reader.standardEnvironment(includeHomebrew: false), timeout: 5)
            xcodeLicenseRequired = !check.succeeded && check.output.localizedCaseInsensitiveContains("license")
        } else { xcodeLicenseRequired = false }
        rebuildEnvironmentIssues()
    }

    func loadPackages(checkUpdates: Bool = false) async {
        guard !isLoadingPackages else { return }
        isLoadingPackages = true
        packages = await DeveloperPackageService.scan(environment: terminal.environment, checkUpdates: checkUpdates)
        isLoadingPackages = false
    }

    func propose(_ command: DeveloperCommand?, state: AppState) {
        guard let command else { operationError = L10n.shared.t("dev.operation.unavailable"); return }
        state.confirmation = .init(title: L10n.shared.t(command.titleKey),
                                   message: L10n.shared.t("dev.command.confirm") + "\n\n" + command.display,
                                   confirmLabel: L10n.shared.t("dev.command.run")) { [weak self] in self?.enqueue(command) }
    }

    func enqueue(_ command: DeveloperCommand) {
        queue.append(command)
        queuedCount = queue.count
        if !commandRunning { runNext() }
    }

    func cancel() {
        cancelled = true
        queue.removeAll()
        queuedCount = 0
        engine.cancelAll()
        profileTask?.cancel()
    }

    /// Claims the same global busy state as a queued command before an async
    /// configuration save can yield. Queued commands resume after its refresh.
    @discardableResult
    func runConfigurationWrite(titleKey: String, failureKey: String = "dev.network.invalidSettings",
                               operation: @escaping @MainActor () async throws -> Void) -> Bool {
        guard !commandRunning, queue.isEmpty, appState?.isBusy != true else {
            operationError = L10n.shared.t("dev.operation.unavailable")
            return false
        }
        commandRunning = true
        commandTitleKey = titleKey
        commandSucceeded = nil
        commandStarted = Date()
        commandFinished = nil
        commandOutput = L10n.shared.t(titleKey) + "\n"
        activeCommandID = nil
        cancelled = false
        Task { [self] in
            guard !cancelled else {
                commandSucceeded = false
                commandOutput += L10n.shared.t("dev.command.cancelled") + "\n"
                commandFinished = Date()
                commandRunning = false
                runNext()
                return
            }
            do {
                try await operation()
                commandSucceeded = true
                commandOutput += L10n.shared.t("dev.command.success") + "\n"
            } catch {
                commandSucceeded = false
                operationError = L10n.shared.t(failureKey)
                commandOutput += L10n.shared.t(failureKey) + "\n"
            }
            await DeveloperTerminalEnvironmentService.shared.invalidate()
            await refresh(forceEnvironment: true)
            refreshRevision &+= 1
            if !packages.packages.isEmpty || !packages.services.isEmpty { await loadPackages() }
            if cancelled {
                commandSucceeded = false
                commandOutput += L10n.shared.t("dev.command.cancelled") + "\n"
            }
            commandFinished = Date()
            commandRunning = false
            runNext()
        }
        return true
    }

    private func runNext() {
        guard !commandRunning, !queue.isEmpty, appState?.isBusy != true else { return }
        let command = queue.removeFirst()
        queuedCount = queue.count
        commandRunning = true
        commandSucceeded = nil
        commandTitleKey = command.titleKey
        commandStarted = Date()
        commandFinished = nil
        commandOutput = command.display + "\n"
        activeCommandID = command.id
        cancelled = false
        Task { [self] in
            // cancel() may arrive after enqueue() claims busy but before this
            // task starts; the engine has no registered process to kill yet.
            guard !cancelled else {
                activeCommandID = nil
                commandSucceeded = false
                commandOutput += L10n.shared.t("dev.command.cancelled") + "\n"
                commandFinished = Date()
                commandRunning = false
                runNext()
                return
            }
            let onLine: (String) -> Void = { [weak self] line in
                let safe = DeveloperSecretRedactor.redact(line)
                Task { @MainActor [weak self] in
                    guard let self, self.activeCommandID == command.id else { return }
                    self.commandOutput = String((self.commandOutput + safe + "\n").suffix(65_536))
                }
            }
            let result: RunResult
            if let request = command.toolchainRequest,
               DeveloperToolchainService.command(manager: request.manager, operation: request.operation, version: request.version, candidate: request.candidate, environment: terminal.environment) == nil {
                result = .init(output: L10n.shared.t("dev.operation.unavailable"), exitCode: 2, timedOut: false)
            } else if let args = command.privilegedArguments {
                result = await engine.runPrivilegedBridge(command.privilegedBridge.rawValue, arguments: args, timeout: command.timeout)
                onLine(result.output)
            } else {
                result = await engine.run(executable: URL(fileURLWithPath: command.executable), arguments: command.arguments,
                                           environment: command.environment, currentDirectory: URL(fileURLWithPath: NSHomeDirectory()),
                                           timeout: command.timeout, onLine: onLine)
            }
            activeCommandID = nil
            commandOutput = String((command.display + "\n" + DeveloperSecretRedactor.redact(result.output + "\n" + result.errorOutput)).suffix(65_536))
            commandSucceeded = (command.titleKey == "dev.sshgit.testConnection"
                ? DeveloperSSHGitService.connectionSucceeded(output: result.output + "\n" + result.errorOutput, exitCode: result.exitCode)
                : result.succeeded) && !cancelled
            if commandSucceeded == true, let request = command.toolchainRequest, request.operation == .available {
                availableQuery = .init(manager: request.manager, candidate: request.candidate,
                                       versions: DeveloperAvailableVersions.parse(result.output, manager: request.manager))
            }
            if commandSucceeded != true, let group = command.operationGroup {
                queue.removeAll { $0.operationGroup == group }
                queuedCount = queue.count
            }
            if cancelled { commandOutput += L10n.shared.t("dev.command.cancelled") + "\n" }
            else if result.timedOut { commandOutput += L10n.shared.t("dev.command.timeout") + "\n" }
            commandFinished = Date()
            if command.refreshAfterExecution {
                await DeveloperTerminalEnvironmentService.shared.invalidate()
                await refresh(forceEnvironment: true)
                refreshRevision &+= 1
                if !packages.packages.isEmpty || !packages.services.isEmpty { await loadPackages() }
            }
            commandRunning = false
            runNext()
        }
    }

    private func rebuildEnvironmentIssues() {
        var issues: [DeveloperEnvironmentIssue] = []
        func add(_ id: String, _ title: String, _ detail: String, _ section: DeveloperWorkspaceSection,
                 _ severity: DeveloperEnvironmentIssue.Severity = .suggestion) {
            issues.append(.init(id: id, titleKey: title, detail: DeveloperSecretRedactor.redact(detail), section: section, severity: severity))
        }
        if terminal.failed { add("terminal", "dev.issue.environment", "", .overview, .attention) }
        let paths = (terminal.environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        let missing = paths.filter { !FileManager.default.fileExists(atPath: $0) }
        if !missing.isEmpty { add("path-dead", "dev.issue.path.dead", missing.joined(separator: " · "), .shell) }
        if Set(paths).count < paths.count { add("path-duplicate", "dev.issue.path.duplicate", "", .shell) }
        if let java = terminal.environment["JAVA_HOME"], !FileManager.default.fileExists(atPath: java) { add("java", "dev.issue.java", java, .toolchains, .attention) }
        if selectedXcode.isEmpty { add("clt", "dev.issue.clt", "", .toolchains, .attention) }
        if xcodeLicenseRequired { add("xcode", "dev.issue.xcode", "", .toolchains, .attention) }
        for manager in DeveloperManager.allCases {
            var candidates = Set(versions.filter { $0.manager == manager }.map(\.candidate))
            let standardCandidates: [DeveloperManager: String] = [.nvm: "node", .fnm: "node", .pyenv: "python", .rbenv: "ruby", .rustup: "rust"]
            if let candidate = standardCandidates[manager] { candidates.insert(candidate) }
            for candidate in candidates {
                for selected in DeveloperToolchainService.defaultVersions(manager, candidate: candidate, environment: terminal.environment, home: NSHomeDirectory()) where selected != "system" &&
                    !versions.contains(where: { $0.manager == manager && $0.candidate == candidate && ($0.version == selected || manager == .rustup && $0.version.hasPrefix(selected + "-")) }) {
                    add("default-" + manager.id + "-" + candidate + "-" + selected, "dev.issue.defaultMissing", manager.displayName + " · " + selected, .toolchains, .attention)
                }
            }
        }
        environmentIssues = issues
    }
}
