import AppKit
import Darwin
import Foundation

// 原生进程采样（libproc）。替代 `ps` 文本：
// - CPU 用两次采样之间的 CPU 时间差 / 墙钟时间差，是"当前占用"而不是 ps 的
//   进程生命周期平均值；
// - 内存直接取常驻集字节数；
// - 每个进程带启动时间，构成跨采样稳定的身份，动作前重新采样核对，PID
//   复用也不会误杀新进程。

/// PID、启动时间与用户确定同一个进程；父进程仅记录关系。
/// 父进程退出后被 launchd 接管，不会改变进程身份。
struct ProcessIdentity: Hashable, Sendable {
    let pid: Int32
    let startTime: UInt64
    let ppid: Int32
    let uid: UInt32

    func isSameProcess(as other: ProcessIdentity) -> Bool {
        pid == other.pid && startTime == other.startTime && uid == other.uid
    }
}

struct ProcessSample: Equatable, Sendable {
    let identity: ProcessIdentity
    var pid: Int32 { identity.pid }
    var ppid: Int32 { identity.ppid }
    var uid: UInt32 { identity.uid }
    let name: String
    let path: String
    /// 百分比（单核 100%，与活动监视器一致）；首个采样没有基线时为 0。
    let cpuPercent: Double
    let residentBytes: UInt64
    let isZombie: Bool
    let isExiting: Bool
    /// 进程已运行秒数。
    let elapsed: TimeInterval

    var lifecycle: ProcessLifecycle {
        if isZombie { return .zombie }
        if isExiting { return .exiting }
        return .normal
    }
}

/// 采样器持有上一轮的 CPU 时间基线，因此要用同一个实例连续采样。
final class ProcessSampler: @unchecked Sendable {
    static let shared = ProcessSampler()

    struct Snapshot: Sendable {
        let processes: [ProcessSample]
        let isComplete: Bool
    }

    private struct Baseline {
        let cpuTimeNanoseconds: UInt64
        let startTime: UInt64
        let sampledAt: TimeInterval
    }

    private let lock = NSLock()
    private var baselines: [Int32: Baseline] = [:]
    private let timebase: Double

