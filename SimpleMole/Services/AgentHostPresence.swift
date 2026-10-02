import Darwin
import CoreFoundation
import Foundation

/// IDE 扩展与 CLI 可以共用 Agent 数据；只有实际安装的宿主和扩展都存在才保留归属。
enum AgentHostPresence {
    private struct Host: Sendable {
        let bundleNames: [String]
        let bundleID: String
        let command: String
        let extensionsRoot: String
        let processName: String
    }

    private static let hosts = [
        Host(bundleNames: ["Visual Studio Code", "Code"], bundleID: "com.microsoft.VSCode",
             command: "code", extensionsRoot: ".vscode/extensions", processName: "Code"),
        Host(bundleNames: ["Visual Studio Code - Insiders", "Code - Insiders"],
             bundleID: "com.microsoft.VSCodeInsiders", command: "code-insiders",
             extensionsRoot: ".vscode-insiders/extensions", processName: "Code - Insiders"),
        Host(bundleNames: ["Cursor"], bundleID: "com.todesktop.230313mzl4w4u92",
             command: "cursor", extensionsRoot: ".cursor/extensions", processName: "Cursor")
    ]
    private static let maximumManifestBytes = 2_097_152
    private static let maximumObsoleteBytes = 1_048_576

    static func hasExtension(ids: [String], home: String, context: AgentPresenceContext) -> Bool {
        !owners(ids: ids, home: home, context: context).isEmpty
    }

    /// Codex can be shipped inside ChatGPT rather than as a separate Codex.app.
    /// The host identity and its active framework must both be real bundles;
    /// a ChatGPT installation alone is not evidence that it contains Codex.
    static func integratedCodexOwners(context: AgentPresenceContext) -> [String] {
        var matches = Set<String>()
        for directory in context.applicationDirs {
            let app = URL(fileURLWithPath: directory).appendingPathComponent("ChatGPT.app")
                .standardizedFileURL.path
            guard let executable = appExecutable(at: app, bundleID: "com.openai.codex"),
                  let framework = activeFrameworkDirectory(app + "/Contents/Frameworks/Codex Framework.framework"),
                  let info = readPropertyList(framework + "/Resources/Info.plist"),
                  info["CFBundleIdentifier"] as? String == "com.openai.codex.framework",
                  info["CFBundlePackageType"] as? String == "FMWK",
                  info["CFBundleExecutable"] as? String == "Codex Framework",
                  isRegularExecutable(framework + "/Codex Framework") else { continue }
            matches.formUnion(["com.openai.codex", executable])
            for (name, bundleID) in [
                ("Codex (Service)", "com.openai.codex.helper"),
                ("Codex (Renderer)", "com.openai.codex.helper.renderer")
            ] {
                if let helper = appExecutable(at: framework + "/Helpers/" + name + ".app", bundleID: bundleID) {
                    matches.formUnion([bundleID, helper])
                }
            }
        }
        return matches.sorted()
    }

    /// Accept only the conventional Current -> <version> framework link. Its
    /// destination must remain a physical child of this framework's Versions.
    private static func activeFrameworkDirectory(_ framework: String) -> String? {
        guard hasPhysicalAncestors(framework), AgentCatalog.isDirectory(framework) else { return nil }
        let versions = framework + "/Versions"
        if AgentCatalog.exists(versions) {
            guard hasPhysicalAncestors(versions), AgentCatalog.isDirectory(versions) else { return nil }
            let current = versions + "/Current"
            let active: String
            if AgentCatalog.isSymlink(current) {
                guard let version = try? FileManager.default.destinationOfSymbolicLink(atPath: current),
                      isBundleExecutableName(version), version != "Current" else { return nil }
                active = versions + "/" + version
            } else {
                active = current
            }
            return hasPhysicalAncestors(active) && AgentCatalog.isDirectory(active) ? active : nil
        }
        return framework
    }

    private static func appExecutable(at app: String, bundleID: String) -> String? {
        guard hasPhysicalAncestors(app), AgentCatalog.isDirectory(app),
              let info = readPropertyList(app + "/Contents/Info.plist"),
              info["CFBundleIdentifier"] as? String == bundleID,
              info["CFBundlePackageType"] as? String == "APPL",
              let executable = info["CFBundleExecutable"] as? String,
              isBundleExecutableName(executable),
              isRegularExecutable(app + "/Contents/MacOS/" + executable) else { return nil }
        return executable
    }

