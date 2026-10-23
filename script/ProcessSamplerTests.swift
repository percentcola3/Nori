import AppKit
import Foundation

@main
struct ProcessSamplerTests {
    static func main() async {
        testLiveSamplingFindsOurselves()
        testAggregationFollowsParentChain()
        testSortFilter()
        testHighUsageTracker()
        testHistoryCapacity()
        testCompletePIDValidation()
        await testTerminatorRefusesOwnTreeAndSystem()
        print("process sampler tests ok")
    }

    static func makeSample(pid: Int32, ppid: Int32, uid: UInt32 = getuid(), name: String,
                           path: String = "/Applications/Test.app/Contents/MacOS/Test",
                           cpu: Double = 0, bytes: UInt64 = 0) -> ProcessSample {
        ProcessSample(identity: ProcessIdentity(pid: pid, startTime: 1, ppid: ppid, uid: uid),
                      name: name, path: path, cpuPercent: cpu, residentBytes: bytes,
                      isZombie: false, isExiting: false, elapsed: 10)
    }

    static func testLiveSamplingFindsOurselves() {
        let sampler = ProcessSampler()
        let first = sampler.sample()
        precondition(!first.isEmpty, "libproc returned no processes")
        let own = ProcessInfo.processInfo.processIdentifier
        guard let me = first.first(where: { $0.pid == own }) else { fatalError("own process missing from sample") }
        precondition(me.uid == getuid(), "own uid mismatch")
        precondition(me.ppid == getppid(), "own ppid mismatch")
        precondition(!me.path.isEmpty, "own path must resolve")
        precondition(me.residentBytes > 0, "resident size must be reported")
        precondition(me.cpuPercent == 0, "first sample has no CPU baseline")

        // Burn a little CPU, then re-sample: our CPU% must now be measurable.
        let until = Date().addingTimeInterval(0.25)
        var sink = 0.0
        while Date() < until { sink += sqrt(Double(sink + 1)) }
        let second = sampler.sample()
        guard let meAgain = second.first(where: { $0.pid == own }) else { fatalError("own process vanished") }
        precondition(meAgain.identity == me.identity, "identity must be stable across samples")
        precondition(meAgain.cpuPercent > 5, "CPU delta must be measured, got \(meAgain.cpuPercent) (\(sink))")
        precondition(sampler.current(for: me.identity) != nil, "current(for:) must find the live identity")
        let fake = ProcessIdentity(pid: own, startTime: me.identity.startTime &+ 1, ppid: me.ppid, uid: me.uid)
        precondition(sampler.current(for: fake) == nil, "changed start time must not match")
    }

    static func testAggregationFollowsParentChain() {
        let app = makeSample(pid: 100, ppid: 1, name: "Test", cpu: 10, bytes: 1_000)
        let helper = makeSample(pid: 101, ppid: 100, name: "Test Helper", cpu: 5, bytes: 500)
        let grandchild = makeSample(pid: 102, ppid: 101, name: "node", path: "/usr/local/bin/node", cpu: 1, bytes: 250)
        let orphan = makeSample(pid: 200, ppid: 1, name: "orphan", path: "/opt/unrelated/background", cpu: 99, bytes: 9_999)
        let groups = ProcessAggregator.groups(
            samples: [app, helper, grandchild, orphan],
            applications: [(pid: 100, name: "Test", startIdentity: "abc")],
            ownPID: 1,
            detail: { "PID \($0)" },
            childDetail: { "child \($0.pid)" })
        precondition(groups.count == 1, "one application → one group")
        let group = groups[0]
        precondition(group.app.cpu == 16, "CPU must sum the tree, got \(group.app.cpu)")
        precondition(group.app.memBytes == 1_750, "memory must sum the tree, got \(group.app.memBytes)")
        precondition(group.children.map(\.pid) == [101, 102], "children sorted by memory, got \(group.children.map(\.pid))")
        precondition(group.app.startIdentity == "abc", "app row keeps the NSRunningApplication identity")
        precondition(!group.children[0].isNativeApp, "children are not native app rows")
    }

