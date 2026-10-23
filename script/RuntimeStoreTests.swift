import Foundation

private struct RuntimeStoreTestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct RuntimeStoreTests {
    static func main() throws {
        try testCompleteAdvancedRows()
        try testNativeMetadata()
        try testVisibleRows()
        try testLegacyGrouping()
        // IPv4/IPv6 wildcard listeners have identical bridge fields. Duplicate IDs
        // used to leave blank row slots in the port page's LazyVStack.
        let portText = """
        7000\t1262\tMon_Aug_31_10:00:00_2026\tControlCenter\t*:7000
        7000\t1262\tMon_Aug_31_10:00:00_2026\tControlCenter\t*:7000
        5000\t1262\tMon_Aug_31_10:00:00_2026\tControlCenter\t*:5000
        5000\t1262\tMon_Aug_31_10:00:00_2026\tControlCenter\t*:5000
        7000\t1262\tMon_Aug_31_10:00:00_2026\tControlCenter\t127.0.0.1:7000
        7000\t1262\tMon_Aug_31_10:00:00_2026\tControlCenter\t[::1]:7000
        7000\t2000\tMon_Aug_31_10:00:01_2026\tOther\t*:7000
        invalid input
        """
        let ports = RuntimeStore.portRows(fromText: portText)
        try expect(ports.count == 5 && Set(ports.map(\.id)).count == ports.count,
                   "duplicate listeners must be collapsed into unique port rows")
        try expect(ports.map(\.endpoint) == ["*:7000", "*:5000", "127.0.0.1:7000", "[::1]:7000", "*:7000"],
                   "deduplication must preserve order, distinct addresses and different processes")
        let refreshedPorts = RuntimeStore.portRows(fromText: portText)
        try expect(ports.map(\.id) == refreshedPorts.map(\.id),
                   "port row identity must stay stable across refreshes")
        let restartedPort = PortRow(port: ports[0].port, pid: ports[0].pid,
                                    startIdentity: "Mon_Aug_31_11:00:00_2026",
                                    command: ports[0].command, endpoint: ports[0].endpoint)
        try expect(restartedPort.id != ports[0].id && restartedPort.signalToken != ports[0].signalToken,
                   "PID reuse must change both row and action identity")

        let text = """
        100\t1\tMon_Aug_31_10:00:00_2026\t10.0\t1.0\t/AppOne\t/Applications/AppOne.app/Contents/MacOS/AppOne
        101\t100\tMon_Aug_31_10:00:01_2026\t20.0\t2.0\t/Helper\t/Applications/AppOne.app/Contents/Frameworks/Helper
        102\t101\tMon_Aug_31_10:00:02_2026\t5.0\t3.0\t/Worker\tworker
        200\t1\tMon_Aug_31_10:00:03_2026\t2.5\t4.0\t/AppTwo\t/Applications/AppTwo.app/Contents/MacOS/AppTwo
        300\t1\tMon_Aug_31_10:00:04_2026\t99.0\t9.0\t/Other\tother
        """
        let usage = RuntimeStore.usageByApplicationPID(Set([100, 200]),
                                                       fromProcessText: text)
        try expect(usage[100]?.cpu == 35.0 && usage[100]?.mem == 6.0,
                   "AppOne did not include its nested helper processes")
        try expect(usage[200]?.cpu == 2.5 && usage[200]?.mem == 4.0,
                   "AppTwo resource usage was not preserved")
        try expect(usage[300] == nil && usage.count == 2,
                   "unrelated process leaked into an application total")

        // The upgraded bridge includes UID, process state and elapsed time. Keep
        // abnormal PIDs visible ahead of high-CPU normal processes.
        let lifecycleText = """
        4100\t4200\t501\tMon_Aug_31_10:01:00_2026\tZE\t00:03\t0.1\t0.1\t/Zombie\t/Applications/Test.app/Zombie
        4101\t1\t501\tMon_Aug_31_10:01:01_2026\tSE\t1-02:03:04\t0.2\t0.2\t/Exiting\t/Applications/Test.app/Exiting
        4102\t1\t501\tMon_Aug_31_10:01:02_2026\tX\t00:05\t99.0\t0.3\t/Traced\t/Applications/Test.app/Traced
        4103\t1\t501\tMon_Aug_31_10:01:03_2026\tT\t00:06\t98.0\t0.4\t/Stopped\t/Applications/Test.app/Stopped
        4104\t1\t501\tMon_Aug_31_10:01:04_2026\tU\t00:07\t97.0\t0.5\t/Waiting\t/Applications/Test.app/Waiting
        4105\t1\t501\tMon_Aug_31_10:01:05_2026\tSZ\t00:08\t96.0\t0.6\t/NotZombie\t/Applications/Test.app/NotZombie
        4106\t1\t501\tMon_Aug_31_10:01:06_2026\tS\t00:09\t95.0\t0.7\t/Orphan\t/Applications/Test.app/Orphan
        """
        let lifecycleRows = RuntimeStore.rows(fromProcessText: lifecycleText, advanced: true)
        let lifecycleByPID = Dictionary(uniqueKeysWithValues: lifecycleRows.map { ($0.pid, $0) })
        try expect(lifecycleRows.prefix(2).map(\.lifecycle) == [.zombie, .exiting],
                   "advanced PID rows did not prioritize abnormal lifecycle states")
        try expect(lifecycleByPID[4100]?.lifecycle == .zombie,
                   "a state beginning with Z was not classified as zombie")
        try expect(lifecycleByPID[4101]?.lifecycle == .exiting,
                   "the additional E state flag was not classified as exiting")
        for pid in [4102, 4103, 4104, 4105, 4106] {
            try expect(lifecycleByPID[Int32(pid)]?.lifecycle == .normal,
                       "state for PID \(pid) was falsely classified as abnormal")
        }
        try expect(lifecycleByPID[4100]?.ppid == 4200 && lifecycleByPID[4100]?.uid == 501,
                   "new process metadata was not preserved")
        try expect(lifecycleByPID[4101]?.state == "SE" &&
                   lifecycleByPID[4101]?.elapsed == 93_784,
                   "state or ps elapsed time was not parsed")

        let legacyRows = RuntimeStore.rows(fromProcessText: text, advanced: true)
        try expect(!legacyRows.isEmpty && legacyRows.allSatisfy {
            $0.lifecycle == .normal && $0.uid == UInt32.max && $0.elapsed == 0
        }, "legacy seven-column process output lost compatibility")

        let firstLaunch = ProcessRow(pid: 500, startIdentity: "first", name: "App",
                                     detail: "", isNativeApp: true, cpu: 0, mem: 0,
                                     memBytes: 0)
        let reusedPID = ProcessRow(pid: 500, startIdentity: "second", name: "App",
                                   detail: "", isNativeApp: true, cpu: 0, mem: 0,
                                   memBytes: 0)
        try expect(firstLaunch.signalToken != reusedPID.signalToken,
                   "process icon identity did not change after PID reuse")

        func process(pid: Int32, start: String, state: String,
                     ppid: Int32 = 1) -> ProcessRow {
            ProcessRow(pid: pid, startIdentity: start, name: "test", detail: "",
                       isNativeApp: false, cpu: 0, mem: 0, memBytes: 0,
                       ppid: ppid, uid: 501, state: state, elapsed: 60)
        }

        var tracker = RuntimeStore.AutomaticCandidateTracker(currentUID: 501)
        let zombie = process(pid: 500, start: "first", state: "Z")
        try expect(zombie.staleCleanupToken == "500|first|1|501",
                   "stale cleanup token did not bind parent and user identity")
        try expect(tracker.candidates(in: [zombie]).isEmpty,
                   "zombie was returned before two consecutive snapshots")
        let zombieCandidates = tracker.candidates(in: [zombie])
        try expect(zombieCandidates.map(\.signalToken) == [zombie.signalToken],
                   "zombie was not returned on the second consecutive snapshot")
        let stillPending = tracker.candidates(in: [zombie])
        try expect(stillPending.map(\.signalToken) == [zombie.signalToken],
                   "candidate was marked attempted before the caller selected it")
        tracker.markAttempted(stillPending)
        try expect(tracker.candidates(in: [zombie]).isEmpty,
                   "an attempted zombie token was returned more than once")
        _ = tracker.candidates(in: [process(pid: 500, start: "first", state: "R")])
        _ = tracker.candidates(in: [zombie])
        try expect(tracker.candidates(in: [zombie]).map(\.signalToken) ==
                   [zombie.signalToken],
                   "normal state did not clear the attempted token for a later retry")

        let resetZombie = process(pid: 501, start: "stable", state: "Z")
        _ = tracker.candidates(in: [resetZombie])
        _ = tracker.candidates(in: [process(pid: 501, start: "stable", state: "S")])
        try expect(tracker.candidates(in: [resetZombie]).isEmpty,
                   "normal state did not clear the zombie observation count")
        try expect(tracker.candidates(in: [resetZombie]).map(\.signalToken) ==
                   [resetZombie.signalToken],
                   "zombie was not returned after a fresh two-snapshot sequence")

        let oldExiting = process(pid: 502, start: "old", state: "SE")
        let reusedExiting = process(pid: 502, start: "new", state: "SE")
        _ = tracker.candidates(in: [oldExiting])
        _ = tracker.candidates(in: [oldExiting])
        try expect(tracker.candidates(in: [reusedExiting]).isEmpty,
                   "PID reuse inherited the previous process observation count")
        try expect(tracker.candidates(in: [reusedExiting]).isEmpty,
                   "exiting process was returned before three consecutive snapshots")
        let exitingCandidates = tracker.candidates(in: [reusedExiting])
        try expect(exitingCandidates.map(\.signalToken) == [reusedExiting.signalToken],
                   "exiting process was not returned on its third stable snapshot")
        tracker.markAttempted(exitingCandidates)
        try expect(tracker.candidates(in: [reusedExiting]).isEmpty,
                   "an attempted exiting token was returned more than once")

        let interruptedZombie = process(pid: 503, start: "interrupted", state: "Z")
        _ = tracker.candidates(in: [interruptedZombie])
        _ = tracker.candidates(in: [])
        try expect(tracker.candidates(in: [interruptedZombie]).isEmpty,
                   "a missing snapshot did not clear the consecutive observation count")
        try expect(tracker.candidates(in: [interruptedZombie]).map(\.signalToken) ==
                   [interruptedZombie.signalToken],
                   "zombie was not returned after two new consecutive snapshots")

        let originalParent = process(pid: 505, start: "same-process", state: "Z", ppid: 700)
        let newParent = process(pid: 505, start: "same-process", state: "Z", ppid: 701)
        _ = tracker.candidates(in: [originalParent])
        try expect(tracker.candidates(in: [newParent]).isEmpty,
                   "a parent change inherited the previous zombie observation count")
        let reparentedCandidates = tracker.candidates(in: [newParent])
        try expect(reparentedCandidates.map(\.staleCleanupToken) ==
                   [newParent.staleCleanupToken],
                   "a reparented zombie was not returned after a fresh stable sequence")

        var gapTracker = RuntimeStore.AutomaticCandidateTracker(currentUID: 501)
        let gapZombie = process(pid: 506, start: "gap", state: "Z")
        _ = gapTracker.candidates(in: [gapZombie], now: 100)
        try expect(gapTracker.candidates(in: [gapZombie], now: 110).isEmpty,
                   "a stale snapshot count survived a long sampling gap")
        try expect(gapTracker.candidates(in: [gapZombie], now: 112).map(\.signalToken) ==
                   [gapZombie.signalToken],
                   "sampling did not restart after a long gap")

        var failedScanTracker = RuntimeStore.AutomaticCandidateTracker(currentUID: 501)
        let failedScanZombie = process(pid: 507, start: "failed-scan", state: "Z")
        _ = failedScanTracker.candidates(in: [failedScanZombie], now: 200)
        failedScanTracker.breakSequence()
        try expect(failedScanTracker.candidates(in: [failedScanZombie], now: 202).isEmpty,
                   "a failed scan did not interrupt consecutive observations")
        let afterFailure = failedScanTracker.candidates(in: [failedScanZombie], now: 204)
        try expect(afterFailure.map(\.signalToken) == [failedScanZombie.signalToken],
                   "sampling did not restart after a failed scan")
        failedScanTracker.markAttempted(afterFailure)
        failedScanTracker.breakSequence()
        _ = failedScanTracker.candidates(in: [failedScanZombie], now: 206)
        try expect(failedScanTracker.candidates(in: [failedScanZombie], now: 208).isEmpty,
                   "a failed scan cleared the already-attempted safety token")

        let otherUserZombie = ProcessRow(
            pid: 504, startIdentity: "other-user", name: "test", detail: "",
            isNativeApp: false, cpu: 0, mem: 0, memBytes: 0,
            ppid: 1, uid: 502, state: "Z", elapsed: 60)
        _ = tracker.candidates(in: [otherUserZombie])
        try expect(tracker.candidates(in: [otherUserZombie]).isEmpty,
                   "automatic tracker returned another user's process")

        let sixteenGiB = UInt64(16) * 1_024 * 1_024 * 1_024
        try expect(ByteFormat.memoryShort(sixteenGiB) == "16G",
                   "16 GiB physical memory was not rendered as 16G")

        let pageSize = UInt64(4_096)
        let memoryUsage = SystemMetrics.normalizedMemoryUsage(
            totalBytes: pageSize * 100,
            pageSize: pageSize,
            internalPages: 70,
            purgeablePages: 20,
            wiredPages: 10,
            compressedPages: 5)
        try expect(memoryUsage.usedBytes == pageSize * 65 && memoryUsage.percent == 65,
                   "memory usage did not exclude purgeable/file-cache pages")
        let clamped = SystemMetrics.normalizedMemoryUsage(
            totalBytes: pageSize * 100,
            pageSize: pageSize,
            internalPages: UInt64.max,
            purgeablePages: 0,
            wiredPages: UInt64.max,
            compressedPages: UInt64.max)
        try expect(clamped.usedBytes == pageSize * 100 && clamped.percent == 100,
                   "memory usage was not clamped to physical memory")
    }

