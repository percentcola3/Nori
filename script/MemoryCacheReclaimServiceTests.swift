import Foundation

// Stub only the engine: use the production RunResult declaration extracted by
// the runner, and never launch osascript or request administrator authorization.
final class MoleEngine {
    static let shared = MoleEngine()
    var result = RunResult(output: "", exitCode: 0, timedOut: false)
    var calls = 0

    func runPrivilegedBridge(_ path: String, arguments: [String], timeout: TimeInterval) async -> RunResult {
        precondition(path == "bin/app_memory_reclaim.sh")
        precondition(arguments.isEmpty)
        precondition(timeout == 120)
        calls += 1
        return result
    }
}

@main
struct MemoryCacheReclaimServiceTests {
    static func main() async {
        let engine = MoleEngine.shared
        func check(_ result: RunResult, _ expected: MemoryCacheReclaimService.Result) async {
            engine.result = result
            let actual = await MemoryCacheReclaimService.run()
            precondition(actual == expected, "Expected \(expected), got \(actual)")
        }
        await check(.init(output: "", exitCode: 0, timedOut: false), .success)
        let cancellation = "0:42: execution error: User canceled. (-128)"
        await check(.init(output: "", errorOutput: cancellation, exitCode: 1, timedOut: false), .cancelled)
        await check(.init(output: "[stderr] " + cancellation + "\n", exitCode: 1, timedOut: false), .cancelled)
        await check(.init(output: "", errorOutput: "0:42: execution error: 用户已取消。 (-128)", exitCode: 1, timedOut: false), .cancelled)
        for diagnostic in ["purge failed: -128", "0:42: execution error: Failure (-1280)",
                           cancellation + "\nother failure", "prefix " + cancellation] {
            await check(.init(output: diagnostic, exitCode: 1, timedOut: false),
                        .failed("Memory cache reclaim failed (exit 1).\n" + diagnostic))
        }
        await check(.init(output: "", errorOutput: cancellation, exitCode: 77, timedOut: false),
                    .failed("Memory cache reclaim failed (exit 77).\n" + cancellation))
        await check(.init(output: "", errorOutput: cancellation, exitCode: 1, timedOut: true),
                    .failed("Memory cache reclaim timed out after 120 seconds.\n" + cancellation))
        await check(.init(output: "", exitCode: 0, timedOut: true),
                    .failed("Memory cache reclaim timed out after 120 seconds."))
        await check(.init(output: "", errorOutput: "purge failed", exitCode: 73, timedOut: false),
                    .failed("Memory cache reclaim failed (exit 73).\npurge failed"))
        await check(.init(output: "", exitCode: 78, timedOut: false),
                    .failed("Memory cache reclaim failed (exit 78)."))

        let previousCalls = engine.calls
        let cancelledTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await MemoryCacheReclaimService.run()
        }
        let result = await cancelledTask.value
        precondition(result == .cancelled)
        precondition(engine.calls == previousCalls)
        print("PASS: service privileged invocation, success, authorization cancellation, failure details, timeout and task cancellation")
    }
}