    init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = info.denom == 0 ? 1 : Double(info.numer) / Double(info.denom)
    }

    /// 采样所有可见进程。系统对其他用户的进程只给出有限信息，这些进程不会
    /// 出现在结果里（也不允许被操作）。
    func sample() -> [ProcessSample] {
        snapshot().processes
    }

    /// Mutation preflight must distinguish an unreadable process table from
    /// an idle installation. Read-only status views may keep using sample().
    func snapshot() -> Snapshot {
        guard let pids = Self.allPIDs() else { return .init(processes: [], isComplete: false) }
        let now = Date().timeIntervalSince1970
        var result: [ProcessSample] = []
        result.reserveCapacity(pids.count)
        var nextBaselines: [Int32: Baseline] = [:]
        var complete = pids.contains(ProcessInfo.processInfo.processIdentifier)

        lock.lock()
        let previous = baselines
        lock.unlock()

        for pid in pids where pid > 0 {
            var bsd = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else { continue }
            var task = proc_taskinfo()
            let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
            let hasTask = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize

            let startTime = bsd.pbi_start_tvsec * 1_000_000 + bsd.pbi_start_tvusec
            let cpuTime = hasTask
                ? UInt64(Double(task.pti_total_user &+ task.pti_total_system) * timebase)
                : 0
            var cpuPercent = 0.0
            if let base = previous[pid], base.startTime == startTime, hasTask {
                let wall = now - base.sampledAt
                if wall > 0.05, cpuTime >= base.cpuTimeNanoseconds {
                    cpuPercent = Double(cpuTime - base.cpuTimeNanoseconds) / (wall * 1_000_000_000) * 100
                }
            }
            nextBaselines[pid] = Baseline(cpuTimeNanoseconds: cpuTime, startTime: startTime, sampledAt: now)

            let identity = ProcessIdentity(pid: pid, startTime: startTime,
                                           ppid: Int32(bitPattern: bsd.pbi_ppid), uid: bsd.pbi_uid)
            let path = Self.path(of: pid)
            if path.isEmpty, bsd.pbi_uid == getuid(), bsd.pbi_status != UInt32(SZOMB),
               bsd.pbi_flags & UInt32(PROC_FLAG_INEXIT) == 0 {
                // A process can exit during sampling. Only a still-live process
                // whose executable cannot be read makes ownership uncertain.
                var fresh = proc_bsdinfo()
                if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &fresh, bsdSize) == bsdSize,
                   fresh.pbi_start_tvsec == bsd.pbi_start_tvsec,
                   fresh.pbi_start_tvusec == bsd.pbi_start_tvusec,
                   fresh.pbi_status != UInt32(SZOMB),
                   fresh.pbi_flags & UInt32(PROC_FLAG_INEXIT) == 0 {
                    complete = false
                }
            }
            let name = Self.name(from: bsd, path: path)
            let elapsed = max(0, now - Double(bsd.pbi_start_tvsec))
            result.append(ProcessSample(identity: identity, name: name, path: path,
                                        cpuPercent: cpuPercent,
                                        residentBytes: hasTask ? task.pti_resident_size : 0,
                                        isZombie: bsd.pbi_status == UInt32(SZOMB),
                                        isExiting: (bsd.pbi_flags & UInt32(PROC_FLAG_INEXIT)) != 0,
                                        elapsed: elapsed))
        }

        lock.lock()
        baselines = nextBaselines
        lock.unlock()
        return .init(processes: result, isComplete: complete)
    }

    /// 重新采样单个进程，用来在动作前核对身份。
    func current(for identity: ProcessIdentity) -> ProcessSample? {
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(identity.pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else { return nil }
        let startTime = bsd.pbi_start_tvsec * 1_000_000 + bsd.pbi_start_tvusec
        guard startTime == identity.startTime, bsd.pbi_uid == identity.uid else { return nil }
        let freshIdentity = ProcessIdentity(pid: identity.pid, startTime: startTime,
                                            ppid: Int32(bitPattern: bsd.pbi_ppid), uid: bsd.pbi_uid)
        let path = Self.path(of: identity.pid)
        return ProcessSample(identity: freshIdentity, name: Self.name(from: bsd, path: path), path: path,
                             cpuPercent: 0, residentBytes: 0,
                             isZombie: bsd.pbi_status == UInt32(SZOMB),
                             isExiting: (bsd.pbi_flags & UInt32(PROC_FLAG_INEXIT)) != 0,
                             elapsed: 0)
    }

    // MARK: - libproc helpers

    private static func allPIDs() -> [Int32]? {
        var count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        // 留出余量：两次调用之间可能有新进程。
        var buffer = [Int32](repeating: 0, count: Int(count) + 64)
        count = proc_listallpids(&buffer, Int32(buffer.count * MemoryLayout<Int32>.size))
        guard count > 0, Int(count) < buffer.count else { return nil }
        return Array(buffer.prefix(Int(count)))
    }

    private static func path(of pid: Int32) -> String {
        // PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN（宏在 Swift 里不可用）。
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        if length > 0 { return String(cString: buffer) }
        // Updating an app can unlink the executable of a surviving helper.
        // libproc then reports ENOENT even though the process is still alive.
        // The kernel's launch path remains available before argv in this
        // buffer; argv[0] is user-controlled and is never a path fallback.
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size, size <= 1_048_576 else { return "" }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &bytes, &size, nil, 0) == 0 else { return "" }
        let start = MemoryLayout<Int32>.size
        guard size > start, let end = bytes[start..<size].firstIndex(of: 0),
              let path = String(bytes: bytes[start..<end], encoding: .utf8), path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return "" }
        return path
    }

    private static func name(from info: proc_bsdinfo, path: String) -> String {
        if !path.isEmpty {
            let last = (path as NSString).lastPathComponent
            if !last.isEmpty { return last }
        }
        let name = withUnsafePointer(to: info.pbi_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        if !name.isEmpty { return name }
        return withUnsafePointer(to: info.pbi_comm) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN + 1)) { String(cString: $0) }
        }
    }
}

// MARK: - 聚合与安全边界

/// 按应用聚合后的一组进程：主进程 + 进程树里的子进程。
struct ProcessGroup: Identifiable, Equatable, Sendable {
    let app: ProcessRow
    let children: [ProcessRow]
    var bundlePath: String? = nil
    var members: [ProcessSample] = []
    var isBackgroundOnly = false
    var id: Int32 { app.pid }
    var totalCPU: Double { app.cpu }
    var totalBytes: UInt64 { app.memBytes }
}

/// Ownership is established by a canonical bundle path or an observed parent
/// chain. Process names, vendor prefixes and arbitrary command arguments are
/// never evidence of ownership.
struct ApplicationProcessScope: Equatable, Sendable {
    let root: String
    var independentRoots: Set<String>

