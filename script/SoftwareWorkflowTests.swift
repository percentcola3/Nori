import Foundation

private struct OwnedWorkflowInventory: ApplicationInventoryReading {
    let root: URL
    private var native: NativeApplicationInventory { .init() }
    func roots(home: URL) -> [(URL, String)] { [(root, "Owned workflow fixture")] }
    func children(of directory: URL) -> [URL] { native.children(of: directory) }
    func metadata(at url: URL) -> ApplicationBundleMetadata? { native.metadata(at: url) }
    func directoryIdentity(_ url: URL) -> String? { native.directoryIdentity(url) }
    func installedApps(in roots: [(URL, String)]) -> [UninstallApp] { native.installedApps(in: roots) }
}

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
    var appliedPlan: UninstallPlan?
    var absent = false
    var noProcesses = true

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
        }, apply: { app, plan, data, removed in
            self.events.append("apply")
            self.appliedPlan = plan
            self.includedData = data
            self.appWasRemoved = removed
            return .init(removed: 1, skipped: 0, failed: 0, messages: [], removedPaths: [app.path])
        }, isAbsent: { _ in self.absent }, hasNoProcesses: { _ in self.noProcesses })
    }
}

@main
struct SoftwareWorkflowTests {
    static func main() async throws {
        await testUpdateScheduling()
        await testUninstallExecution()
        testAgentRemovalReviewQueue()
        try await testInstallationOnlyNativePlan()
        print("Software workflow tests passed")
    }

    private static func testAgentRemovalReviewQueue() {
        var uninstall = UninstallQueue()
        var reviews = AgentRemovalReviewQueue()
        let first = UninstallApp(name: "First", bundleID: "fixture.first", source: "Fixture",
            path: "/fixture/First.app", size: "1 KB", appIdentity: "first", infoIdentity: "first-info")
        let second = UninstallApp(name: "Second", bundleID: "fixture.second", source: "Fixture",
            path: "/fixture/Second.app", size: "1 KB", appIdentity: "second", infoIdentity: "second-info")
        uninstall.enqueue(app: first, plan: nil)
        uninstall.enqueue(app: second, plan: nil)
        let firstJob = uninstall.startNext(blocked: false)!
        reviews.record(agentIDs: ["first-agent"], installationWasRemoved: true)
        uninstall.finish(firstJob.id, succeeded: true, message: "Removed first")
        precondition(reviews.takeIfReady(hasUninstallWork: uninstall.hasWork, isBlocked: false).isEmpty,
                     "A queued desktop uninstall must finish before any complete-data review")
        let secondJob = uninstall.startNext(blocked: false)!
        reviews.record(agentIDs: ["failed-agent"], installationWasRemoved: false)
        uninstall.finish(secondJob.id, succeeded: false, message: "Kept second")
        precondition(reviews.takeIfReady(hasUninstallWork: uninstall.hasWork, isBlocked: true).isEmpty,
                     "A removal review cannot replace an uninstall failure notice")
        reviews.record(agentIDs: ["first-agent", "another-removed-agent"], installationWasRemoved: true)
        precondition(reviews.takeIfReady(hasUninstallWork: uninstall.hasWork, isBlocked: false)
                     == ["first-agent", "another-removed-agent"],
                     "Batch review includes proven successful removals once, excluding failed installations")
        precondition(reviews.takeIfReady(hasUninstallWork: false, isBlocked: false).isEmpty,
                     "Dismissal must not repeatedly offer the same data review")
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
            path: "/Applications/Workflow.app", size: "1 KB", appIdentity: "captured-app", infoIdentity: "captured-info")
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
        guard case .applied(let result, _) = outcome else { preconditionFailure("Expected execution") }
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
            guard case .applied(let summary, _) = result else { preconditionFailure("Expected elevation result") }
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

