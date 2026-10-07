import Foundation

/// The metadata-checking boundary used by presentation code. Installation and
/// process shutdown are deliberately outside this interface.
protocol SoftwareUpdateChecking: Sendable {
    func check(_ target: SoftwareUpdateService.Target) async -> SoftwareUpdateResult
    func clearCache() async
}

extension SoftwareUpdateService: SoftwareUpdateChecking {}

/// Owns bounded scheduling independently of the software page's visible state.
enum SoftwareUpdateCheckBatch {
    static func run(_ targets: [SoftwareUpdateService.Target],
                    using checker: any SoftwareUpdateChecking,
                    maximumConcurrentChecks: Int = 4) async -> [String: SoftwareUpdateResult] {
        await checker.clearCache()
        return await withTaskGroup(of: (String, SoftwareUpdateResult).self) { group in
            var next = 0
            func enqueue(_ index: Int) {
                let target = targets[index]
                group.addTask { (target.id, await checker.check(target)) }
            }
            while next < min(max(1, maximumConcurrentChecks), targets.count) {
                enqueue(next)
                next += 1
            }
            var completed: [String: SoftwareUpdateResult] = [:]
            while let (id, result) = await group.next() {
                completed[id] = result
                if next < targets.count {
                    enqueue(next)
                    next += 1
                }
            }
            return completed
        }
    }
}
