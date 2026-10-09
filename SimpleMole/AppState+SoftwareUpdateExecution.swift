import AppKit
import Foundation

@MainActor
extension AppState {
    private enum UpdateSelection {
        case app(UninstallApp, token: String?)
        case tool(CommandLineTool)
        var name: String { switch self { case .app(let app, _): return app.name; case .tool(let tool): return tool.name } }
        var key: String { switch self { case .app(let app, _): return SoftwareUpdateService.appKey(app); case .tool(let tool): return SoftwareUpdateService.toolKey(tool) } }
    }

    private func updateProcessScope(_ selection: UpdateSelection) -> SoftwareUpdateProcesses.Scope {
        switch selection {
        case .tool(let tool): return .tool(tool)
        case .app(let app, _):
            var scope = SoftwareUpdateProcesses.Scope.app(app)
            let path = URL(fileURLWithPath: app.path).resolvingSymlinksInPath().path
            let pids = Set(NSWorkspace.shared.runningApplications.compactMap { running -> Int32? in
                guard !running.isTerminated, running.bundleIdentifier == app.bundleID,
                      running.bundleURL?.resolvingSymlinksInPath().path == path else { return nil }
                return running.processIdentifier
            })
            scope.applicationIdentities = Set(ProcessSampler.shared.sample().filter { pids.contains($0.pid) }.map(\.identity))
            return scope
        }
    }

    func updateSoftware(_ app: UninstallApp) {
        guard installedApps.contains(app) else { return }
        let plan = uninstallPlan(for: app)
        requestSoftwareUpdate(.app(app, token: plan?.isBrewCask == true ? plan?.caskToken : nil))
    }
    func updateSoftware(_ tool: CommandLineTool) {
        guard commandLineTools.contains(tool) else { return }
        requestSoftwareUpdate(.tool(tool))
    }

    private func requestSoftwareUpdate(_ selection: UpdateSelection) {
        guard let result = softwareUpdateResults[selection.key], result.state == .available,
              result.latest != nil else { return }
        if case .app(let app, _) = selection,
           app.path == Bundle.main.bundleURL.path, app.bundleID == Bundle.main.bundleIdentifier {
            AppUpdateController.shared.checkForUpdates()
            return
        }
        guard !isSoftwareTaskBusy, !isSoftwareMutationBlocked,
              confirmation == nil, taskNotice == nil else { return }
        softwareUpdatingID = selection.key
        let identity: String?
        switch selection {
        case .app(let app, _): identity = app.appIdentity
        case .tool(let tool): identity = DeletionPlan.identity(at: tool.path)
        }
        Task {
            let scope = updateProcessScope(selection)
            let snapshot = await Task.detached(priority: .utility) { SoftwareUpdateProcesses.probe(scope) }.value
            guard snapshot.isComplete else {
                softwareUpdateFailed(selection, reason: "software.install.runtimeUnknown")
                return
            }
            if !snapshot.processes.isEmpty {
                presentUpdateCloseConfirmation(selection, result: result, identity: identity, processes: snapshot.processes)
            } else {
                await performSoftwareUpdate(selection, result: result, identity: identity, mayClose: false)
            }
        }
    }

    private func presentUpdateCloseConfirmation(_ selection: UpdateSelection, result: SoftwareUpdateResult,
                                                identity: String?,
                                                processes: [ProcessSample]) {
        softwareUpdatingID = nil
        guard confirmation == nil, taskNotice == nil else { return }
        confirmation = Confirmation(title: L10n.shared.tf("software.install.closeTitle", selection.name),
            message: L10n.shared.tf("software.install.closeMessage", selection.name)
                + "\n\n" + Set(processes.map(\.name)).sorted().joined(separator: ", "),
            confirmLabel: L10n.shared.t("software.install.closeAction")) { [weak self] in
                guard let self, !self.isSoftwareTaskBusy, !self.isSoftwareMutationBlocked,
                      !self.isCheckingSoftwareUpdates,
                      self.softwareUpdateResults[selection.key]?.state == .available else { return }
                self.softwareUpdatingID = selection.key
                Task { await self.performSoftwareUpdate(selection, result: result, identity: identity, mayClose: true) }
            }
    }

