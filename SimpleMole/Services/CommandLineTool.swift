import Foundation

/// 软件页的命令行工具清单：先发现安装，再探测版本和容量。
/// 同名工具按物理安装目录区分，管理器操作绑定该目录。
struct CommandLineTool: Identifiable, Equatable, Sendable {
    enum Manager: String, CaseIterable, Sendable {
        case homebrew, npm, pnpm, pipx, uv, cargo, go, local

        var displayName: String {
            switch self {
            case .homebrew: return "Homebrew"
            case .npm: return "npm"
            case .pnpm: return "pnpm"
            case .pipx: return "pipx"
            case .uv: return "uv"
            case .cargo: return "cargo"
            case .go: return "go"
            case .local: return "Local"
            }
        }
    }

    let manager: Manager
    let name: String
    var version: String
    let path: String
    var bytes: UInt64
    let dependents: [String]
    let installedOnRequest: Bool
    var agentID: String? = nil
    var installationSource: String? = nil
    var updatePackageName: String? = nil
    var supportsPublicRegistryUpdates = true
    var executablePaths: [String] = []
    var agentInstallation: AgentCLIInstallation? = nil
    var sizeIsKnown = true
    var managerExecutable: String? = nil

    var installationRoot: String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return manager == .homebrew && url.lastPathComponent != name ? url.deletingLastPathComponent().path : url.path
    }
    var id: String {
        manager.rawValue + ":" + name + ":" + URL(fileURLWithPath: installationRoot).resolvingSymlinksInPath().path
    }
    var canUninstall: Bool { (manager != .local || agentInstallation != nil) && dependents.isEmpty }
}
