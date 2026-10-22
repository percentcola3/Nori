import Foundation

// Compile the actual AppState extension against a controlled engine. No system
// authorization, privileged process, application defaults, or user files are used.
@MainActor final class AppState {
    var administratorSession: AdministratorSessionState = .idle
    var administratorSessionDetail: String?
    var administratorSessionInFlight = false
}

@MainActor final class MoleEngine {
    static let shared = MoleEngine()
    var calls = 0
    var pending: CheckedContinuation<RunResult, Never>?

    func authorizeAdministratorSession() async -> RunResult {
        calls += 1
        return await withCheckedContinuation { pending = $0 }
    }

    func finish(_ result: RunResult) {
        precondition(pending != nil, "Expected an authorization request")
        pending?.resume(returning: result)
        pending = nil
    }
}

@main struct AdministratorSessionStateTests {
    @MainActor static func waitFor(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            precondition(Date() < deadline, "Timed out waiting for fixture state")
            await Task.yield()
        }
    }

    @MainActor static func main() async {
        func result(_ text: String = "", _ code: Int32 = 1, _ timeout: Bool = false) -> RunResult {
            RunResult(output: "", errorOutput: text, exitCode: code, timedOut: timeout)
        }
        let cancel = "0:1: execution error: 用户已取消。 (-128)"
        assert(AppState.administratorSessionState(for: result("", 0)) == .ready)
        for text in [cancel, "[stderr] " + cancel, "\n" + cancel + "\n"] {
            assert(AppState.administratorSessionState(for: result(text)) == .cancelled)
        }
        for text in [cancel + "\nother failure", cancel.replacingOccurrences(of: "-128", with: "-1280"), "arbitrary (-128)"] {
            assert(AppState.administratorSessionState(for: result(text)) == .failed)
        }
        assert(AppState.administratorSessionState(for: result(cancel, 1, true)) == .failed)
        assert(AppState.administratorSessionState(for: result(cancel, 2)) == .failed)
        let state = AppState()
        state.requestAdministratorSession()
        state.requestAdministratorSession()
        await waitFor { MoleEngine.shared.pending != nil }
        assert(MoleEngine.shared.calls == 1 && state.administratorSession == .authorizing)
        MoleEngine.shared.finish(result(cancel))
        await waitFor { !state.administratorSessionInFlight }
        assert(state.administratorSession == .cancelled && state.administratorSessionDetail == nil)

        state.requestAdministratorSession()
        await waitFor { MoleEngine.shared.pending != nil }
        MoleEngine.shared.finish(result("fixture authorization failure", 73))
        await waitFor { !state.administratorSessionInFlight }
        assert(state.administratorSession == .failed)
        assert(state.administratorSessionDetail == "fixture authorization failure")

        state.requestAdministratorSession()
        await waitFor { MoleEngine.shared.pending != nil }
        assert(state.administratorSessionDetail == nil)
        MoleEngine.shared.finish(result("", 0))
        await waitFor { !state.administratorSessionInFlight }
        assert(state.administratorSession == .ready)
        state.requestAdministratorSession()
        assert(MoleEngine.shared.calls == 3)

        state.updateAdministratorSession("ended")
        assert(state.administratorSession == .idle)
        state.updateAdministratorSession("authorizing")
        assert(state.administratorSession == .authorizing)
        state.requestAdministratorSession()
        assert(MoleEngine.shared.calls == 3)
        state.updateAdministratorSession("cancelled")
        assert(state.administratorSession == .cancelled)
        state.updateAdministratorSession("failed")
        assert(state.administratorSession == .failed)
        state.updateAdministratorSession("ready")
        assert(state.administratorSession == .ready)
        state.updateAdministratorSession("unrecognized")
        assert(state.administratorSession == .ready)
        print("PASS: classification, complete cancellation diagnostics, timeout priority, duplicate requests, retry, failure details, ready guard, engine notifications")
    }
}
