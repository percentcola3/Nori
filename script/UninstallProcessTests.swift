import Darwin
import Foundation

@main
struct UninstallProcessTests {
    static func main() async throws {
        let app = UninstallApp(name: "Fixture", bundleID: "com.example.fixture", source: "Fixture",
                               path: "/Applications/Fixture.app", size: "1 KB", appIdentity: "1", infoIdentity: "2")
        func sample(_ pid: Int32, path: String, uid: UInt32 = 501, ppid: Int32 = 1,
                    start: UInt64 = 10) -> ProcessSample {
            .init(identity: .init(pid: pid, startTime: start, ppid: ppid, uid: uid),
                  name: URL(fileURLWithPath: path).lastPathComponent, path: path,
                  cpuPercent: 0, residentBytes: 0, isZombie: false, isExiting: false, elapsed: 0)
        }
        let main = sample(100, path: app.path + "/Contents/MacOS/Fixture")
        let orphan = sample(101, path: app.path + "/Contents/Frameworks/crashpad")
        let unrelated = sample(102, path: "/Applications/Other.app/Contents/MacOS/crashpad")
        let prefixCollision = sample(103, path: "/Applications/Fixture.app-copy/Contents/MacOS/Fixture")
        precondition(UninstallProcessController.processes(for: app,
            samples: [main, orphan, unrelated, prefixCollision]).map(\.pid) == [100, 101])
        final class Capture {
            var samples: [ProcessSample] = []
            var signals: [(Int32, Int32)] = []
            var waits = 0
        }
        let capture = Capture()
        var env = UninstallProcessController.Environment()
        env.uid = 501; env.ownPID = 999
        env.appIsCurrent = { _ in true }
        env.sample = { capture.samples }
        env.current = { identity in capture.samples.first { $0.identity == identity } }
        env.signal = { pid, signal in
            capture.signals.append((pid, signal))
            capture.samples.removeAll { $0.pid == pid }
            return true
        }
        env.wait = {
            capture.waits += 1
            if capture.waits == 1 { capture.samples.append(sample(104, path: orphan.path)) }
        }
        capture.samples = [main, orphan, unrelated]
        let stopped = await UninstallProcessController.stop(app, environment: env)
        precondition(stopped && capture.signals.map { $0.0 } == [100, 101, 104]
                     && capture.signals.allSatisfy { $0.1 == SIGKILL }
                     && capture.samples.map(\.pid) == [102], "Stop main, orphan and respawned helpers, preserving unrelated apps")
        capture.signals = []; capture.samples = [orphan]
        var changedApp = env
        changedApp.appIsCurrent = { _ in false }
        let changedResult = await UninstallProcessController.stop(app, environment: changedApp)
        precondition(!changedResult && capture.signals.isEmpty)
        var reusedPID = env
        reusedPID.current = { _ in sample(101, path: unrelated.path, start: 99) }
        let reusedResult = await UninstallProcessController.stop(app, environment: reusedPID)
        precondition(!reusedResult && capture.signals.isEmpty)
        var executedOtherBinary = env
        executedOtherBinary.current = { _ in sample(101, path: unrelated.path) }
        let executedResult = await UninstallProcessController.stop(app, environment: executedOtherBinary)
        precondition(!executedResult && capture.signals.isEmpty)
        for target in [sample(101, path: orphan.path, uid: 502),
                       sample(999, path: main.path), sample(101, path: orphan.path, ppid: 999)] {
            capture.samples = [target]
            let refusedTarget = await UninstallProcessController.stop(app, environment: env)
            precondition(!refusedTarget && capture.signals.isEmpty)
        }
        capture.samples = [orphan]
        var refused = env
        refused.signal = { _, _ in false }
        let refusedResult = await UninstallProcessController.stop(app, environment: refused)
        precondition(!refusedResult)
        var persistent = env
        persistent.signal = { _, _ in true }
        persistent.wait = {}
        let persistentResult = await UninstallProcessController.stop(app, environment: persistent)
        precondition(!persistentResult, "Persistent processes must fail within the retry bound")

        var selected: Set<String> = ["/fixture/settings"]
        var queue = UninstallQueue()
        queue.enqueue(app: app, plan: nil, dataPaths: selected)
        selected.removeAll()
        precondition(queue.startNext(blocked: false)?.dataPaths == ["/fixture/settings"], "Keep the data scope that the user confirmed")

        // Signal only an executable compiled inside our owned fixture, never an installed app.
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = fixture.appendingPathComponent("Fixture.app")
        let executable = root.appendingPathComponent("Contents/MacOS/helper")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try OwnedProcessFixture.makeSleeper(at: executable)
        try Data("fixture".utf8).write(to: root.appendingPathComponent("Contents/Info.plist"))
        let live = UninstallApp(name: "Fixture", bundleID: "com.example.fixture", source: "Fixture", path: root.path, size: "1 KB")
        let process = Process()
        process.executableURL = executable; process.arguments = ["20"]
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        var native = UninstallProcessController.Environment()
        native.ownPID = Int32.max // The fixture host stands in for a separate app.
        let liveStopped = await UninstallProcessController.stop(live, environment: native)
        process.waitUntilExit()
        precondition(liveStopped && process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL)
        print("Uninstall processes: exact bundle scope, main/orphan/respawn, PID reuse, executable changes, ownership, bounded failures, confirmed data and native SIGKILL passed")
    }
}
