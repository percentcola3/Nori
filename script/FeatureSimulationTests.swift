import AppKit
import Darwin
import Foundation

/// Deterministic cross-product scenarios; expected outcomes come from public
/// safety contracts, not snapshots copied from the implementation.
enum FeatureSimulationTests {
    static let fm = FileManager.default
    static var scenarios = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NSError(domain: "FeatureSimulation", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func write(_ path: URL, data: Data = Data(repeating: 83, count: 4096)) throws {
        try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: path)
    }
    static func run(_ fixture: URL) async throws {
        try await deletionMatrix(fixture)
        try await schedulingMatrix(fixture)
        try inventoryMatrix(fixture)
        try ageMatrix()
        try feedbackMatrix()
        try permissionMatrix(fixture)
        print("PASS feature simulations: \(scenarios) independent scenarios")
    }
    static func deletionMatrix(_ fixture: URL) async throws {
        // Different disposal routes: generic cache, developer cache, Xcode,
        // browser, log and explicit Trash. Use production scan identities.
        let roots = ["Library/Caches/com.example.fixture", ".npm/_cacache",
                     "Library/Developer/Xcode/DerivedData/Fixture", ".cargo/registry/cache",
                     "Library/Application Support/Google/Chrome/Default/Cache", "Library/Logs/Fixture", ".Trash/Fixture"]
        let names = ["ordinary.cache", "空 格.cache", "name..cache", "-leading.cache"]
        let mutations = ["unchanged", "missing", "replaced", "symlink", "whitelist", "busy", "unknown", "hardlink"]
        for (route, relative) in roots.enumerated() {
            for (nameIndex, name) in names.enumerated() {
                for mutation in mutations {
                    let home = fixture.appendingPathComponent("matrix/r\(route)-n\(nameIndex)-\(mutation)/home")
                    let root = home.appendingPathComponent(relative)
                    let payload = root.appendingPathComponent(name)
                    let outside = home.appendingPathComponent("Documents/sentinel")
                    let sentinel = Data("user-owned-sentinel".utf8)
                    try write(payload); try write(outside, data: sentinel)
                    try write(home.appendingPathComponent(".config/mole/whitelist"), data: Data())
                    let core = NativeCore(cleanupOpenFileProbe: { [] })
                    let scan = await core.scanCleanup(homeDirectory: home.path, mode: .deep,
                        agentPresence: AgentPresenceContext(applicationDirs: [], searchPath: []))
                    let plan = scan.categories.flatMap { c in
                        c.paths.filter { payload.path == $0 || payload.path.hasPrefix($0 + "/") }.map {
                            DeletionPlan.Item(record: $0, identity: c.pathIdentities[$0] ?? "")
                        }
                    }
                    try check(scan.succeeded && !plan.isEmpty && plan.allSatisfy { !$0.identity.isEmpty }, "missing matrix plan \(relative) / \(name.debugDescription)")
                    var sink = core
                    switch mutation {
                    case "missing": try fm.removeItem(at: root)
                    case "replaced":
                        try fm.moveItem(at: root, to: root.deletingLastPathComponent().appendingPathComponent("saved"))
                        try write(payload, data: sentinel)
                    case "symlink":
                        try fm.removeItem(at: root)
                        try fm.createSymbolicLink(at: root, withDestinationURL: outside.deletingLastPathComponent())
                    case "whitelist": try write(home.appendingPathComponent(".config/mole/whitelist"), data: Data((root.path + "\n").utf8))
                    case "busy": sink = NativeCore(cleanupOpenFileProbe: { [payload.path] })
                    case "unknown": sink = NativeCore(cleanupOpenFileProbe: { nil })
                    case "hardlink": try fm.linkItem(at: payload, to: home.appendingPathComponent("Documents/hardlink"))
                    default: break
                    }
                    let result = sink.applyCleanup(items: plan, permanent: true, homeDirectory: home.path)
                    let permitted = mutation == "unchanged" || mutation == "hardlink"
                    try check(permitted ? result.removed > 0 && result.failed == 0 : result.removed == 0 && result.reclaimedBytes == 0,
                        "unsafe mutation result \(relative) / \(mutation): \(result.messages)")
                    try check(fm.contents(atPath: outside.path) == sentinel, "matrix touched user data")
                    if ["busy", "unknown", "whitelist", "replaced"].contains(mutation) {
                        try check(fm.fileExists(atPath: payload.path), "matrix guard lost payload")
                    }
                    if mutation == "hardlink" {
                        try check(fm.contents(atPath: home.appendingPathComponent("Documents/hardlink").path) == Data(repeating: 83, count: 4096), "hardlink survivor corrupted")
                    }
                    scenarios += 1
                    try fm.removeItem(at: home.deletingLastPathComponent())
                }
            }
        }
        print("PASS deletion matrix: 7 routes × 4 file names × 8 mutations = 224")
    }
    static func schedulingMatrix(_ fixture: URL) async throws {
        let root = fixture.appendingPathComponent("scheduling/cache")
        let old = root.appendingPathComponent("old.cache")
        let recent = root.appendingPathComponent("recent.cache")
        try write(old); try write(recent)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-10 * 86400)], ofItemAtPath: old.path)
        for policy in AutoCleanupPolicy.allCases {
            for authorized in [false, true] {
                for days in [-1, 0, 1, 7, 30] {
                    for limit in [AutoCleanupRule.minimumSizeLimitBytes - 1, AutoCleanupRule.minimumSizeLimitBytes,
                                  AutoCleanupRule.maximumSizeLimitBytes, AutoCleanupRule.maximumSizeLimitBytes + 1] {
                        let rule = AutoCleanupRule(directory: root.path, policy: policy, sizeLimitBytes: limit,
                            retentionDays: days, isRegenerable: authorized)
                        let valid = authorized && (policy == .retentionDays ? days > 0 :
                            (AutoCleanupRule.minimumSizeLimitBytes...AutoCleanupRule.maximumSizeLimitBytes).contains(limit))
                        var planned: AutoCleanupPlan?
                        do { planned = try await AutoCleanupPlanner.plan(for: rule) }
                        catch { try check(!valid, "valid schedule rejected: \(error)") }
                        try check((planned != nil) == valid, "invalid schedule admitted")
                        if let plan = planned {
                            let expected = policy == .retentionDays && days < 10 ? [old.path] : []
                            try check(plan.candidates.map(\.path) == expected, "schedule age/capacity candidates")
                            try check(plan.totalBytes == plan.remainingBytes + plan.reclaimableBytes, "schedule accounting")
                        }
                        scenarios += 1
                    }
                }
            }
        }
        print("PASS scheduling matrix: 2 policies × 2 authorizations × 5 retention values × 4 capacity bounds = 80")
    }
    static func inventoryMatrix(_ fixture: URL) throws {
        // All combinations of four Docker resources: valid empty, failure,
        // malformed and valid populated. Partial failures may never appear ready.
        let kinds = DockerResourceKind.allCases
        for encoded in 0..<256 {
            var value = encoded
            var expected = Set<DockerResourceKind>()
            let results = kinds.map { kind -> DockerInventory.CommandResult in
                let state = value % 4; value /= 4
                if state == 0 || state == 3 { expected.insert(kind) }
                let body: String
                switch kind {
                case .images: body = "{\"ID\":\"image\",\"Repository\":\"demo\",\"Tag\":\"latest\"}"
                case .containers: body = "{\"ID\":\"container\",\"Names\":\"demo\",\"State\":\"running\"}"
                case .volumes: body = "{\"Name\":\"volume\",\"Driver\":\"local\"}"
                case .buildCache: body = "{\"ID\":\"cache\",\"Description\":\"fixture\",\"InUse\":false}"
                }
                return .init(kind: kind, succeeded: state != 1,
                    output: state == 0 ? "" : state == 3 ? kind.rawValue + "\t" + body : "malformed",
                    diagnostic: state == 1 ? "injected unavailable" : "")
            }
            let report = DockerInventory.scanResult(from: results)
            try check(report.completedKinds == expected, "Docker concealed category failure")
            if expected.count == 4 { try check(report.phase == .ready, "complete Docker inventory not ready") }
            else { try check(report.phase != .ready, "partial Docker inventory presented ready") }
            scenarios += 1
        }
        for state in ["Shutdown", "shutdown", " Shutdown ", "Booted", "Creating", "Unknown", ""] {
            for available in [true, false] {
                for name in ["Phone", "设备 空格", "Fake (Shutdown)", "line\nbreak"] {
                    let row: [String: Any] = ["name": name, "udid": "11111111-1111-4111-8111-111111111111",
                        "state": state, "isAvailable": available, "dataPath": "/etc"]
                    let data = try JSONSerialization.data(withJSONObject: ["devices": ["com.apple.CoreSimulator.SimRuntime.iOS-18-0": [row]]])
                    let devices = try SimulatorInventory.decodeDevices(String(decoding: data, as: UTF8.self), homeDirectory: fixture)
                    try check(devices.count == 1 && devices[0].name == name, "Simulator lost valid identity/name")
                    try check(devices[0].canDeleteManually == (state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "shutdown"), "Simulator unknown/running state admitted")
                    scenarios += 1
                }
            }
        }
        print("PASS inventory matrix: 256 Docker result combinations + 56 Simulator states/names")
    }
    static func ageMatrix() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let offsets: [Double?] = [nil, -2_000_000, -604801, -604800, -604799, -1, 0, 120, 121]
        for modified in offsets { for accessed in offsets {
            let evidence = CleanupAgePolicy.activityEvidence(modified: modified.map { now.addingTimeInterval($0) }, accessed: accessed.map { now.addingTimeInterval($0) })
            let mostRecent = [modified, accessed].compactMap { $0 }.max()
            for retention in [-1.0, 0, 1, 604800, 2_000_000] {
                let expected = retention > 0 && mostRecent.map { $0 <= 120 && -$0 >= retention } == true
                try check(CleanupAgePolicy.isStale(evidence, now: now, retention: retention) == expected, "age evidence cross-product")
                scenarios += 1
            }
        } }
        print("PASS age matrix: 9 modification × 9 access × 5 retention values = 405")
    }
    static func permissionMatrix(_ fixture: URL) throws {
        for screen in ["0", "1", "unknown", "", "2", "true"] {
            for disk in ["0", "1", "unknown", "", "2", "true"] {
                let probe = PermissionCenter.LiveProbe.parse("screen=\(screen) disk=\(disk) unrelated=1")
                try check(probe?.screenRecording == (screen == "1" ? true : screen == "0" ? false : nil), "screen helper admitted unknown authorization")
                try check(probe?.fullDiskAccess == (disk == "1" ? true : disk == "0" ? false : nil), "disk helper admitted unknown authorization")
                scenarios += 1
            }
        }
        for value in ["garbage", "", "\n", "permission=1", "screen", "screen=truex"] {
            let probe = PermissionCenter.LiveProbe.parse(value)
            try check(probe?.screenRecording != true && probe?.fullDiskAccess != true, "malformed helper became authorized")
            scenarios += 1
        }
        let readable = fixture.appendingPathComponent("permission/probe")
        try write(readable)
        try check(PermissionCenter.canOpenProtectedScanLocation(paths: [readable.path]), "readable probe not recognized")
        try check(!PermissionCenter.canOpenProtectedScanLocation(paths: [readable.path + "-missing"]), "missing probe authorized")
        scenarios += 2
        print("PASS permissions: 36 helper state pairs + 6 malformed payloads + 2 controlled read probes (no TCC changes)")
    }
    static func feedbackMatrix() throws {
        for count in [1, 10, 100, 1000] {
            var queue = TaskFeedbackQueue()
            for i in 0..<count {
                let notice = TaskFeedbackNotice(message: "failure-\(i)", details: ["detail-\(i)"])
                queue.enqueue(notice); queue.enqueue(notice)
            }
            for i in 0..<count {
                try check(queue.active?.message == "failure-\(i)", "feedback duplicate/FIFO invariant")
                queue.dismiss()
            }
            try check(queue.active == nil, "feedback queue failed to drain")
            scenarios += 1
        }
        print("PASS feedback matrix: duplicate suppression + FIFO at 1/10/100/1000 notices")
    }
}
