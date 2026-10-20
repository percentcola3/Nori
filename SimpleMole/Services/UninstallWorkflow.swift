import Darwin
import Foundation

enum UninstallExecutionPhase {
    case closing, planning, removing
}

enum UninstallExecutionOutcome {
    case processesCouldNotStop
    case planUnavailable
    case applied(NativeCore.ApplySummary, plan: UninstallPlan? = nil)
}

/// Executes an already-confirmed request. Authorization, queue ownership and
/// user-visible messages remain with the main-actor presentation coordinator.
@MainActor
protocol UninstallExecuting {
    func execute(_ job: UninstallJob,
                 progress: (UninstallExecutionPhase) -> Void) async -> UninstallExecutionOutcome
}

@MainActor
struct UninstallWorkflow: UninstallExecuting {
    struct Dependencies {
        var stop: @MainActor (UninstallApp) async -> Bool
        var plan: @MainActor (UninstallApp) async -> UninstallPlan?
        var elevate: @MainActor (UninstallApp) async -> NativeCore.ApplySummary
        var apply: @MainActor (UninstallApp, UninstallPlan, Set<String>, Bool) async -> NativeCore.ApplySummary
        var isAbsent: @MainActor (UninstallApp) -> Bool = {
            var metadata = stat()
            return lstat($0.path, &metadata) != 0 && errno == ENOENT
        }
        var hasNoProcesses: @MainActor (UninstallApp) -> Bool = {
            UninstallProcessController.processes(for: $0, samples: ProcessSampler.shared.sample()).isEmpty
        }

        static var live: Self {
            Self(stop: { await UninstallProcessController.stop($0) },
                 plan: { await NativeCore.shared.uninstallPlan(for: $0, homeDirectory: NSHomeDirectory()) },
                 elevate: { await AdministratorUninstallService.apply($0) },
                 apply: { app, plan, includingData, appAlreadyRemoved in
                     await Task.detached(priority: .utility) {
                         NativeCore.shared.applyUninstall(app, plan: plan,
                             homeDirectory: NSHomeDirectory(), appAlreadyRemoved: appAlreadyRemoved,
                             includingData: includingData)
                     }.value
                 })
        }
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies? = nil) {
        self.dependencies = dependencies ?? .live
    }

    func execute(_ job: UninstallJob,
                 progress: (UninstallExecutionPhase) -> Void) async -> UninstallExecutionOutcome {
        let app = job.app
        let wasAlreadyAbsent = job.forceCleanup && dependencies.isAbsent(app)
        progress(.closing)
        if wasAlreadyAbsent {
            // A missing bundle cannot authorize terminating processes. Only
            // continue with residues when no process still uses its path.
            guard dependencies.hasNoProcesses(app) else { return .processesCouldNotStop }
        } else {
            guard await dependencies.stop(app) else { return .processesCouldNotStop }
        }

        // Cached inventory is for presentation. Rebuild the plan for the
        // captured app identity after shutdown, immediately before removal.
        progress(.planning)
        // Recovery owns the exact previously accepted scope. Never rescan into
        // new data, or rebind the request to a replacement app at the same path.
        let candidate = job.forceCleanup ? job.plan : await dependencies.plan(app)
        guard let freshPlan = candidate, !freshPlan.files.isEmpty,
              freshPlan.includesProtectedAppData else { return .planUnavailable }
        // An opt-in to history/configuration binds the exact reviewed data,
        // rather than accepting a replacement folder at the same path.
        for path in job.dataPaths where freshPlan.files.contains(where: { $0.path == path && $0.isAgentData }) {
            guard let identity = job.plan?.fileIdentities[path], identity == freshPlan.fileIdentities[path] else {
                return .planUnavailable
            }
        }
        let plan: UninstallPlan
        switch job.scope {
        case .applicationAndResidues:
            plan = freshPlan
        case .installationOnly:
            // Empty dataPaths retain optional data, but ordinary cache/log
            // residues are still automatic. Scope this request to the exact
            // captured bundle before calling any native/package remover.
            let bodies = freshPlan.files.filter { $0.path == app.path && $0.label == "app" && !$0.informational }
            guard bodies.count == 1, freshPlan.fileIdentities[app.path] == app.appIdentity else {
                return .planUnavailable
            }
            plan = UninstallPlan(files: bodies, fileIdentities: [app.path: app.appIdentity],
                needsAdmin: freshPlan.needsAdmin, isBrewCask: freshPlan.isBrewCask, caskToken: freshPlan.caskToken,
                includesProtectedAppData: freshPlan.includesProtectedAppData, scannedAt: freshPlan.scannedAt)
        }
        if wasAlreadyAbsent {
            guard dependencies.isAbsent(app) else { return .planUnavailable }
            guard dependencies.hasNoProcesses(app) else { return .processesCouldNotStop }
        } else {
            guard await dependencies.stop(app) else { return .processesCouldNotStop }
        }
        progress(.removing)

        let includingData = job.dataPaths.intersection(plan.dataPaths)
        let appAlreadyRemoved: Bool
        if wasAlreadyAbsent {
            appAlreadyRemoved = true
        } else if (plan.needsAdmin && !plan.isBrewCask)
                    || (job.forceCleanup && AdministratorUninstallPlan.allows(app)) {
            let elevated = await dependencies.elevate(app)
            guard elevated.succeeded else { return .applied(elevated, plan: plan) }
            guard elevated.removedPaths == [app.path] else {
                return .applied(.init(removed: elevated.removed, skipped: elevated.skipped,
                    failed: max(1, elevated.failed),
                    messages: elevated.messages + ["The application bundle was not removed."],
                    removedPaths: elevated.removedPaths, remainingPaths: elevated.remainingPaths,
                    retainedPaths: elevated.retainedPaths, reclaimedBytes: elevated.reclaimedBytes), plan: plan)
            }
            appAlreadyRemoved = true
        } else {
            appAlreadyRemoved = false
        }
        // An explicitly chosen recovery uses the native Trash route even if
        // the package manager was the reason the first attempt failed.
        let applyPlan = job.forceCleanup ? UninstallPlan(files: plan.files,
            fileIdentities: plan.fileIdentities, needsAdmin: plan.needsAdmin,
            isBrewCask: false, caskToken: "", includesProtectedAppData: plan.includesProtectedAppData,
            scannedAt: plan.scannedAt) : plan
        var result = await dependencies.apply(app, applyPlan, includingData, appAlreadyRemoved)
        if wasAlreadyAbsent, result.removedPaths.contains(app.path) {
            // The first attempt already counted the bundle. Recovery only
            // reports newly removed residues, even though apply verifies both.
            result = .init(removed: max(0, result.removed - 1), skipped: result.skipped,
                failed: result.failed, messages: result.messages,
                removedPaths: result.removedPaths.subtracting([app.path]),
                remainingPaths: result.remainingPaths, retainedPaths: result.retainedPaths,
                reclaimedBytes: result.reclaimedBytes)
        }
        return .applied(result, plan: plan)
    }
}
