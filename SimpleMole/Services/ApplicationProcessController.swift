import AppKit
import Darwin
import Foundation

/// One app-level shutdown path for Quit, Force Quit and uninstall. Every pass
/// rediscovers helpers, retains proven orphans and revalidates before signalling.
enum ApplicationProcessController {
    struct Outcome: Sendable {
        var completed: Bool
        var remaining: [ProcessSample] = []
        var reasonKey: String? = nil
        var jobs: [String] = []
    }

    struct Environment {
        var snapshot: () -> ProcessSampler.Snapshot = { ProcessSampler.shared.snapshot() }
        var current: (ProcessIdentity) -> ProcessSample? = { ProcessSampler.shared.current(for: $0) }
        var signal: (Int32, Int32) -> Bool = { kill($0, $1) == 0 }
        var wait: () async -> Void = { try? await Task.sleep(nanoseconds: 100_000_000) }
        var stopJobs: (ApplicationProcessScope) -> [String] = ApplicationLaunchJobs.stop
        var independentRoots: Set<String>? = nil
        var uid = getuid()
        var ownPID = ProcessInfo.processInfo.processIdentifier
    }

    static func stop(_ scope: ApplicationProcessScope, remembering initial: [ProcessSample],
                     force: Bool = false, environment env: Environment = Environment(),
                     stillCurrent: () -> Bool = { true }) async -> Outcome {
        guard scope.root.hasSuffix(".app"), !ProcessAggregator.isProtectedPath(scope.root) else {
            return .init(completed: false, reasonKey: "proc.refusal.protected")
        }
        var scope = scope
        let independentRoots: Set<String>
        if let supplied = env.independentRoots { independentRoots = supplied }
        else {
            independentRoots = await MainActor.run {
                Set(NSWorkspace.shared.runningApplications.compactMap { app in
                    guard !app.isTerminated, app.activationPolicy != .prohibited,
                          let path = app.executableURL?.path else { return nil }
                    return ApplicationProcessScope.bundlePath(of: path)
                })
            }
        }
        scope.independentRoots.formUnion(independentRoots.subtracting([scope.root]))
        var known = initial
        var quiet = 0
        var remaining: [ProcessSample] = []
        var failedJobs: [String] = []
        for pass in 0..<60 {
            guard !Task.isCancelled, stillCurrent() else {
                return .init(completed: false, remaining: remaining, reasonKey: "proc.refusal.identity")
            }
            let snapshot = env.snapshot()
            guard snapshot.isComplete else {
                return .init(completed: false, reasonKey: "proc.exit.unknown")
            }
            remaining = scope.processes(in: snapshot.processes, remembering: known)
            // Validate the entire set before stopping any jobs or processes.
            guard remaining.allSatisfy({ $0.pid > 1 && $0.uid == env.uid && !$0.path.isEmpty &&
                !ApplicationProcessScope.belongsToOwnTree($0.pid, ownPID: env.ownPID, samples: snapshot.processes) }) else {
                return .init(completed: false, remaining: remaining, reasonKey: "proc.exit.protected")
            }
            known = remaining
            // Boot out only jobs whose program is physically in the selected
            // bundle. No persistent disable, plist deletion or name matching.
            if pass == 0 || pass == 30 {
                failedJobs = env.stopJobs(scope)
            }
            if remaining.isEmpty {
                quiet += 1
                // A full second of quiet samples catches delayed helper respawn.
                if quiet >= 10 {
                    return .init(completed: failedJobs.isEmpty,
                                 reasonKey: failedJobs.isEmpty ? nil : "proc.exit.jobs", jobs: failedJobs)
                }
            } else {
                quiet = 0
                for target in remaining {
                    guard stillCurrent(), !Task.isCancelled else {
                        return .init(completed: false, remaining: remaining, reasonKey: "proc.refusal.identity")
                    }
                    guard let current = env.current(target.identity) else { continue }
                    if current.isZombie || current.isExiting { continue }
                    guard current.identity.isSameProcess(as: target.identity), current.path == target.path else {
                        return .init(completed: false, remaining: remaining, reasonKey: "proc.refusal.identity")
                    }
                    // A selected, observed descendant may be a system-provided
                    // interpreter; ancestry authorizes that instance only.
                    let signal: Int32 = force || pass >= 30 ? SIGKILL : SIGTERM
                    if !env.signal(current.pid, signal), env.current(current.identity) != nil {
                        return .init(completed: false, remaining: remaining, reasonKey: "proc.exit.incomplete")
                    }
                }
            }
            await env.wait()
        }
        return .init(completed: false, remaining: remaining, reasonKey: "proc.exit.incomplete", jobs: failedJobs)
    }
}

