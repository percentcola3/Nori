import Foundation

@main
struct IslandResourcePolicyTests {
    static func main() {
        func eligible(_ resource: IslandResource = .cpu, cpu: Double = 70, previous: Double = 50,
                      bytes: UInt64 = 700 * 1024 * 1024, hidden: Bool = true, active: Bool = false,
                      regular: Bool = true, sameUser: Bool = true, own: Bool = false,
                      path: String = "/Applications/Example.app/Contents/MacOS/Example",
                      elapsed: TimeInterval = 120) -> Bool {
            IslandResourcePolicy.isEligible(resource: resource, cpu: cpu, previousCPU: previous,
                                            memoryBytes: bytes, isHidden: hidden, isActive: active,
                                            isRegular: regular, isSameUser: sameUser, isOwnApp: own,
                                            executablePath: path, elapsed: elapsed)
        }
        precondition(eligible())
        precondition(!eligible(hidden: false), "Visible apps must be retained")
        precondition(!eligible(active: true), "Frontmost app must be retained")
        precondition(!eligible(regular: false), "Agents must be retained")
        precondition(!eligible(sameUser: false), "Other users must be retained")
        precondition(!eligible(own: true), "Own app must be retained")
        precondition(!eligible(path: "/System/Library/CoreServices/Finder.app/Finder"))
        precondition(!eligible(path: ""))
        precondition(!eligible(elapsed: 59), "Freshly launched apps must be retained")
        precondition(!eligible(previous: 0), "Transient CPU spike is insufficient")
        precondition(!eligible(cpu: 19))
        precondition(eligible(.memory, cpu: 0, previous: 0), "Memory cleanup is independent of CPU")
        precondition(!eligible(.memory, bytes: 511 * 1024 * 1024))
        precondition(eligible(.cpu, bytes: 0), "CPU cleanup is independent of memory")
        precondition(IslandResourcePolicy.health(percent: 59.9) == .healthy)
        precondition(IslandResourcePolicy.health(percent: 60) == .elevated)
        precondition(IslandResourcePolicy.health(percent: 84.9) == .elevated)
        precondition(IslandResourcePolicy.health(percent: 85) == .high)
        print("Island resource policy: CPU/memory selection, foreground/system/identity safeguards and health thresholds passed")
    }
}
