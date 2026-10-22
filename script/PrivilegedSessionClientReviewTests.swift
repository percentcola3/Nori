import Foundation

// This engine only records bootstrap commands and returns a synthetic denial.
// No osascript, authorization, or privileged operation is executed.
struct RunResult: Sendable {
    var output: String
    var errorOutput: String = ""
    var exitCode: Int32
    var timedOut: Bool
    var succeeded: Bool { exitCode == 0 && !timedOut }
    var diagnosticOutput: String { errorOutput.isEmpty ? output : errorOutput }
}
actor BootstrapProbe {
    static let shared = BootstrapProbe()
    var commands: [String] = []
    func record(_ arguments: [String]) { commands.append(arguments.last ?? "") }
    func snapshot() -> [String] { commands }
}
final class MoleEngine: @unchecked Sendable {
    func cancelAll() {}
    func standardEnvironment(includeHomebrew: Bool) -> [String: String] { [:] }
    func run(executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval, cancellation: (() -> Void)?) async -> RunResult {
        await BootstrapProbe.shared.record(arguments)
        try? await Task.sleep(nanoseconds: 100_000_000)
        return RunResult(output: "Synthetic authorization denial", exitCode: 1, timedOut: false)
    }
}
@main struct PrivilegedSessionClientReviewTests {
    static func main() async {
        let client = PrivilegedSessionClient()
        let bundle = URL(fileURLWithPath: "/fixture/space and 'quote/Nori.app")
        let resources = bundle.appendingPathComponent("Contents/Resources")
        await withTaskGroup(of: RunResult.self) { group in
            for _ in 0..<20 {
                group.addTask { await client.authorize(bundle: bundle, resources: resources, hash: "abcd") }
            }
            for await result in group { precondition(result.exitCode == 1) }
        }
        let commands = await BootstrapProbe.shared.snapshot()
        precondition(commands.count == 1, "Concurrent authorization must launch once")
        let command = commands[0]
        precondition(command.contains("/bin/mkdir -m 700"), "Code staging must stay private")
        precondition(command.contains("/usr/sbin/chown -R -P root:wheel"), "Copied code ownership must become root")
        precondition(command.contains("/bin/chmod -R -P go-w"), "Copied code must not remain writable")
        precondition(command.contains("/usr/bin/codesign --verify --deep --strict"), "Staged bundle must be verified")
        precondition(command.contains("/usr/bin/env -i"), "Broker must not inherit caller environment")
        let owner = MoleEngine()
        let unavailable = await client.run(relativePath: "bin/app_memory_reclaim.sh", arguments: [], resources: resources, timeout: 1, owner: ObjectIdentifier(owner), generation: PrivilegedSessionClient.cancellationGeneration(for: ObjectIdentifier(owner)))
        precondition(unavailable.exitCode == 77, "Denied session must not execute operation")
        await client.revoke()
        PrivilegedSessionClient.shutdown()
        print("Privileged client: concurrency, denial, staging guards passed; no authorization or privileged execution")
    }
}
