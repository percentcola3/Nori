import Foundation

@main
struct DeveloperSessionTests {
    @MainActor static func main() async throws {
        let watchdog = Task.detached {
            do {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                fputs("FAIL: session fixture exceeded its asynchronous deadline\n", stderr)
                exit(1)
            } catch { }
        }
        defer { watchdog.cancel() }
        try viewReconstructionKeepsModels()
        try await writesKeepBusyThroughRefresh()
        try await failedWritesDoNotRefresh()
        try await ownerReleaseHasNoRetainCycle()
        try await activeRefreshDoesNotRetainOwner()
        try await releasedSessionClearsClaimedWrite()
        try await cancelledRefreshRetriesSameToken(DeveloperShellModel(), label: "Shell")
        try await cancelledRefreshRetriesSameToken(DeveloperNetworkModel(), label: "Network")
        try await oldCancellationPreservesNewToken(DeveloperShellModel(), label: "Shell")
        try await oldCancellationPreservesNewToken(DeveloperNetworkModel(), label: "Network")
        print("Developer Session: persistent models, global write/refresh lock, failed-write behavior, weak lifetimes and cancellation-safe refresh tokens passed")
    }

    @MainActor static func viewReconstructionKeepsModels() throws {
        let state = AppState()
        let first = DeveloperSessionViewFixture(state: state)
        first.shellModel.draft = "unsaved PATH draft"
        first.networkModel.draft = "unsaved hosts draft"
        first.sshModel.draft = "unsaved SSH draft"
        first.workspace.pendingCommands = ["queued task"]
        let rebuilt = DeveloperSessionViewFixture(state: state)
        try check(first.identities == rebuilt.identities && first.workspace === state.developerWorkspaceSession.workspace,
                  "Reconstructed Dev views share all six app-owned models")
        try check(rebuilt.shellModel.draft == "unsaved PATH draft" && rebuilt.networkModel.draft == "unsaved hosts draft"
                  && rebuilt.sshModel.draft == "unsaved SSH draft" && rebuilt.workspace.pendingCommands == ["queued task"],
                  "Page reconstruction preserves drafts and queued work")
        try check(rebuilt.workspace.attachedState === state, "The retained workspace attaches to its AppState owner")
    }

    @MainActor static func writesKeepBusyThroughRefresh() async throws {
        await DeveloperTerminalEnvironmentService.shared.reset()
        let state = AppState(), session = state.developerWorkspaceSession
        state.externalBusy = true
        try check(session.shell.canWrite?() == false && !session.shell.beginWrite(), "Another global operation blocks a Shell write")
        state.externalBusy = false
        state.isDeveloperCommandRunning = true
        try check(!session.shell.beginWrite(), "A management command blocks a Shell write")
        state.isDeveloperCommandRunning = false
        try check(session.shell.beginWrite() && state.isDeveloperConfigurationWriting && state.isBusy,
                  "Beginning a write claims the global lock synchronously")
        session.shell.finishWrite(succeeded: true)
        try check(state.isDeveloperConfigurationWriting && !session.shell.isSaving && session.shell.canWrite?() == false,
                  "Successful saving retains the global lock while environment refresh starts")
        await session.workspace.waitForRefresh()
        try check(session.workspace.refreshCalls == [true] && session.workspace.refreshRevision == 0
                  && state.isBusy && !session.shell.beginWrite(), "Forced refresh holds the write lock and blocks a second save")
        let invalidations = await DeveloperTerminalEnvironmentService.shared.invalidations
        try check(invalidations == 1, "Successful Shell writes invalidate the cached terminal sample once")
        session.workspace.releaseRefresh()
        await state.waitForWriteUnlock()
        try check(session.workspace.refreshRevision == 1 && !state.isBusy && session.shell.canWrite?() == true,
                  "Only a completed environment refresh publishes revision and releases busy")
        try check(session.shell.beginWrite(), "The Shell editor can save again after refresh finishes")
        session.shell.finishWrite(succeeded: false)
        try check(!state.isBusy, "A subsequent failed save also releases the lock")
    }

    @MainActor static func failedWritesDoNotRefresh() async throws {
        await DeveloperTerminalEnvironmentService.shared.reset()
        let state = AppState(), session = state.developerWorkspaceSession
        try check(session.shell.beginWrite(), "An idle Shell editor accepts the failure fixture")
        session.shell.finishWrite(succeeded: false)
        await Task.yield()
        let invalidations = await DeveloperTerminalEnvironmentService.shared.invalidations
        try check(!state.isBusy && session.shell.revision == 0 && session.workspace.refreshRevision == 0
                  && session.workspace.refreshCalls.isEmpty && invalidations == 0,
                  "A failure with unchanged revision never refreshes or invalidates the terminal sample")
    }

