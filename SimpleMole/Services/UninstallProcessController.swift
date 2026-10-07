import Darwin
import Foundation

/// Only a confirmed uninstall may stop processes. Bind every signal to the
/// reviewed app identity, the process start identity and its executable path.
enum UninstallProcessController {
    struct Environment {
        var sample: () -> [ProcessSample] = { ProcessSampler.shared.sample() }
        var current: (ProcessIdentity) -> ProcessSample? = { ProcessSampler.shared.current(for: $0) }
        var signal: (Int32, Int32) -> Bool = { kill($0, $1) == 0 }
        var wait: () async -> Void = { try? await Task.sleep(nanoseconds: 100_000_000) }
        var appIsCurrent: (UninstallApp) -> Bool = {
            DeletionPlan.identity(at: $0.path) == $0.appIdentity
                && DeletionPlan.identity(at: $0.path + "/Contents/Info.plist") == $0.infoIdentity
        }
        var uid: UInt32 = getuid()
        var ownPID: Int32 = ProcessInfo.processInfo.processIdentifier
    }

    static func processes(for app: UninstallApp, samples: [ProcessSample]) -> [ProcessSample] {
        let root = URL(fileURLWithPath: app.path).resolvingSymlinksInPath().standardizedFileURL.path
        return samples.filter {
            guard !$0.path.isEmpty, !$0.isZombie,
                  DeletionPlan.isLexicallySafePath($0.path) else { return false }
            let executable = URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL.path
            return executable.hasPrefix(root + "/")
        }
    }

    /// Re-enumerate to catch helpers spawned during shutdown. A bounded failure
    /// stops the uninstall before any application or residue is moved.
    static func stop(_ app: UninstallApp, environment env: Environment = Environment()) async -> Bool {
        for _ in 0..<20 {
            guard !Task.isCancelled, env.appIsCurrent(app) else { return false }
            let samples = env.sample()
            let targets = processes(for: app, samples: samples)
            guard !targets.isEmpty else { return true }
            let byPID = Dictionary(samples.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
            // Never stop Nori or any ancestor/descendant of the current worker.
            func belongsToOwnTree(_ pid: Int32) -> Bool {
                var current = pid
                var seen = Set<Int32>()
                while current > 1, seen.insert(current).inserted {
                    if current == env.ownPID { return true }
                    guard let parent = byPID[current]?.ppid else { break }
                    current = parent
                }
                current = env.ownPID
                seen.removeAll()
                while current > 1, seen.insert(current).inserted {
                    if current == pid { return true }
                    guard let parent = byPID[current]?.ppid else { break }
                    current = parent
                }
                return false
            }
            for target in targets {
                guard target.pid > 1, target.uid == env.uid,
                      !belongsToOwnTree(target.pid),
                      !ProcessAggregator.isProtectedPath(target.path),
                      env.appIsCurrent(app) else { return false }
                guard let current = env.current(target.identity) else { continue }
                guard current.identity == target.identity, current.path == target.path,
                      processes(for: app, samples: [current]).count == 1 else { return false }
                if !env.signal(target.pid, SIGKILL), env.current(target.identity) != nil { return false }
            }
            await env.wait()
        }
        return env.appIsCurrent(app) && processes(for: app, samples: env.sample()).isEmpty
    }
}
