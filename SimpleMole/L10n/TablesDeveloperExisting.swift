import Foundation

/// Text shared by the existing developer diagnostics and cleanup panels.
enum L10nDeveloperExistingTables {
    private static let entries: [(String, String, String, String)] = [
        ("dev.workspace.searching", "Searching", "检索中", "檢索中"),
        ("dev.cli.title", "Command-line tools", "命令行工具", "命令列工具"),
        ("dev.cli.checking", "Checking", "检查中", "檢查中"),
        ("dev.cli.issuesOnly", "Issues only", "仅看问题", "僅看問題"),
        ("dev.cli.copyPath", "Copy PATH", "复制 PATH", "複製 PATH"),
        ("dev.cli.copyPath.help", "Copy the PATH used by this diagnostic", "复制本次诊断使用的 PATH", "複製本次診斷使用的 PATH"),
        ("dev.cli.empty", "No matching tools.", "没有符合条件的工具。", "沒有符合條件的工具。"),
        ("dev.cli.discovering", "Discovering common tool sources…", "读取常见工具来源…", "讀取常見工具來源…"),
        ("dev.cli.relativePath", "Empty and relative PATH entries were skipped.", "已跳过 PATH 的空值与相对路径。", "已略過 PATH 的空值與相對路徑。"),
        ("dev.cli.copyLocation", "Copy path", "复制路径", "複製路徑"),
        ("dev.cli.copyDiagnostic", "Copy diagnostic command", "复制诊断命令", "複製診斷命令"),
        ("dev.cli.openDiagnostic", "Check sources in Terminal", "在 Terminal 检查来源", "在 Terminal 檢查來源"),
        ("dev.cli.shadowing.help", "The first PATH source wins. Expand to compare.", "PATH 首个来源优先，可展开比较。", "PATH 第一個來源優先，可展開比較。"),
        ("dev.cli.outsidePath.help", "Outside PATH. Check sources in Terminal.", "未在 PATH 中，可在终端检查来源。", "未在 PATH 中，可在終端機檢查來源。"),
        ("dev.cli.version.reading", "Reading version…", "读取版本…", "讀取版本…"),
        ("dev.cli.version.deferred", "Source only", "仅查来源", "僅查來源"),
        ("dev.cli.version.timeout", "Version lookup timed out", "版本读取超时", "版本讀取逾時"),
        ("dev.cli.version.unavailable", "Version unavailable", "版本不可用", "版本無法使用"),
        ("dev.cli.version.deferred.help", "Version commands were skipped to avoid SDK downloads, installation, or initialization.", "为避免 SDK 下载、安装或初始化，未运行版本命令。", "為避免 SDK 下載、安裝或初始化，未執行版本命令。"),
        ("dev.cli.version.timeout.help", "Lookup stopped. Copy the diagnostic command to check sources.", "已停止检查，可复制诊断命令检查来源。", "已停止檢查，可複製診斷命令檢查來源。"),
        ("dev.cli.version.unavailable.help", "Version unavailable. Check links, permissions, or dependencies.", "版本不可读，请检查链接、权限或工具依赖。", "版本無法讀取，請檢查連結、權限或工具相依項目。"),
        ("dev.cli.shadowing", "Multiple PATH sources", "PATH 多来源", "PATH 多個來源"),
        ("dev.cli.extra", "Extra installation", "额外安装", "額外安裝"),
        ("dev.cli.notFound", "Not found", "未发现", "未發現"),
        ("dev.cli.outsidePath", "Outside PATH", "不在 PATH", "不在 PATH"),
        ("dev.cli.environment.help", "PATH reflects the current scan; undetected does not mean uninstalled.", "PATH 以本次扫描为准；未发现不等于未安装。", "PATH 以本次掃描為準；未發現不代表未安裝。"),
        ("dev.cli.found", "%d found", "已发现 %d 个", "已發現 %d 個"),
        ("dev.cli.duplicatePath", "%d duplicate PATH directories", "PATH 有 %d 个重复目录", "PATH 有 %d 個重複目錄"),
        ("dev.cli.actions", "Actions for %@", "%@ 工具操作", "%@ 工具操作"),
        ("dev.cli.sources", "%d sources", "%d 个来源", "%d 個來源"),
        ("dev.cli.copyLocation.accessibility", "Copy %@", "复制 %@", "複製 %@"),
        ("dev.cli.category.web", "Web & JavaScript", "Web 与 JavaScript", "Web 與 JavaScript"),
        ("dev.cli.category.mobile", "Apple & mobile development", "Apple 与移动开发", "Apple 與行動開發"),
        ("dev.cli.category.utilities", "Developer utilities", "开发基础工具", "開發基礎工具"),
        ("dev.cli.source.local", "PATH / local", "PATH / 本地", "PATH / 本機"),
        ("dev.cleanup.runtimes", "Installed runtimes", "已安装运行时", "已安裝執行環境"),
        ("dev.cleanup.protected", "Current / default nvm versions are protected", "当前 / 默认 nvm 版本受保护", "目前 / 預設 nvm 版本受保護"),
        ("dev.cleanup.cleanableOnly", "Cleanable only", "仅可清理", "僅可清理"),
        ("dev.cleanup.runtimes.empty", "No matching runtimes.", "没有符合条件的运行时。", "沒有符合條件的執行環境。"),
        ("dev.cleanup.trash", "Move to Trash", "移入废纸篓", "移到垃圾桶"),
        ("dev.cleanup.caches", "Package and build caches", "包与构建缓存", "套件與建置快取"),
        ("dev.cleanup.caches.help", "Official cleanup commands; the next build may download again", "用官方命令清理，下次构建可能重新下载", "使用官方命令清理，下次建置可能重新下載"),
        ("dev.cleanup.resources", "Containers & simulators", "容器与模拟器", "容器與模擬器"),
        ("dev.cleanup.docker", "Docker storage", "Docker 空间", "Docker 空間"),
        ("dev.cleanup.docker.help", "Images, containers, volumes and build cache", "镜像、容器、卷和构建缓存的占用", "映像、容器、磁碟區與建置快取的用量"),
        ("dev.cleanup.simulators", "iOS simulators", "iOS 模拟器", "iOS 模擬器"),
        ("dev.cleanup.simulators.help", "Review and delete unused devices by runtime", "按系统版本查看并删除不用的设备", "依系統版本檢視並刪除未使用的裝置"),
        ("dev.cleanup.manage", "Manage…", "管理…", "管理…"),
        ("dev.cleanup.current", "Current / default", "当前 / 默认", "目前 / 預設"),
        ("dev.cleanup.reveal", "Reveal in Finder", "在 Finder 中查看", "在 Finder 中顯示"),
        ("dev.cleanup.clean", "Clean", "清理", "清理"),
        ("dev.cleanup.caches.empty", "No cache cleanup tools were found in the current search paths.", "当前检查范围未发现可用的缓存清理工具。", "目前檢查範圍未發現可用的快取清理工具。"),
        ("dev.cleanup.globalPackages", "Includes version-specific global npm packages: %@", "包含该版本的全局 npm 包：%@", "包含該版本的全域 npm 套件：%@"),
        ("dev.cleanup.row.globalPackages", "Global npm packages are included: %@", "全局 npm 包随版本一起清理：%@", "全域 npm 套件會隨版本一起清理：%@"),
        ("dev.cleanup.system", "System", "系统内置", "系統內建"),
        ("dev.cleanup.managerOwned", "Manager-owned", "由工具管理", "由工具管理"),
        ("dev.cleanup.copied", "Copied", "已复制", "已複製"),
        ("dev.cleanup.copyUninstall", "Copy uninstall command", "复制卸载命令", "複製解除安裝命令"),
        ("dev.cleanup.sizeUnknown", "Size unknown", "大小未知", "大小未知"),
    ]

    static func table(for language: AppLanguage) -> [String: String] {
        switch language {
        case .en: return Dictionary(uniqueKeysWithValues: entries.map { ($0.0, $0.1) })
        case .zhHans: return Dictionary(uniqueKeysWithValues: entries.map { ($0.0, $0.2) })
        case .zhHant: return Dictionary(uniqueKeysWithValues: entries.map { ($0.0, $0.3) })
        default: return [:]
        }
    }
}