    @MainActor static func ownerReleaseHasNoRetainCycle() async throws {
        var owner: AppState? = AppState()
        weak var weakOwner = owner
        weak var weakSession = owner?.developerWorkspaceSession
        weak var weakWorkspace = owner?.developerWorkspaceSession.workspace
        weak var weakShell = owner?.developerWorkspaceSession.shell
        weak var weakNetwork = owner?.developerWorkspaceSession.network
        weak var weakTools = owner?.developerWorkspaceSession.networkTools
        weak var weakCLI = owner?.developerWorkspaceSession.cli
        weak var weakSSH = owner?.developerWorkspaceSession.ssh
        owner = nil
        try check(weakOwner == nil && weakSession == nil && weakWorkspace == nil && weakShell == nil
                  && weakNetwork == nil && weakTools == nil && weakCLI == nil && weakSSH == nil,
                  "Owner, Session and all models deallocate without callback retain cycles")
    }

    @MainActor static func activeRefreshDoesNotRetainOwner() async throws {
        await DeveloperTerminalEnvironmentService.shared.reset()
        var owner: AppState? = AppState()
        weak var weakOwner = owner
        weak var weakSession = owner?.developerWorkspaceSession
        let workspace = owner!.developerWorkspaceSession.workspace
        try check(owner!.developerWorkspaceSession.shell.beginWrite(), "A write can start the in-flight lifetime fixture")
        owner!.developerWorkspaceSession.shell.finishWrite(succeeded: true)
        await workspace.waitForRefresh()
        owner = nil
        try check(weakOwner == nil && workspace.attachedState == nil && weakSession != nil,
                  "An in-flight refresh retains its work but does not keep AppState alive")
        workspace.releaseRefresh()
        await workspace.waitForRevision(1)
        for _ in 0..<100 where weakSession != nil { await Task.yield() }
        try check(weakSession == nil, "The transient Session lifetime ends when its refresh completes")
    }

    @MainActor static func releasedSessionClearsClaimedWrite() async throws {
        await DeveloperTerminalEnvironmentService.shared.reset()
        let state = AppState()
        var transient: DeveloperWorkspaceSession? = DeveloperWorkspaceSession(state: state)
        weak var weakSession = transient
        let shell = transient!.shell
        try check(shell.beginWrite(), "A standalone Session can claim a write fixture")
        shell.finishWrite(succeeded: true)
        // No suspension occurs before release; the callback Task sees weak self.
        transient = nil
        try check(weakSession == nil && state.isBusy, "Callbacks do not keep an abandoned Session alive")
        await state.waitForWriteUnlock()
        let invalidations = await DeveloperTerminalEnvironmentService.shared.invalidations
        try check(!state.isBusy && invalidations == 0, "Abandoned Session callbacks release their claimed lock without refreshing")
    }

    @MainActor static func cancelledRefreshRetriesSameToken<Model: DeveloperRefreshFixture>(_ model: Model, label: String) async throws {
        let first = Task { await model.refresh(for: 41) }
        await model.scanGate.waitForCalls(1)
        first.cancel()
        try check(model.cachedToken == nil && model.committedSnapshot == nil,
                  "\(label): an unfinished cancelled scan is not treated as a cached result")

        // The detached/process scan can outlive the cancelled view task. A
        // returning view must start its read before that old scan finishes.
        let retry = Task { await model.refresh(for: 41) }
        await model.scanGate.waitForCalls(2)
        try check(model.scanGate.calls == 2 && model.committedSnapshot == nil,
                  "\(label): same-token reentry starts while the old cancelled scan is still pending")
        model.scanGate.release(index: 1)
        await retry.value
        try check(model.cachedToken == 41 && model.committedSnapshot == 2,
                  "\(label): returning with the same token retries and commits a fresh snapshot")

        model.scanGate.release(index: 0)
        await first.value
        try check(model.cachedToken == 41 && model.committedSnapshot == 2,
                  "\(label): the older cancelled same-token read cannot overwrite its replacement")
        await model.refresh(for: 41)
        try check(model.scanGate.calls == 2 && model.committedSnapshot == 2,
                  "\(label): a successful same-token reentry reuses its cached snapshot")
    }

    @MainActor static func oldCancellationPreservesNewToken<Model: DeveloperRefreshFixture>(_ model: Model, label: String) async throws {
        let old = Task { await model.refresh(for: 51) }
        await model.scanGate.waitForCalls(1)
        old.cancel()
        let newer = Task { await model.refresh(for: 52) }
        await model.scanGate.waitForCalls(2)

        model.scanGate.release(index: 1)
        await newer.value
        try check(model.cachedToken == 52 && model.committedSnapshot == 2,
                  "\(label): a newer token commits while an older cancelled scan remains pending")
        model.scanGate.release(index: 0)
        await old.value
        try check(model.cachedToken == 52 && model.committedSnapshot == 2,
                  "\(label): an old cancelled scan cannot overwrite a newer completed token")
        await model.refresh(for: 52)
        try check(model.cachedToken == 52 && model.committedSnapshot == 2 && model.scanGate.calls == 2,
                  "\(label): the newer scan commits and keeps its successful token cached")
    }

    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw SessionTestFailure(message: message) }
        print("PASS: " + message)
    }
    struct SessionTestFailure: Error { let message: String }
}
