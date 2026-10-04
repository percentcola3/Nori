import Foundation
import Combine

struct DeveloperQueueTestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct DeveloperCommandQueueTests {
    static let fixture = DeveloperQueueFixture.shared
    static let selectionKey = DeveloperQueueFixture.key("/usr/bin/xcode-select", ["-p"])

    @MainActor
    static func main() async {
        let defaults = UserDefaults.standard
        let enabledKey = DeveloperTerminalEnvironmentService.enabledKey
        let previousSampling = defaults.object(forKey: enabledKey)
        defaults.set(false, forKey: enabledKey)
        defer {
            if let previousSampling { defaults.set(previousSampling, forKey: enabledKey) }
            else { defaults.removeObject(forKey: enabledKey) }
        }
        let watchdog = Task.detached {
            do {
                try await Task.sleep(nanoseconds: 20_000_000_000)
                fputs("FAIL: developer command queue fixture exceeded its async deadline\n", stderr)
                exit(1)
            } catch { }
        }
        defer { watchdog.cancel() }
        do {
            try await serialDuringRefresh()
            try await postCommandRefreshWaitsForExistingRead()
            try await failureRemovesOnlyItsGroup()
            try await cancellationClearsQueue()
            try await immediateCancellationNeverStartsCommand()
            try await externalBusyBlocksAndResumes()
            try await automaticResumeWithoutViewCallbacks()
            try await configurationWriteClaimsBeforeSuspension()
            try await disabledSamplingNeverRunsShell()
            print("PASS: developer command queue (refresh seriality/overlapping reads, grouped failure, running/immediate cancellation, global busy, automatic resume without views, configuration write lock, sampling disabled)")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw DeveloperQueueTestFailure(description: message) }
    }

    static func path(_ name: String) -> String { "/fixture/commands/" + name }

    static func command(_ name: String, group: UUID? = nil, refresh: Bool = false) -> DeveloperCommand {
        var command = DeveloperCommand(titleKey: "fixture." + name, executable: path(name), arguments: [],
                                       environment: ["PATH": "/fixture/commands"], timeout: 5, privilegedArguments: nil)
        command.operationGroup = group
        command.refreshAfterExecution = refresh
        return command
    }

    @MainActor
    static func waitForIdle(_ model: DeveloperWorkspaceModel) async {
        guard model.commandRunning || model.queuedCount != 0 else { return }
        var token: AnyCancellable?
        await withCheckedContinuation { continuation in
            token = model.$commandRunning.dropFirst().sink { running in
                if !running && model.queuedCount == 0 { continuation.resume() }
            }
        }
        token?.cancel()
    }

    @MainActor
    static func waitForStopped(_ model: DeveloperWorkspaceModel) async {
        guard model.commandRunning else { return }
        var token: AnyCancellable?
        await withCheckedContinuation { continuation in
            token = model.$commandRunning.dropFirst().sink { running in
                if !running { continuation.resume() }
            }
        }
        token?.cancel()
    }

    @MainActor
    static func waitForCommandFinished(_ model: DeveloperWorkspaceModel) async {
        guard model.commandFinished == nil else { return }
        var token: AnyCancellable?
        await withCheckedContinuation { continuation in
            token = model.$commandFinished.dropFirst().sink { finished in
                if finished != nil { continuation.resume() }
            }
        }
        token?.cancel()
    }

