import Foundation

/// 统一的“未活跃”判定。开发者缓存与构建产物默认以连续 7×24 小时无活动
/// 作为回收门槛；判定必须基于能取得的证据，证据缺失时不能升级为推荐清理。
///
/// 证据语义（保守优先）：
/// - 单一时间戳只能说明该时间点的情况。mtime 说明最近写入（创建文件时
///   mtime 即创建时间），atime 在 noatime 挂载下不可信。两者取“最新”作为
///   该缓存单元的活动证据：只要任何一项显示近期有活动，就视为活跃。
/// - ctime（status change）不作为证据：chmod、备份、迁移等元数据操作都
///   会刷新它，与“内容仍在使用”没有必然联系。
/// - 时间缺失、不可读取：无法证明未活跃 → 不推荐。
/// - 未来时间（超过允许的时钟偏差）：视为证据异常 → 不推荐。
/// - 边界：活动时间与“现在”的间隔 ≥ 保留期才算未活跃，恰好等于保留期时
///   视为未活跃（边界行为由测试固定）。
enum CleanupAgePolicy {
    /// 开发者缓存与构建产物的默认保留期：7 天。
    static let developerRetention: TimeInterval = 7 * 24 * 3600
    /// 文件系统时间戳与扫描进程之间允许的时钟偏差。
    private static let clockSkewTolerance: TimeInterval = 120

    /// 一个缓存单元的活动证据。`date` 为 nil 表示没有可用证据。
    static func activityEvidence(modified: Date?, accessed: Date?) -> Date? {
        let candidates = [modified, accessed].compactMap { $0 }
        return candidates.max()
    }

    /// 证据是否足以证明该单元已经连续 `retention` 未活跃。
    /// - nil 证据、未来时间（含偏差容忍）一律返回 false。
    static func isStale(_ evidence: Date?, now: Date = Date(),
                        retention: TimeInterval) -> Bool {
        guard retention > 0, let evidence else { return false }
        guard evidence.timeIntervalSince(now) <= clockSkewTolerance else { return false }
        return now.timeIntervalSince(evidence) >= retention
    }

    /// 扫描后、执行前的复核：单元在扫描之后重新变得活跃（或时间证据变得
    /// 不可用）时，返回 false 以跳过该条目。
    ///
    /// `previousEvidence` 是扫描时看到的证据；执行前重新测得 `recheck`。
    /// 若重测证据缺失（目录被移动、权限变化），同样跳过。
    static func remainsStale(previous: Date?, recheck: Date?, now: Date = Date(),
                             retention: TimeInterval) -> Bool {
        guard let recheck else { return false }
        return isStale(recheck, now: now, retention: retention)
    }
}
