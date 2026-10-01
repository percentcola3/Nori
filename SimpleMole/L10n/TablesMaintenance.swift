import Foundation

/// 系统维护能力文案表（原系统优化页分流后的新入口）。当前提供 en/zh-Hans
/// 全量文案，其余语言回退 English（与 permissions.openSettings 等既有键同策略）。
enum L10nMaintenanceTables {
    static let en: [String: String] = [
        // 清理页 · 系统数据库维护
        "sysmaint.title": "System Database Maintenance",
        "sysmaint.card.hint": "Checked after a deep scan; each item runs only on your confirmation.",
        "sysmaint.item.sqlite-vacuum": "Compress system databases",
        "sysmaint.item.sqlite-vacuum.detail": "Mail, Messages and Safari databases, compacted after an integrity check.",
        "sysmaint.item.notifications": "Notification history",
        "sysmaint.item.notifications.detail": "Delete delivered notifications older than 30 days when the database exceeds 50 MB.",
        "sysmaint.item.coreduet": "Usage knowledge base",
        "sysmaint.item.coreduet.detail": "Reset the usage database when it exceeds 100 MB.",
        "sysmaint.item.quarantine": "Download quarantine history",
        "sysmaint.item.quarantine.detail": "Clear the download-attribution history; files and Gatekeeper checks are unaffected.",
        "sysmaint.item.saved-state": "Saved window states",
        "sysmaint.item.saved-state.detail": "Move application window states older than 30 days to Trash.",
        "sysmaint.status.inspecting": "Checking system databases…",
        "sysmaint.status.clean": "All system databases are healthy.",
        "sysmaint.status.found": "%d item(s) can reclaim space",
        "sysmaint.status.running": "Running maintenance…",
        "sysmaint.confirm.title": "Run this maintenance item?",
        "sysmaint.confirm.message": "%@: %@ It runs immediately after you confirm.",
        "sysmaint.confirm.ok": "Run",
        "sysmaint.check": "Re-check",
        // 开发环境 · 网络与服务修复
        "nettool.section": "Network & Service Repair",
        "nettool.dns": "Flush DNS Cache",
        "nettool.network-stack": "Reset Network Stack",
        "nettool.quicklook": "Rebuild Quick Look",
        "nettool.iconservices": "Restart Icon Service",
        "nettool.launchservices": "Rebuild LaunchServices",
        "nettool.confirm.title": "Run this network tool?",
        "nettool.confirm.dns": "Flushes the resolver cache and restarts mDNSResponder. Your administrator password is requested once.",
        "nettool.confirm.network-stack": "Flushes routing and ARP caches to repair connectivity. Your administrator password is requested once.",
        "nettool.confirm.ok": "Run",
        "nettool.status.running": "Running…",
        "nettool.status.failed": "Execution failed; see the log.",
        "nettool.status.skipped": "Skipped in test mode.",
        "nettool.reset.title": "Reset Network to Factory",
        "nettool.reset.confirm.title": "Reset the network environment?",
        "nettool.reset.confirm.message": "Removes everything that is not a system default: turns off all proxies, resets DNS to automatic, forgets saved Wi-Fi networks, deletes non-Automatic network locations, restores /etc/hosts and removes custom /etc/resolver entries. Every modified file is backed up first. Saved Wi-Fi passwords and proxy settings will be lost.",
        "nettool.reset.confirm.ok": "Reset",
        "nettool.reset.done": "Network environment reset.",
        // 开发环境 · 环境变量体检
        "envaudit.title": "Environment Variable Audit",
        "envaudit.scan": "Audit",
        "envaudit.fix": "Clean Selected",
        "envaudit.empty": "No stale entries in your shell profiles.",
        "envaudit.reason.deadPath": "PATH points at a missing directory",
        "envaudit.reason.duplicatePath": "Duplicate PATH entry",
        "envaudit.reason.deadExport": "%@ points at a missing directory",
        "envaudit.reason.deadToolInit": "Initializes a tool that is no longer installed",
        "envaudit.confirm.title": "Clean shell profile entries?",
        "envaudit.confirm.message": "%d line(s) will be rewritten or removed. Every modified file is backed up next to the original first.",
        "envaudit.confirm.ok": "Clean",
        "envaudit.status.fixed": "Cleaned %d line(s); backups: %@",
        "envaudit.status.fixedNoBackup": "Cleaned %d line(s)."
    ]