/// Stop loaded launchd jobs only after checking the job's actual program from
/// `launchctl print`, not a potentially changed plist or a vendor-like label.
/// A failed bootout is returned to the user, never reported as a successful quit.
enum ApplicationLaunchJobs {
    struct Job: Equatable {
        let service: String
        let program: String
    }

    static func ownedJob(_ output: String, service: String, scope: ApplicationProcessScope) -> Job? {
        // launchctl print indents a service's own fields by one tab. Nested
        // dictionaries (environment, endpoints) must not authorize an action.
        let lines = output.components(separatedBy: "\n")
        guard let programLine = lines.first(where: { $0.hasPrefix("\tprogram = ") }) else { return nil }
        let program = String(programLine.dropFirst("\tprogram = ".count))
        guard scope.contains(program) else { return nil }
        return .init(service: service, program: program)
    }

    static func stop(_ scope: ApplicationProcessScope) -> [String] {
        let manager = FileManager.default
        let directories: [(String, String)] = [
            (manager.homeDirectoryForCurrentUser.path + "/Library/LaunchAgents", "gui/\(getuid())"),
            ("/Library/LaunchAgents", "gui/\(getuid())"),
            ("/Library/LaunchDaemons", "system"),
            (scope.root + "/Contents/Library/LaunchAgents", "gui/\(getuid())"),
            (scope.root + "/Contents/Library/LaunchDaemons", "system")
        ]
        var failed: [String] = []
        var candidates = Set<String>()
        // Transient jobs and SMAppService registrations need not have a plist
        // in ~/Library. Index the live current-user jobs by owned PID, then
        // still require the loaded program path before authorizing bootout.
        let ownedPIDs = Set(ProcessSampler.shared.sample().filter { scope.contains($0.path) }.map(\.pid))
        let listed = command(["list"])
        if listed.status == 0 {
            for line in listed.output.components(separatedBy: "\n") {
                let columns = line.split(whereSeparator: \.isWhitespace)
                guard columns.count == 3, let pid = Int32(columns[0]), ownedPIDs.contains(pid) else { continue }
                let label = String(columns[2])
                if !label.contains("/") { candidates.insert("gui/\(getuid())/" + label) }
            }
        } else { failed.append("launchctl list") }
        for (directory, domain) in directories {
            guard let files = try? manager.contentsOfDirectory(atPath: directory) else { continue }
            for name in files where name.hasSuffix(".plist") {
                let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url),
                      let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                      let label = plist["Label"] as? String, !label.isEmpty,
                      !label.contains("/"), !label.contains("\n") else { continue }
                let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first ?? ""
                if scope.contains(program) { candidates.insert(domain + "/" + label) }
            }
        }
        for service in candidates.sorted() {
            // A plist or PID is only a candidate index. Authorize against the
            // currently loaded program immediately before bootout.
            let loaded = command(["print", service])
            guard loaded.status == 0 else {
                if loaded.status != 113 { failed.append(service) }
                continue
            }
            guard let job = ownedJob(loaded.output, service: service, scope: scope) else { continue }
            let fresh = command(["print", service])
            guard fresh.status == 0,
                  ownedJob(fresh.output, service: service, scope: scope) == job else {
                failed.append(service); continue
            }
            let result = command(["bootout", service])
            if result.status != 0, command(["print", service]).status != 113 { failed.append(service) }
        }
        return failed
    }

    private static func command(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                if process.isRunning { process.terminate() }
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch { return (-1, "") }
    }
}
