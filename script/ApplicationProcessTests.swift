import AppKit
import Darwin
import Foundation

@main
struct ApplicationProcessTests {
    static let root = "/Applications/ProcessFixture.app"
    static func sample(_ pid: Int32, _ path: String, ppid: Int32 = 1, start: UInt64 = 10,
                       uid: UInt32 = 501) -> ProcessSample {
        .init(identity: .init(pid: pid, startTime: start, ppid: ppid, uid: uid),
              name: URL(fileURLWithPath: path).lastPathComponent, path: path,
              cpuPercent: 1, residentBytes: 100, isZombie: false, isExiting: false, elapsed: 1)
    }
    static var main: ProcessSample { sample(100, root + "/Contents/MacOS/App") }
    static var helper: ProcessSample { sample(101, root + "/Contents/Resources/app-server") }
    static var external: ProcessSample { sample(102, "/opt/homebrew/bin/node", ppid: 100) }
    static var other: ProcessSample { sample(200, "/Applications/Other.app/Contents/MacOS/App") }
    static let scope = ApplicationProcessScope(root: root)

    static func groups(_ samples: [ProcessSample], live: Bool, previous: [ProcessGroup] = []) -> [ProcessGroup] {
        ProcessAggregator.groups(samples: samples,
            applications: live ? [(100, "ProcessFixture", "native")] : [], ownPID: 999,
            previous: previous, detail: { "PID \($0)" }, childDetail: { "PID \($0.pid)" })
    }

    static func testOwnership() {
        let nested = sample(103, root + "/Contents/Frameworks/Renderer.app/Contents/MacOS/Renderer")
        let orphan = groups([helper, nested], live: false)
        precondition(orphan.count == 1 && orphan[0].isBackgroundOnly && orphan[0].members.count == 2)
        precondition(orphan[0].bundlePath == root && orphan[0].totalBytes == 200 && orphan[0].children.count == 2)
        let helperFirst = ProcessAggregator.groups(samples: [main, nested],
            applications: [(103, "Renderer", "renderer"), (100, "App", "native")], ownPID: 999,
            detail: { "PID \($0)" }, childDetail: { "PID \($0.pid)" })
        precondition(helperFirst.count == 1 && helperFirst[0].app.pid == 100,
                     "A nested NSRunningApplication must never replace the outer main app")
        let nestedOnly = ProcessAggregator.groups(samples: [nested], applications: [(103, "Renderer", "renderer")],
            ownPID: 999, detail: { "PID \($0)" }, childDetail: { "PID \($0.pid)" })
        precondition(nestedOnly[0].isBackgroundOnly)
        let running = groups([main, helper, external, other], live: true)
        let selected = running.first { $0.bundlePath == root }!
        precondition(selected.members.map(\.pid) == [100, 101, 102] && !selected.isBackgroundOnly)
        let reparented = sample(102, external.path)
        let after = groups([helper, reparented, other], live: false, previous: running)
        precondition(after.first { $0.bundlePath == root }!.members.map(\.pid) == [101, 102])
        // Even if only an external descendant remains, retain its app group.
        let externalOnly = groups([reparented], live: false, previous: running)
        precondition(externalOnly.count == 1 && externalOnly[0].bundlePath == root)
        let reused = sample(102, external.path, start: 99)
        precondition(scope.processes(in: [reused], remembering: [external]).isEmpty)
        let changed = sample(102, "/opt/unrelated/task")
        precondition(scope.processes(in: [changed], remembering: [external]).isEmpty)
        precondition(!scope.contains(root + "-copy/Contents/MacOS/App"))
        precondition(ApplicationProcessScope.bundlePath(of: nested.path) == root)
        // Independent apps are separate even when launched by the selected app.
        let independent = sample(201, other.path, ppid: 100)
        let bounded = ApplicationProcessScope(root: root, independentRoots: ["/Applications/Other.app"])
        precondition(bounded.processes(in: [main, independent]).map(\.pid) == [100])
        let externalApp = sample(202, "/Users/test/Helper.app/Contents/MacOS/Helper", ppid: 100)
        let externalGroups = groups([main, externalApp], live: true)
        precondition(externalGroups.count == 1 && externalGroups[0].members.count == 2,
                     "Proven helper apps must not appear in duplicate groups")
    }

