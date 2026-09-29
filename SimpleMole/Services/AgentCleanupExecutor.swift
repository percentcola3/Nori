import Foundation

/// 与 UI 无关的执行计划，便于在测试中直接驱动。
enum AgentCleanupExecutor {
    struct Outcome {
        var summary: NativeCore.ApplySummary
        /// 复核阶段被拒绝（归属者在运行、目录不再认领、身份缺失）的条目数。
        var refused: Int
    }

    struct Plan {
        var items: [DeletionPlan.Item]
        var verified: Set<String>
        var families: [[String]]
        var refused: Int
    }

    static func plan(_ requested: [CleanupCategory],
                     running snapshot: RunningApplicationSnapshot,
                     home: String) -> Plan {
        let catalogPaths = AgentCatalog.deletablePaths(home: home)
        var items: [DeletionPlan.Item] = []
        var verified = Set<String>()
        var refused = 0
        for category in requested {
            let candidates = category.paths.filter(category.isPathSelected)
            guard let subset = CleanupRiskPolicy.runtimeEligibleSubset(category, running: snapshot),
                  CleanupRiskPolicy.isEligible(subset, mode: .manual, running: snapshot) else {
                refused += candidates.count
                continue
            }
            for path in candidates {
                let known = category.reasonKey == "agents.reason.skill"
                    ? AgentCatalog.isDeletableSkill(path, home: home)
                    : catalogPaths.contains(path)
                guard known, subset.isPathSelected(path),
                      let identity = category.pathIdentities[path], !identity.isEmpty else {
                    refused += 1
                    continue
                }
                items.append(DeletionPlan.Item(record: path, identity: identity))
                verified.insert(path)
            }
        }
        // 族成员以磁盘现状为准：未进入计划的成员（扫描后新出现的 -wal、
        // 用户只勾了伴随文件）没有身份，漏斗会因此保留整族。
        let planned = Set(items.map(\.record))
        var mains = Set<String>()
        for path in planned {
            let main = AgentCatalog.sqliteCompanionSuffixes.reduce(path) { current, suffix in
                current.hasSuffix(suffix) ? String(current.dropLast(suffix.count)) : current
            }
            if main.hasSuffix(".sqlite") || main.hasSuffix(".db") { mains.insert(main) }
        }
        let families: [[String]] = mains.sorted().compactMap { main in
            let members = ([main] + AgentCatalog.sqliteCompanionSuffixes.map { main + $0 })
                .filter { planned.contains($0) || AgentCatalog.exists($0) }
            return members.count > 1 ? members : nil
        }
        return Plan(items: items, verified: verified, families: families, refused: refused)
    }

    static func execute(_ requested: [CleanupCategory],
                        running snapshot: RunningApplicationSnapshot,
                        home: String,
                        permanent: Bool = false) -> Outcome {
        let plan = plan(requested, running: snapshot, home: home)
        guard !plan.items.isEmpty else {
            return Outcome(summary: NativeCore.ApplySummary(removed: 0, skipped: 0, failed: 0,
                                                            messages: []),
                           refused: plan.refused)
        }
        let summary = NativeCore.shared.applyCleanup(
            items: plan.items, permanent: permanent, homeDirectory: home,
            verifiedTargets: plan.verified, atomicFamilies: plan.families)
        return Outcome(summary: summary, refused: plan.refused)
    }
}
