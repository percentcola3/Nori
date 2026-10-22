import Foundation

extension AppState {
    enum AdministratorSessionState: String, Equatable {
        case idle, authorizing, ready, cancelled, failed

        var statusKey: String { "settings.administratorSession.\(rawValue)" }
    }

    /// Manual authorization from Settings. Privileged operations otherwise
    /// authorize on first use (MoleEngine.runPrivilegedBridge); the session is
    /// scoped to this process and reused, so the system prompt appears once per
    /// run. Destructive operations retain their own confirmation.
    func requestAdministratorSession() {
        guard !administratorSessionInFlight,
              administratorSession != .authorizing,
              administratorSession != .ready else { return }
        administratorSessionInFlight = true
        administratorSession = .authorizing
        administratorSessionDetail = nil
        Task { [weak self] in
            let result = await MoleEngine.shared.authorizeAdministratorSession()
            guard let self else { return }
            self.administratorSessionInFlight = false
            self.administratorSession = Self.administratorSessionState(for: result)
            self.administratorSessionDetail = self.administratorSession == .failed
                ? result.diagnosticOutput.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }
    }

    static func administratorSessionState(for result: RunResult) -> AdministratorSessionState {
        // A killed authorization prompt can also print -128 on timeout.
        if result.timedOut { return .failed }
        if result.succeeded { return .ready }
        let diagnostic = result.diagnosticOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        // Match the entire localized osascript error, as MemoryCacheReclaimService
        // does; arbitrary command output containing -128 is not cancellation.
        if result.exitCode == 1,
           diagnostic.range(of: #"\A(?:\[stderr\] )?[0-9]+:[0-9]+: execution error: [^\r\n]* \(-128\)\z"#,
                            options: .regularExpression) != nil {
            return .cancelled
        }
        return .failed
    }

    func updateAdministratorSession(_ engineState: String) {
        switch engineState {
        case "authorizing": administratorSession = .authorizing
        case "ready": administratorSession = .ready
        case "ended": administratorSession = .idle
        case "cancelled": administratorSession = .cancelled
        case "failed": administratorSession = .failed
        default: return
        }
        administratorSessionDetail = nil
    }
}