        let recoveryPlan = plan(admin: true, cask: true)
        let recoveryJob = UninstallJob(id: UUID(), app: app, plan: recoveryPlan,
            dataPaths: [dataPath, "/fixture/unselected-new-data"], forceCleanup: true)
        let recovery = UninstallTrace()
        recovery.freshPlan = emptyPlan // Recovery must not read a broader/new inventory.
        recovery.elevated.removedPaths = [app.path]
        let recovered = await UninstallWorkflow(dependencies: recovery.dependencies).execute(recoveryJob) { _ in }
        guard case .applied(_, let retainedPlan) = recovered else { preconditionFailure("Expected recovery") }
        precondition(retainedPlan == recoveryPlan && !recovery.events.contains("plan:captured-app")
                     && recovery.events.contains("elevate") && recovery.appWasRemoved
                     && recovery.appliedPlan?.isBrewCask == false && recovery.includedData == [dataPath],
                     "Force cleanup must preserve the approved scope, elevate, and bypass only the failed package-manager route")
        let residuesOnly = UninstallTrace()
        residuesOnly.absent = true
        let residues = await UninstallWorkflow(dependencies: residuesOnly.dependencies).execute(recoveryJob) { _ in }
        guard case .applied(let residueResult, _) = residues else { preconditionFailure("Expected residue recovery") }
        precondition(residuesOnly.appWasRemoved && !residuesOnly.events.contains("elevate")
                     && !residuesOnly.events.contains("stop:captured-app")
                     && residueResult.removed == 0 && !residueResult.removedPaths.contains(app.path),
                     "Recovery after bundle removal must not require a new app or count its removal twice")
        let occupiedResidues = UninstallTrace()
        occupiedResidues.absent = true
        occupiedResidues.noProcesses = false
        let occupied = await UninstallWorkflow(dependencies: occupiedResidues.dependencies).execute(recoveryJob) { _ in }
        guard case .processesCouldNotStop = occupied else { preconditionFailure("Unproven process state was accepted") }
        precondition(!occupiedResidues.events.contains("apply") && !occupiedResidues.events.contains("elevate"),
                     "A missing app must never authorize process termination or cleanup while its path remains occupied")
        let noPlan = UninstallJob(id: UUID(), app: app, plan: nil, dataPaths: [], forceCleanup: true)
        let refusedRecovery = UninstallTrace()
        let refusal = await UninstallWorkflow(dependencies: refusedRecovery.dependencies).execute(noPlan) { _ in }
        guard case .planUnavailable = refusal else { preconditionFailure("Unreviewed force cleanup was accepted") }
        precondition(!refusedRecovery.events.contains("apply") && !refusedRecovery.events.contains("elevate"))

