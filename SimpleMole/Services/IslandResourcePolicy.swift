import Foundation

enum IslandResource: String, Hashable {
    case cpu, memory
}

/// 灵动岛清理只结束“残留进程”：被父进程遗弃（已过继给 launchd）、不属于任何
/// 运行中的 App、也不受 launchd 管理的本用户进程，例如终端关掉后留下的开发服务器、
/// 已退出 App 的辅助进程、无头浏览器。正在使用的 App 及其子进程一律不碰。
enum IslandResourcePolicy {
    struct ProcessFacts: Equatable {
        let pid: Int32
        let ppid: Int32
        let uid: UInt32
        let name: String
        let path: String
        let cpu: Double
        let previousCPU: Double
        let residentBytes: UInt64
        let elapsed: TimeInterval
        var isZombie = false
        var isExiting = false
    }

    struct Residual: Equatable {
        let rootPID: Int32
        let name: String
        let pids: [Int32]
        let residentBytes: UInt64
        let cpu: Double
    }

    static let protectedPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/private/", "/Library/Apple/"]
    static let sessionKeepers: Set<String> = [
        "tmux", "screen", "mosh-server", "zellij", "sshd", "ssh-agent", "gpg-agent", "login",
        "zsh", "bash", "fish", "sh"
    ]
    static let minimumAge: TimeInterval = 120
    static let cpuThreshold: Double = 30
    static let memoryThreshold: UInt64 = 300 * 1024 * 1024
    static let idleCPU: Double = 3

    static func residuals(resource: IslandResource, processes: [ProcessFacts],
                          applicationPIDs: Set<Int32>, managedPIDs: Set<Int32>,
                          ownPID: Int32, uid: UInt32, ownBundlePath: String,
                          inUseRoots: [String] = [], limit: Int = 5) -> [Residual] {
        let inUse = (inUseRoots + [ownBundlePath]).filter { !$0.isEmpty }.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var children: [Int32: [Int32]] = [:]
        for process in processes { children[process.ppid, default: []].append(process.pid) }

        func subtree(_ pid: Int32) -> [Int32] {
            var order: [Int32] = [], stack = [pid], seen: Set<Int32> = []
            while let next = stack.popLast(), order.count < 256 {
                guard seen.insert(next).inserted else { continue }
                order.append(next)
                stack.append(contentsOf: children[next] ?? [])
            }
            return order.reversed()
        }

        func isEligible(_ process: ProcessFacts) -> Bool {
            process.uid == uid && process.pid != ownPID && process.pid > 1 && process.ppid == 1
                && !process.isZombie && !process.isExiting && process.elapsed >= minimumAge
                && !applicationPIDs.contains(process.pid) && !managedPIDs.contains(process.pid)
                && !process.path.isEmpty && !protectedPrefixes.contains(where: process.path.hasPrefix)
                && !process.path.contains(".xpc/")
                && !inUse.contains(where: process.path.hasPrefix)
                && !sessionKeepers.contains(process.name.lowercased())
        }

        var result: [Residual] = []
        for root in processes where isEligible(root) {
            let tree = subtree(root.pid)
            let members = tree.compactMap { byPID[$0] }
            guard !members.contains(where: { member in
                applicationPIDs.contains(member.pid) || managedPIDs.contains(member.pid) || member.uid != uid
                    || member.pid == ownPID || inUse.contains(where: member.path.hasPrefix)
            }) else { continue }
            let bytes = members.reduce(UInt64(0)) { $0 + $1.residentBytes }
            let cpu = members.reduce(0) { $0 + $1.cpu }
            let previous = members.reduce(0) { $0 + $1.previousCPU }
            switch resource {
            case .cpu:
                guard cpu >= cpuThreshold, previous >= cpuThreshold else { continue }
            case .memory:
                guard bytes >= memoryThreshold, cpu < idleCPU, previous < idleCPU else { continue }
            }
            result.append(Residual(rootPID: root.pid, name: root.name, pids: tree,
                                   residentBytes: bytes, cpu: cpu))
        }
        result.sort { resource == .cpu ? $0.cpu > $1.cpu : $0.residentBytes > $1.residentBytes }
        return Array(result.prefix(limit))
    }

    static func managedPIDs(fromLaunchctlList output: String) -> Set<Int32> {
        Set(output.split(whereSeparator: \.isNewline).compactMap { line in
            line.split(separator: "\t", maxSplits: 1).first.flatMap { Int32($0) }
        })
    }

    enum Health { case healthy, elevated, high }
    static func health(percent: Double) -> Health {
        if percent >= 85 { return .high }
        if percent >= 60 { return .elevated }
        return .healthy
    }
}
