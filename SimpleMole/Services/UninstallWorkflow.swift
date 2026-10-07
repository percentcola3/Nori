import Foundation

enum UninstallExecutionPhase {
    case closing, planning, removing
}

enum UninstallExecutionOutcome {
    case processesCouldNotStop
    case planUnavailable
    case applied(NativeCore.ApplySummary)
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
        progress(.closing)
        guard await dependencies.stop(app) else { return .processesCouldNotStop }

        // Cached inventory is for presentation. Rebuild the plan for the
        // captured app identity after shutdown, immediately before removal.
        progress(.planning)
        guard let plan = await dependencies.plan(app), !plan.files.isEmpty,
              plan.includesProtectedAppData else { return .planUnavailable }
        guard await dependencies.stop(app) else { return .processesCouldNotStop }
        progress(.removing)

        let includingData = job.dataPaths.intersection(plan.dataPaths)
        let appAlreadyRemoved: Bool
        if plan.needsAdmin && !plan.isBrewCask {
            let elevated = await dependencies.elevate(app)
            guard elevated.succeeded else { return .applied(elevated) }
            guard elevated.removedPaths == [app.path] else {
                return .applied(.init(removed: elevated.removed, skipped: elevated.skipped,
                    failed: max(1, elevated.failed),
                    messages: elevated.messages + ["The application bundle was not removed."],
                    removedPaths: elevated.removedPaths, remainingPaths: elevated.remainingPaths,
                    retainedPaths: elevated.retainedPaths, reclaimedBytes: elevated.reclaimedBytes))
            }
            appAlreadyRemoved = true
        } else {
            appAlreadyRemoved = false
        }
        return .applied(await dependencies.apply(app, plan, includingData, appAlreadyRemoved))
    }
}