    @MainActor
    static func serialDuringRefresh() async throws {
        await fixture.reset(allowed: [path("first"), path("second"), path("third"), selectionKey])
        let model = DeveloperWorkspaceModel(), state = AppState()
        model.attach(state: state)
        model.enqueue(command("first", refresh: true))
        let first = await fixture.waitForCall(path("first"))
        model.enqueue(command("second"))
        await fixture.release(first)
        let refresh = await fixture.waitForCall("/usr/bin/xcode-select", arguments: ["-p"])
        try check(model.commandRunning && state.isBusy && state.isDeveloperCommandRunning,
                  "Command/global busy must remain set during its post-command refresh")
        model.enqueue(command("third"))
        let paused = await fixture.snapshot()
        try check(model.queuedCount == 2 && paused.invocations.map(\.path) == [path("first"), "/usr/bin/xcode-select"],
                  "Enqueue during post-command refresh must leave both successors pending")
        await fixture.release(refresh, result: .init(output: "", exitCode: 1, timedOut: false))
        let second = await fixture.waitForCall(path("second"))
        try check(model.refreshRevision == 1, "Next command must start after refresh revision advances")
        await fixture.release(second)
        let third = await fixture.waitForCall(path("third"))
        await fixture.release(third)
        await waitForIdle(model)
        let completed = await fixture.snapshot()
        try check(completed.invocations.filter(\.isManagementCommand).map(\.path) == [path("first"), path("second"), path("third")],
                  "Workspace command order must remain FIFO across refresh")
        try check(completed.maximumActiveCommands == 1 && completed.activeCommands == 0,
                  "Workspace must never run management commands in parallel")
        try check(!state.isDeveloperCommandRunning && !state.isBusy && model.commandSucceeded == true,
                  "Final completion must clear global busy and preserve success")
        try check(!model.terminal.isSampled, "Disabled terminal sampling must remain disabled after command refresh")
    }

    @MainActor
    static func failureRemovesOnlyItsGroup() async throws {
        await fixture.reset(allowed: [path("group-fail"), path("other-group")])
        let model = DeveloperWorkspaceModel(), state = AppState(), group = UUID()
        model.attach(state: state)
        model.enqueue(command("group-fail", group: group))
        let first = await fixture.waitForCall(path("group-fail"))
        model.enqueue(command("skip-after-failure", group: group))
        model.enqueue(command("other-group", group: UUID()))
        await fixture.release(first, result: .init(output: "fixture failed", exitCode: 1, timedOut: false))
        let other = await fixture.waitForCall(path("other-group"))
        try check(model.queuedCount == 0, "Failure must remove remaining commands in the failed group")
        await fixture.release(other)
        await waitForIdle(model)
        let completed = await fixture.snapshot()
        try check(completed.invocations.map(\.path) == [path("group-fail"), path("other-group")],
                  "Failure must skip its successor without discarding an unrelated operation")
    }

    @MainActor
    static func postCommandRefreshWaitsForExistingRead() async throws {
        await fixture.reset(allowed: [path("during-read"), path("after-fresh-read"), selectionKey])
        let model = DeveloperWorkspaceModel(), state = AppState()
        model.attach(state: state)
        let existingRead = Task { await model.refresh() }
        let oldSelection = await fixture.waitForCall("/usr/bin/xcode-select", arguments: ["-p"])
        model.enqueue(command("during-read", refresh: true))
        let commandCall = await fixture.waitForCall(path("during-read"))
        model.enqueue(command("after-fresh-read"))
        await fixture.release(commandCall)
        await waitForCommandFinished(model)
        let waiting = await fixture.snapshot()
        try check(model.commandRunning && state.isBusy && model.queuedCount == 1 && model.refreshRevision == 0,
                  "Completed mutation must keep busy while waiting for an existing read refresh")
        try check(waiting.invocations.filter { $0.path == "/usr/bin/xcode-select" }.count == 1
                  && !waiting.invocations.contains { $0.path == path("after-fresh-read") },
                  "Forced post-command refresh must wait before starting a new scan or successor")
        await fixture.release(oldSelection, result: .init(output: "", exitCode: 1, timedOut: false))
        await existingRead.value
        let freshSelection = await fixture.waitForCall("/usr/bin/xcode-select", arguments: ["-p"], occurrence: 2)
        try check(model.commandRunning && state.isBusy && model.refreshRevision == 0 && model.queuedCount == 1,
                  "Waiting for a preexisting refresh must still be followed by a fresh post-mutation scan")
        await fixture.release(freshSelection, result: .init(output: "", exitCode: 1, timedOut: false))
        let next = await fixture.waitForCall(path("after-fresh-read"))
        try check(model.refreshRevision == 1, "Successor may begin only after the fresh post-command scan completes")
        await fixture.release(next)
        await waitForIdle(model)
    }