        let bodyJob = UninstallJob(id: UUID(), app: app, plan: nil, dataPaths: [dataPath], scope: .installationOnly)
        let bodyOnly = UninstallTrace()
        let bodyPlan = plan()
        bodyOnly.freshPlan = UninstallPlan(files: bodyPlan.files + [.init(bytes: 2, label: "cache", path: "/fixture/cache")],
            fileIdentities: bodyPlan.fileIdentities.merging(["/fixture/cache": "captured-cache"], uniquingKeysWith: { first, _ in first }),
            needsAdmin: false, isBrewCask: false, caskToken: "", includesProtectedAppData: true, scannedAt: .distantPast)
        _ = await UninstallWorkflow(dependencies: bodyOnly.dependencies).execute(bodyJob) { _ in }
        precondition(bodyOnly.appliedPlan?.files.map(\.path) == [app.path] && bodyOnly.includedData.isEmpty,
                     "Installation-only removes automatic cache residues as well as optional data from the apply plan")
        let ordinary = UninstallTrace()
        ordinary.freshPlan = bodyOnly.freshPlan
        _ = await UninstallWorkflow(dependencies: ordinary.dependencies).execute(job) { _ in }
        precondition(job.scope == .applicationAndResidues && ordinary.appliedPlan == ordinary.freshPlan
                     && ordinary.appliedPlan!.files.contains { $0.path == "/fixture/cache" && !$0.informational }
                     && ordinary.includedData == [dataPath],
                     "The default software uninstall lost its ordinary cache/selected-data behavior")
        let history = UninstallTrace()
        history.freshPlan = UninstallPlan(files: [.init(bytes: 10, label: "app", path: app.path),
            .init(bytes: 20, label: "agentData", path: dataPath)],
            fileIdentities: [app.path: "captured-app", dataPath: "new-data-identity"],
            needsAdmin: false, isBrewCask: false, caskToken: "", includesProtectedAppData: true, scannedAt: .distantPast)
        let replacedData = await UninstallWorkflow(dependencies: history.dependencies).execute(job) { _ in }
        guard case .planUnavailable = replacedData else { preconditionFailure("History consent rebound to a replaced data root") }
        precondition(!history.events.contains("apply") && !history.events.contains("elevate"))
        let malformedBody = UninstallTrace()
        malformedBody.freshPlan = UninstallPlan(files: [.init(bytes: 1, label: "cache", path: "/fixture/cache")],
            fileIdentities: ["/fixture/cache": "captured-cache"], needsAdmin: false, isBrewCask: false,
            caskToken: "", includesProtectedAppData: true, scannedAt: .distantPast)
        let malformedResult = await UninstallWorkflow(dependencies: malformedBody.dependencies).execute(bodyJob) { _ in }
        guard case .planUnavailable = malformedResult else { preconditionFailure("An unproven body plan was accepted") }
        precondition(!malformedBody.events.contains("apply") && !malformedBody.events.contains("elevate"))
    }

    @MainActor
    private static func testInstallationOnlyNativePlan() async throws {
        let fm = FileManager.default
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath().standardizedFileURL
        precondition(fixture.lastPathComponent.hasPrefix(".software-workflow-fixture."), "An unowned fixture was supplied")
        let home = fixture.appendingPathComponent("home")
        let applications = home.appendingPathComponent("Applications")
        let identifier = "com.example.nori-body-only-fixture"
        func write(_ relative: String) throws {
            let url = home.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("owned fixture".utf8).write(to: url)
        }
        func app(_ relative: String) throws -> UninstallApp {
            let url = home.appendingPathComponent(relative)
            try fm.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            let info = ["CFBundleIdentifier": identifier, "CFBundleName": "BodyOnlyFixture",
                        "CFBundlePackageType": "APPL", "CFBundleExecutable": "BodyOnlyFixture"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: url.appendingPathComponent("Contents/Info.plist"))
            return .init(name: "BodyOnlyFixture", bundleID: identifier, source: "Owned fixture", path: url.path, size: "1 KB")
        }
        let selected = try app("Applications/BodyOnlyFixture.app")
        let otherInstallation = try app("AnotherPrefix/BodyOnlyFixture.app")
        try write("Library/Caches/\(identifier)/cache.bin")
        try write("Library/Logs/\(identifier)/log.bin")
        try write("Library/Preferences/\(identifier).plist")
        try write("Library/Application Support/BodyOnlyFixture/User/history.bin")
        let planner = UninstallPlanningService(dependencies: .init(inventory: OwnedWorkflowInventory(root: applications),
            allocatedBytes: { BoundedApplicationSizeMeasurer().allocatedBytes(at: $0) },
            isPhysicalPath: { url, home in url.path.hasPrefix(home.path + "/") && DeletionPlan.isLexicallySafePath(url.path) },
            requiresAdministrator: { _ in true }, commandOutput: { _, _ in nil }))
        let original = planner.plan(for: selected, homeDirectory: home.path)!
        let cache = home.appendingPathComponent("Library/Caches/\(identifier)").path
        let logs = home.appendingPathComponent("Library/Logs/\(identifier)").path
        precondition(original.files.contains { $0.path == cache && !$0.informational }
                     && original.files.contains { $0.path == logs && !$0.informational }
                     && !original.dataPaths.isEmpty, "The native fixture did not reproduce automatic and optional residue coverage")
        let preservedPaths = original.files.filter { $0.path != selected.path }.map(\.path) + [otherInstallation.path]
        let before = Dictionary(preservedPaths.map { ($0, DeletionPlan.identity(at: $0)!) }, uniquingKeysWith: { first, _ in first })
        let core = NativeCore(cleanupOpenFileProbe: { [] })
        var stops = 0
        var nativeApplies = 0
        let dependencies = UninstallWorkflow.Dependencies(stop: { app in
            stops += 1
            var environment = UninstallProcessController.Environment()
            environment.sample = { [] } // The owned dummy bundle is never launched.
            environment.signal = { _, _ in preconditionFailure("An owned metadata fixture received a signal") }
            return await UninstallProcessController.stop(app, environment: environment)
        }, plan: { app in planner.plan(for: app, homeDirectory: home.path) }, elevate: { app in
            // Simulate only the administrator's captured-body result, without
            // authorization or the user's Trash. Native apply still runs below.
            precondition(DeletionPlan.identity(at: app.path) == app.appIdentity
                         && DeletionPlan.identity(at: app.path + "/Contents/Info.plist") == app.infoIdentity)
            try! fm.removeItem(atPath: app.path)
            return .init(removed: 1, skipped: 0, failed: 0, messages: [], removedPaths: [app.path])
        }, apply: { app, plan, data, appAlreadyRemoved in
            nativeApplies += 1
            precondition(plan.files.map(\.path) == [app.path] && data.isEmpty && appAlreadyRemoved,
                         "Native apply received a cache/data path before associated-data consent")
            return core.applyUninstall(app, plan: plan, homeDirectory: home.path,
                                       appAlreadyRemoved: appAlreadyRemoved, includingData: data)
        })
        let job = UninstallJob(id: UUID(), app: selected, plan: original, dataPaths: Set(original.dataPaths), scope: .installationOnly)
        let result = await UninstallWorkflow(dependencies: dependencies).execute(job) { _ in }
        guard case .applied(let summary, _) = result else { preconditionFailure("Expected native installation-only result") }
        precondition(summary.succeeded && summary.removedPaths == [selected.path]
                     && !fm.fileExists(atPath: selected.path) && stops == 2 && nativeApplies == 1,
                     "The captured body was not removed through the guarded native workflow")
        precondition(before.allSatisfy { DeletionPlan.identity(at: $0.key) == $0.value },
                     "Installation-only changed automatic caches, optional data or another installation")
    }
}
