import Foundation

enum L10nAgentManagementTables {
    static func table(for language: AppLanguage) -> [String: String] {
        let en = [
            "agents.manage.delete": "Delete source", "agents.manage.unlink": "Unlink selected",
            "agents.manage.deleteTitle": "Delete selected resources?", "agents.manage.unlinkTitle": "Unlink selected bindings?",
            "agents.manage.deleteImpact": "Move the selected local sources to Trash and remove their known bindings from every Agent. Running, protected or changed resources are kept.",
            "agents.manage.unlinkImpact": "Remove only the selected links or configuration registrations. Resource sources and other Agent bindings remain. Configuration files are backed up before editing.",
            "agents.manage.implicit": "Auto-discovered", "agents.manage.implicitReason": "This Agent reads the shared directory automatically. There is no separate registration to unlink.",
            "agents.manage.linkBinding": "Directory link", "agents.manage.configBinding": "Configuration registration",
            "agents.manage.danglingBinding": "Broken link",
            "agents.manage.danglingReason": "The Skill target is missing. Broken links are selected for cleanup by default.",
            "agents.manage.cleanDangling": "Clean broken links",
            "agents.manage.cleanDanglingTitle": "Clean selected broken Skill links?",
            "agents.manage.cleanDanglingImpact": "Remove the selected links whose targets are missing. Targets restored since scanning are kept. Related configuration edits are backed up first.",
            "agents.manage.readOnly": "No deletable local source; bindings can be managed separately.",
            "agents.manage.search": "Search name, path or Agent", "agents.manage.selectBindings": "Select all bindings",
            "agents.manage.selectSources": "Select all sources", "agents.manage.clear": "Clear selection",
            "agents.manage.bindings": "%d bindings", "agents.manage.selected": "%d selected",
            "agents.manage.cleanData": "Clean selected data", "agents.manage.open": "Show source",
            "agents.manage.empty": "No matching resources", "agents.manage.scope": "Scope: %@"
        ]
        let zh = [
            "agents.manage.delete": "删除本体", "agents.manage.unlink": "解绑所选",
            "agents.manage.deleteTitle": "删除所选资源？", "agents.manage.unlinkTitle": "解除所选绑定？",
            "agents.manage.deleteImpact": "将所选本地本体移至废纸篓，并移除所有 Agent 中已识别的绑定。运行中、受保护或已变化的资源会保留。",
            "agents.manage.unlinkImpact": "仅移除所选链接或配置注册，保留资源本体和其它 Agent 的绑定。修改配置前会自动备份。",
            "agents.manage.implicit": "自动发现", "agents.manage.implicitReason": "该 Agent 自动读取共享目录，没有独立注册可供单独解绑。",
            "agents.manage.linkBinding": "目录链接", "agents.manage.configBinding": "配置注册",
            "agents.manage.danglingBinding": "失效链接",
            "agents.manage.danglingReason": "Skill 原目录已不存在，失效链接默认勾选，可清理。",
            "agents.manage.cleanDangling": "清理失效链接",
            "agents.manage.cleanDanglingTitle": "清理所选 Skill 失效链接？",
            "agents.manage.cleanDanglingImpact": "移除目标已不存在的所选链接。扫描后目标已恢复的会保留；涉及配置修改时会先备份。",
            "agents.manage.readOnly": "没有可删除的本地本体，可单独管理绑定。",
            "agents.manage.search": "搜索名称、路径或 Agent", "agents.manage.selectBindings": "全选可解绑项",
            "agents.manage.selectSources": "全选本体", "agents.manage.clear": "取消选择",
            "agents.manage.bindings": "%d 个绑定", "agents.manage.selected": "已选 %d 项",
            "agents.manage.cleanData": "清理所选数据", "agents.manage.open": "显示本体",
            "agents.manage.empty": "没有匹配的资源", "agents.manage.scope": "范围：%@"
        ]
        return language == .zhHans || language == .zhHant ? zh : en
    }
}