    @MainActor
    static func cancellationClearsQueue() async throws {
        await fixture.reset(allowed: [path("cancel-running"), path("after-cancel")])
        let model = DeveloperWorkspaceModel(), state = AppState()
        model.attach(state: state)
        model.enqueue(command("cancel-running"))
        _ = await fixture.waitForCall(path("cancel-running"))
        model.enqueue(command("skip-after-cancel"))
        model.cancel()
        try check(model.queuedCount == 0, "Cancellation must clear queued work immediately")
        await waitForIdle(model)
        let cancelled = await fixture.snapshot()
        try check(cancelled.cancellations == 1 && cancelled.invocations.map(\.path) == [path("cancel-running")],
                  "Cancellation must stop the active engine and never run the queued successor")
        try check(model.commandSucceeded == false && model.commandOutput.contains("dev.command.cancelled")
                  && !state.isDeveloperCommandRunning, "Cancelled command must publish its status and clear busy")
        model.enqueue(command("after-cancel"))
        let next = await fixture.waitForCall(path("after-cancel"))
        await fixture.release(next)
        await waitForIdle(model)
        try check(model.commandSucceeded == true, "Queue must be reusable after cancellation")
    }

    @MainActor
    static func externalBusyBlocksAndResumes() async throws {
        await fixture.reset(allowed: [path("busy-first"), path("busy-second"), selectionKey])
        let model = DeveloperWorkspaceModel(), state = AppState()
        state.externalBusy = true
        model.attach(state: state)
        model.enqueue(command("busy-first", refresh: true))
        model.resumeQueue()
        try check(model.queuedCount == 1 && !model.commandRunning, "Existing AppState work must block command start")
        let blocked = await fixture.snapshot()
        try check(blocked.invocations.isEmpty, "Resume must not bypass the global busy guard")
        state.externalBusy = false
        model.resumeQueue()
        let first = await fixture.waitForCall(path("busy-first"))
        model.enqueue(command("busy-second"))
        await fixture.release(first)
        let refresh = await fixture.waitForCall("/usr/bin/xcode-select", arguments: ["-p"])
        state.externalBusy = true
        await fixture.release(refresh, result: .init(output: "", exitCode: 1, timedOut: false))
        await waitForStopped(model)
        try check(model.queuedCount == 1 && state.isBusy && !state.isDeveloperCommandRunning,
                  "New global work during refresh must defer the next queued command")
        model.resumeQueue()
        let stillBlocked = await fixture.snapshot()
        try check(!stillBlocked.invocations.contains { $0.path == path("busy-second") },
                  "Explicit resume must still respect another AppState operation")
        state.externalBusy = false
        model.resumeQueue()
        let second = await fixture.waitForCall(path("busy-second"))
        await fixture.release(second)
        await waitForIdle(model)
        try check(!state.isBusy && model.commandSucceeded == true, "Clearing external busy and resuming must drain the queue")
    }

    @MainActor
    static func immediateCancellationNeverStartsCommand() async throws {
        await fixture.reset(allowed: [])
        let model = DeveloperWorkspaceModel(), state = AppState()
        model.attach(state: state)
        // There is deliberately no async yield between enqueue and cancel.
        model.enqueue(command("must-not-start"))
        model.cancel()
        await fixture.waitForCancellation()
        await waitForIdle(model)
        let completed = await fixture.snapshot()
        try check(completed.invocations.isEmpty && !state.isBusy && model.commandSucceeded == false,
                  "Cancellation before the command Task starts must prevent process invocation")
    }

