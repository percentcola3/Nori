import Darwin
import Foundation

/// The software installed for an Agent is independent of its shared data.
/// Match catalog evidence before measuring any application bundle.
enum AgentSoftwareInventory {
    static func agentIDs(for app: UninstallApp) -> Set<String> {
        matchingAgentIDs(name: app.name, bundleID: app.bundleID, path: app.path)
    }

    static func applications(home: String = NSHomeDirectory(),
                             presence: AgentPresenceContext? = nil,
                             sizer: any ApplicationSizeMeasuring = BoundedApplicationSizeMeasurer())
        -> [String: [UninstallApp]] {
        let inventory = NativeApplicationInventory(sizer: sizer)
        let roots = presence.map {
            $0.applicationDirs.map { (URL(fileURLWithPath: $0, isDirectory: true), "Applications") }
        } ?? inventory.roots(home: URL(fileURLWithPath: home, isDirectory: true).standardizedFileURL)
        var seenRoots = Set<String>()
        var seenApps = Set<String>()
        var result: [String: [UninstallApp]] = [:]
        for (root, source) in roots {
            let physicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
            guard let rootIdentity = inventory.directoryIdentity(physicalRoot),
                  seenRoots.insert(rootIdentity).inserted else { continue }
            for appURL in inventory.children(of: physicalRoot) {
                guard appURL.pathExtension.lowercased() == "app",
                      let physicalIdentity = inventory.directoryIdentity(appURL),
                      !seenApps.contains(physicalIdentity),
                      let metadata = inventory.metadata(at: appURL) else { continue }
                let agentIDs = matchingAgentIDs(name: metadata.name, bundleID: metadata.bundleID,
                                               path: appURL.path)
                guard !agentIDs.isEmpty,
                      let appIdentity = DeletionPlan.identity(at: appURL.path),
                      let infoIdentity = DeletionPlan.identity(at: appURL.path + "/Contents/Info.plist") else { continue }
                let bytes = sizer.allocatedBytes(at: appURL)
                // A scan may overlap an installer replacing the bundle or its
                // manifest. Keep a row only when its captured evidence agrees.
                guard DeletionPlan.identity(at: appURL.path) == appIdentity,
                      DeletionPlan.identity(at: appURL.path + "/Contents/Info.plist") == infoIdentity,
                      inventory.directoryIdentity(appURL) == physicalIdentity else { continue }
                seenApps.insert(physicalIdentity)
                let app = UninstallApp(name: metadata.name, bundleID: metadata.bundleID,
                    source: source, path: appURL.path, size: ByteFormat.format(bytes),
                    appIdentity: appIdentity, infoIdentity: infoIdentity)
                for agentID in agentIDs { result[agentID, default: []].append(app) }
            }
        }
        for agentID in Array(result.keys) {
            result[agentID]?.sort {
                let lhs = ByteFormat.parse($0.size), rhs = ByteFormat.parse($1.size)
                if lhs != rhs { return lhs > rhs }
                let names = $0.name.localizedStandardCompare($1.name)
                return names == .orderedSame ? $0.path < $1.path : names == .orderedAscending
            }
        }
        return result
    }

    /// Preserve the exact installation record used by the shared CLI workflow.
    /// Local runtimes remain read-only; verified native/bun Agent installs carry
    /// the Agent remover rather than a generic local-file deletion route.
    static func commandLineTool(for installation: AgentCLIInstallation,
                                bytes: UInt64 = 0, sizeIsKnown: Bool = false) -> CommandLineTool {
        let manager: CommandLineTool.Manager
        switch installation.manager {
        case .homebrew: manager = .homebrew
        case .npm: manager = .npm
        case .pnpm: manager = .pnpm
        case .pipx: manager = .pipx
        case .uv: manager = .uv
        case .native, .bun: manager = .local
        }
        return CommandLineTool(manager: manager, name: installation.packageName ?? installation.name,
            version: manifestVersion(for: installation),
            path: installation.managedPaths.first ?? installation.executablePaths.first ?? "",
            bytes: bytes, dependents: [], installedOnRequest: true,
            agentID: installation.agentID,
            installationSource: installation.manager == .native ? "Native" : installation.manager.rawValue,
            supportsPublicRegistryUpdates: manager != .local,
            executablePaths: installation.executablePaths, agentInstallation: installation,
            sizeIsKnown: sizeIsKnown, managerExecutable: installation.managerExecutable)
    }

    private static func matchingAgentIDs(name: String, bundleID: String, path: String) -> Set<String> {
        let names = Set([name, URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent])
        return Set(AgentCatalog.definitions.compactMap { agent in
            let declaredNames = AgentCatalog.installationPresence(for: agent)?.bundleNames ?? []
            let matchesName = declaredNames.contains { names.contains($0) }
            let matchesBundle = !bundleID.isEmpty && agent.owners.contains {
                CleanupRiskPolicy.isValidReverseDNSOwner($0) && $0 == bundleID
            }
            return matchesName || matchesBundle ? agent.id : nil
        })
    }

    private static func manifestVersion(for installation: AgentCLIInstallation) -> String {
        guard let package = installation.packageName,
              let root = installation.managedPaths.first,
              DeletionPlan.isLexicallySafePath(root) else { return "" }
        let manifest = root + "/package.json"
        let descriptor = open(manifest, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return "" }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size > 0, metadata.st_size <= 1_048_576,
              let data = try? FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).read(upToCount: 1_048_577),
              data.count <= 1_048_576,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["name"] as? String == package else { return "" }
        return object["version"] as? String ?? ""
    }
}