    static func testSortFilter() {
        func group(_ pid: Int32, _ name: String, cpu: Double, bytes: UInt64, child: String? = nil) -> ProcessGroup {
            let row = ProcessRow(pid: pid, startIdentity: "x", name: name, detail: "", isNativeApp: true,
                                 cpu: cpu, mem: 0, memBytes: bytes)
            let children = child.map { [ProcessRow(pid: pid + 1000, startIdentity: "y", name: $0, detail: "",
                                                   isNativeApp: false, cpu: 0, mem: 0, memBytes: 0)] } ?? []
            return ProcessGroup(app: row, children: children)
        }
        let groups = [group(1, "Zed", cpu: 1, bytes: 300), group(2, "Alpha", cpu: 50, bytes: 100, child: "renderer"),
                      group(3, "Mid", cpu: 10, bytes: 200)]
        precondition(ProcessAggregator.sorted(groups, by: .memory).map(\.id) == [1, 3, 2], "memory sort")
        precondition(ProcessAggregator.sorted(groups, by: .cpu).map(\.id) == [2, 3, 1], "cpu sort")
        precondition(ProcessAggregator.sorted(groups, by: .name).map(\.id) == [2, 3, 1], "name sort")
        precondition(ProcessAggregator.filter(groups, query: "  ").count == 3, "blank query keeps everything")
        precondition(ProcessAggregator.filter(groups, query: "alp").map(\.id) == [2], "name search is case-insensitive")
        precondition(ProcessAggregator.filter(groups, query: "render").map(\.id) == [2], "search matches child names")
        precondition(ProcessAggregator.filter(groups, query: "3").map(\.id) == [3], "search matches PID")
    }

    static func testHighUsageTracker() {
        var tracker = HighUsageTracker()
        let hot = ProcessGroup(app: ProcessRow(pid: 7, startIdentity: "h", name: "Hot", detail: "", isNativeApp: true,
                                               cpu: 95, mem: 0, memBytes: 0), children: [])
        let fat = ProcessGroup(app: ProcessRow(pid: 8, startIdentity: "f", name: "Fat", detail: "", isNativeApp: true,
                                               cpu: 1, mem: 0, memBytes: 5 * 1024 * 1024 * 1024), children: [])
        let t0: TimeInterval = 1_000
        var alerts = tracker.update([hot, fat], now: t0)
        precondition(alerts.map(\.pid) == [8], "memory alert is immediate, CPU alert needs duration; got \(alerts)")
        alerts = tracker.update([hot, fat], now: t0 + 29)
        precondition(alerts.map(\.pid) == [8], "CPU alert must wait the full duration")
        alerts = tracker.update([hot, fat], now: t0 + 30)
        precondition(alerts.map(\.pid) == [7, 8], "CPU alert after 30 s of sustained load; got \(alerts)")
        let cool = ProcessGroup(app: ProcessRow(pid: 7, startIdentity: "h", name: "Hot", detail: "", isNativeApp: true,
                                                cpu: 3, mem: 0, memBytes: 0), children: [])
        alerts = tracker.update([cool], now: t0 + 31)
        precondition(alerts.isEmpty, "dropping below the threshold resets the CPU timer")
        alerts = tracker.update([hot], now: t0 + 40)
        precondition(alerts.isEmpty, "timer restarted from the last drop")
    }

    static func testHistoryCapacity() {
        var history = ProcessHistory(capacity: 5)
        let make = { (cpu: Double) in
            ProcessGroup(app: ProcessRow(pid: 1, startIdentity: "a", name: "A", detail: "", isNativeApp: true,
                                         cpu: cpu, mem: 0, memBytes: 0), children: [])
        }
        for value in 1...7 { history.record([make(Double(value))]) }
        precondition(history.series(for: 1) == [3, 4, 5, 6, 7], "history keeps the newest N samples")
        history.record([])
        precondition(history.series(for: 1).isEmpty, "vanished processes drop their history")
    }