    private static let bridgeStart = "Mon_Aug_31_10:00:00_2026"

    private static func record(_ pid: Int32, ppid: Int32 = 1, uid: UInt32 = 501,
                               state: String = "S", cpu: Double = 1, mem: Double = 0.1,
                               command: String, arguments: String = "") -> String {
        "\(pid)\t\(ppid)\t\(uid)\t\(bridgeStart)\t\(state)\t00:09\t\(cpu)\t\(mem)\t\(command)\t\(arguments)"
    }

    private static func testCompleteAdvancedRows() throws {
        // Entry paths cover shared runtimes and arbitrary compiled executable names.
        let paths = [
            "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
            "/bin/zsh",
            "/usr/local/bin/node",
            "/Users/test/.venv/bin/python3",
            "/Library/Java/JavaVirtualMachines/Fixture.jdk/Contents/Home/bin/java",
            "/private/var/folders/fixture/go-build/server",
            "/Users/test/project/target/debug/renamed-task",
            "/usr/local/share/dotnet/dotnet",
            "/usr/local/bin/arbitrary-name",
            "/usr/local/bin/node"
        ]
        var lines = paths.enumerated().map { index, path in
            record(10_100 + Int32(index), ppid: index == 0 ? 1 : 10_100,
                   command: path, arguments: path + " /Users/test/project-\(index)/entry")
        }
        lines.append(record(10_110, command: "/opt/homebrew/bin/node"))
        lines.append(record(10_111, uid: 0, command: "/usr/libexec/system-worker"))
        lines += (0..<60).map { index in
            record(10_200 + Int32(index), ppid: 10_100,
                   command: "/Users/test/workers/worker-\(index)")
        }
        let rows = RuntimeStore.rows(fromProcessText: lines.joined(separator: "\n"), advanced: true)
        let byPID = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0) })
        try expect(rows.count == lines.count && rows.count > 40,
                   "advanced mode filtered paths, inherited a system parent filter, or truncated PID rows")
        try expect(Set(rows.map(\.pid)).count == lines.count,
                   "advanced mode merged distinct process instances")
        for (index, path) in paths.enumerated() {
            let pid = 10_100 + Int32(index)
            try expect(byPID[pid]?.executablePath == path && byPID[pid]?.startIdentity == bridgeStart,
                       "advanced mode lost a runtime path or bridge identity for PID \(pid)")
            try expect(byPID[pid]?.ppid == (index == 0 ? 1 : 10_100) && byPID[pid]?.uid == 501,
                       "advanced mode lost parent or user metadata for PID \(pid)")
        }
        try expect(byPID[10_102] != nil && byPID[10_109] != nil,
                   "two projects that share node must remain separate PID rows")
        try expect(byPID[10_110] != nil && byPID[10_111]?.uid == 0,
                   "background or other-user observations must not inherit action filters")

        let abnormalText = (0..<45).map { index in
            record(11_000 + Int32(index), ppid: 10_100, state: "Z", command: "/usr/local/bin/worker")
        }.joined(separator: "\n")
        let abnormalRows = RuntimeStore.rows(fromProcessText: abnormalText, advanced: true)
        var tracker = RuntimeStore.AutomaticCandidateTracker(currentUID: 501)
        try expect(tracker.candidates(in: abnormalRows, now: 100).isEmpty,
                   "complete advanced rows bypassed the first stable-snapshot threshold")
        try expect(tracker.candidates(in: abnormalRows, now: 102).count == 45,
                   "a presentation limit hid abnormal process observations from the tracker")
    }

    private static func testNativeMetadata() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2026, month: 8, day: 31, hour: 10))!
        let start = UInt64(date.timeIntervalSince1970) * 1_000_000 + 999_999
        let bytes = UInt64(256) * 1_024 * 1_024
        let text = record(12_000, ppid: 10_100, cpu: 80, mem: 1.5, command: "/usr/local/bin/node")
        func metadata(startTime: UInt64 = start, uid: UInt32 = 501,
                      residentBytes: UInt64 = bytes, cpu: Double = 12.5) -> RuntimeStore.ProcessMetadata {
            .init(startTime: startTime, name: "Arbitrary Native Worker",
                  path: "/Users/test/Project With Spaces/bin/worker", cpuPercent: cpu,
                  residentBytes: residentBytes, ppid: 1, uid: uid, state: "SE", elapsed: 42.25,
                  workingDirectory: "/Users/test/Project With Spaces", bundlePath: "/Users/test/Fixture.app")
        }
        let native = metadata()
        let row = RuntimeStore.rows(fromProcessText: text, advanced: true, metadata: [12_000: native])[0]
        try expect(row.startIdentity == bridgeStart && row.signalToken == "12000|\(bridgeStart)",
                   "native display metadata changed the bridge action identity")
        try expect(row.nativeStartTime == start && row.name == "Arbitrary Native Worker  PID 12000" && !row.isNativeApp,
                   "matched native metadata did not retain the exact process identity or display name")
        try expect(row.cpu == 12.5 && row.memBytes == bytes,
                   "matched native metadata did not replace lifetime CPU and rounded memory")
        let expectedMemory = RuntimeStore.physicalMemory > 0
            ? Double(bytes) / Double(RuntimeStore.physicalMemory) * 100 : 0
        try expect(abs(row.mem - expectedMemory) < 0.000_001,
                   "native memory percent does not correspond to resident bytes")
        try expect(row.executablePath == native.path && row.workingDirectory == native.workingDirectory &&
                   row.bundlePath == native.bundlePath,
                   "matched native executable, working directory, or display bundle path was lost")
        try expect(row.ppid == 1 && row.uid == 501 && row.state == "SE" && row.elapsed == 42.25,
                   "matched native reparenting or lifecycle metadata was lost")
        try expect(row.detail.contains("PPID 1") && row.staleCleanupToken == "12000|\(bridgeStart)|1|501",
                   "the display or stale token did not retain the observed parent")

        for candidate in [metadata(startTime: start + 1_000_000), metadata(uid: 502)] {
            let fallback = RuntimeStore.rows(fromProcessText: text, advanced: true,
                                             metadata: [12_000: candidate])[0]
            try expect(fallback.nativeStartTime == nil && fallback.workingDirectory == nil && fallback.bundlePath == nil,
                       "a reused PID or different user borrowed native metadata")
            try expect(fallback.name == "node  PID 12000" && fallback.executablePath == "/usr/local/bin/node" &&
                       fallback.cpu == 80 && fallback.mem == 1.5 && fallback.ppid == 10_100 &&
                       fallback.uid == 501 && fallback.state == "S" && fallback.elapsed == 9,
                       "a rejected native match changed bridge process fields")
        }
        let unavailable = metadata(residentBytes: 0, cpu: 0)
        let bridgeRow = RuntimeStore.rows(fromProcessText: text, advanced: true)[0]
        let unavailableRow = RuntimeStore.rows(fromProcessText: text, advanced: true,
                                              metadata: [12_000: unavailable])[0]
        try expect(unavailableRow.cpu == bridgeRow.cpu && unavailableRow.mem == bridgeRow.mem &&
                   unavailableRow.memBytes == bridgeRow.memBytes,
                   "unavailable native task data replaced valid bridge resource values with zero")
        try expect(unavailableRow.nativeStartTime == start && unavailableRow.executablePath == native.path &&
                   unavailableRow.workingDirectory == native.workingDirectory,
                   "unavailable native task data discarded verified identity or directory metadata")
        let idleText = record(12_000, cpu: 0, mem: 0, command: "/usr/local/bin/node")
        let idleRow = RuntimeStore.rows(fromProcessText: idleText, advanced: true,
                                        metadata: [12_000: unavailable])[0]
        try expect(idleRow.cpu == 0 && idleRow.mem == 0 && idleRow.memBytes == 0,
                   "zero bridge and native task values invented resource usage")
        let legacy = "12000\t10100\t\(bridgeStart)\t80.0\t1.5\t/usr/local/bin/node\t/usr/local/bin/node serve"
        let legacyRow = RuntimeStore.rows(fromProcessText: legacy, advanced: true, metadata: [12_000: native])[0]
        try expect(legacyRow.nativeStartTime == nil && legacyRow.workingDirectory == nil &&
                   legacyRow.uid == UInt32.max && legacyRow.state.isEmpty && legacyRow.elapsed == 0,
                   "legacy unknown UID borrowed native metadata or lost seven-column compatibility")
    }

    private static func testVisibleRows() throws {
        func row(_ pid: Int32, name: String, ppid: Int32 = 1, cpu: Double, bytes: UInt64,
                 state: String = "S", path: String? = nil, cwd: String? = nil) -> ProcessRow {
            ProcessRow(pid: pid, startIdentity: bridgeStart, name: name, detail: "", isNativeApp: false,
                       cpu: cpu, mem: 0, memBytes: bytes, ppid: ppid, uid: 501, state: state,
                       executablePath: path, workingDirectory: cwd)
        }
        let rows = [
            row(13_000, name: "Zulu", cpu: 0, bytes: 1, state: "Z"),
            row(13_001, name: "Yankee", cpu: 0, bytes: 2, state: "SE"),
            row(13_002, name: "Alpha", ppid: 7654, cpu: 10, bytes: 300,
                path: "/Users/test/executables/PathOnly/server", cwd: "/Users/test/worktrees/CwdOnly"),
            row(13_003, name: "Beta", cpu: 90, bytes: 100,
                path: "/usr/local/bin/server", cwd: "/Users/test/project-b"),
            row(13_004, name: "alpha", cpu: 10, bytes: 300)
        ]
        try expect(RuntimeStore.visibleRows(rows, query: "  \n", sort: .memory).map(\.pid) ==
                   [13_000, 13_001, 13_002, 13_004, 13_003],
                   "memory sort lost abnormal priority, blank-query rows, or deterministic ties")
        try expect(RuntimeStore.visibleRows(rows, query: "", sort: .cpu).map(\.pid) ==
                   [13_000, 13_001, 13_003, 13_002, 13_004],
                   "CPU sort lost abnormal priority or deterministic ties")
        try expect(RuntimeStore.visibleRows(rows, query: "", sort: .name).map(\.pid) ==
                   [13_000, 13_001, 13_002, 13_004, 13_003],
                   "name sort lost abnormal priority or case-insensitive ordering")
        for query in ["13002", "7654", "  pathonly  ", "CWDONLY"] {
            try expect(RuntimeStore.visibleRows(rows, query: query, sort: .cpu).map(\.pid) == [13_002],
                       "PID, PPID, executable path, or working-directory search failed for \(query)")
        }
        try expect(RuntimeStore.visibleRows(rows, query: "ALPHA", sort: .name).map(\.pid) == [13_002, 13_004],
                   "process name search did not preserve distinct same-name instances")
        try expect(RuntimeStore.visibleRows(rows, query: "no-match", sort: .cpu).isEmpty,
                   "an unmatched query did not clear presentation rows")
    }

    private static func testLegacyGrouping() throws {
        let systemText = [
            record(14_000, command: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
            record(14_001, ppid: 14_000, command: "/usr/local/bin/node")
        ].joined(separator: "\n")
        try expect(RuntimeStore.rows(fromProcessText: systemText, advanced: false).isEmpty,
                   "the legacy grouped path changed its system-root filtering")
        let groupedText = [
            record(14_100, cpu: 2, mem: 1, command: "/Users/test/LegacyOwner"),
            record(14_101, ppid: 14_100, cpu: 3, mem: 2, command: "/Users/test/LegacyChild")
        ].joined(separator: "\n")
        let grouped = RuntimeStore.rows(fromProcessText: groupedText, advanced: false)
        try expect(grouped.count == 1 && grouped[0].pid == 14_100 && grouped[0].cpu == 5 && grouped[0].mem == 3,
                   "the legacy grouped path changed its root or resource aggregation")
        var manyLines: [String] = []
        for index in 0..<60 {
            let pid = Int32(15_000 + index)
            let cpu = Double(60 - index)
            let memory = Double(index + 1)
            manyLines.append(record(pid, cpu: cpu, mem: memory, command: "/Users/test/Legacy-\(index)"))
        }
        let manyText = manyLines.joined(separator: "\n")
        let byCPU = RuntimeStore.rows(fromProcessText: manyText, advanced: false)
        let byMemory = RuntimeStore.rows(fromProcessText: manyText, advanced: false, sortByMemory: true)
        try expect(byCPU.count == 40 && byCPU.first?.pid == 15_000 &&
                   byMemory.count == 40 && byMemory.first?.pid == 15_059,
                   "the legacy grouped path changed its limit or sort order")
    }

    private static func expect(_ condition: @autoclosure () -> Bool,
                               _ message: String) throws {
        guard condition() else { throw RuntimeStoreTestFailure(description: message) }
    }
}
