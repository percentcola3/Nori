import Foundation

/// Exercise the real controller without generating internet traffic.
@MainActor
final class MoleEngine {
    struct Invocation {
        let executable: URL
        let arguments: [String]
        let timeout: TimeInterval
    }
    static var invocations: [Invocation] = []
    static var response = RunResult(output: "", exitCode: 0, timedOut: false)
    static var delay: UInt64 = 0

    func standardEnvironment(_ extra: [String: String] = [:], includeHomebrew: Bool = true) -> [String: String] { extra }
    func cancelAll() {}
    func run(executable: URL, arguments: [String], environment: [String: String],
             timeout: TimeInterval, captureLimit: Int) async -> RunResult {
        Self.invocations.append(Invocation(executable: executable, arguments: arguments, timeout: timeout))
        let response = Self.response
        if Self.delay > 0 { try? await Task.sleep(nanoseconds: Self.delay) }
        return response
    }
}

@main
@MainActor
struct IslandNetworkProbeCommandTests {
    static func finish(_ controller: IslandNetworkProbe) async {
        let deadline = Date().addingTimeInterval(1)
        while controller.running != nil && Date() < deadline { await Task.yield() }
        precondition(controller.running == nil, "The controller must finish without a manual stop")
    }

    static func main() async {
        let output = #"{"dl_throughput":200000000,"ul_throughput":40000000,"base_rtt":12.5}"#
        MoleEngine.response = RunResult(output: output, exitCode: 0, timedOut: false)
        let controller = IslandNetworkProbe()
        controller.start(.bandwidth)
        await finish(controller)
        guard let command = MoleEngine.invocations.last,
              command.executable.path == "/usr/bin/networkQuality",
              command.arguments.contains("-c"),
              let limitIndex = command.arguments.firstIndex(of: "-M"),
              limitIndex + 1 < command.arguments.count,
              let limit = Double(command.arguments[limitIndex + 1]), (10...20).contains(limit),
              command.timeout > limit, command.timeout <= 25 else {
            print("FAIL: speed testing must request a short automatic finish with a bounded timeout")
            exit(1)
        }
        precondition(controller.bandwidthResult?.downloadMbps == 200 && controller.errorKey == nil && !controller.stopped)

        for (response, expectedError) in [
            (RunResult(output: output, exitCode: 0, timedOut: true), "island.network.timeout"),
            (RunResult(output: output, exitCode: 0, timedOut: false, outputTruncated: true), "island.network.failed"),
            (RunResult(output: output, exitCode: 1, timedOut: false), "island.network.failed"),
            (RunResult(output: "{}", exitCode: 0, timedOut: false), "island.network.failed"),
        ] {
            MoleEngine.response = response
            controller.start(.bandwidth)
            precondition(controller.bandwidthResult == nil, "A new test must clear the previous conclusion")
            await finish(controller)
            precondition(controller.bandwidthResult == nil && controller.errorKey == expectedError)
        }

        MoleEngine.response = RunResult(output: output, exitCode: 0, timedOut: false)
        MoleEngine.delay = 200_000_000
        controller.start(.bandwidth)
        await Task.yield()
        controller.cancel()
        try? await Task.sleep(nanoseconds: 250_000_000)
        precondition(controller.running == nil && controller.stopped && controller.bandwidthResult == nil)
        print("PASS: automatic bandwidth completion, bounded command, result/error handling and cancellation")
    }
}
