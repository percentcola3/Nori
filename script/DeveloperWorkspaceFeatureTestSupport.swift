import Foundation

// A process-free engine: fixture commands are recorded, never launched.
struct RunResult: Sendable {
    let output: String
    var errorOutput = ""
    let exitCode: Int32
    let timedOut: Bool
    var succeeded: Bool { exitCode == 0 && !timedOut }
}

final class MoleEngine: @unchecked Sendable {
    static let shared = MoleEngine()
    struct Invocation: Sendable {
        let path: String
        let arguments: [String]
        let environment: [String: String]
    }
    private static let lock = NSLock()
    private static var responses: [String: RunResult] = [:]
    private static var recorded: [Invocation] = []
    private static var fixtureRoot = ""

    static var invocations: [Invocation] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
    static func reset(root: String, responses: [String: RunResult] = [:]) {
        lock.lock(); defer { lock.unlock() }
        fixtureRoot = root
        self.responses = responses
        recorded = []
    }
    static func key(_ name: String, _ arguments: [String]) -> String {
        ([name] + arguments).joined(separator: "\0")
    }
    func standardEnvironment(includeHomebrew: Bool = true) -> [String: String] { [:] }
    func run(executable: URL, arguments: [String], environment: [String: String] = [:],
             currentDirectory: URL? = nil, timeout: TimeInterval,
             onLine: ((String) -> Void)? = nil) async -> RunResult {
        Self.result(path: executable.path, arguments: arguments, environment: environment)
    }
    private static func result(path: String, arguments: [String], environment: [String: String]) -> RunResult {
        lock.lock(); defer { lock.unlock() }
        precondition(path.hasPrefix(fixtureRoot + "/"), "Fixture attempted a non-fixture executable: " + path)
        recorded.append(.init(path: path, arguments: arguments, environment: environment))
        guard let result = responses[key(URL(fileURLWithPath: path).lastPathComponent, arguments)] else {
            preconditionFailure("Unregistered fixture command: " + path + " " + arguments.joined(separator: " "))
        }
        return result
    }
}

final class L10n {
    static let shared = L10n()
    func t(_ key: String) -> String { key }
}
