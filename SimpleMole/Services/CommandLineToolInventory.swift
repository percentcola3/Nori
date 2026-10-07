import Foundation

enum CommandLineToolInventory {
    struct DiscoveryContext {
        let home: String
        let searchPath: [String]
        let control: CleanupScanControl
    }

    /// Each provider appends metadata; it cannot remove an earlier provider's
    /// installations. Receipts and optional enrichment have separate budgets.
    struct DiscoveryProvider {
        let name: String
        let discover: (DiscoveryContext, [CommandLineTool]) throws -> [CommandLineTool]
    }

    struct Dependencies {
        var providers: [DiscoveryProvider]
        var agentInstallations: (DiscoveryContext) -> [AgentCLIInstallation] = { context in
            AgentCatalog.definitions.flatMap { AgentCLIService.installations(for: $0, home: context.home) }
        }
        var inspectVersion: (CommandLineTool, DiscoveryContext) -> String? = { tool, context in
            CLIInstalledToolDiscovery.inspectVersion(tool, home: context.home, searchPath: context.searchPath)
        }
        var measure: (String, CleanupScanControl) -> CleanupScanWorker.Measurement = CleanupScanWorker.measure
        var versionBudget: TimeInterval = 12

        static var live: Self {
            .init(providers: [
                .init(name: "homebrew") { context, _ in
                    CLIInstalledToolDiscovery.homebrewFormulae(home: context.home,
                        searchPath: context.searchPath, control: context.control)
                },
                .init(name: "npm") { context, _ in
                    CLIInstalledToolDiscovery.nodeGlobals(.npm, home: context.home,
                        searchPath: context.searchPath, control: context.control)
                },
                .init(name: "pnpm") { context, _ in
                    CLIInstalledToolDiscovery.nodeGlobals(.pnpm, home: context.home,
                        searchPath: context.searchPath, control: context.control)
                },
                .init(name: "pipx") { context, _ in
                    CLIInstalledToolDiscovery.pipxTools(home: context.home,
                        searchPath: context.searchPath, control: context.control)
                },
                .init(name: "uv") { context, _ in
                    CLIInstalledToolDiscovery.uvTools(home: context.home,
                        searchPath: context.searchPath, control: context.control)
                },
                .init(name: "cargo") { context, _ in
                    CLIInstalledToolDiscovery.cargoTools(home: context.home,
                        control: context.control, searchPath: context.searchPath)
                },
                .init(name: "go") { context, _ in CLIInstalledToolDiscovery.goBinaries(home: context.home) },
                .init(name: "local") { context, managed in
                    CLIInstalledToolDiscovery.localTools(home: context.home, managed: managed)
                }
            ])
        }
    }

    struct ProviderFailure: Equatable {
        let provider: String
        let message: String
    }

    struct ScanResult {
        let tools: [CommandLineTool]
        let providerFailures: [ProviderFailure]
    }

    static func scan(home: String = NSHomeDirectory(),
                     control: CleanupScanControl = CleanupScanControl(mode: .deep, totalBudget: 60, directoryBudget: 20),
                     dependencies: Dependencies = .live) -> [CommandLineTool] {
        scanResult(home: home, control: control, dependencies: dependencies).tools
    }

    static func scanResult(home: String, control: CleanupScanControl,
                           dependencies: Dependencies) -> ScanResult {
        let discovery = CleanupScanControl(mode: .deep, cancellationSource: control)
        let context = DiscoveryContext(home: home,
            searchPath: AgentCatalog.executableSearchPath(home: home), control: discovery)
        var tools: [CommandLineTool] = []
        var failures: [ProviderFailure] = []
        for provider in dependencies.providers {
            guard !control.isCancelled else { break }
            do { tools += try provider.discover(context, tools) }
            catch { failures.append(.init(provider: provider.name, message: error.localizedDescription)) }
        }
        let installations = control.isCancelled ? [] : dependencies.agentInstallations(context)
        let collected = mergingAgents(tools, installations: installations, control: discovery)
        let versionControl = CleanupScanControl(mode: .deep, totalBudget: dependencies.versionBudget,
                                               cancellationSource: control)
        var enriched = deduplicated(collected)
        for index in enriched.indices where enriched[index].version.isEmpty && enriched[index].manager == .local {
            guard !versionControl.shouldStop else { break }
            if let version = dependencies.inspectVersion(enriched[index], context) { enriched[index].version = version }
        }
        let sizing = CleanupScanControl(mode: .deep, totalBudget: control.totalBudget,
            directoryBudget: control.directoryBudget, onDirectory: { control.reportDirectory($0) },
            cancellationSource: control)
        let sized = sizeTools(enriched, control: sizing, measure: dependencies.measure)
        return .init(tools: sized.sorted {
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            return $0.name != $1.name ? $0.name < $1.name : $0.id < $1.id
        }, providerFailures: failures)
    }

