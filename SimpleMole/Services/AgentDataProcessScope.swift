import AppKit
import Darwin
import Foundation

/// Data cleanup has separate consent from uninstalling an installation. Close
/// only verified installations and Workspace applications associated with the
/// selected Agent, including its real extension hosts. Names are not authority.
@MainActor
enum AgentDataProcessScope {
    struct Application: Sendable {
        let bundleID: String
        let name: String
        let bundlePath: String
        let identity: ProcessIdentity
    }

    struct Environment {
        var applications: @MainActor () -> [Application] = { workspaceApplications() }
        var resolvedOwnerIDs: @MainActor (Set<String>, String) -> Set<String> = { ids, home in
            Set(AgentCatalog.definitions.filter { ids.contains($0.id) }.flatMap {
                AgentCatalog.runtimeOwners(for: $0, home: home)
            }.filter(CleanupRiskPolicy.isValidReverseDNSOwner))
        }
        var verifiedBundleID: @MainActor (String) -> String? = { verifiedBundleIdentifier(at: $0) }
        var current: (ProcessIdentity) -> ProcessSample? = { ProcessSampler.shared.current(for: $0) }
        var ownUID: UInt32 = getuid()
    }

    static func make(agentIDs: Set<String>, cli: [AgentCLIInstallation], home: String = NSHomeDirectory())
        -> SoftwareUpdateProcesses.Scope {
        make(agentIDs: agentIDs, cli: cli, home: home, environment: Environment())
    }

    static func make(agentIDs: Set<String>, cli: [AgentCLIInstallation], home: String = NSHomeDirectory(),
                     environment: Environment) -> SoftwareUpdateProcesses.Scope {
        guard !agentIDs.isEmpty else { return .init(roots: []) }
        var roots = Set<String>()
        for installation in cli where agentIDs.contains(installation.agentID) {
            // A native link-only record explicitly leaves its unknown target
            // installed. It cannot authorize stopping every process at that target.
            guard !installation.onlyUnlinksExecutable else { continue }
            for path in installation.managedPaths + installation.executablePaths {
                guard DeletionPlan.isLexicallySafePath(path), path != "/", path != home else { continue }
                // A changed launcher is no longer the captured installation's
                // executable. Keep its trusted package root, not a new link target.
                if AgentCatalog.isSymlink(path),
                   installation.identities[path] != DeletionPlan.identity(at: path) { continue }
                roots.insert(path)
            }
        }
        let matchesScripts = !roots.isEmpty
        let ownerIDs = Set(environment.resolvedOwnerIDs(agentIDs, home)
            .filter(CleanupRiskPolicy.isValidReverseDNSOwner))
        var applicationIdentities = Set<ProcessIdentity>()
        if !ownerIDs.isEmpty {
            for application in environment.applications() {
                guard ownerIDs.contains(application.bundleID),
                      DeletionPlan.isLexicallySafePath(application.bundlePath),
                      URL(fileURLWithPath: application.bundlePath).pathExtension.lowercased() == "app",
                      application.identity.pid > 1, application.identity.startTime > 0,
                      application.identity.uid == environment.ownUID else { continue }
                let physical = URL(fileURLWithPath: application.bundlePath).resolvingSymlinksInPath().path
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: physical, isDirectory: &directory), directory.boolValue,
                      environment.verifiedBundleID(physical) == application.bundleID,
                      let current = environment.current(application.identity),
                      current.identity == application.identity, !current.isZombie, !current.isExiting,
                      DeletionPlan.isLexicallySafePath(current.path) else { continue }
                roots.insert(physical)
                // A real Workspace application's executable may use a signing
                // clone or translocation path outside its installed bundle.
                applicationIdentities.insert(application.identity)
            }
        }
        return .init(roots: roots.sorted(), matchesScripts: matchesScripts,
                     applicationIdentities: applicationIdentities)
    }

    private static func workspaceApplications() -> [Application] {
        let applications = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        let samples = Dictionary(ProcessSampler.shared.snapshot().processes.map { ($0.pid, $0) },
                                 uniquingKeysWith: { first, _ in first })
        return applications.compactMap { application in
            guard let bundleID = application.bundleIdentifier, let bundleURL = application.bundleURL,
                  let launch = application.launchDate,
                  let sample = samples[application.processIdentifier], !sample.isZombie, !sample.isExiting,
                  let fresh = NSRunningApplication(processIdentifier: application.processIdentifier), !fresh.isTerminated,
                  fresh.bundleIdentifier == bundleID, fresh.bundleURL == bundleURL,
                  fresh.launchDate == launch else { return nil }
            return Application(bundleID: bundleID, name: application.localizedName ?? bundleID,
                               bundlePath: bundleURL.path, identity: sample.identity)
        }
    }

    private static func verifiedBundleIdentifier(at path: String) -> String? {
        guard let appIdentity = DeletionPlan.identity(at: path),
              let infoIdentity = DeletionPlan.identity(at: path + "/Contents/Info.plist"),
              let bundle = Bundle(path: path), bundle.infoDictionary?["CFBundlePackageType"] as? String == "APPL",
              let bundleID = bundle.bundleIdentifier, CleanupRiskPolicy.isValidReverseDNSOwner(bundleID),
              DeletionPlan.identity(at: path) == appIdentity,
              DeletionPlan.identity(at: path + "/Contents/Info.plist") == infoIdentity else { return nil }
        return bundleID
    }
}
