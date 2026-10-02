import AppKit
import Foundation

/// Brand identity is independent of CLI locations: executable icons belong to
/// the shell/file type, not to the Agent that owns its data.
struct AgentIconDescriptor: Equatable {
    var bundleIDs: [String] = []
    var bundleNames: [String] = []
    var assetName: String?
    var templateAsset = false
}

enum AgentIconCatalog {
    static func descriptor(for agentID: String) -> AgentIconDescriptor? {
        switch agentID {
        case "claude-code", "claude-desktop":
            return .init(bundleIDs: ["com.anthropic.claudefordesktop"], bundleNames: ["Claude"], assetName: "claude")
        case "codex", "codex-app":
            return .init(bundleIDs: ["com.openai.codex"], bundleNames: ["Codex"])
        case "cursor", "cursor-cli":
            return .init(bundleIDs: ["com.todesktop.230313mzl4w4u92"], bundleNames: ["Cursor"])
        case "copilot": return .init(assetName: "copilot", templateAsset: true)
        case "gemini": return .init(assetName: "gemini")
        case "antigravity":
            return .init(bundleIDs: ["com.google.antigravity"], bundleNames: ["Antigravity"])
        case "opencode": return .init(bundleNames: ["OpenCode", "opencode"], assetName: "opencode")
        case "grok": return .init()
        case "pi": return .init(assetName: "pi")
        case "kimi": return .init(assetName: "kimi")
        case "factory", "droid": return .init(bundleNames: ["Factory"], assetName: "factory")
        case "devin", "windsurf":
            return .init(bundleIDs: ["com.exafunction.windsurf"], bundleNames: ["Devin", "Windsurf"])
        case "qoder": return .init(bundleNames: ["Qoder"])
        case "kiro": return .init(bundleNames: ["Kiro"])
        case "trae": return .init(bundleNames: ["Trae"])
        case "zed":
            return .init(bundleIDs: ["dev.zed.Zed", "dev.zed.Zed-Preview", "dev.zed.Zed-Nightly"],
                         bundleNames: ["Zed", "Zed Preview", "Zed Nightly"])
        case "warp":
            return .init(bundleIDs: ["dev.warp.Warp-Stable", "dev.warp.Warp-Preview"],
                         bundleNames: ["Warp", "WarpPreview", "Warp Preview"])
        case "amp": return .init(assetName: "amp")
        case "crush": return .init()
        case "chrome-devtools-mcp":
            return .init(bundleIDs: ["com.google.Chrome", "com.google.Chrome.canary"],
                         bundleNames: ["Google Chrome", "Google Chrome Canary"])
        case "shared", "shared-mcp": return .init()
        default: return nil
        }
    }
}

struct AgentIconImage {
    let image: NSImage
    let isTemplate: Bool
}

/// App metadata and NSWorkspace lookup stay off the UI actor. The bounded
/// cache keys installed images by bundle path and modification time so tab
/// revisits do not reload icons, while app updates can refresh them.
enum AgentIconLoader {
    private static let queue = DispatchQueue(label: "com.nori.agent-icons", qos: .utility)
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()

    static func image(agentID: String) async -> AgentIconImage? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let descriptor = AgentIconCatalog.descriptor(for: agentID) else {
                    continuation.resume(returning: nil)
                    return
                }
                let directories = ["/Applications", NSHomeDirectory() + "/Applications", "/System/Applications"]
                if let app = applicationURL(for: descriptor, directories: directories,
                    registeredApplication: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }) {
                    let modified = (try? app.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
                    let key = "app:\(app.path):\(modified)" as NSString
                    if let image = cache.object(forKey: key) {
                        continuation.resume(returning: .init(image: image, isTemplate: false))
                        return
                    }
                    let image = NSWorkspace.shared.icon(forFile: app.path)
                    cache.setObject(image, forKey: key)
                    continuation.resume(returning: .init(image: image, isTemplate: false))
                    return
                }
                guard let asset = assetURL(for: descriptor, resourceRoot: Bundle.main.resourceURL) else {
                    continuation.resume(returning: nil)
                    return
                }
                let key = "asset:\(asset.path)" as NSString
                let image = cache.object(forKey: key) ?? NSImage(contentsOf: asset)
                if let image { cache.setObject(image, forKey: key) }
                continuation.resume(returning: image.map {
                    AgentIconImage(image: $0, isTemplate: descriptor.templateAsset)
                })
            }
        }
    }

    static func assetURL(for descriptor: AgentIconDescriptor, resourceRoot: URL?) -> URL? {
        guard let resourceRoot, let name = descriptor.assetName else { return nil }
        let directory = resourceRoot.appendingPathComponent("AgentIcons", isDirectory: true)
        return ["pdf", "png", "ico"].lazy.map {
            directory.appendingPathComponent(name + "." + $0)
        }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func applicationURL(for descriptor: AgentIconDescriptor, directories: [String],
                               registeredApplication: (String) -> URL?) -> URL? {
        var candidates = descriptor.bundleIDs.compactMap(registeredApplication)
        for directory in directories {
            candidates += descriptor.bundleNames.map {
                URL(fileURLWithPath: directory, isDirectory: true)
                    .appendingPathComponent($0 + ".app", isDirectory: true)
            }
        }
        return candidates.first { hasApplicationIcon(at: $0, expectedBundleIDs: descriptor.bundleIDs) }
    }

    private static func hasApplicationIcon(at url: URL, expectedBundleIDs: [String]) -> Bool {
        guard url.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: url),
              let info = bundle.infoDictionary,
              info["CFBundlePackageType"] as? String == "APPL",
              let identifier = info["CFBundleIdentifier"] as? String,
              expectedBundleIDs.isEmpty || expectedBundleIDs.contains(identifier),
              let resources = bundle.resourceURL else { return false }
        // An app without a declared icon yields the generic macOS application
        // icon. Prefer our bundled brand mark or custom fallback in that case.
        if let file = info["CFBundleIconFile"] as? String, !file.isEmpty {
            let icon = resources.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: icon.path)
                || FileManager.default.fileExists(atPath: icon.appendingPathExtension("icns").path) {
                return true
            }
        }
        return info["CFBundleIconName"] as? String != nil
            && FileManager.default.fileExists(atPath: resources.appendingPathComponent("Assets.car").path)
    }
}
