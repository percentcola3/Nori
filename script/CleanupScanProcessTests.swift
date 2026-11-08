import Foundation
import Darwin
import Security

private enum TestError: Error { case failure(String) }
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestError.failure(message) }
}
private func reject(_ message: String, _ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw TestError.failure(message)
}
private func fixtureCategory(home: String, count: Int = 2) -> CleanupCategory {
    let paths = (0..<count).map { home + "/synthetic/item-\($0)" }
    var category = CleanupCategory(name: "wire fixture", paths: paths, bytes: UInt64(count * 4096),
        pathBytes: Dictionary(uniqueKeysWithValues: paths.map { ($0, UInt64(4096)) }),
        pathIdentities: Dictionary(uniqueKeysWithValues: paths.map { ($0, "12:34:56") }),
        retentionClass: .artifacts,
        pathActivity: [paths[0]: Date(timeIntervalSince1970: 123456)],
        pathNotes: [paths[0]: "fixture note"], pathRetentionBlocked: [paths[0]],
        selected: false, expanded: true, source: .appLeftover, risk: .warning,
        disposal: .permanentDelete, applyRoute: .genericTrash, activityGuard: .appData,
        retention: 604800, reasonKey: "fixture.reason")
    category = category.selectingPaths([paths[0]])
    category.activityOwners = ["fixture.owner"]
    category.uninstallDataOwner = UninstallDataOwner(kind: .agent, name: "fixture",
        bundleID: "example.fixture", installationPath: home + "/Applications/fixture.app",
        names: ["fixture"], groups: ["fixture.group"], commands: ["fixture"], agentIDs: ["fixture"])
    return category
}
private func fixtureScan(home: String, count: Int = 2) -> NativeCore.CleanupScan {
    let category = fixtureCategory(home: home, count: count)
    return NativeCore.CleanupScan(categories: [category], succeeded: true, error: nil,
        deferredPaths: [home + "/deferred"], diagnostics: "fixture diagnostics",
        administratorRequiredPaths: [category.paths[0]], completedRoots: [home + "/completed"])
}

@main
struct CleanupScanProcessTests {
    static func main() async throws {
        setbuf(stdout, nil)
        let name = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
        if name.hasPrefix("fixture-") { try await fakeWorker(String(name.dropFirst(8))); return }
        if name == "orphan-driver" { try orphanDriver(); return }
        try expect(CommandLine.arguments.count == 3, "fixture root and real worker arguments required")
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
        let worker = URL(fileURLWithPath: CommandLine.arguments[2])
        try expect(root.lastPathComponent.hasPrefix("nori-process-fixture."), "nonce fixture required")
        try protocolTests(root: root)
        try await processTests(root: root, realWorker: worker)
        print("Cleanup scan protocol/process tests passed")
    }

