import AppKit
import SwiftUI

@main
struct AgentIconTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let support = root.appendingPathComponent("SimpleMole/Support", isDirectory: true)
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("nori-agent-icons-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let recognized = ["claude-code", "claude-desktop", "codex", "codex-app", "cursor", "cursor-cli",
            "copilot", "gemini", "antigravity", "opencode", "grok", "pi", "kimi", "factory", "devin",
            "windsurf", "chrome-devtools-mcp", "qoder", "kiro", "trae", "zed", "warp", "amp", "crush", "shared"]
        for id in recognized { precondition(AgentIconCatalog.descriptor(for: id) != nil, "Missing \(id)") }
        precondition(AgentIconCatalog.descriptor(for: "unknown-agent") == nil)
        precondition(AgentIconCatalog.descriptor(for: "cursor") == AgentIconCatalog.descriptor(for: "cursor-cli"))
        precondition(AgentIconCatalog.descriptor(for: "codex") == AgentIconCatalog.descriptor(for: "codex-app"))
        precondition(AgentIconCatalog.descriptor(for: "claude-code") == AgentIconCatalog.descriptor(for: "claude-desktop"))
        precondition(AgentIconCatalog.descriptor(for: "factory") == AgentIconCatalog.descriptor(for: "droid"))

        for id in ["claude-code", "copilot", "gemini", "opencode", "pi", "kimi", "factory", "amp"] {
            let descriptor = AgentIconCatalog.descriptor(for: id)!
            guard let asset = AgentIconLoader.assetURL(for: descriptor, resourceRoot: support),
                  let image = NSImage(contentsOf: asset) else { preconditionFailure("Undecodable \(id) brand icon") }
            precondition(image.size.width > 0 && image.size.height > 0)
        }
        precondition(AgentIconCatalog.descriptor(for: "copilot")!.templateAsset,
                     "The monochrome Copilot mark must adapt to light/dark appearance")
        precondition(AgentIconLoader.assetURL(for: .init(assetName: "missing"), resourceRoot: support) == nil)

        func app(_ name: String, identifier: String, icon: Bool) throws -> URL {
            let app = fixture.appendingPathComponent(name + ".app", isDirectory: true)
            let contents = app.appendingPathComponent("Contents", isDirectory: true)
            let resources = contents.appendingPathComponent("Resources", isDirectory: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            var plist: [String: String] = ["CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL"]
            if icon {
                plist["CFBundleIconFile"] = "icon.png"
                try FileManager.default.copyItem(at: support.appendingPathComponent("AgentIcons/claude.png"),
                                                 to: resources.appendingPathComponent("icon.png"))
            }
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            return app
        }
        let cursor = AgentIconCatalog.descriptor(for: "cursor-cli")!
        let installed = try app("Cursor", identifier: cursor.bundleIDs[0], icon: true)
        let wrong = try app("Wrong", identifier: "com.example.unrelated", icon: true)
        precondition(AgentIconLoader.applicationURL(for: cursor, directories: [fixture.path],
            registeredApplication: { _ in wrong }) == installed, "An unrelated registered app must not replace Cursor")
        let binary = fixture.appendingPathComponent("cursor-agent")
        try Data().write(to: binary)
        precondition(AgentIconLoader.applicationURL(for: cursor, directories: [fixture.path],
            registeredApplication: { _ in binary }) == installed, "A CLI binary must never supply a generic execution icon")
        let noIcon = try app("NoIcon", identifier: cursor.bundleIDs[0], icon: false)
        precondition(AgentIconLoader.applicationURL(for: cursor, directories: [],
            registeredApplication: { _ in noIcon }) == nil, "Apps without their own icon must fall back to a brand/default mark")

        let fallback = ImageRenderer(content: AgentIconView(agentID: "unknown-agent", size: 24))
        precondition(fallback.nsImage?.size == CGSize(width: 24, height: 24),
                     "The code-native fallback must keep the Agent header's icon footprint")
        print("Agent icons: catalog aliases, official bundled image decoding, app identity selection, CLI rejection and fallback footprint passed")
    }
}