    @MainActor
    static func automaticResumeWithoutViewCallbacks() async throws {
        await fixture.reset(allowed: [path("automatic-first"), path("automatic-second"), selectionKey])
        let model = DeveloperWorkspaceModel(), state = AppState()
        state.externalBusy = true
        model.attach(state: state)
        model.enqueue(command("automatic-first", refresh: true))
        try check(model.queuedCount == 1 && !model.commandRunning,
                  "Pending work must wait for another AppState operation")
        // No View exists in this fixture and no resumeQueue() callback is sent.
        state.externalBusy = false
        let first = await fixture.waitForCall(path("automatic-first"))
        try check(state.isDeveloperCommandRunning && state.isBusy,
                  "The attached model must automatically resume when global busy clears")
        model.enqueue(command("automatic-second"))
        await fixture.release(first)
        let refresh = await fixture.waitForCall("/usr/bin/xcode-select", arguments: ["-p"])
        state.externalBusy = true
        await fixture.release(refresh, result: .init(output: "", exitCode: 1, timedOut: false))
        await waitForStopped(model)
        let paused = await fixture.snapshot()
        try check(model.queuedCount == 1 && !paused.invocations.contains { $0.path == path("automatic-second") },
                  "An external task during refresh must preserve the paused successor")
        // This also models switching the main tab away while the queue waits.
        state.externalBusy = false
        let second = await fixture.waitForCall(path("automatic-second"))
        await fixture.release(second)
        await waitForIdle(model)
        let completed = await fixture.snapshot()
        try check(completed.maximumActiveCommands == 1 && !state.isBusy && model.commandSucceeded == true,
                  "A paused queue must drain without relying on a SwiftUI lifecycle callback")
    }

    @MainActor
    static func configurationWriteClaimsBeforeSuspension() async throws {
        await fixture.reset(allowed: [path("save-gate"), path("after-save"), selectionKey])
        let model = DeveloperWorkspaceModel(), state = AppState()
        model.attach(state: state)
        state.externalBusy = true
        var rejectedOperationRan = false
        let rejected = model.runConfigurationWrite(titleKey: "fixture.blocked") { rejectedOperationRan = true }
        try check(!rejected && !rejectedOperationRan && !model.commandRunning,
                  "Configuration write must respect an existing global busy operation")
        state.externalBusy = false
        let accepted = model.runConfigurationWrite(titleKey: "fixture.save") {
            // This non-executing gate stands for the asynchronous atomic save.
            _ = await MoleEngine().run(executable: URL(fileURLWithPath: path("save-gate")), arguments: [], timeout: 5)
        }
        try check(accepted && model.commandRunning && state.isDeveloperCommandRunning && state.isBusy,
                  "Configuration write must claim global busy synchronously before its Task yields")
        model.enqueue(command("after-save"))
        let saving = await fixture.waitForCall(path("save-gate"))
        let pending = await fixture.snapshot()
        try check(model.queuedCount == 1 && pending.invocations.map(\.path) == [path("save-gate")],
                  "Enqueue during a configuration save must stay pending")
        let secondWrite = model.runConfigurationWrite(titleKey: "fixture.concurrent-save") { rejectedOperationRan = true }
        try check(!secondWrite && !rejectedOperationRan, "A second save must not enter the claimed configuration lock")
        await fixture.release(saving)
        let refresh = await fixture.waitForCall("/usr/bin/xcode-select", arguments: ["-p"])
        try check(model.commandRunning && state.isBusy && model.queuedCount == 1,
                  "Configuration lock must remain held through post-save refresh")
        await fixture.release(refresh, result: .init(output: "", exitCode: 1, timedOut: false))
        let afterSave = await fixture.waitForCall(path("after-save"))
        try check(model.refreshRevision == 1, "Commands may resume only after configuration refresh completes")
        await fixture.release(afterSave)
        await waitForIdle(model)
        let completed = await fixture.snapshot()
        try check(completed.maximumActiveCommands == 1 && !state.isBusy,
                  "Saving and queued management commands must share one serial busy lifetime")
    }

    @MainActor
    static func disabledSamplingNeverRunsShell() async throws {
        await fixture.reset(allowed: [selectionKey])
        let model = DeveloperWorkspaceModel()
        let task = Task { await model.refresh(forceEnvironment: true) }
        let selection = await fixture.waitForCall("/usr/bin/xcode-select", arguments: ["-p"])
        await fixture.release(selection, result: .init(output: "", exitCode: 1, timedOut: false))
        await task.value
        let completed = await fixture.snapshot()
        try check(completed.invocations.count == 1 && completed.invocations[0].path == "/usr/bin/xcode-select",
                  "Forced refresh with sampling off may only perform the explicit read-only Xcode selection check")
        try check(!model.terminal.isSampled && model.terminal.sampledAt == nil && !model.isRefreshing,
                  "Forced refresh must preserve the unsampled terminal fallback")
    }
}