    static let zhHans: [String: String] = [
        // 清理页 · 系统数据库维护
        "sysmaint.title": "系统数据库维护",
        "sysmaint.card.hint": "深度扫描后体检，逐项确认后才会执行。",
        "sysmaint.item.sqlite-vacuum": "压缩系统数据库",
        "sysmaint.item.sqlite-vacuum.detail": "Mail、信息与 Safari 的数据库；完整性检查通过后压缩。",
        "sysmaint.item.notifications": "通知历史",
        "sysmaint.item.notifications.detail": "数据库超过 50 MB 时删除 30 天前的已送达通知。",
        "sysmaint.item.coreduet": "使用记录知识库",
        "sysmaint.item.coreduet.detail": "使用记录数据库超过 100 MB 时重置。",
        "sysmaint.item.quarantine": "下载隔离历史",
        "sysmaint.item.quarantine.detail": "清空下载归属历史；不影响文件与门禁检查。",
        "sysmaint.item.saved-state": "窗口保存状态",
        "sysmaint.item.saved-state.detail": "将 30 天前的应用窗口状态移入废纸篓。",
        "sysmaint.status.inspecting": "正在体检系统数据库…",
        "sysmaint.status.clean": "系统数据库均处于健康范围。",
        "sysmaint.status.found": "%d 项可回收空间",
        "sysmaint.status.running": "正在执行维护…",
        "sysmaint.confirm.title": "执行这项维护？",
        "sysmaint.confirm.message": "%@：%@ 确认后立即执行。",
        "sysmaint.confirm.ok": "执行",
        "sysmaint.check": "重新体检",
        // 开发环境 · 网络与服务修复
        "nettool.section": "网络与服务修复",
        "nettool.dns": "刷新 DNS 缓存",
        "nettool.network-stack": "重置网络栈",
        "nettool.quicklook": "重建快速查看",
        "nettool.iconservices": "重启图标服务",
        "nettool.launchservices": "重建 LaunchServices",
        "nettool.confirm.title": "执行该网络工具？",
        "nettool.confirm.dns": "刷新解析缓存并重启 mDNSResponder；会请求一次管理员密码。",
        "nettool.confirm.network-stack": "清空路由与 ARP 缓存以修复连通性；会请求一次管理员密码。",
        "nettool.confirm.ok": "执行",
        "nettool.status.running": "正在执行…",
        "nettool.status.failed": "执行失败，详见日志。",
        "nettool.status.skipped": "测试模式下跳过。",
        "nettool.reset.title": "网络环境出厂重置",
        "nettool.reset.confirm.title": "重置网络环境？",
        "nettool.reset.confirm.message": "将删除系统默认之外的全部网络配置：关闭所有代理、DNS 恢复自动、忘记已保存的 Wi-Fi、删除非“自动”的网络位置、恢复 /etc/hosts 并移除 /etc/resolver 自定义条目。被修改的文件都会先备份。已保存的 Wi-Fi 密码与代理设置将丢失。",
        "nettool.reset.confirm.ok": "重置",
        "nettool.reset.done": "网络环境已重置。",
        // 开发环境 · 环境变量体检
        "envaudit.title": "环境变量体检",
        "envaudit.scan": "体检",
        "envaudit.fix": "清理选中项",
        "envaudit.empty": "Shell 配置文件中没有失效条目。",
        "envaudit.reason.deadPath": "PATH 指向不存在的目录",
        "envaudit.reason.duplicatePath": "PATH 存在重复项",
        "envaudit.reason.deadExport": "%@ 指向不存在的目录",
        "envaudit.reason.deadToolInit": "初始化的工具已不存在",
        "envaudit.confirm.title": "清理 Shell 配置条目？",
        "envaudit.confirm.message": "将改写或移除 %d 行；每个被修改的文件都会先在原位备份。",
        "envaudit.confirm.ok": "清理",
        "envaudit.status.fixed": "已清理 %d 行；备份：%@",
        "envaudit.status.fixedNoBackup": "已清理 %d 行。"
    ]

    static func table(for language: AppLanguage) -> [String: String] {
        switch language {
        case .zhHans: return zhHans
        default: return en
        }
    }
}
