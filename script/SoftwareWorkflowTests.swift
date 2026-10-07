import Foundation

private actor CountingUpdateChecker: SoftwareUpdateChecking {
    private var active = 0
    private var peak = 0
    private var clears = 0
    private var completed = Set<String>()

    func clearCache() { clears += 1 }

    func check(_ target: SoftwareUpdateService.Target) async -> SoftwareUpdateResult {
        precondition(clears == 1, "The refresh must clear old metadata before scheduling checks")
        active += 1
        peak = max(peak, active)
        try? await Task.sleep(nanoseconds: 8_000_000)
        completed.insert(target.id)
        active -= 1
        return .init(installed: target.installed, latest: "2.0", state: .available)
    }

    func snapshot() -> (peak: Int, clears: Int, completed: Set<String>) {
        (peak, clears, completed)
    }
}

@MainActor
private final class UninstallTrace {
    var events: [String] = []
    var stopResults = [true, true]
    var freshPlan: UninstallPlan?
    var elevated = NativeCore.ApplySummary(removed: 1, skipped: 0, failed: 0, messages: [])
    var includedData = Set<String>()
    var appWasRemoved = false

    var dependencies: UninstallWorkflow.Dependencies {
        .init(stop: { app in
            self.events.append("stop:\(app.appIdentity)")
            return self.stopResults.removeFirst()
        }, plan: { app in
            self.events.append("plan:\(app.appIdentity)")
            return self.freshPlan
        }, elevate: { _ in
            self.events.append("elevate")
            return self.elevated
        }, apply: { _, _, data, removed in
            self.events.append("apply")
            self.includedData = data
            self.appWasRemoved = removed
            return .init(removed: 1, skipped: 0, failed: 0, messages: [])
        })
    }
}

@main
struct SoftwareWorkflowTests {
    static func main() async {
        await testUpdateScheduling()
        await testUninstallExecution()
        print("Software workflow tests passed")
    }

    private static func testUpdateScheduling() async {
        let targets = (0..<11).map {
            SoftwareUpdateService.Target(id: "fixture:\($0)", installed: "1.0", source: .unsupported)
        }
        let checker = CountingUpdateChecker()
        let results = await SoftwareUpdateCheckBatch.run(targets, using: checker, maximumConcurrentChecks: 3)
        let snapshot = await checker.snapshot()
        precondition(results.count == targets.count && snapshot.completed == Set(targets.map(\.id)),
                     "Every discovered target must receive a result")
        precondition((1...3).contains(snapshot.peak) && snapshot.clears == 1,
                     "Scheduling must respect its concurrency limit and refresh metadata once")

        let serial = CountingUpdateChecker()
        let serialResults = await SoftwareUpdateCheckBatch.run(targets, using: serial, maximumConcurrentChecks: 0)
        let serialSnapshot = await serial.snapshot()
        precondition(serialResults.count == targets.count && serialSnapshot.peak == 1,
                     "A zero concurrency preference must not lose or stall targets")

        let empty = CountingUpdateChecker()
        let emptyResults = await SoftwareUpdateCheckBatch.run([], using: empty)
        let emptySnapshot = await empty.snapshot()
        precondition(emptyResults.isEmpty && emptySnapshot.peak == 0 && emptySnapshot.clears == 1)
    }

    @MainActor
    private static func testUninstallExecution() async {
        let app = UninstallApp(name: "Workflow Fixture", bundleID: "com.example.workflow", source: "Fixture",
            path: "/fixture/Workflow.app", size: "1 KB", appIdentity: "captured-app", infoIdentity: "captured-info")
        let dataPath = "/fixture/data"
        func plan(admin: Bool = false, cask: Bool = false, protectedData: Bool = true) -> UninstallPlan {
            .init(files: [.init(bytes: 1, label: "app", path: app.path),
                          .init(bytes: 1, label: "review", path: dataPath)],
                fileIdentities: [app.path: "captured-app", dataPath: "captured-data"],
                needsAdmin: admin, isBrewCask: cask, caskToken: cask ? "fixture" : "",
                includesProtectedAppData: protectedData, scannedAt: .distantPast)
        }
        // The cached plan intentionally has different coverage; execution must
        // use the fresh plan and only data paths captured by the confirmation.
        let job = UninstallJob(id: UUID(), app: app, plan: plan(protectedData: false),
                               dataPaths: [dataPath, "/fixture/absent-from-fresh-plan"])
        let trace = UninstallTrace()
        trace.freshPlan = plan()
        let outcome = await UninstallWorkflow(dependencies: trace.dependencies).execute(job) { phase in
            switch phase {
            case .closing: trace.events.append("closing")
            case .planning: trace.events.append("planning")
            case .removing: trace.events.append("removing")
            }
        }
        guard case .applied(let result) = outcome else { preconditionFailure("Expected execution") }
        precondition(result.succeeded && trace.events == ["closing", "stop:captured-app", "planning",
            "plan:captured-app", "stop:captured-app", "removing", "apply"])
        precondition(trace.includedData == [dataPath] && !trace.appWasRemoved)

        for stopResults in [[false], [true, false]] {
            let refused = UninstallTrace()
            refused.stopResults = stopResults
            refused.freshPlan = plan()
            let result = await UninstallWorkflow(dependencies: refused.dependencies).execute(job) { _ in }
            guard case .processesCouldNotStop = result else { preconditionFailure("Expected shutdown refusal") }
            precondition(!refused.events.contains("apply") && !refused.events.contains("elevate"))
        }
        let emptyPlan = UninstallPlan(files: [], fileIdentities: [:], needsAdmin: false,
            isBrewCask: false, caskToken: "", includesProtectedAppData: true, scannedAt: .distantPast)
        for unavailablePlan in [nil, emptyPlan, plan(protectedData: false)] as [UninstallPlan?] {
            let refused = UninstallTrace()
            refused.freshPlan = unavailablePlan
            let result = await UninstallWorkflow(dependencies: refused.dependencies).execute(job) { _ in }
            guard case .planUnavailable = result else { preconditionFailure("Expected fresh-plan refusal") }
            precondition(refused.events == ["stop:captured-app", "plan:captured-app"])
        }
        for elevated in [
            NativeCore.ApplySummary(removed: 0, skipped: 0, failed: 1, messages: ["Denied"]),
            NativeCore.ApplySummary(removed: 1, skipped: 0, failed: 0, messages: [], removedPaths: ["/fixture/other.app"])
        ] {
            let refused = UninstallTrace()
            refused.freshPlan = plan(admin: true)
            refused.elevated = elevated
            let result = await UninstallWorkflow(dependencies: refused.dependencies).execute(job) { _ in }
            guard case .applied(let summary) = result else { preconditionFailure("Expected elevation result") }
            precondition(!summary.succeeded, "A replacement elevation dependency must prove removal of the captured app")
            precondition(!refused.events.contains("apply"), "Residues require proven removal of the captured app")
        }
        let elevated = UninstallTrace()
        elevated.freshPlan = plan(admin: true)
        elevated.elevated.removedPaths = [app.path]
        _ = await UninstallWorkflow(dependencies: elevated.dependencies).execute(job) { _ in }
        precondition(elevated.appWasRemoved && elevated.events.suffix(2) == ["elevate", "apply"])

        let cask = UninstallTrace()
        cask.freshPlan = plan(admin: true, cask: true)
        _ = await UninstallWorkflow(dependencies: cask.dependencies).execute(job) { _ in }
        precondition(!cask.appWasRemoved && !cask.events.contains("elevate"),
                     "Package-managed apps retain their existing uninstall route")
    }
}
