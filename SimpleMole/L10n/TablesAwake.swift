import Foundation

enum L10nAwakeTables {
    static let en: [String: String] = [
        "awake.title": "Keep awake",
        "awake.mode.systemOnly": "System only",
        "awake.mode.systemAndDisplay": "System + display",
        "awake.active": "Awake",
        "awake.hint": "Stays awake until you turn this off or quit Nori. Closing the lid still puts the Mac to sleep.",
        "awake.agentRunning": "An agent is running — keep the Mac awake?",
        "awake.settings.display": "Keep display awake by default",
        "awake.settings.display.hint": "New keep-awake sessions will also prevent the display from sleeping.",
        "awake.settings.batteryFloor": "Auto-end below battery",
        "awake.settings.off": "Off",
        "awake.settings.thermal": "Auto-end at critical heat",
        "awake.notice.battery": "Keep-awake ended: battery at %d%%",
        "awake.notice.thermal": "Keep-awake ended: Mac is critically hot"
    ]

    static let zhHans: [String: String] = [
        "awake.title": "保持唤醒",
        "awake.mode.systemOnly": "只防睡眠",
        "awake.mode.systemAndDisplay": "同时防息屏",
        "awake.active": "保持唤醒",
        "awake.hint": "开启后持续保持唤醒，直到手动关闭或退出 Nori；合盖仍会进入睡眠。",
        "awake.agentRunning": "有 Agent 正在运行，要保持唤醒吗？",
        "awake.settings.display": "默认同时防息屏",
        "awake.settings.display.hint": "开启后，新开始的保持唤醒会话会同时防止息屏。",
        "awake.settings.batteryFloor": "电量低于此值自动结束",
        "awake.settings.off": "关闭",
        "awake.settings.thermal": "温度过高时自动结束",
        "awake.notice.battery": "保持唤醒已结束：电量 %d%%",
        "awake.notice.thermal": "保持唤醒已结束：机身温度过高"
    ]

    static func table(for language: AppLanguage) -> [String: String] {
        switch language {
        case .en: return en
        case .zhHans: return zhHans
        default: return [:]
        }
    }
}
