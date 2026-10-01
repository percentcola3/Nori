import Foundation

/// 重复文件与相似图片；其他语言沿用英文回退。
enum L10nDuplicatesTables {
    static let en: [String: String] = [
        "duplicates.mode.label": "Scan mode",
        "duplicates.mode.exact": "Exact duplicates",
        "duplicates.mode.similar": "Similar images",
        "duplicates.scan": "Compare again",
        "duplicates.empty.none": "No duplicate groups to review",
        "duplicates.empty.noneHint": "Files in your personal folders were compared. System files and app-managed locations are excluded automatically.",
        "duplicates.empty.scanning": "Comparing files…",
        "duplicates.empty.scanningHint": "Large folders can take a while. You can cancel the scan at any time.",
        "duplicates.group.exact": "Group %ld · %ld identical files",
        "duplicates.group.similar": "Group %ld · %ld similar images",
        "duplicates.keepOne": "Keep at least one file in each group",
        "duplicates.similar.hint": "Similar images may contain different details. Preview each original before deciding what to remove.",
        "duplicates.sharpness.hint": "Sharpness is an estimate for comparison within a group. A higher score does not always mean a better photo.",
        "duplicates.dimensions": "%ld × %ld px",
        "duplicates.quality": "Sharpness %.1f",
        "duplicates.preview": "Preview original",
        "duplicates.reveal": "Show in Finder",
        "duplicates.row.selected": "Selected for Trash",
        "duplicates.row.kept": "Keep file",
        "duplicates.selection.hint": "Select files individually; keep at least one per group.",
        "duplicates.selection.count": "%ld selected · %@ in file sizes",
        "duplicates.trash": "Move to Trash",
        "duplicates.trash.title": "Move %ld selected files to the Trash?",
        "duplicates.trash.message": "Each group must retain a verified copy. Files are checked again before removal; changed or unverified files are skipped. Moving to the Trash does not immediately free disk space. Shared storage and snapshots can affect the space eventually reclaimed.",
        "duplicates.trash.similarMessage": "You have chosen these images for removal. Similarity does not mean identical content; ensure the remaining images contain what you need. Changed or unverified files are skipped. Moving to the Trash does not immediately free disk space. Shared storage and snapshots can affect the space eventually reclaimed.",
        "duplicates.status.enumerating": "Found %d files",
        "duplicates.status.hashing": "Verifying %d / %d candidates",
        "duplicates.status.images": "Comparing images %d / %d",
        "duplicates.status.complete": "Found %d groups",
        "duplicates.status.cancelled": "Scan cancelled. Incomplete results cannot be used to delete files; scan again to continue.",
        "duplicates.status.failed": "Scan failed. Check folder access and try again.",
        "duplicates.status.noAccess": "Full Disk Access is required to compare files.",
        "duplicates.status.idle": "Nothing compared yet — use Compare again to start.",
        "duplicates.status.deleting": "Checking files and moving selected items to the Trash…",
        "duplicates.status.deleted": "Moved %d files to the Trash; skipped %d; failed %d. Scan again to refresh the results.",
        "duplicates.status.invalidSelection": "Keep at least one unchanged file in every group. Scan again to refresh the results.",
        "duplicates.coverage": "%d files scanned · %d skipped",
        "duplicates.coverage.partial": "Only completed results are shown. Some files were inaccessible or exceeded processing limits.",
        "duplicates.coverage.exactSkipped": "%d additional identical images can be reviewed in Exact duplicates."
    ]

    static let zhHans: [String: String] = [
        "duplicates.mode.label": "扫描模式",
        "duplicates.mode.exact": "完全重复",
        "duplicates.mode.similar": "相似图片",
        "duplicates.scan": "重新查重",
        "duplicates.empty.none": "没有发现重复文件",
        "duplicates.empty.noneHint": "已比较你个人目录中的文件，系统文件与应用私有位置自动排除。",
        "duplicates.empty.scanning": "正在比较文件…",
        "duplicates.empty.scanningHint": "文件较多时需要一些时间，可随时取消扫描。",
        "duplicates.group.exact": "第 %ld 组 · %ld 个完全重复文件",
        "duplicates.group.similar": "第 %ld 组 · %ld 张相似图片",
        "duplicates.keepOne": "每组至少保留一份",
        "duplicates.similar.hint": "相似图片可能包含不同细节。请逐张预览原图，再决定是否删除。",
        "duplicates.sharpness.hint": "清晰度仅供组内比较，分数高不一定代表照片更好。",
        "duplicates.dimensions": "%ld × %ld 像素",
        "duplicates.quality": "参考清晰度 %.1f",
        "duplicates.preview": "预览原文件",
        "duplicates.reveal": "在 Finder 中显示",
        "duplicates.row.selected": "已选择移入废纸篓",
        "duplicates.row.kept": "保留文件",
        "duplicates.selection.hint": "逐项勾选需要删除的文件，每组至少保留一份。",
        "duplicates.selection.count": "已选 %ld 项 · 文件大小合计 %@",
        "duplicates.trash": "移入废纸篓",
        "duplicates.trash.title": "将所选 %ld 个文件移入废纸篓？",
        "duplicates.trash.message": "每组必须保留一份经过验证的副本。删除前会重新检查；已变化或无法确认的文件会跳过。移入废纸篓不会立即释放磁盘空间，共享数据与快照也可能影响最终释放量。",
        "duplicates.trash.similarMessage": "这些图片由你选择删除。相似不代表内容相同，请确认保留的图片包含你需要的内容。已变化或无法确认的文件会跳过。移入废纸篓不会立即释放磁盘空间，共享数据与快照也可能影响最终释放量。",
        "duplicates.status.enumerating": "已找到 %d 个文件",
        "duplicates.status.hashing": "正在校验 %d / %d 个候选",
        "duplicates.status.images": "正在比较图片 %d / %d",
        "duplicates.status.complete": "找到 %d 组",
        "duplicates.status.cancelled": "扫描已取消。未完成的结果不能用于删除，请重新扫描。",
        "duplicates.status.failed": "扫描失败，请检查目录访问权限后重试。",
        "duplicates.status.noAccess": "需要完全磁盘访问权限后才能比对文件。",
        "duplicates.status.idle": "尚未比对，点击“重新查重”开始。",
        "duplicates.status.deleting": "正在复核文件并将所选项移入废纸篓…",
        "duplicates.status.deleted": "已移入废纸篓 %d 个，跳过 %d 个，失败 %d 个；请重新扫描。",
        "duplicates.status.invalidSelection": "每组至少保留一个未变化的文件，请重新扫描。",
        "duplicates.coverage": "扫描 %d 个文件，跳过 %d 个",
        "duplicates.coverage.partial": "仅显示已完成部分，部分文件无法访问或超过处理限制。",
        "duplicates.coverage.exactSkipped": "另有 %d 份完全相同的图片，请在“完全重复”模式处理。"
    ]

    static func table(for language: AppLanguage) -> [String: String] {
        switch language {
        case .zhHans: return zhHans
        case .auto: return [:]
        default: return en
        }
    }
}
