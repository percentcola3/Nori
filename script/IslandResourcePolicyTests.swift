import Foundation

@main
struct IslandResourcePolicyTests {
    static func main() {
        typealias Facts = IslandResourcePolicy.ProcessFacts
        let uid: UInt32 = 501
        let mb: UInt64 = 1024 * 1024
        func process(_ pid: Int32, ppid: Int32 = 1, name: String = "node", path: String = "/opt/homebrew/bin/node",
                     cpu: Double = 0, previous: Double = 0, bytes: UInt64 = 400 * 1024 * 1024,
                     elapsed: TimeInterval = 600, uid owner: UInt32 = 501, zombie: Bool = false) -> Facts {
            Facts(pid: pid, ppid: ppid, uid: owner, name: name, path: path, cpu: cpu, previousCPU: previous,
                  residentBytes: bytes, elapsed: elapsed, isZombie: zombie)
        }
        func residuals(_ resource: IslandResource, _ processes: [Facts],
                       apps: Set<Int32> = [], managed: Set<Int32> = []) -> [IslandResourcePolicy.Residual] {
            IslandResourcePolicy.residuals(resource: resource, processes: processes, applicationPIDs: apps,
                managedPIDs: managed, ownPID: 999, uid: uid, ownBundlePath: "/Applications/Nori.app")
        }

        let orphan = residuals(.memory, [process(10), process(11, ppid: 10, bytes: 100 * mb)])
        precondition(orphan.count == 1 && orphan[0].pids == [11, 10] && orphan[0].residentBytes == 500 * mb,
                     "an idle orphan tree is ended children first and measured as a whole")
        precondition(residuals(.memory, [process(10, ppid: 77)]).isEmpty, "processes with a live parent are in use")
        precondition(residuals(.memory, [process(10)], apps: [10]).isEmpty, "running apps are never residual")
        precondition(residuals(.memory, [process(10), process(11, ppid: 10)], apps: [11]).isEmpty,
                     "a tree containing an app is still in use")
        precondition(residuals(.memory, [process(10)], managed: [10]).isEmpty, "launchd services are retained")
        precondition(residuals(.memory, [process(10, uid: 0)]).isEmpty, "other users are retained")
        precondition(residuals(.memory, [process(10, path: "/usr/libexec/foo")]).isEmpty, "system paths are retained")
        precondition(residuals(.memory, [process(10, path: "/Applications/X.app/Contents/XPCServices/Y.xpc/Contents/MacOS/Y")]).isEmpty,
                     "XPC services are retained")
        precondition(residuals(.memory, [process(10, path: "/Applications/Nori.app/Contents/MacOS/helper")]).isEmpty,
                     "own helpers are retained")
        precondition(residuals(.memory, [process(10, name: "tmux", path: "/opt/homebrew/bin/tmux")]).isEmpty,
                     "session keepers hold the user's work")
        let worker = process(10, path: "/Users/me/Library/Application Support/Cursor/agent-cli/bin/cursor-agent")
        precondition(IslandResourcePolicy.residuals(resource: .memory, processes: [worker], applicationPIDs: [],
            managedPIDs: [], ownPID: 999, uid: uid, ownBundlePath: "",
            inUseRoots: ["/Users/me/Library/Application Support/Cursor"]).isEmpty,
            "detached workers of a running app are in use")
        precondition(residuals(.memory, [worker]).count == 1, "the same worker is residual once its app has quit")
        precondition(residuals(.memory, [process(10, elapsed: 30)]).isEmpty, "fresh processes are retained")
        precondition(residuals(.memory, [process(10, zombie: true)]).isEmpty, "zombies cannot be signalled")
        precondition(residuals(.memory, [process(10, bytes: 200 * mb)]).isEmpty, "small processes are not worth ending")
        precondition(residuals(.memory, [process(10, cpu: 20, previous: 20)]).isEmpty,
                     "memory cleanup only ends idle processes")
        precondition(residuals(.cpu, [process(10, cpu: 80, previous: 60)]).count == 1, "sustained CPU orphans qualify")
        precondition(residuals(.cpu, [process(10, cpu: 80, previous: 0)]).isEmpty, "a CPU spike is insufficient")
        let ordered = residuals(.cpu, [process(10, cpu: 40, previous: 40), process(20, cpu: 90, previous: 90)])
        precondition(ordered.map(\.rootPID) == [20, 10], "highest usage first")
        precondition(IslandResourcePolicy.managedPIDs(fromLaunchctlList: "PID\tStatus\tLabel\n312\t0\tcom.a\n-\t0\tcom.b\n")
                     == [312], "launchctl list parsing keeps running service PIDs")
        precondition(IslandResourcePolicy.health(percent: 59.9) == .healthy)
        precondition(IslandResourcePolicy.health(percent: 60) == .elevated)
        precondition(IslandResourcePolicy.health(percent: 85) == .high)
        print("Island resource policy: residual-only selection, in-use/app/service/system safeguards and health thresholds passed")
    }
}
