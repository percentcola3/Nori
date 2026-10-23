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
    var installationIdentities: [String: String] = [:]

    var installationRoot: String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return manager == .homebrew && url.lastPathComponent != name ? url.deletingLastPathComponent().path : url.path
    }
    var id: String {
        manager.rawValue + ":" + name + ":" + URL(fileURLWithPath: installationRoot).resolvingSymlinksInPath().path
    }
    var canUninstall: Bool { (manager != .local || agentInstallation != nil) && dependents.isEmpty }

    var uninstallDataOwner: UninstallDataOwner {
        let commands = executablePaths.map { URL(fileURLWithPath: $0).lastPathComponent }
        let package = name.split(separator: "/").last.map(String.init) ?? name
        return .init(kind: .cli, name: name, installationPath: installationRoot,
                     names: Array(Set([package] + commands)).sorted(), commands: commands.isEmpty ? [package] : commands,
                     agentIDs: agentID.map { [$0] } ?? [])
    }

    /// Validate the installation evidence used by discovery. A receipt-backed
    /// tool remains actionable when its command file has already disappeared.
    var confirmationPath: String {
        if manager == .cargo {
            return URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".crates.toml").path
        }
        return path
    }
}

/// Cargo discovery and removal confirmation read the same install receipt.
/// An unreadable/unsupported receipt is different from an empty one.
enum CargoInstallReceipt {
    struct Package {
        let name: String
        let version: String
        let binaries: [String]
        let supportsPublicRegistryUpdates: Bool
    }

    static func packages(at path: String) -> [Package]? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let pattern = try? NSRegularExpression(pattern: #"^"([^ "]+) ([^ "]+) [^"]*"\s*=\s*\[(.*)\]$"#) else { return nil }
        var inPackages = false
        var packages: [Package] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                guard line == "[v1]" else { return nil }
                inPackages = true
                continue
            }
            guard inPackages,
                  let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let nameRange = Range(match.range(at: 1), in: line),
                  let versionRange = Range(match.range(at: 2), in: line),
                  let binaryRange = Range(match.range(at: 3), in: line) else { return nil }
            let binaries = line[binaryRange].split(separator: ",").map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            }
            guard Set(binaries).count == binaries.count,
                  binaries.allSatisfy({ $0 != "." && $0 != ".."
                && $0.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil }) else { return nil }
            packages.append(.init(name: String(line[nameRange]), version: String(line[versionRange]), binaries: binaries,
                supportsPublicRegistryUpdates: line.contains("registry+https://github.com/rust-lang/crates.io-index")
                    || line.contains("registry+https://index.crates.io/")))
        }
        return inPackages ? packages : nil
    }
}