    static func sizeTools(_ tools: [CommandLineTool], control: CleanupScanControl,
                          measure: (String, CleanupScanControl) -> CleanupScanWorker.Measurement = CleanupScanWorker.measure) -> [CommandLineTool] {
        var output = tools
        for index in output.indices where ![.cargo, .go].contains(output[index].manager)
            && (output[index].manager != .local || output[index].agentInstallation != nil) {
            guard !control.shouldStop else {
                output[index].sizeIsKnown = false
                continue
            }
            let paths = output[index].agentInstallation?.managedPaths ?? [output[index].path]
            let measurements = DeletionPlan.nonOverlappingPaths(paths).map { measure($0, control) }
            output[index].bytes = measurements.reduce(0) { $0 &+ $1.bytes }
            output[index].sizeIsKnown = measurements.allSatisfy(\.complete)
        }
        return output
    }

    static func deduplicated(_ tools: [CommandLineTool]) -> [CommandLineTool] {
        var output: [CommandLineTool] = []
        var locations: [String: Int] = [:]
        for tool in tools {
            let physical = URL(fileURLWithPath: tool.installationRoot).resolvingSymlinksInPath().path
            let key = tool.manager.rawValue + ":" + tool.name + ":" + physical
            if let index = locations[key] {
                if output[index].agentInstallation == nil, tool.agentInstallation != nil { output[index] = tool }
            } else { locations[key] = output.count; output.append(tool) }
        }
        return output
    }

    /// Reconcile by physical installation, not package name. Agent discovery
    /// also finds native commands and packages under other runtime prefixes.
    static func mergingAgents(_ tools: [CommandLineTool], installations: [AgentCLIInstallation],
                              control: CleanupScanControl) -> [CommandLineTool] {
        var result = tools
        func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        func overlaps(_ a: String, _ b: String) -> Bool {
            let a = canonical(a), b = canonical(b)
            return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
        }
        var seen = Set<String>()
        for installation in installations where seen.insert(installation.id).inserted && !control.isCancelled {
            if let index = result.firstIndex(where: { tool in
                (installation.managedPaths + installation.executablePaths).contains { overlaps(tool.path, $0) }
            }) {
                result[index].agentID = installation.agentID
                result[index].agentInstallation = installation
                if result[index].managerExecutable == nil { result[index].managerExecutable = installation.managerExecutable }
                result[index].executablePaths = Array(Set(result[index].executablePaths + installation.executablePaths)).sorted()
                continue
            }
            let manager: CommandLineTool.Manager
            switch installation.manager {
            case .npm: manager = .npm
            case .pnpm: manager = .pnpm
            case .homebrew: manager = .homebrew
            case .pipx: manager = .pipx
            case .uv: manager = .uv
            case .native, .bun: manager = .local
            }
            guard let path = installation.managedPaths.first ?? installation.executablePaths.first else { continue }
            var version = ""
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path + "/package.json")), data.count <= 1_048_576,
               let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               manifest["name"] as? String == installation.packageName {
                version = manifest["version"] as? String ?? ""
            }
            result.append(.init(manager: manager, name: installation.packageName ?? installation.name,
                version: version, path: path, bytes: 0, dependents: [], installedOnRequest: true,
                agentID: installation.agentID,
                installationSource: installation.manager == .native ? "Native" : installation.manager.rawValue,
                supportsPublicRegistryUpdates: manager != .local && !version.isEmpty,
                executablePaths: installation.executablePaths, agentInstallation: installation, sizeIsKnown: false,
                managerExecutable: installation.managerExecutable))
        }
        return result
    }

}