    static func testCompletePIDValidation() {
        let uid = getuid()
        let ancestor = makeSample(pid: 700, ppid: 1, name: "launcher", path: "/Users/test/launcher")
        let parent = makeSample(pid: 701, ppid: 700, name: "parent", path: "/Users/test/parent")
        let host = makeSample(pid: 702, ppid: 701, name: "Nori", path: "/Applications/Nori.app/Contents/MacOS/Nori")
        let child = makeSample(pid: 703, ppid: 702, name: "child", path: "/Users/test/child")
        let grandchild = makeSample(pid: 704, ppid: 703, name: "grandchild", path: "/Users/test/grandchild")
        let sibling = makeSample(pid: 705, ppid: 701, name: "sibling", path: "/Users/test/sibling")
        let service = makeSample(pid: 800, ppid: 1, name: "custom-server", path: "/Users/test/project/target/debug/custom-server")
        let system = makeSample(pid: 801, ppid: 1, name: "python3", path: "/usr/bin/python3")
        let unknown = makeSample(pid: 802, ppid: 1, name: "unknown", path: "")
        let foreign = makeSample(pid: 803, ppid: 1, uid: uid &+ 1, name: "foreign", path: "/Users/other/server")
        let samples = [ancestor, parent, host, child, grandchild, sibling, service, system, unknown, foreign]
        let snapshot = ProcessSampler.Snapshot(processes: samples, isComplete: true)
        let protected = ApplicationProcessScope.ownProcessTreePIDs(ownPID: host.pid, samples: samples)
        precondition(protected == [700, 701, 702, 703, 704], "Protect ancestors and all descendants, not unrelated siblings")
        func validate(_ sample: ProcessSample, expectedPath: String? = nil) -> Result<ProcessSample, ProcessTerminator.Refusal> {
            ProcessTerminator.validate(sample.identity, current: sample, snapshot: snapshot,
                                       ownPID: host.pid, ownUID: uid, expectedPath: expectedPath)
        }
        for member in [ancestor, parent, host, child, grandchild] {
            precondition(validate(member) == .failure(.ownProcessTree), "Never signal the inspector's full process lineage")
        }
        precondition(validate(sibling) == .success(sibling))
        precondition(validate(service, expectedPath: service.path) == .success(service),
                     "A separately selected user PID is not an entire runtime or project")
        precondition(validate(service, expectedPath: "/Users/test/project/old-server") == .failure(.identityChanged))
        precondition(validate(system) == .failure(.protectedPath), "Display visibility does not authorize system PID control")
        precondition(validate(unknown) == .failure(.protectedPath))
        precondition(validate(foreign) == .failure(.otherUser))
        let reused = ProcessIdentity(pid: service.pid, startTime: 999, ppid: service.ppid, uid: uid)
        precondition(ProcessTerminator.validate(reused, current: service, snapshot: snapshot,
                     ownPID: host.pid, ownUID: uid) == .failure(.identityChanged))
        precondition(ProcessTerminator.validate(service.identity, current: service,
                     snapshot: .init(processes: samples, isComplete: false), ownPID: host.pid, ownUID: uid)
                     == .failure(.identityChanged))
        precondition(ProcessTerminator.validate(service.identity, current: service,
                     snapshot: .init(processes: samples.filter { $0.pid != host.pid }, isComplete: true),
                     ownPID: host.pid, ownUID: uid) == .failure(.identityChanged))
    }

    static func testTerminatorRefusesOwnTreeAndSystem() async {
        let sampler = ProcessSampler()
        let own = ProcessInfo.processInfo.processIdentifier
        guard let me = sampler.sample().first(where: { $0.pid == own }) else { fatalError("own process missing") }
        precondition(ProcessTerminator.validate(me.identity, sampler: sampler) == .failure(.ownProcessTree),
                     "must refuse to terminate ourselves")
        let parent = ProcessIdentity(pid: getppid(), startTime: 0, ppid: 0, uid: getuid())
        precondition(ProcessTerminator.validate(parent, sampler: sampler) == .failure(.identityChanged),
                     "wrong start time must be rejected before any signal")
        precondition(ProcessAggregator.isProtectedPath("/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"))
        precondition(ProcessAggregator.isProtectedPath("/usr/libexec/trustd"))
        precondition(!ProcessAggregator.isProtectedPath("/Applications/Safari.app/Contents/MacOS/Safari"))
        // A stale identity never reaches kill(): terminateThenKill reports false without signalling.
        let stale = ProcessIdentity(pid: own, startTime: me.identity.startTime &+ 1, ppid: me.ppid, uid: me.uid)
        let ended = await ProcessTerminator.terminateThenKill(stale, grace: 0.1, sampler: sampler)
        precondition(!ended, "stale identity must not be treated as terminated")
    }
}
