import Foundation

/// Explicit, system-wide filesystem cache reclaim. This does not promise that
/// application memory will shrink; callers should sample memory again afterward.
enum MemoryCacheReclaimService {
    enum Result: Equatable, Sendable {
        case success
        case cancelled
        case failed(String)
    }

    static func run() async -> Result {
        guard !Task.isCancelled else { return .cancelled }
        let result = await MoleEngine.shared.runPrivilegedBridge(
            "bin/app_memory_reclaim.sh", arguments: [], timeout: 120)
        // A timeout can interrupt osascript too; never present it as a dismissed
        // authorization prompt, even if its trailing output contains -128.
        if result.timedOut {
            return .failed(failureDetails("Memory cache reclaim timed out after 120 seconds.", result))
        }
        if Task.isCancelled { return .cancelled }
        if result.succeeded { return .success }

        let diagnostic = result.diagnosticOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        // osascript exits 1 for AppleScript errors. Match its complete diagnostic,
        // including the terminal error number, rather than a substring in purge
        // output or another failure (e.g. -1280). The message may be localized.
        if result.exitCode == 1,
           diagnostic.range(of: #"\A(?:\[stderr\] )?[0-9]+:[0-9]+: execution error: [^\r\n]* \(-128\)\z"#,
                            options: .regularExpression) != nil {
            return .cancelled
        }
        return .failed(failureDetails("Memory cache reclaim failed (exit \(result.exitCode)).", result))
    }

    private static func failureDetails(_ summary: String, _ result: RunResult) -> String {
        let diagnostic = result.diagnosticOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return diagnostic.isEmpty ? summary : summary + "\n" + diagnostic
    }
}
