import Foundation

// Session wiring and the two refresh-token entry points are real here.
// None of these doubles reads user files,
// preferences, starts a process, or samples an actual terminal environment.
@MainActor
protocol DeveloperRefreshFixture: AnyObject {
    var scanGate: DeveloperRefreshScanGate { get }
    var cachedToken: Int? { get }
    var committedSnapshot: Int? { get }
    func refresh(for token: Int) async
}

@MainActor
final class DeveloperRefreshScanGate {
    private(set) var calls = 0
    private var pending: [Int: CheckedContinuation<Int, Never>] = [:]
    private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func scan() async -> Int {
        let index = calls
        calls += 1
        return await withCheckedContinuation { continuation in
            pending[index] = continuation
            let ready = callWaiters.filter { $0.0 <= calls }
            callWaiters.removeAll { $0.0 <= calls }
            ready.forEach { $0.1.resume() }
        }
    }
    func waitForCalls(_ count: Int) async {
        guard calls < count else { return }
        await withCheckedContinuation { callWaiters.append((count, $0)) }
    }
    func release(index: Int) {
        guard let continuation = pending.removeValue(forKey: index) else { preconditionFailure("Missing fixture scan") }
        continuation.resume(returning: index + 1)
    }
}

@MainActor
final class AppState {
    var externalBusy = false
    var isDeveloperCommandRunning = false
    var isDeveloperConfigurationWriting = false {
        didSet {
            if !isDeveloperConfigurationWriting {
                let waiters = unlockWaiters
                unlockWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
    }
    var isBusy: Bool { externalBusy || isDeveloperCommandRunning || isDeveloperConfigurationWriting }
    private var unlockWaiters: [CheckedContinuation<Void, Never>] = []
    // SESSION_OWNER_DECLARATION
    func waitForWriteUnlock() async {
        guard isDeveloperConfigurationWriting else { return }
        await withCheckedContinuation { unlockWaiters.append($0) }
    }
}

@MainActor
final class DeveloperWorkspaceModel {
    private(set) weak var attachedState: AppState?
    private(set) var refreshRevision = 0
    private(set) var refreshCalls: [Bool] = []
    var pendingCommands: [String] = []
    private var refreshWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var pendingRefreshes: [Int: CheckedContinuation<Void, Never>] = [:]
    private var revisionWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func attach(state: AppState) { attachedState = state }
    func refresh(forceEnvironment: Bool = false) async {
        let index = refreshCalls.count
        refreshCalls.append(forceEnvironment)
        await withCheckedContinuation { continuation in
            pendingRefreshes[index] = continuation
            let ready = refreshWaiters.filter { $0.0 <= refreshCalls.count }
            refreshWaiters.removeAll { $0.0 <= refreshCalls.count }
            ready.forEach { $0.1.resume() }
        }
    }
    func waitForRefresh(count: Int = 1) async {
        guard refreshCalls.count < count else { return }
        await withCheckedContinuation { refreshWaiters.append((count, $0)) }
    }
    func releaseRefresh(index: Int = 0) {
        guard let continuation = pendingRefreshes.removeValue(forKey: index) else { preconditionFailure("Missing fixture refresh") }
        continuation.resume()
    }
    func didChangeEnvironment() {
        refreshRevision &+= 1
        let ready = revisionWaiters.filter { $0.0 <= refreshRevision }
        revisionWaiters.removeAll { $0.0 <= refreshRevision }
        ready.forEach { $0.1.resume() }
    }
    func waitForRevision(_ value: Int) async {
        guard refreshRevision < value else { return }
        await withCheckedContinuation { revisionWaiters.append((value, $0)) }
    }
}

@MainActor
final class DeveloperShellModel: DeveloperRefreshFixture {
    var revision = 0
    var draft = ""
    private(set) var isSaving = false
    var canWrite: (() -> Bool)?
    var savingStateChanged: ((Bool) -> Void)?
    let scanGate = DeveloperRefreshScanGate()
    private var lastToken: Int?
    var cachedToken: Int? { lastToken }
    private(set) var committedSnapshot: Int?
    // SHELL_REFRESH_METHOD
    func refresh() async {
        let snapshot = await scanGate.scan()
        guard !Task.isCancelled else { return }
        committedSnapshot = snapshot
    }
    @discardableResult
    func beginWrite() -> Bool {
        guard !isSaving, canWrite?() != false else { return false }
        isSaving = true
        savingStateChanged?(true)
        return true
    }
    func finishWrite(succeeded: Bool) {
        precondition(isSaving)
        if succeeded { revision &+= 1 }
        isSaving = false
        savingStateChanged?(false)
    }
}
@MainActor
final class DeveloperNetworkModel: DeveloperRefreshFixture {
    var draft = ""
    let scanGate = DeveloperRefreshScanGate()
    private var lastToken: Int?
    var cachedToken: Int? { lastToken }
    private(set) var committedSnapshot: Int?
    // NETWORK_REFRESH_METHOD
    func refresh() async {
        let snapshot = await scanGate.scan()
        guard !Task.isCancelled else { return }
        committedSnapshot = snapshot
    }
}
@MainActor final class DeveloperNetworkToolsModel {}
@MainActor final class DeveloperCLIModel {}
@MainActor final class DeveloperSSHGitModel { var draft = "" }

actor DeveloperTerminalEnvironmentService {
    static let shared = DeveloperTerminalEnvironmentService()
    private(set) var invalidations = 0
    func invalidate() { invalidations += 1 }
    func reset() { invalidations = 0 }
}