    private static func protocolTests(root: URL) throws {
        let home = root.path
        let presence = AgentPresenceContext(applicationDirs: [home + "/Applications"], searchPath: [home + "/bin"],
            applicationPathsByName: ["Fixture": [home + "/Applications/Fixture.app"]])
        let request = CleanupScanProtocol.Request(home: home, mode: .deep, presence: presence,
            includingAdministratorRequired: true, excludingRoots: [home + "/done"],
            parentPID: getpid(), parentUID: getuid())
        let encoded = try CleanupScanProtocol.encodeRequest(request)
        let decoded = try CleanupScanProtocol.decodeRequest(Data(encoded.dropFirst(4)))
        try expect(decoded.id == request.id && decoded.mode == "deep" && decoded.excludingRoots == request.excludingRoots,
                   "request fields lost")
        try expect(decoded.presence?.applicationPathsByName == presence.applicationPathsByName, "presence fields lost")
        var object = try JSONSerialization.jsonObject(with: Data(encoded.dropFirst(4))) as! [String: Any]
        object["mode"] = "apply"
        try reject("unknown mode accepted") { _ = try CleanupScanProtocol.decodeRequest(JSONSerialization.data(withJSONObject: object)) }
        object["mode"] = "quick"; object["operation"] = "delete"
        try reject("mutation operation accepted") { _ = try CleanupScanProtocol.decodeRequest(JSONSerialization.data(withJSONObject: object)) }
        object["operation"] = "scan"; object["command"] = "/bin/sh"
        try reject("command field accepted") { _ = try CleanupScanProtocol.decodeRequest(JSONSerialization.data(withJSONObject: object)) }
        try reject("oversized header accepted") {
            _ = try CleanupScanProtocol.bodyLength(Data([255, 255, 255, 255]), limit: CleanupScanProtocol.maximumFrameBytes)
        }
        try reject("truncated header accepted") { _ = try CleanupScanProtocol.bodyLength(Data([0, 1]), limit: 100) }
        let source = fixtureScan(home: home)
        let frame = try CleanupScanProtocol.encodeFrame(.result(source, id: request.id))
        let result = try CleanupScanProtocol.decodeFrame(Data(frame.dropFirst(4)), id: request.id).scan!.model()
        let lhs = source.categories[0], rhs = result.categories[0]
        try expect(lhs.id == rhs.id && lhs.paths == rhs.paths && lhs.bytes == rhs.bytes
            && lhs.pathBytes == rhs.pathBytes && lhs.pathIdentities == rhs.pathIdentities
            && lhs.retentionClass == rhs.retentionClass && lhs.pathActivity == rhs.pathActivity
            && lhs.pathNotes == rhs.pathNotes && lhs.pathRetentionBlocked == rhs.pathRetentionBlocked
            && lhs.selectedPaths == rhs.selectedPaths && lhs.expanded == rhs.expanded
            && lhs.source == rhs.source && lhs.risk == rhs.risk && lhs.disposal == rhs.disposal
            && lhs.applyRoute == rhs.applyRoute && lhs.activityGuard == rhs.activityGuard
            && lhs.retention == rhs.retention && lhs.reasonKey == rhs.reasonKey
            && lhs.activityOwners == rhs.activityOwners && lhs.uninstallDataOwner == rhs.uninstallDataOwner,
            "category safety or path metadata lost")
        try expect(result.deferredPaths == source.deferredPaths && result.completedRoots == source.completedRoots
            && result.administratorRequiredPaths == source.administratorRequiredPaths
            && result.diagnostics == source.diagnostics && result.error == source.error
            && result.succeeded == source.succeeded, "scan metadata lost")
        try reject("wrong request id accepted") {
            _ = try CleanupScanProtocol.decodeFrame(Data(frame.dropFirst(4)), id: UUID())
        }
        var response = try JSONSerialization.jsonObject(with: Data(frame.dropFirst(4))) as! [String: Any]
        var scan = response["scan"] as! [String: Any]
        var categories = scan["categories"] as! [[String: Any]]
        categories[0]["disposal"] = "unknownFutureDisposal"
        scan["categories"] = categories; response["scan"] = scan
        try reject("unknown safety enum accepted") {
            _ = try CleanupScanProtocol.decodeFrame(JSONSerialization.data(withJSONObject: response), id: request.id).scan!.model()
        }
        let preflight = CleanupScanProtocol.Request(home: home, mode: .deep, presence: presence,
            includingAdministratorRequired: true, excludingRoots: [], parentPID: getpid(), parentUID: getuid(),
            cachedCategories: source.categories)
        let preflightBytes = try CleanupScanProtocol.encodeRequest(preflight)
        let decodedPreflight = try CleanupScanProtocol.decodeRequest(Data(preflightBytes.dropFirst(4)))
        try expect(decodedPreflight.operation == "preflight", "read-only cache preflight missing")
        print("protocol: full metadata, presence, preflight, bounds and invalid modes passed")
    }

