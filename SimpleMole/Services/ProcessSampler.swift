import AppKit
import Darwin
import Foundation

// 原生进程采样（libproc）。替代 `ps` 文本：
// - CPU 用两次采样之间的 CPU 时间差 / 墙钟时间差，是"当前占用"而不是 ps 的
//   进程生命周期平均值；
// - 内存直接取常驻集字节数；
// - 每个进程带启动时间，构成跨采样稳定的身份，动作前重新采样核对，PID
//   复用也不会误杀新进程。

/// 跨采样稳定的进程身份：PID 在进程退出后可能被复用，加上启动时间、父进程和
/// 用户就能唯一确定"当时看到的那个进程"。
struct ProcessIdentity: Hashable, Sendable {
    let pid: Int32
    let startTime: UInt64
    let ppid: Int32
    let uid: UInt32
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
        let pids = Self.allPIDs()
        let now = Date().timeIntervalSince1970
        var result: [ProcessSample] = []
        result.reserveCapacity(pids.count)
        var nextBaselines: [Int32: Baseline] = [:]

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
        return result
    }

    /// 重新采样单个进程，用来在动作前核对身份。
    func current(for identity: ProcessIdentity) -> ProcessSample? {
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(identity.pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else { return nil }
        let startTime = bsd.pbi_start_tvsec * 1_000_000 + bsd.pbi_start_tvusec
        guard startTime == identity.startTime,
              Int32(bitPattern: bsd.pbi_ppid) == identity.ppid,
              bsd.pbi_uid == identity.uid else { return nil }
        let path = Self.path(of: identity.pid)
        return ProcessSample(identity: identity, name: Self.name(from: bsd, path: path), path: path,
                             cpuPercent: 0, residentBytes: 0,
                             isZombie: bsd.pbi_status == UInt32(SZOMB),
                             isExiting: (bsd.pbi_flags & UInt32(PROC_FLAG_INEXIT)) != 0,
                             elapsed: 0)
    }

    // MARK: - libproc helpers

    private static func allPIDs() -> [Int32] {
        var count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        // 留出余量：两次调用之间可能有新进程。
        var buffer = [Int32](repeating: 0, count: Int(count) + 64)
        count = proc_listallpids(&buffer, Int32(buffer.count * MemoryLayout<Int32>.size))
        guard count > 0 else { return [] }
        return Array(buffer.prefix(Int(count)))
    }

    private static func path(of pid: Int32) -> String {
        // PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN（宏在 Swift 里不可用）。
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return String(cString: buffer)
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
    var id: Int32 { app.pid }
    var totalCPU: Double { app.cpu }
    var totalBytes: UInt64 { app.memBytes }
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

    /// 生成应用分组：每个 NSRunningApplication 一组，CPU / 内存为整棵进程树之和。
    /// `applications` 由调用方在主线程取好（NSWorkspace 不是线程安全的）。
    static func groups(samples: [ProcessSample],
                       applications: [(pid: Int32, name: String, startIdentity: String)],
                       ownPID: Int32,
                       detail: (Int32) -> String,
                       childDetail: (ProcessSample) -> String) -> [ProcessGroup] {
        let byPID = Dictionary(samples.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let applicationPIDs = Set(applications.map(\.pid))
        var usage: [Int32: (cpu: Double, bytes: UInt64)] = [:]
        var children: [Int32: [ProcessSample]] = [:]
        for sample in samples where sample.pid != ownPID {
            guard let owner = owningApplicationPID(of: sample, applicationPIDs: applicationPIDs, byPID: byPID)
            else { continue }
            var current = usage[owner] ?? (0, 0)
            current.cpu += sample.cpuPercent
            current.bytes += sample.residentBytes
            usage[owner] = current
            if sample.pid != owner { children[owner, default: []].append(sample) }
        }
        return applications.compactMap { application in
            guard let main = byPID[application.pid] else { return nil }
            let total = usage[application.pid] ?? (0, 0)
            let row = ProcessRow(pid: application.pid, startIdentity: application.startIdentity,
                                 name: application.name, detail: detail(application.pid),
                                 isNativeApp: true, cpu: total.cpu,
                                 mem: percentOfPhysicalMemory(total.bytes), memBytes: total.bytes,
                                 ppid: main.ppid, uid: main.uid,
                                 state: main.isZombie ? "Z" : (main.isExiting ? "E" : "S"),
                                 elapsed: main.elapsed)
            let childRows = (children[application.pid] ?? [])
                .sorted { $0.residentBytes > $1.residentBytes }
                .map { sample in
                    ProcessRow(pid: sample.pid, startIdentity: String(sample.identity.startTime, radix: 16),
                               name: sample.name, detail: childDetail(sample),
                               isNativeApp: false, cpu: sample.cpuPercent,
                               mem: percentOfPhysicalMemory(sample.residentBytes),
                               memBytes: sample.residentBytes,
                               ppid: sample.ppid, uid: sample.uid,
                               state: sample.isZombie ? "Z" : (sample.isExiting ? "E" : "S"),
                               elapsed: sample.elapsed)
                }
            return ProcessGroup(app: row, children: childRows)
        }
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