    init(root: String, independentRoots: Set<String> = []) {
        self.root = Self.canonical(root)
        self.independentRoots = independentRoots
    }

    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func bundlePath(of path: String) -> String? {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        let components = canonical(path).split(separator: "/")
        for index in components.indices where components[index].hasSuffix(".app") {
            guard index + 1 < components.count, components[index + 1] == "Contents" else { continue }
            let root = "/" + components[...index].joined(separator: "/")
            return ProcessAggregator.isProtectedPath(root) ? nil : root
        }
        return nil
    }

    func contains(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return false }
        return Self.canonical(path).hasPrefix(root + "/")
    }

    func processes(in samples: [ProcessSample], remembering known: [ProcessSample] = [],
                   canonicalPaths suppliedPaths: [String: String]? = nil) -> [ProcessSample] {
        let paths = suppliedPaths ?? Dictionary(Set(samples.map(\.path)).map { ($0, Self.canonical($0)) },
                                                uniquingKeysWith: { a, _ in a })
        let remembered = Dictionary(known.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        func independent(_ sample: ProcessSample) -> Bool {
            guard !independentRoots.isEmpty, let path = paths[sample.path] else { return false }
            return independentRoots.contains { path.hasPrefix($0 + "/") }
        }
        var owned = Set(samples.filter { sample in
            guard !sample.isZombie, !independent(sample) else { return false }
            if sample.path.hasPrefix("/"), !sample.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
               paths[sample.path]?.hasPrefix(root + "/") == true { return true }
            guard let old = remembered[sample.pid] else { return false }
            return old.identity.isSameProcess(as: sample.identity) && old.path == sample.path
        }.map(\.pid))
        // Fixed-point expansion handles arbitrary sample order and grandchildren.
        for _ in 0..<64 {
            let next = samples.filter { !$0.isZombie && !independent($0) && owned.contains($0.ppid) }.map(\.pid)
            let count = owned.count
            owned.formUnion(next)
            if count == owned.count { break }
        }
        return samples.filter { owned.contains($0.pid) }
    }

    static func belongsToOwnTree(_ pid: Int32, ownPID: Int32, samples: [ProcessSample]) -> Bool {
        let byPID = Dictionary(samples.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        func isAncestor(_ ancestor: Int32, of child: Int32) -> Bool {
            var current = child
            var seen = Set<Int32>()
            while current > 1, seen.insert(current).inserted {
                if current == ancestor { return true }
                current = byPID[current]?.ppid ?? 0
            }
            return false
        }
        return isAncestor(pid, of: ownPID) || isAncestor(ownPID, of: pid)
    }
}

enum ProcessSort: String, CaseIterable {
    case memory, cpu, name
    var l10nKey: String { "proc.sort.\(rawValue)" }
}

enum ProcessAggregator {
    /// 系统与自身进程树永不出现在可操作列表里。
    static let protectedPathPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/private/"]

    static func isProtectedPath(_ path: String) -> Bool {
        protectedPathPrefixes.contains { path.hasPrefix($0) }
    }

    /// 沿父进程链找到所属的应用主进程；链上先遇到的应用即归属。
    static func owningApplicationPID(of sample: ProcessSample,
                                     applicationPIDs: Set<Int32>,
                                     byPID: [Int32: ProcessSample]) -> Int32? {
        var current = sample
        var steps = 0
        while steps < 64 {
            if applicationPIDs.contains(current.pid) { return current.pid }
            guard current.ppid > 1, let parent = byPID[current.ppid] else { return nil }
            current = parent
            steps += 1
        }
        return nil
    }

    /// Combine live application ancestry with physical bundle ownership. Bundle
    /// helpers remain visible even after reparenting to launchd. Previously
    /// observed descendants retain ownership only while start identity AND
    /// executable match, so an exec or PID reuse cannot inherit that scope.
    static func groups(samples: [ProcessSample],
                       applications: [(pid: Int32, name: String, startIdentity: String)],
                       ownPID: Int32,
                       previous: [ProcessGroup] = [],
                       detail: (Int32) -> String,
                       childDetail: (ProcessSample) -> String) -> [ProcessGroup] {
        let byPID = Dictionary(samples.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let canonicalPaths = Dictionary(Set(samples.map(\.path)).filter { !$0.isEmpty }.map {
            ($0, ApplicationProcessScope.canonical($0))
        }, uniquingKeysWith: { a, _ in a })
        let ownRoot = byPID[ownPID].flatMap { ApplicationProcessScope.bundlePath(of: $0.path) }
        let live = applications.filter { $0.pid != ownPID && byPID[$0.pid] != nil }
        let roots = Set(samples.compactMap { ApplicationProcessScope.bundlePath(of: $0.path) } + previous.compactMap(\.bundlePath))
        let liveRoots = Set(live.compactMap { byPID[$0.pid].flatMap { ApplicationProcessScope.bundlePath(of: $0.path) } })
        var assigned = Set<Int32>()
        var result: [ProcessGroup] = []
        func row(_ sample: ProcessSample, name: String? = nil, identity: String? = nil,
                 totalCPU: Double? = nil, totalBytes: UInt64? = nil, native: Bool = false) -> ProcessRow {
            let bytes = totalBytes ?? sample.residentBytes
            return ProcessRow(pid: sample.pid, startIdentity: identity ?? String(sample.identity.startTime, radix: 16),
                              name: name ?? sample.name, detail: native ? detail(sample.pid) : childDetail(sample),
                              isNativeApp: native, cpu: totalCPU ?? sample.cpuPercent,
                              mem: percentOfPhysicalMemory(bytes), memBytes: bytes,
                              ppid: sample.ppid, uid: sample.uid,
                              state: sample.isZombie ? "Z" : (sample.isExiting ? "E" : "S"), elapsed: sample.elapsed)
        }
        let candidates = roots.filter { $0 != ownRoot }.map { root in
            let scope = ApplicationProcessScope(root: root, independentRoots: liveRoots.subtracting([root]))
            let remembered = previous.filter { $0.bundlePath == root }.flatMap(\.members)
            return (root: root, members: scope.processes(in: samples, remembering: remembered, canonicalPaths: canonicalPaths))
        }.sorted { lhs, rhs in
            if liveRoots.contains(lhs.root) != liveRoots.contains(rhs.root) { return liveRoots.contains(lhs.root) }
            if lhs.members.count != rhs.members.count { return lhs.members.count > rhs.members.count }
            return lhs.root < rhs.root
        }
        for candidate in candidates {
            let root = candidate.root
            let members = candidate.members.filter { $0.pid != ownPID && !assigned.contains($0.pid) }
            guard !members.isEmpty else { continue }
            let bundle = Bundle(path: root)
            let executable = bundle?.executablePath.map(ApplicationProcessScope.canonical)
            let application = live.first {
                guard let path = byPID[$0.pid].flatMap({ canonicalPaths[$0.path] }) else { return false }
                return path == executable
            } ?? live.first {
                byPID[$0.pid].flatMap { canonicalPaths[$0.path] }?.hasPrefix(root + "/Contents/MacOS/") == true
            }
            let main = application.flatMap { byPID[$0.pid] } ?? members.min { $0.pid < $1.pid }!
            let name = application?.name ?? previous.first(where: { $0.bundlePath == root })?.app.name ?? (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? URL(fileURLWithPath: root).deletingPathExtension().lastPathComponent
            let totalCPU = members.reduce(0) { $0 + $1.cpuPercent }
            let totalBytes = members.reduce(UInt64(0)) { $0 + $1.residentBytes }
            let children = members.filter { application == nil || $0.pid != main.pid }.sorted { $0.residentBytes > $1.residentBytes }.map { row($0) }
            result.append(ProcessGroup(app: row(main, name: name, identity: application?.startIdentity,
                                                totalCPU: totalCPU, totalBytes: totalBytes, native: true),
                                       children: children, bundlePath: root, members: members,
                                       isBackgroundOnly: application == nil))
            assigned.formUnion(members.map(\.pid))
        }
        // Preserve native rows for apps whose executable is outside a .app.
        let applicationPIDs = Set(live.map(\.pid))
        for application in live where !assigned.contains(application.pid) {
            guard let main = byPID[application.pid], !isProtectedPath(main.path) else { continue }
            let members = samples.filter {
                !assigned.contains($0.pid) && $0.pid != ownPID &&
                    owningApplicationPID(of: $0, applicationPIDs: applicationPIDs, byPID: byPID) == main.pid
            }
            result.append(ProcessGroup(app: row(main, name: application.name, identity: application.startIdentity,
                                                totalCPU: members.reduce(0) { $0 + $1.cpuPercent },
                                                totalBytes: members.reduce(0) { $0 + $1.residentBytes }, native: true),
                                       children: members.filter { $0.pid != main.pid }.map { row($0) }, members: members))
        }
        return result
    }

    static func sorted(_ groups: [ProcessGroup], by sort: ProcessSort) -> [ProcessGroup] {
        groups.sorted { lhs, rhs in
            switch sort {
            case .memory:
                if lhs.totalBytes != rhs.totalBytes { return lhs.totalBytes > rhs.totalBytes }
            case .cpu:
                if lhs.totalCPU != rhs.totalCPU { return lhs.totalCPU > rhs.totalCPU }
            case .name:
                break
            }
            return lhs.app.name.localizedCaseInsensitiveCompare(rhs.app.name) == .orderedAscending
        }
    }

    /// 搜索匹配应用名或任一子进程名 / PID。
    static func filter(_ groups: [ProcessGroup], query: String) -> [ProcessGroup] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return groups }
        return groups.filter { group in
            if group.app.name.localizedCaseInsensitiveContains(needle) { return true }
            if String(group.app.pid) == needle { return true }
            return group.children.contains {
                $0.name.localizedCaseInsensitiveContains(needle) || String($0.pid) == needle
            }
        }
    }

    static func percentOfPhysicalMemory(_ bytes: UInt64) -> Double {
        let physical = ProcessInfo.processInfo.physicalMemory
        guard physical > 0 else { return 0 }
        return Double(bytes) / Double(physical) * 100
    }
}

// MARK: - 高占用跟踪

/// 连续高占用提醒：CPU ≥ 阈值持续 N 秒，或内存超过阈值。
struct HighUsageTracker: Equatable {
    var cpuThreshold: Double = 80
    var cpuDuration: TimeInterval = 30
    var memoryThreshold: UInt64 = 4 * 1024 * 1024 * 1024
    private var cpuSince: [Int32: TimeInterval] = [:]

    struct Alert: Equatable, Identifiable {
        enum Reason: Equatable { case cpu, memory }
        let pid: Int32
        let name: String
        let reason: Reason
        var id: String { "\(pid)-\(reason)" }
    }

    mutating func update(_ groups: [ProcessGroup], now: TimeInterval = Date().timeIntervalSince1970) -> [Alert] {
        var alerts: [Alert] = []
        var seen = Set<Int32>()
        for group in groups {
            seen.insert(group.app.pid)
            if group.totalCPU >= cpuThreshold {
                let since = cpuSince[group.app.pid] ?? now
                cpuSince[group.app.pid] = since
                if now - since >= cpuDuration {
                    alerts.append(Alert(pid: group.app.pid, name: group.app.name, reason: .cpu))
                }
            } else {
                cpuSince.removeValue(forKey: group.app.pid)
            }
            if group.totalBytes >= memoryThreshold {
                alerts.append(Alert(pid: group.app.pid, name: group.app.name, reason: .memory))
            }
        }
        cpuSince = cpuSince.filter { seen.contains($0.key) }
        return alerts
    }
}

/// 每个应用最近 N 个采样的 CPU 历史，供趋势线使用。
struct ProcessHistory: Equatable {
    let capacity: Int
    private(set) var cpu: [Int32: [Double]] = [:]

    init(capacity: Int = 30) { self.capacity = capacity }

    mutating func record(_ groups: [ProcessGroup]) {
        var next: [Int32: [Double]] = [:]
        for group in groups {
            var series = cpu[group.app.pid] ?? []
            series.append(group.totalCPU)
            if series.count > capacity { series.removeFirst(series.count - capacity) }
            next[group.app.pid] = series
        }
        cpu = next
    }

    func series(for pid: Int32) -> [Double] { cpu[pid] ?? [] }
}

// MARK: - 结束进程

enum ProcessTerminator {
    enum Refusal: Error, Equatable {
        case identityChanged
        case otherUser
        case protectedPath
        case ownProcessTree
    }

    /// 结束前的安全核对：身份未变、同一用户、非系统路径、不在自己的进程树里。
    static func validate(_ identity: ProcessIdentity, sampler: ProcessSampler = .shared,
                         ownPID: Int32 = ProcessInfo.processInfo.processIdentifier,
                         ownUID: UInt32 = getuid()) -> Result<ProcessSample, Refusal> {
        guard let current = sampler.current(for: identity) else { return .failure(.identityChanged) }
        if current.pid == ownPID || current.ppid == ownPID { return .failure(.ownProcessTree) }
        guard current.uid == ownUID else { return .failure(.otherUser) }
        guard !ProcessAggregator.isProtectedPath(current.path) else { return .failure(.protectedPath) }
        return .success(current)
    }

    /// SIGTERM → 等待 → 仍在则 SIGKILL。返回进程是否已经消失。
    static func terminateThenKill(_ identity: ProcessIdentity, grace: TimeInterval,
                                  sampler: ProcessSampler = .shared) async -> Bool {
        guard case .success = validate(identity, sampler: sampler) else { return false }
        kill(identity.pid, SIGTERM)
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if sampler.current(for: identity) == nil { return true }
        }
        guard case .success = validate(identity, sampler: sampler) else { return true }
        kill(identity.pid, SIGKILL)
        try? await Task.sleep(nanoseconds: 300_000_000)
        return sampler.current(for: identity) == nil
    }
}