    private static func readPropertyList(_ path: String) -> [String: Any]? {
        guard let data = readRegularFile(path, maximumBytes: maximumManifestBytes) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func isBundleExecutableName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("\0") && name != "." && name != ".."
    }

    /// 只返回确实装有匹配扩展的宿主，供删除时的活动进程 / bundle 占用复核。
    static func owners(ids: [String], home: String, context: AgentPresenceContext) -> [String] {
        let expected = Set(ids.map { $0.lowercased() }.filter { !$0.isEmpty })
        guard !expected.isEmpty else { return [] }
        var matches = Set<String>()
        for host in hosts where isInstalled(host, context: context) {
            let root = AgentCatalog.absolute(host.extensionsRoot, home: home)
            guard AgentCatalog.isPhysical(root, home: home), AgentCatalog.isDirectory(root),
                  let obsolete = obsoleteFolders(at: root) else { continue }
            for folder in AgentCatalog.childNames(of: root) where !obsolete.contains(folder.lowercased()) {
                let directory = root + "/" + folder
                guard AgentCatalog.isPhysical(directory, home: home), AgentCatalog.isDirectory(directory),
                      let manifest = readJSONObject(directory + "/package.json", maximumBytes: maximumManifestBytes),
                      let publisher = manifest["publisher"] as? String,
                      let name = manifest["name"] as? String,
                      isIdentifierComponent(publisher), isIdentifierComponent(name),
                      expected.contains((publisher + "." + name).lowercased()) else { continue }
                matches.insert(host.bundleID)
                matches.insert(host.processName)
                break
            }
        }
        return matches.sorted()
    }

    private static func isInstalled(_ host: Host, context: AgentPresenceContext) -> Bool {
        for directory in context.applicationDirs {
            for name in host.bundleNames {
                let app = URL(fileURLWithPath: directory).appendingPathComponent(name + ".app")
                    .standardizedFileURL.path
                guard appExecutable(at: app, bundleID: host.bundleID) != nil else { continue }
                return true
            }
        }
        return context.searchPath.contains {
            isRegularExecutable(URL(fileURLWithPath: $0).appendingPathComponent(host.command)
                .standardizedFileURL.path)
        }
    }

    private static func obsoleteFolders(at root: String) -> Set<String>? {
        let path = root + "/.obsolete"
        if !AgentCatalog.exists(path) { return [] }
        guard let object = readJSONObject(path, maximumBytes: maximumObsoleteBytes) else { return nil }
        return Set(object.compactMap { key, value in
            // .obsolete 的值是 JSON boolean；不把数字 1 当作已卸载标记。
            guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID(),
                  value.boolValue else { return nil }
            return key.lowercased()
        })
    }

    private static func readJSONObject(_ path: String, maximumBytes: Int) -> [String: Any]? {
        guard let data = readRegularFile(path, maximumBytes: maximumBytes) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func readRegularFile(_ path: String, maximumBytes: Int) -> Data? {
        guard hasPhysicalAncestors(path), isRegularFile(path),
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumBytes + 1),
              data.count <= maximumBytes else { return nil }
        return data
    }

    private static func isRegularExecutable(_ path: String) -> Bool {
        var metadata = stat()
        return hasPhysicalAncestors(path) && lstat(path, &metadata) == 0
            && (metadata.st_mode & S_IFMT) == S_IFREG && metadata.st_size > 0
            && FileManager.default.isExecutableFile(atPath: path)
    }

    private static func isRegularFile(_ path: String) -> Bool {
        var metadata = stat()
        return lstat(path, &metadata) == 0 && (metadata.st_mode & S_IFMT) == S_IFREG
    }

    private static func hasPhysicalAncestors(_ path: String) -> Bool {
        var current = URL(fileURLWithPath: path).standardizedFileURL.path
        guard current.hasPrefix("/") else { return false }
        while current != "/" {
            if AgentCatalog.isSymlink(current) { return false }
            current = (current as NSString).deletingLastPathComponent
        }
        return true
    }

    private static func isIdentifierComponent(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 256 && value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
    }
}