    final class Capture {
        var samples: [ProcessSample] = []
        var signals: [(Int32, Int32)] = []
        var waits = 0
        var jobs = 0
    }
    static func environment(_ capture: Capture) -> ApplicationProcessController.Environment {
        var env = ApplicationProcessController.Environment()
        env.uid = 501; env.ownPID = 999; env.independentRoots = []
        env.snapshot = { .init(processes: capture.samples, isComplete: true) }
        env.current = { id in capture.samples.first { $0.identity.isSameProcess(as: id) } }
        env.signal = { pid, signal in
            capture.signals.append((pid, signal))
            capture.samples.removeAll { $0.pid == pid }
            return true
        }
        env.wait = { capture.waits += 1 }
        env.stopJobs = { _ in capture.jobs += 1; return [] }
        return env
    }
    static func testShutdown() async {
        let capture = Capture()
        capture.samples = [main, helper, external, other]
        var env = environment(capture)
        env.signal = { pid, signal in
            capture.signals.append((pid, signal))
            capture.samples.removeAll { $0.pid == pid }
            if pid == main.pid {
                capture.samples = capture.samples.map { $0.pid == external.pid ? sample(102, external.path) : $0 }
            }
            return true
        }
        env.wait = {
            capture.waits += 1
            if capture.waits == 4 { capture.samples.append(sample(104, helper.path, start: 20)) }
        }
        let result = await ApplicationProcessController.stop(scope, remembering: [main, helper, external], environment: env)
        precondition(result.completed && Set(capture.signals.map { $0.0 }) == [100, 101, 102, 104])
        precondition(capture.samples.map(\.pid) == [200] && capture.waits >= 14 && capture.jobs > 0)
        precondition(capture.signals.allSatisfy { $0.1 == SIGTERM })

        capture.samples = [helper]; capture.signals = []; capture.waits = 0
        env = environment(capture)
        env.signal = { pid, signal in
            capture.signals.append((pid, signal))
            if signal == SIGKILL { capture.samples.removeAll { $0.pid == pid } }
            return true
        }
        let escalated = await ApplicationProcessController.stop(scope, remembering: [], environment: env)
        precondition(escalated.completed && capture.signals.contains { $0.1 == SIGKILL })
        capture.samples = [helper]; capture.signals = []
        env.signal = { pid, signal in capture.signals.append((pid, signal)); return true }
        let persistent = await ApplicationProcessController.stop(scope, remembering: [], environment: env)
        precondition(!persistent.completed && persistent.remaining.map(\.pid) == [101])

        // Refuse before any signal or launch job operation when scope is unsafe.
        for target in [sample(101, helper.path, uid: 502), sample(999, helper.path),
                       sample(101, helper.path, ppid: 999), sample(101, helper.path, ppid: 998)] {
            capture.samples = [target]
            if target.ppid == 998 { capture.samples.append(sample(999, "/opt/Nori", ppid: 101)) }
            capture.signals = []; capture.jobs = 0
            let refused = await ApplicationProcessController.stop(scope, remembering: [], environment: environment(capture))
            precondition(!refused.completed && capture.signals.isEmpty && capture.jobs == 0)
        }
        capture.samples = [helper]; capture.signals = []
        env = environment(capture)
        env.snapshot = { .init(processes: [], isComplete: false) }
        let unknown = await ApplicationProcessController.stop(scope, remembering: [], environment: env)
        precondition(!unknown.completed && capture.signals.isEmpty)
        env = environment(capture)
        env.current = { _ in sample(101, helper.path, start: 99) }
        let reused = await ApplicationProcessController.stop(scope, remembering: [], environment: env)
        precondition(!reused.completed && capture.signals.isEmpty)
        env.current = { _ in sample(101, other.path) }
        let execChanged = await ApplicationProcessController.stop(scope, remembering: [], environment: env)
        precondition(!execChanged.completed && capture.signals.isEmpty)
        env = environment(capture)
        env.current = { id in
            capture.samples.removeAll { $0.pid == id.pid }
            return .init(identity: id, name: "exiting", path: "", cpuPercent: 0, residentBytes: 0,
                         isZombie: true, isExiting: false, elapsed: 0)
        }
        let naturallyExited = await ApplicationProcessController.stop(scope, remembering: [], environment: env)
        precondition(naturallyExited.completed && capture.signals.isEmpty,
                     "A child exiting with its parent must be verified as gone, not reported as an executable change")
        capture.samples = [helper]
        env = environment(capture)
        env.stopJobs = { _ in ["system/com.example.fixture"] }
        let jobFailed = await ApplicationProcessController.stop(scope, remembering: [], environment: env)
        precondition(!jobFailed.completed && jobFailed.jobs == ["system/com.example.fixture"])
    }

