import Foundation

enum L10nMenuBarCollectionTables {
    static func table(for language: AppLanguage) -> [String: String] {
        switch language {
        case .auto: return [:]
        case .zhHans: return zhHans
        case .zhHant: return zhHans.mapValues { $0.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? $0 }
        default: return en
        }
    }
    private static let en = [
        "menubar.capture.scope": "Optional. Used for screenshots, the screenshot editor and native menu bar icon thumbnails.",
        "island.item.collection": "Collected icons",
        "menubar.enable": "Collect menu bar icons",
        "menubar.tray.show": "Show tray icon in the menu bar",
        "menubar.drawer.open": "Show collected icons",
        "menubar.drawer.interaction": "Click or right-click to use the original icon. Restore shows it in the menu bar.",
        "menubar.native.access": "Original icon interactions",
        "menubar.access.authorize": "Allow Accessibility…",
        "menubar.access.required": "Allow Accessibility to use original menu bar icons from the island.",
        "menubar.icon.unavailable": "The original icon could not be located. Refresh the icons and try again.",
        "menubar.native.hint": "Accessibility is allowed. Icons are resolved again before opening their original menus.",
        "menubar.preview.fallback": "App icons are used for previews until Accessibility is allowed.",
        "menubar.capture.hint": "Allow Screen Recording for native thumbnails; app icons are used otherwise.",
        "menubar.selected": "Selected",
        "menubar.unselected": "Not selected",
        "menubar.permission.scope": "Global shortcuts and hiding icons do not require Accessibility. Opening original icons from the island optionally uses Accessibility.",
        "menubar.title": "Menu bar collection",
        "menubar.experimental": "Menu bar collection · Experimental",
        "menubar.experimental.hint": "macOS 27 experimental support. Select apps to collect their icons; system controls stay visible. Choices and collapse state are restored after restarting or updating Nori. System updates may break support. Enable the Collected icons slot in Island settings for hover previews.",
        "menubar.legacy.hint": "Hold ⌘ and drag icons to the left of │; keep the tray button to its right. Collapse hides everything left of │. Restore to use the original icons. A display notch can still obstruct icons when expanded. Quitting Nori shows the bar; restarting or updating restores your saved collection state.",
        "menubar.unavailable": "Collection is unavailable on this system. All icons remain visible.",
        "menubar.arrangement": "Hold ⌘ and move │ to the left of the tray button. This display layout may not support collapse.",
        "menubar.select": "Select the apps whose menu bar icons you want to collect.",
        "menubar.apps.hint": "Select apps with menu bar icons. The list includes apps without icons; selecting those has no effect.",
        "menubar.refresh": "Refresh apps",
        "menubar.collapse": "Collapse icons",
        "menubar.restore": "Restore all icons",
        "menubar.collapsed": "Collapsed",
        "menubar.expanded": "Expanded",
        "menubar.failed": "Could not hide icons; restored the menu bar"
    ]
    private static let zhHans = [
        "menubar.capture.scope": "可选，用于截图、截图编辑器及菜单栏图标缩略图。",
        "island.item.collection": "收纳",
        "menubar.enable": "收纳菜单栏图标",
        "menubar.tray.show": "在菜单栏显示收纳图标",
        "menubar.drawer.open": "展开收纳图标",
        "menubar.drawer.interaction": "左键或右键操作原图标；使用原菜单时会恢复菜单栏显示。",
        "menubar.native.access": "原生图标交互",
        "menubar.access.authorize": "授权辅助功能…",
        "menubar.access.required": "请授权辅助功能，以便从灵动岛操作原生菜单栏图标。",
        "menubar.icon.unavailable": "暂时无法定位原图标，请刷新图标后重试。",
        "menubar.native.hint": "辅助功能已授权。点击收纳图标可打开原有菜单。",
        "menubar.preview.fallback": "授权辅助功能后可读取并操作原生图标；当前使用应用图标预览。",
        "menubar.capture.hint": "授权屏幕录制可显示原图标缩略图；未授权时使用应用图标。",
        "menubar.selected": "已选择",
        "menubar.unselected": "未选择",
        "menubar.permission.scope": "全局快捷键及收起图标无需辅助功能权限；从灵动岛直接操作原图标需要辅助功能权限。",
        "menubar.title": "菜单栏收纳",
        "menubar.experimental": "菜单栏收纳 · 实验功能",
        "menubar.experimental.hint": "macOS 27 实验支持：按应用收纳，系统图标保持显示。收纳开关、应用选择及收起状态会在重启或更新 Nori 后恢复，系统更新可能使功能失效。在灵动岛「快捷指标」中勾选「收纳」，悬停缩略图展开图标列表。",
        "menubar.legacy.hint": "按住 ⌘ 将待收纳图标拖到 │ 左侧，收纳按钮保留在右侧。收起会隐藏 │ 左侧全部图标，展开后使用原有图标。刘海可能遮挡展开后的图标。退出 Nori 会恢复展示，重启或更新后自动恢复保存的收纳状态。",
        "menubar.unavailable": "当前系统暂不支持收纳，全部图标保持显示。",
        "menubar.arrangement": "请按住 ⌘ 将 │ 拖到收纳按钮左侧；当前显示器布局也可能不支持收起。",
        "menubar.select": "勾选要收纳菜单栏图标的应用。",
        "menubar.apps.hint": "勾选带有菜单栏图标的应用。列表也包含没有图标的应用，勾选这些应用不会产生收纳效果。",
        "menubar.refresh": "刷新应用",
        "menubar.collapse": "收起图标",
        "menubar.restore": "恢复全部图标",
        "menubar.collapsed": "已收起",
        "menubar.expanded": "已展开",
        "menubar.failed": "收起失败，已恢复菜单栏"
    ]
}