    @MainActor
    private static func processTests(root: URL, realWorker: URL) async throws {
        let own = URL(fileURLWithPath: CommandLine.arguments[0])
        func executable(_ name: String) throws -> URL {
            let destination = root.appendingPathComponent(name)
            try FileManager.default.copyItem(at: own, to: destination)
            return destination
        }
        let success = try executable("fixture-success")
        let result = await CleanupScanProcess.testScan(worker: success, home: root.path)
        try expect(result.succeeded && result.categories.count == 1, "child result not delivered")
        for mode in ["bad", "truncated", "oversized", "exit", "empty", "duplicate"] {
            let helper = try executable("fixture-" + mode)
            let failure = await CleanupScanProcess.testScan(worker: helper, home: root.path)
            try expect(!failure.succeeded && failure.categories.isEmpty && failure.error != nil, "fail-open for \(mode)")
        }
        let missing = await CleanupScanProcess.testScan(worker: root.appendingPathComponent("absent"), home: root.path)
        try expect(!missing.succeeded && missing.categories.isEmpty, "missing worker fell back")
        // The production resolver must reject this standalone unsigned test host.
        let unsigned = await CleanupScanProcess.scanCleanup(homeDirectory: root.path)
        try expect(!unsigned.succeeded && unsigned.categories.isEmpty, "unsigned host accepted")

        let large = try executable("fixture-large")
        var beats = 0
        var maxGap = 0.0
        let heartbeat = Task { @MainActor in
            var previous = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
                let now = ProcessInfo.processInfo.systemUptime
                maxGap = max(maxGap, now - previous); previous = now; beats += 1
            }
        }
        let largeResult = await CleanupScanProcess.testScan(worker: large, home: root.path)
        heartbeat.cancel()
        try expect(largeResult.succeeded && largeResult.categories[0].paths.count == 100_000, "large snapshot failed")
        try expect(beats >= 10 && maxGap < 0.25, "main executor stalled during large snapshot: \(maxGap)s")
        print(String(format: "100000 paths: heartbeat=%d maxGap=%.3fs", beats, maxGap))

        let hang = try executable("fixture-hang")
        for taskCancellation in [false, true] {
            let control = CleanupScanControl(mode: .deep)
            let pid = LockedPID()
            let sink = CleanupScanProgressSink(minimumInterval: 0) { event in
                pid.set(Int32((event.currentPath as NSString).lastPathComponent) ?? 0)
            }
            let task = Task { await CleanupScanProcess.testScan(worker: hang, home: root.path, control: control, progress: sink) }
            try await waitUntil { pid.get() > 0 }
            let started = ProcessInfo.processInfo.systemUptime
            if taskCancellation { task.cancel() } else { control.cancel() }
            let cancelled = await task.value
            try expect(!cancelled.succeeded && cancelled.categories.isEmpty, "cancelled result accepted")
            try expect(ProcessInfo.processInfo.systemUptime - started < 2, "cancel took too long")
            try await waitUntil { kill(pid.get(), 0) != 0 }
        }
        print("process: corrupt/truncated/oversized/nonzero/missing/duplicate fail closed; control + Task cancellation reaped")

        let descendantHome = root.appendingPathComponent("process-lifetime-descendant")
        try FileManager.default.createDirectory(at: descendantHome, withIntermediateDirectories: true)
        for taskCancellation in [false, true] {
            let control = CleanupScanControl(mode: .deep)
            let descendant = LockedPID()
            let sink = CleanupScanProgressSink(minimumInterval: 0) { event in
                descendant.set(Int32((event.currentPath as NSString).lastPathComponent) ?? 0)
            }
            let task = Task { await CleanupScanProcess.testScan(worker: realWorker, home: descendantHome.path,
                control: control, progress: sink) }
            try await waitUntil { descendant.get() > 0 }
            let group = getpgid(descendant.get())
            try expect(group > 1 && group != getpgrp() && getpgid(group) == group,
                       "POSIX descendant escaped the worker process group")
            if taskCancellation { task.cancel() } else { control.cancel() }
            let cancelled = await task.value
            try expect(!cancelled.succeeded, "cancelled descendant scan succeeded")
            try await waitUntil { kill(descendant.get(), 0) != 0 && kill(group, 0) != 0 }
        }
        let timedDescendant = LockedPID()
        let timed = await CleanupScanProcess.testScan(worker: realWorker,
            home: root.appendingPathComponent("process-timeout-descendant").path,
            progress: CleanupScanProgressSink(minimumInterval: 0) { event in
                timedDescendant.set(Int32((event.currentPath as NSString).lastPathComponent) ?? 0)
            })
        try expect(!timed.succeeded && timedDescendant.get() > 0, "worker command timeout fixture failed")
        try await waitUntil { kill(timedDescendant.get(), 0) != 0 }
        print("process group: real POSIX descendant is reaped after control/Task cancellation and timeout")

