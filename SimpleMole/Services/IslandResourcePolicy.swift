import Foundation

enum IslandResource: String, Hashable {
    case cpu, memory
}

/// 自动处理只选隐藏的高占用应用；正常退出仍由应用自己处理未保存的文档。
enum IslandResourcePolicy {
    static func isEligible(resource: IslandResource, cpu: Double, previousCPU: Double,
                           memoryBytes: UInt64, isHidden: Bool, isActive: Bool,
                           isRegular: Bool, isSameUser: Bool, isOwnApp: Bool,
                           executablePath: String, elapsed: TimeInterval) -> Bool {
        guard isHidden, !isActive, isRegular, isSameUser, !isOwnApp,
              elapsed >= 60, !executablePath.isEmpty,
              !["/System/", "/usr/", "/bin/", "/sbin/", "/private/"].contains(where: executablePath.hasPrefix)
        else { return false }
        switch resource {
        case .cpu: return cpu >= 20 && previousCPU >= 20
        case .memory: return memoryBytes >= 512 * 1024 * 1024
        }
    }

    enum Health { case healthy, elevated, high }
    static func health(percent: Double) -> Health {
        if percent >= 85 { return .high }
        if percent >= 60 { return .elevated }
        return .healthy
    }
}