    private func performSoftwareUpdate(_ selection: UpdateSelection, result: SoftwareUpdateResult, identity originalIdentity: String?, mayClose: Bool) async {
        guard let latest = result.latest else { softwareUpdatingID = nil; return }
        func stillCurrent() -> Bool {
            switch selection {
            case .app(let app, _):
                return DeletionPlan.identity(at: app.path) == app.appIdentity
                    && DeletionPlan.identity(at: app.path + "/Contents/Info.plist") == app.infoIdentity
            case .tool(let tool):
                return originalIdentity != nil && DeletionPlan.identity(at: tool.path) == originalIdentity
            }
        }
        guard stillCurrent() else { softwareUpdateFailed(selection, reason: "software.install.changed"); return }
        if case .tool(let expected) = selection {
            let actual = await Task.detached(priority: .utility) { CommandLineToolInventory.scan() }.value
                .first { $0.manager == expected.manager && $0.name == expected.name
                    && ($0.id == expected.id || $0.path == expected.path) }
            guard let actual, actual.version == expected.version, actual.path == expected.path,
                  actual.supportsPublicRegistryUpdates == expected.supportsPublicRegistryUpdates else {
                softwareUpdateFailed(selection, reason: "software.install.changed")
                return
            }
        }

        // Nori's signed updater owns its own exit/relaunch cycle.
        if case .app(let app, _) = selection,
           app.path == Bundle.main.bundleURL.path, app.bundleID == Bundle.main.bundleIdentifier {
            softwareUpdatingID = nil
            AppUpdateController.shared.checkForUpdates()
            return
        }
        let scope = updateProcessScope(selection)
        let fresh = await Task.detached(priority: .utility) { SoftwareUpdateProcesses.probe(scope) }.value
        guard fresh.isComplete else { softwareUpdateFailed(selection, reason: "software.install.runtimeUnknown"); return }
        if !fresh.processes.isEmpty {
            if !mayClose {
                // An app can start between the first check and installation.
                presentUpdateCloseConfirmation(selection, result: result, identity: originalIdentity, processes: fresh.processes)
                return
            }
            guard await SoftwareUpdateProcesses.close(scope, stillCurrent: stillCurrent) else {
                softwareUpdateFailed(selection, reason: "software.install.closeFailed")
                return
            }
        }
        let finalScope = updateProcessScope(selection)
        let finalProcesses = await Task.detached(priority: .utility) { SoftwareUpdateProcesses.probe(finalScope) }.value
        guard finalProcesses.isComplete else { softwareUpdateFailed(selection, reason: "software.install.runtimeUnknown"); return }
        if !finalProcesses.processes.isEmpty {
            presentUpdateCloseConfirmation(selection, result: result, identity: originalIdentity,
                                           processes: finalProcesses.processes)
            return
        }
        guard stillCurrent() else { softwareUpdateFailed(selection, reason: "software.install.changed"); return }
        let command: SoftwareUpdateExecution.Command?
        switch selection {
        case .tool(let tool): command = SoftwareUpdateExecution.toolCommand(tool, latest: latest)
        case .app(_, let token): command = token.flatMap { SoftwareUpdateExecution.appCommand(token: $0) }
        }
        guard let command else {
            if case .app(let app, _) = selection {
                let opened: Bool
                if let url = result.updatePage { opened = NSWorkspace.shared.open(url) }
                else { opened = NSWorkspace.shared.open(URL(fileURLWithPath: app.path)) }
                softwareUpdatingID = nil
                if opened { softwareUpdateHandoffIDs.insert(selection.key) }
                else { softwareUpdateFailed(selection, reason: "software.install.openFailed") }
            } else { softwareUpdateFailed(selection, reason: "software.install.managerUnavailable") }
            return
        }
        let installed = await SoftwareUpdateExecution.run(command)
        if !installed.output.isEmpty { log(installed.output) }
        guard installed.succeeded else {
            softwareUpdateFailed(selection, reason: "software.install.commandFailed")
            return
        }

        // Exit status alone cannot establish that the requested version arrived.
        switch selection {
        case .tool(let old):
            let tools = await Task.detached(priority: .utility) { CommandLineToolInventory.scan() }.value
            commandLineTools = tools
            let current = tools.first { $0.manager == old.manager && $0.name == old.name
                && ($0.id == old.id || $0.path == old.path) }
            guard let current, let order = SoftwareUpdateService.compare(current.version, latest), order != .orderedAscending else {
                softwareUpdateFailed(selection, reason: "software.install.notVerified")
                return
            }
            softwareUpdateResults.removeValue(forKey: selection.key)
            softwareUpdateResults[SoftwareUpdateService.toolKey(current)] = .init(installed: current.version, latest: latest,
                                                                                state: .current, source: result.source)
            commandLineToolStatus = L10n.shared.tf("cli.status.count", tools.count, ByteFormat.format(tools.reduce(0) { $0 &+ $1.bytes }))
        case .app(let old, let token):
            let current = UninstallApp(name: old.name, bundleID: old.bundleID, source: old.source, path: old.path, size: old.size)
            let target = await Task.detached(priority: .utility) { SoftwareUpdateService.appTarget(current, cask: token) }.value
            let buildVerified: Bool
            if let wanted = result.latestBuild, case .appcast(_, let build) = target.source {
                buildVerified = SoftwareUpdateService.compare(build, wanted).map { $0 != .orderedAscending } == true
            } else { buildVerified = result.latestBuild == nil }
            guard buildVerified, let order = SoftwareUpdateService.compare(target.installed, latest), order != .orderedAscending else {
                softwareUpdateFailed(selection, reason: "software.install.notVerified")
                return
            }
            installedApps = installedApps.map { $0.id == old.id ? current : $0 }
            softwareUpdateResults.removeValue(forKey: selection.key)
            softwareUpdateResults[SoftwareUpdateService.appKey(current)] = .init(installed: target.installed, latest: latest,
                                                                               state: .current, source: result.source)
        }
        softwareUpdatingID = nil
        softwareUpdateHandoffIDs.remove(selection.key)
        resampleAfterMutation()
        scheduleSoftwareInventoryRefresh()
    }

    private func scheduleSoftwareInventoryRefresh() { scanInstalledApps(background: true) }
    private func softwareUpdateFailed(_ selection: UpdateSelection, reason: String) {
        softwareUpdatingID = nil
        presentTaskFailure(message: L10n.shared.tf("software.install.failed", selection.name),
                           details: [L10n.shared.t(reason)], detailsAreLocalized: true)
    }
}