        // Real worker touches only the nonce home, with an injected empty
        // presence context. No fixture path resolves to the user's home.
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".Trash"), withIntermediateDirectories: true)
        let item = home.appendingPathComponent(".Trash/own-fixture.txt")
        try Data(repeating: 65, count: 4096).write(to: item)
        let oldCache = home.appendingPathComponent(".npm/_cacache")
        try FileManager.default.createDirectory(at: oldCache, withIntermediateDirectories: true)
        let oldLeaf = oldCache.appendingPathComponent("payload")
        try Data(repeating: 66, count: 4096).write(to: oldLeaf)
        let oldSeconds = Int(Date().timeIntervalSince1970) - 9 * 86400
        // APFS coalesces reads when atime >= mtime. Make atime older so
        // the real kernel pread must exercise an atime-only change.
        var oldTimes = [timeval(tv_sec: oldSeconds - 86400, tv_usec: 0), timeval(tv_sec: oldSeconds, tv_usec: 0)]
        try expect(utimes(oldLeaf.path, &oldTimes) == 0 && utimes(oldCache.path, &oldTimes) == 0, "could not age own cache fixture")
        var signedWorker: SecStaticCode?, signature: CFDictionary?
        try expect(SecStaticCodeCreateWithPath(realWorker as CFURL, [], &signedWorker) == errSecSuccess, "fixture code unavailable")
        try expect(SecCodeCopySigningInformation(signedWorker!, SecCSFlags(rawValue: kSecCSSigningInformation), &signature) == errSecSuccess,
                   "fixture signature unavailable")
        let codeHash = (signature as! [String: Any])[kSecCodeInfoUnique as String] as! Data
        let wrongHash = await CleanupScanProcess.testScan(worker: realWorker, home: home.path,
            expectedCodeHash: Data(repeating: 0, count: codeHash.count))
        try expect(!wrongHash.succeeded && wrongHash.categories.isEmpty, "actual child code hash mismatch was accepted")
        let real = await CleanupScanProcess.testScan(worker: realWorker, home: home.path, expectedCodeHash: codeHash)
        try expect(real.succeeded && real.categories.flatMap(\.paths).contains(item.path),
                   "real worker fixture scan failed: \(real.error ?? "") \(real.diagnostics) paths=\(real.categories.flatMap(\.paths))")
        try expect(FileManager.default.fileExists(atPath: item.path), "read-only worker modified fixture")
        var afterScan = stat()
        try expect(lstat(oldLeaf.path, &afterScan) == 0, "old cache fixture disappeared")
        let oldCategory = real.categories.filter { $0.paths.contains(oldCache.path) }
        try expect(oldCategory.first?.isPathSelected(oldCache.path) == true, "child lost the old cache activity proof")
        let freshParent = NativeCore(cleanupOpenFileProbe: { [] })
        let reviewed = await Task.detached(priority: .utility) {
            freshParent.preflightCleanupCategories(oldCategory, homeDirectory: home.path,
                control: .init(mode: .deep), includingAdministratorRequired: true)
        }.value
        let parentStillSelected = reviewed.categories.first?.isPathSelected(oldCache.path) == true
        try expect(afterScan.st_atimespec.tv_sec > oldSeconds && !parentStillSelected,
                   "real pread/drop-proof control did not exercise cross-process age evidence")
        try await inspectionHandoffTests(home: home, oldLeaf: oldLeaf, oldCache: oldCache,
            oldCategory: oldCategory, realWorker: realWorker)
        print("real own-read: kernel atime advanced; unrelated fresh parent drops proof; explicit trusted pipe handoff retains age")

        let terminalHome = root.appendingPathComponent("terminal-observations")
        try FileManager.default.createDirectory(at: terminalHome, withIntermediateDirectories: true)
        let terminalLeaf = terminalHome.appendingPathComponent("payload")
        try Data(repeating: 67, count: 4096).write(to: terminalLeaf)
        var terminalTimes = [timeval(tv_sec: Int(Date().timeIntervalSince1970), tv_usec: 0),
                             timeval(tv_sec: oldSeconds, tv_usec: 0)]
        try expect(utimes(terminalLeaf.path, &terminalTimes) == 0, "could not prepare terminal observation fixture")
        for mode in ["observation-exit", "observation-duplicate", "observation-bad-id", "observation-success"] {
            let fake = try executable("fixture-" + mode)
            let outcome = await CleanupScanProcess.testScan(worker: fake, home: terminalHome.path)
            let imported = NativeCore.shared.exportCleanupInspectionObservations(homeDirectory: terminalHome.path)
                .contains { $0.path == terminalLeaf.path }
            try expect(outcome.succeeded == (mode == "observation-success")
                && imported == (mode == "observation-success"),
                "temporary evidence imported before valid terminal frame and normal exit: \(mode)")
        }
        print("handoff import gate: nonzero exit, duplicate terminal and wrong id discard observations")

        let driver = try executable("orphan-driver")
        let process = Process()
        process.executableURL = driver; process.arguments = [realWorker.path, root.path]
        try process.run()
        process.waitUntilExit()
        let pidPath = root.appendingPathComponent("orphan.pid")
        let orphanPID = Int32(try String(contentsOf: pidPath, encoding: .utf8))!
        let orphanDescendant = Int32(try String(contentsOf: root.appendingPathComponent("orphan.descendant.pid"), encoding: .utf8))!
        try await waitUntil { kill(orphanPID, 0) != 0 && kill(orphanDescendant, 0) != 0 }
        print("real worker: nonce scan is read-only; parent-exit watchdog reaped worker and POSIX descendant")
    }

    @MainActor
    private static func inspectionHandoffTests(home: URL, oldLeaf: URL, oldCache: URL,
                                               oldCategory: [CleanupCategory], realWorker: URL) async throws {
        let observations = NativeCore.shared.exportCleanupInspectionObservations(homeDirectory: home.path)
        guard let leaf = observations.first(where: { $0.path == oldLeaf.path }) else {
            throw TestError.failure("signed worker reply did not import its real read observation")
        }
        let request = CleanupScanProtocol.Request(home: home.path, mode: .deep, presence: nil,
            includingAdministratorRequired: true, excludingRoots: [], parentPID: getpid(), parentUID: getuid(),
            observations: observations)
        let requestBytes = try CleanupScanProtocol.encodeRequest(request)
        let decoded = try CleanupScanProtocol.decodeRequest(Data(requestBytes.dropFirst(4)))
        try expect(decoded.observations == observations, "request lost temporary observation metadata")
        let frame = try CleanupScanProtocol.encodeFrame(.result(fixtureScan(home: home.path),
            observations: observations, id: request.id))
        let reply = try CleanupScanProtocol.decodeFrame(Data(frame.dropFirst(4)), id: request.id)
        try expect(reply.observations == observations, "reply lost temporary observation metadata")

        let seeded = NativeCore(cleanupOpenFileProbe: { [] })
        try expect(seeded.importTrustedCleanupInspectionObservations(observations, homeDirectory: home.path) > 0,
                   "explicit trusted import rejected fresh same-object evidence")
        let reviewed = await Task.detached(priority: .utility) {
            seeded.preflightCleanupCategories(oldCategory, homeDirectory: home.path,
                control: .init(mode: .deep), includingAdministratorRequired: true)
        }.value
        try expect(reviewed.categories.first?.isPathSelected(oldCache.path) == true,
                   "trusted imported observation lost the old cache age")
        for preflight in [false, true] {
            let next = await CleanupScanProcess.testScan(worker: realWorker, home: home.path, mode: .deep,
                cachedCategories: preflight ? oldCategory : nil)
            try expect(next.succeeded && next.categories.contains { $0.isPathSelected(oldCache.path) },
                       "deep/preflight child did not receive the live parent observation seed")
            let exported = NativeCore.shared.exportCleanupInspectionObservations(homeDirectory: home.path)
            guard let carried = exported.first(where: { $0.path == oldLeaf.path }) else {
                throw TestError.failure("cross-hop observation disappeared")
            }
            try expect(carried.firstObservedContinuousTicks == leaf.firstObservedContinuousTicks
                && carried.expiresAtContinuousTicks == leaf.expiresAtContinuousTicks,
                "quick/deep/preflight handoff renewed the first 300-second deadline")
        }
        print("handoff: typed request/reply roundtrip, parent fresh validation, deep/preflight seed and unchanged absolute expiry passed")
    }

    private final class LockedPID: @unchecked Sendable {
        private let lock = NSLock(); private var value: Int32 = 0
        func set(_ pid: Int32) { lock.lock(); value = pid; lock.unlock() }
        func get() -> Int32 { lock.lock(); defer { lock.unlock() }; return value }
    }
    private static func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !predicate() {
            try expect(ProcessInfo.processInfo.systemUptime < deadline, "process lifecycle condition timed out")
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private static func fakeWorker(_ mode: String) async throws {
        guard let body = try CleanupScanPipe.readFrame(STDIN_FILENO,
            limit: CleanupScanProtocol.maximumRequestBytes, check: {}) else { _exit(65) }
        let request = try CleanupScanProtocol.decodeRequest(body)
        if mode == "hang" {
            signal(SIGTERM, SIG_IGN)
            try CleanupScanPipe.write(CleanupScanProtocol.encodeFrame(.progress(.init(phase: "native", completed: 0,
                total: 1, currentPath: "/fixture/\(getpid())"), id: request.id)), fd: STDOUT_FILENO, check: {})
            let end = ProcessInfo.processInfo.systemUptime + 10
            while ProcessInfo.processInfo.systemUptime < end { _ = poll(nil, 0, 100) }
            _exit(99)
        }
        if mode == "empty" { return }
        if mode == "bad" { try CleanupScanPipe.write(Data([0, 0, 0, 1, 255]), fd: STDOUT_FILENO, check: {}); return }
        if mode == "truncated" { try CleanupScanPipe.write(Data([0, 0, 0, 8, 123]), fd: STDOUT_FILENO, check: {}); return }
        if mode == "oversized" { try CleanupScanPipe.write(Data([255, 255, 255, 255]), fd: STDOUT_FILENO, check: {}); return }
        let scan = fixtureScan(home: request.home, count: mode == "large" ? 100_000 : 2)
        var observations: [NativeCore.CleanupInspectionObservation] = []
        if mode.hasPrefix("observation-") {
            let path = request.home + "/payload"
            var observed = stat()
            guard lstat(path, &observed) == 0 else { _exit(65) }
            var original = observed
            original.st_atimespec.tv_sec -= 10 * 86400
            // Test-only factory is absent from every production worker build.
            observations = [NativeCore.cleanupInspectionObservationForTesting(path: path,
                original: original, observed: observed)]
        }
        let framed = try CleanupScanProtocol.encodeFrame(.result(scan, observations: observations,
            id: mode == "observation-bad-id" ? UUID() : request.id))
        try CleanupScanPipe.write(framed, fd: STDOUT_FILENO, check: {})
        if mode == "duplicate" || mode == "observation-duplicate" {
            try CleanupScanPipe.write(framed, fd: STDOUT_FILENO, check: {})
        }
        if mode == "exit" || mode == "observation-exit" { _exit(9) }
    }

    private static func orphanDriver() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        output.fileHandleForWriting.closeFile()
        input.fileHandleForReading.closeFile()
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        let request = CleanupScanProtocol.Request(home: root.appendingPathComponent("process-lifetime-descendant").path,
            mode: .quick, presence: AgentPresenceContext(applicationDirs: [], searchPath: []),
            includingAdministratorRequired: false, excludingRoots: [], parentPID: getpid(), parentUID: getuid())
        try CleanupScanPipe.write(CleanupScanProtocol.encodeRequest(request), fd: input.fileHandleForWriting.fileDescriptor, check: {})
        input.fileHandleForWriting.closeFile()
        guard let bytes = try CleanupScanPipe.readFrame(output.fileHandleForReading.fileDescriptor,
                limit: CleanupScanProtocol.maximumProgressBytes, check: {}),
              let event = try CleanupScanProtocol.decodeFrame(bytes, id: request.id).progress,
              let descendant = Int32((event.currentPath as NSString).lastPathComponent) else {
            throw TestError.failure("parent-exit descendant did not launch")
        }
        try expect(getpgid(descendant) == process.processIdentifier, "parent-exit descendant escaped worker group")
        try String(process.processIdentifier).write(to: root.appendingPathComponent("orphan.pid"), atomically: true, encoding: .utf8)
        try String(descendant).write(to: root.appendingPathComponent("orphan.descendant.pid"), atomically: true, encoding: .utf8)
        _ = poll(nil, 0, 350)
        // A real, long-lived POSIX descendant is alive when the driver exits.
        _exit(0)
    }
}
