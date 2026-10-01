import Foundation

enum L10nUpdateTables {
    static func table(for language: AppLanguage) -> [String: String] {
        switch language {
        case .zhHans: return [
            "updates.title": "版本更新",
            "updates.check": "检查更新…",
            "updates.autoCheck": "自动检查更新",
            "updates.autoDownload": "自动下载并在退出时安装",
            "updates.current": "当前版本 %@",
            "updates.checking": "正在检查更新…",
            "updates.available": "新版本 %@ 可用",
            "updates.latest": "已是最新版本",
            "updates.busy": "当前任务进行中，更新稍后继续。",
            "updates.failed": "暂时无法检查更新",
        ]
        case .zhHant: return [
            "updates.title": "版本更新",
            "updates.check": "檢查更新…",
            "updates.autoCheck": "自動檢查更新",
            "updates.autoDownload": "自動下載並在結束時安裝",
            "updates.current": "目前版本 %@",
            "updates.checking": "正在檢查更新…",
            "updates.available": "新版本 %@ 可用",
            "updates.latest": "已是最新版本",
            "updates.busy": "目前工作進行中，更新稍後繼續。",
            "updates.failed": "暫時無法檢查更新",
        ]
        default: return [
            "updates.title": "Updates",
            "updates.check": "Check for Updates…",
            "updates.autoCheck": "Automatically check for updates",
            "updates.autoDownload": "Automatically download and install on quit",
            "updates.current": "Current version %@",
            "updates.checking": "Checking for updates…",
            "updates.available": "Version %@ is available",
            "updates.latest": "You're up to date",
            "updates.busy": "A task is in progress. The update will wait.",
            "updates.failed": "Unable to check for updates",
        ]
        }
    }
}