    static func testLaunchJobOwnership() {
        let program = root + "/Contents/MacOS/App"
        let valid = "gui/501/example = {\n\tprogram = \(program)\n\tpid = 100\n}"
        precondition(ApplicationLaunchJobs.ownedJob(valid, service: "gui/501/example", scope: scope)?.program == program)
        let nested = "gui/501/example = {\n\tprogram = /usr/bin/unrelated\n\tenvironment = {\n\t\tprogram = \(program)\n\t}\n}"
        precondition(ApplicationLaunchJobs.ownedJob(nested, service: "gui/501/example", scope: scope) == nil)
        precondition(ApplicationLaunchJobs.ownedJob(valid.replacingOccurrences(of: root, with: root + "-copy"),
                                                  service: "gui/501/example", scope: scope) == nil)
    }

    static func testNativeReparenting(_ fixture: URL) async throws {
        let app = fixture.appendingPathComponent("Orphan.app")
        let parentURL = app.appendingPathComponent("Contents/MacOS/parent")
        let workerURL = fixture.appendingPathComponent("external-worker")
        try FileManager.default.createDirectory(at: parentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try OwnedProcessFixture.makeSleeper(at: workerURL)
        let source = parentURL.appendingPathExtension("c")
        try """
        #include <unistd.h>
        #include <stdlib.h>
        int main(int argc, char **argv) {
            if (fork() == 0) { execl(argv[1], argv[1], "30", (char *)0); _exit(1); }
            sleep(2); return 0;
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = [source.path, "-o", parentURL.path]
        try compiler.run(); compiler.waitUntilExit()
        precondition(compiler.terminationStatus == 0)
        let parent = Process()
        parent.executableURL = parentURL; parent.arguments = [workerURL.path]
        try parent.run()
        defer { if parent.isRunning { parent.terminate(); parent.waitUntilExit() } }
        let sampler = ProcessSampler()
        var child: ProcessSample?
        for _ in 0..<100 {
            child = sampler.sample().first { $0.ppid == parent.processIdentifier && $0.path == workerURL.path }
            if child != nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let child else { fatalError("Owned worker was not observed before reparenting") }
        defer {
            if sampler.current(for: child.identity) != nil { kill(child.pid, SIGKILL) }
        }
        parent.waitUntilExit()
        let fresh = sampler.current(for: child.identity)
        precondition(fresh != nil && fresh!.ppid != child.ppid && fresh!.identity.isSameProcess(as: child.identity),
                     "Reparenting must not masquerade as process disappearance")
        var env = ApplicationProcessController.Environment()
        env.ownPID = Int32.max // Fixture represents a separate app, not the test host's child.
        env.stopJobs = { _ in [] }
        let result = await ApplicationProcessController.stop(.init(root: app.path), remembering: [child], environment: env)
        precondition(result.completed && sampler.current(for: child.identity).map { $0.isZombie || $0.isExiting } != false)
    }

    static func testNativeLaunchJob(_ fixture: URL) async throws {
        let app = fixture.appendingPathComponent("Launch Job.app")
        let executable = app.appendingPathComponent("Contents/MacOS/worker")
        let plistURL = fixture.appendingPathComponent("transient-service.plist")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try OwnedProcessFixture.makeSleeper(at: executable)
        let label = "com.nori.owned-process-fixture." + UUID().uuidString.lowercased()
        let service = "gui/\(getuid())/" + label
        let plist: [String: Any] = ["Label": label, "ProgramArguments": [executable.path, "30"],
                                    "RunAtLoad": true, "KeepAlive": true]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)
        func launchctl(_ arguments: [String]) -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl"); process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            do { try process.run(); process.waitUntilExit(); return process.terminationStatus }
            catch { return -1 }
        }
        guard launchctl(["bootstrap", "gui/\(getuid())", plistURL.path]) == 0 else {
            print("Native launchd integration skipped: no usable GUI bootstrap domain")
            return
        }
        defer { _ = launchctl(["bootout", service]) }
        for _ in 0..<100 {
            if ProcessSampler.shared.sample().contains(where: { $0.path == executable.path }) { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        var env = ApplicationProcessController.Environment()
        env.ownPID = Int32.max
        let result = await ApplicationProcessController.stop(.init(root: app.path), remembering: [], environment: env)
        precondition(result.completed && launchctl(["print", service]) == 113,
                     "Owned KeepAlive service must be booted out and verified, not merely killed")
        precondition(ProcessSampler.shared.sample().allSatisfy { $0.path != executable.path || $0.isZombie })
        print("Native launchd integration: owned KeepAlive job bootout verified")
    }

    static func main() async throws {
        testOwnership()
        await testShutdown()
        testLaunchJobOwnership()
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        try await testNativeReparenting(fixture)
        try await testNativeLaunchJob(fixture)
        print("Application processes: background-only apps, bundle/orphan ownership, remembered descendants, independent apps, reparenting, respawn, escalation, quiet verification, launch jobs and mutation safety passed")
    }
}
