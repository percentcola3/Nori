import Foundation
import Darwin

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
        await testUnsupportedAdministratorTargets()
        testAgentRemovalReviewQueue()
        try await testInstallationOnlyNativePlan()
        try await testPartialUninstallNativeRecovery()
        print("Software workflow tests passed")
    }

    @MainActor
    private static func testUnsupportedAdministratorTargets() async {
        // Path-only fixtures and injected effects: never inspect or stop a real
        // system service, request administrator access, or remove its bundle.
        let app = UninstallApp(name: "Service fixture", bundleID: "com.example.service", source: "Fixture",
            path: "/Library/Application Support/FixtureVendor/Service.app", size: "1 KB",
            appIdentity: "captured-service", infoIdentity: "captured-service-info")
        let dataPath = "/fixture/service-data"
        func plan(admin: Bool, cask: Bool = false, identity: String = "captured-service") -> UninstallPlan {
            .init(files: [.init(bytes: 1, label: "app", path: app.path),
                          .init(bytes: 1, label: "review", path: dataPath)],
                fileIdentities: [app.path: identity, dataPath: "captured-data"],
                needsAdmin: admin, isBrewCask: cask, caskToken: cask ? "service-fixture" : "",
                includesProtectedAppData: true, scannedAt: .distantPast)
        }
        let administrator = plan(admin: true)
        let native = plan(admin: false)
        let brew = plan(admin: true, cask: true)
        precondition(!AdministratorUninstallPlan.allows(app))
        precondition(!UninstallWorkflow.canRecover(app, plan: administrator, isAbsent: { _ in false })
            && !UninstallWorkflow.canRecover(app, plan: brew, isAbsent: { _ in false })
            && UninstallWorkflow.canRecover(app, plan: native, isAbsent: { _ in false })
            && UninstallWorkflow.canRecover(app, plan: administrator, isAbsent: { _ in true }),
                     "Recovery capabilities ignored effective native privileges or the missing-body route")
        let supported = UninstallApp(name: app.name, bundleID: app.bundleID, source: app.source,
            path: "/Applications/ServiceFixture.app", size: "", appIdentity: app.appIdentity, infoIdentity: app.infoIdentity)
        precondition(UninstallWorkflow.canRecover(supported, plan: administrator, isAbsent: { _ in false }),
                     "Supported administrator recovery was hidden")

        for force in [false, true] {
            for capturedPlan in [administrator, brew] where force || !capturedPlan.isBrewCask {
                let trace = UninstallTrace()
                trace.freshPlan = capturedPlan
                let job = UninstallJob(id: UUID(), app: app, plan: capturedPlan,
                    dataPaths: [dataPath], forceCleanup: force)
                let outcome = await UninstallWorkflow(dependencies: trace.dependencies).execute(job) { _ in }
                guard case .applied(let refusal, let recoveryPlan) = outcome else {
                    preconditionFailure("Expected explicit unsupported administrator location")
                }
                precondition(refusal.removed == 0 && refusal.failed == 1
                    && refusal.messages == [AdministratorUninstallPlan.unsupportedLocationMessage]
                    && refusal.remainingPaths == [app.path] && recoveryPlan == nil,
                             "Unsupported uninstall lost its reason or offered a guaranteed-failing recovery")
                precondition(trace.events == (force ? [] : ["plan:captured-service"]),
                             "Unsupported uninstall stopped a process, elevated, applied, or rescanned recovery")
            }
        }

        // Cached administrator/native classification cannot reject a newly
        // supported current native or package-manager route.
        let ordinary = UninstallJob(id: UUID(), app: app, plan: administrator, dataPaths: [dataPath])
        for fresh in [native, brew] {
            let trace = UninstallTrace()
            trace.freshPlan = fresh
            let outcome = await UninstallWorkflow(dependencies: trace.dependencies).execute(ordinary) { _ in }
            guard case .applied(let result, _) = outcome else { preconditionFailure("Fresh supported route was rejected") }
            precondition(result.succeeded && trace.appliedPlan == fresh && !trace.events.contains("elevate")
                && trace.events.filter { $0 == "stop:captured-service" }.count == 2
                && trace.events.filter { $0 == "plan:captured-service" }.count == 2,
                         "A stale cached plan overrode fresh support or skipped post-shutdown planning")
        }
        let nativeRecovery = UninstallTrace()
        let nativeJob = UninstallJob(id: UUID(), app: app, plan: native, dataPaths: [dataPath], forceCleanup: true)
        let nativeResult = await UninstallWorkflow(dependencies: nativeRecovery.dependencies).execute(nativeJob) { _ in }
        guard case .applied(let recoveredNative, _) = nativeResult else { preconditionFailure("User-writable native recovery was blocked") }
        precondition(recoveredNative.succeeded && nativeRecovery.appliedPlan == native
            && !nativeRecovery.events.contains("plan:captured-service") && !nativeRecovery.events.contains("elevate"),
                     "Non-administrator recovery broadened scope, rescanned, or elevated")
        let wrongIdentity = UninstallTrace()
        wrongIdentity.freshPlan = plan(admin: true, identity: "replacement-service")
        let replaced = await UninstallWorkflow(dependencies: wrongIdentity.dependencies).execute(ordinary) { _ in }
        guard case .planUnavailable = replaced else { preconditionFailure("Preflight accepted a replacement identity") }
        precondition(wrongIdentity.events == ["plan:captured-service"],
                     "An unbound preflight snapshot authorized stopping the selected service")

        // Permissions can change while shutdown suspends; the final plan must
        // still satisfy the administrator worker's unchanged location policy.
        let changing = UninstallTrace()
        var dependencies = changing.dependencies
        var planningCalls = 0
        dependencies.plan = { _ in
            changing.events.append("plan:captured-service")
            planningCalls += 1
            return planningCalls == 1 ? native : administrator
        }
        let changed = await UninstallWorkflow(dependencies: dependencies).execute(ordinary) { _ in }
        guard case .applied(let refusal, let recoveryPlan) = changed else {
            preconditionFailure("A newly unsupported administrator plan was accepted")
        }
        precondition(refusal.failed == 1 && recoveryPlan == nil
            && changing.events == ["plan:captured-service", "stop:captured-service", "plan:captured-service"],
                     "Post-shutdown support changes reached a second stop/elevation/apply")

        let recovery = UninstallJob(id: UUID(), app: app, plan: brew, dataPaths: [dataPath], forceCleanup: true)
        let missing = UninstallTrace()
        missing.absent = true
        let recovered = await UninstallWorkflow(dependencies: missing.dependencies).execute(recovery) { _ in }
        guard case .applied(let result, let retainedPlan) = recovered else {
            preconditionFailure("Missing unsupported bundle blocked reviewed residue recovery")
        }
        precondition(missing.events == ["apply"] && missing.appWasRemoved && retainedPlan == brew
            && missing.appliedPlan?.isBrewCask == false && result.removed == 0,
                     "Missing-body recovery required bundle privileges, rescanned, or recounted its removal")
        let occupied = UninstallTrace()
        occupied.absent = true
        occupied.noProcesses = false
        let refused = await UninstallWorkflow(dependencies: occupied.dependencies).execute(recovery) { _ in }
        guard case .processesCouldNotStop = refused else { preconditionFailure("Missing service bypassed occupancy") }
        precondition(occupied.events.isEmpty)
        print("Unsupported administrator uninstall: bound preflight, no futile recovery, fresh/Brew/native/missing scope preserved")
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
    private static func testPartialUninstallNativeRecovery() async throws {
        struct Fixture {
            let root: URL
            let home: URL
            let trash: URL
            let body: URL
            let cache: URL
            let logs: URL
            let app: UninstallApp
            let plan: UninstallPlan
        }
        let fm = FileManager.default
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath().standardizedFileURL
        precondition(fixture.lastPathComponent.hasPrefix(".software-workflow-fixture.")
            && DeletionPlan.isLexicallySafePath(fixture.path), "Unowned recovery fixture")
        let core = NativeCore(cleanupOpenFileProbe: { [] })
        let names = ["Cache.db", "Cache.db-wal", "Cache.db-shm"]
        func move(_ source: URL, to destination: URL, in root: URL) throws {
            precondition(root.path.hasPrefix(fixture.path + "/")
                && DeletionPlan.isLexicallySafePath(source.path) && DeletionPlan.isLexicallySafePath(destination.path)
                && source.path.hasPrefix(root.path + "/") && destination.path.hasPrefix(root.path + "/"),
                         "A recovery fixture move escaped its exact nonce root")
            try fm.moveItem(at: source, to: destination)
        }
        func makeFixture(_ name: String) throws -> Fixture {
            let root = fixture.appendingPathComponent("partial-native-recovery/" + name)
            let home = root.appendingPathComponent("home")
            let trash = root.appendingPathComponent("Trash")
            let body = home.appendingPathComponent("Applications/OwnedRecovery.app")
            let identifier = "dev.nori-recovery-" + UUID().uuidString.lowercased() + ".app"
            let cache = home.appendingPathComponent("Library/Caches/" + identifier)
            let logs = home.appendingPathComponent("Library/Logs/OwnedRecovery")
            try fm.createDirectory(at: body.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier,
                "CFBundleName": "OwnedRecovery", "CFBundlePackageType": "APPL", "CFBundleExecutable": "OwnedRecovery"],
                format: .xml, options: 0).write(to: body.appendingPathComponent("Contents/Info.plist"))
            let app = UninstallApp(name: "OwnedRecovery", bundleID: identifier, source: "Owned recovery fixture",
                                   path: body.path, size: "1 KB")
            try fm.createDirectory(at: cache, withIntermediateDirectories: true)
            for file in names { try Data(("owned fake " + file).utf8).write(to: cache.appendingPathComponent(file)) }
            try fm.createDirectory(at: logs, withIntermediateDirectories: true)
            try Data("owned old log".utf8).write(to: logs.appendingPathComponent("old.log"))
            let planner = UninstallPlanningService(dependencies: .init(inventory: OwnedWorkflowInventory(root: home.appendingPathComponent("Applications")),
                allocatedBytes: { BoundedApplicationSizeMeasurer().allocatedBytes(at: $0) },
                isPhysicalPath: { url, home in url.path.hasPrefix(home.path + "/") && DeletionPlan.isLexicallySafePath(url.path) },
                requiresAdministrator: { _ in false }, commandOutput: { _, _ in nil }, brewExecutables: []))
            let plan = planner.plan(for: app, homeDirectory: home.path)!
            precondition([body.path, cache.path, logs.path].allSatisfy { path in
                plan.files.contains { $0.path == path && !$0.informational } && plan.fileIdentities[path]?.isEmpty == false
            }, "Recovery did not capture the body, .app cache and Logs identities")
            try fm.createDirectory(at: trash, withIntermediateDirectories: false)
            // Simulate a real first attempt that already moved these two roots.
            try move(body, to: trash.appendingPathComponent("first-body.app"), in: root)
            try move(logs, to: trash.appendingPathComponent("first-logs"), in: root)
            return Fixture(root: root, home: home, trash: trash, body: body, cache: cache, logs: logs, app: app, plan: plan)
        }
        func withIdentities(_ value: Fixture, _ identities: [String: String]) -> UninstallPlan {
            .init(files: value.plan.files, fileIdentities: identities, needsAdmin: value.plan.needsAdmin,
                isBrewCask: value.plan.isBrewCask, caskToken: value.plan.caskToken,
                includesProtectedAppData: value.plan.includesProtectedAppData, scannedAt: value.plan.scannedAt)
        }
        @MainActor
        func recover(_ value: Fixture, plan: UninstallPlan? = nil,
                     trashHandler: @escaping (URL) throws -> Void) async -> NativeCore.ApplySummary {
            let captured = plan ?? value.plan
            var applies = 0
            let dependencies = UninstallWorkflow.Dependencies(
                stop: { _ in preconditionFailure("Missing-body recovery must not stop any process") },
                plan: { _ in preconditionFailure("Force recovery must not rescan the accepted scope") },
                elevate: { _ in preconditionFailure("Missing-body recovery must never elevate") },
                apply: { app, plan, data, bodyAlreadyRemoved in
                    applies += 1
                    precondition(app == value.app && plan.files == captured.files
                        && plan.fileIdentities == captured.fileIdentities && plan.needsAdmin == captured.needsAdmin
                        && plan.includesProtectedAppData == captured.includesProtectedAppData && plan.scannedAt == captured.scannedAt
                        && !plan.isBrewCask && plan.caskToken.isEmpty && data.isEmpty && bodyAlreadyRemoved,
                                 "Recovery changed its original scope or lost the absent-body native route")
                    return core.applyUninstall(app, plan: plan, homeDirectory: value.home.path,
                        appAlreadyRemoved: bodyAlreadyRemoved, includingData: data, trashHandler: trashHandler)
                }, hasNoProcesses: { _ in true })
            let job = UninstallJob(id: UUID(), app: value.app, plan: captured, dataPaths: [], forceCleanup: true)
            let outcome = await UninstallWorkflow(dependencies: dependencies).execute(job) { _ in }
            guard case .applied(let summary, let accepted) = outcome else {
                preconditionFailure("Expected full force-to-native recovery result")
            }
            precondition(applies == 1 && accepted == captured, "Recovery bypassed Native or rebound its plan")
            return summary
        }
        let partial = try makeFixture("two-stage")
        let cacheDestination = partial.trash.appendingPathComponent("recovered-cache")
        var moved: [String] = []
        let first = await recover(partial) { source in
            precondition(source.path == partial.cache.path, "Recovery attempted to remove an already completed root")
            try move(source, to: cacheDestination, in: partial.root)
            moved.append(source.path)
        }
        precondition(first.succeeded && first.removed == 1 && first.removedPaths == [partial.cache.path]
            && first.remainingPaths.isEmpty && moved == [partial.cache.path],
                     "Already removed Logs produced a false failure or were counted as a new removal")
        for name in names {
            let payload = try Data(contentsOf: cacheDestination.appendingPathComponent(name))
            precondition(payload == Data(("owned fake " + name).utf8), "Recovered cache family was not intact in fixture Trash")
        }
        let second = await recover(partial) { _ in preconditionFailure("A no-op second recovery moved an absent path") }
        precondition(second.succeeded && second.removed == 0 && second.removedPaths.isEmpty && second.remainingPaths.isEmpty,
                     "An already completed captured scope did not recover idempotently")
        let bodyNotRemoved = core.applyUninstall(partial.app, plan: partial.plan, homeDirectory: partial.home.path,
            appAlreadyRemoved: false, trashHandler: { _ in preconditionFailure("Absent-body failure moved residues") })
        precondition(bodyNotRemoved.failed > 0 && bodyNotRemoved.removed == 0,
                     "Residue absence handling bypassed the ordinary body identity guard")

        for identity in [nil, "", "not-a-reviewed-identity", "1:2:not-a-time"] as [String?] {
            let value = try makeFixture("identity-" + UUID().uuidString)
            try move(value.cache, to: value.trash.appendingPathComponent("precompleted-cache"), in: value.root)
            var identities = value.plan.fileIdentities
            identities[value.logs.path] = identity
            let refused = await recover(value, plan: withIdentities(value, identities)) { _ in
                preconditionFailure("Missing or malformed identity authorized removal")
            }
            precondition(!refused.succeeded && refused.failed > 0 && refused.removed == 0,
                         "An absent path washed away missing or malformed consent")
        }
        for kind in ["ancestor-link", "dangling-leaf", "not-directory", "permission-denied"] {
            if kind == "permission-denied" && geteuid() == 0 { continue }
            let value = try makeFixture(kind)
            try move(value.cache, to: value.trash.appendingPathComponent("precompleted-cache"), in: value.root)
            let logsParent = value.logs.deletingLastPathComponent()
            if kind == "ancestor-link" {
                let redirect = value.root.appendingPathComponent("redirect")
                try fm.createDirectory(at: redirect, withIntermediateDirectories: false)
                try move(logsParent, to: value.trash.appendingPathComponent("original-logs-parent"), in: value.root)
                try fm.createSymbolicLink(at: logsParent, withDestinationURL: redirect)
            } else if kind == "dangling-leaf" {
                try fm.createSymbolicLink(at: value.logs, withDestinationURL: value.root.appendingPathComponent("absent-target"))
            } else if kind == "not-directory" {
                try move(logsParent, to: value.trash.appendingPathComponent("original-logs-parent"), in: value.root)
                try Data("not a directory".utf8).write(to: logsParent)
            } else {
                try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: logsParent.path)
            }
            let refused = await recover(value) { _ in preconditionFailure("Unknown or redirected absence authorized a move") }
            if kind == "permission-denied" { try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logsParent.path) }
            precondition(!refused.succeeded && refused.failed > 0 && refused.removed == 0,
                         "Unknown or nonphysical absence was accepted: " + kind)
        }
        let replacement = try makeFixture("replacement")
        try move(replacement.cache, to: replacement.trash.appendingPathComponent("original-cache"), in: replacement.root)
        try fm.createDirectory(at: replacement.cache, withIntermediateDirectories: false)
        try Data("new cache object".utf8).write(to: replacement.cache.appendingPathComponent("new.cache"))
        let changed = await recover(replacement) { _ in preconditionFailure("An old plan moved a replacement cache") }
        precondition(!changed.succeeded && changed.removed == 0 && changed.remainingPaths.contains(replacement.cache.path),
                     "A replacement object inherited recovery consent")
        let reappeared = try makeFixture("reappeared-logs")
        let reappearedResult = await recover(reappeared) { source in
            precondition(source.path == reappeared.cache.path)
            try move(source, to: reappeared.trash.appendingPathComponent("recovered-cache"), in: reappeared.root)
            try fm.createDirectory(at: reappeared.logs, withIntermediateDirectories: true)
            try Data("new log after the absence check".utf8).write(to: reappeared.logs.appendingPathComponent("new.log"))
        }
        precondition(!reappearedResult.succeeded && reappearedResult.removed == 1
            && reappearedResult.removedPaths == [reappeared.cache.path]
            && reappearedResult.remainingPaths.contains(reappeared.logs.path),
                     "Final verification accepted a skipped residue that reappeared during removal")
        print("Partial native recovery: only new cache counted, second recovery no-op, identity/absence/errors/links/reappearance refused")
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
            requiresAdministrator: { _ in false }, commandOutput: { _, _ in nil }))
        let original = planner.plan(for: selected, homeDirectory: home.path)!
        let cache = home.appendingPathComponent("Library/Caches/\(identifier)").path
        let logs = home.appendingPathComponent("Library/Logs/\(identifier)").path
        precondition(original.files.contains { $0.path == cache && !$0.informational }
                     && original.files.contains { $0.path == logs && !$0.informational }
                     && !original.dataPaths.isEmpty, "The native fixture did not reproduce automatic and optional residue coverage")
        let preservedPaths = original.files.filter { $0.path != selected.path }.map(\.path) + [otherInstallation.path]
        let before = Dictionary(preservedPaths.map { ($0, DeletionPlan.identity(at: $0)!) }, uniquingKeysWith: { first, _ in first })
        let core = NativeCore(cleanupOpenFileProbe: { [] })
        let trash = fixture.appendingPathComponent("Trash", isDirectory: true)
        precondition(DeletionPlan.isLexicallySafePath(fixture.path)
            && trash.path.hasPrefix(fixture.path + "/") && trash.deletingLastPathComponent().path == fixture.path,
                     "The owned Trash must remain directly inside the nonce fixture")
        try fm.createDirectory(at: trash, withIntermediateDirectories: false)
        let trashedBundle = trash.appendingPathComponent((selected.path as NSString).lastPathComponent)
        var stops = 0
        var nativeApplies = 0
        let dependencies = UninstallWorkflow.Dependencies(stop: { app in
            stops += 1
            var environment = UninstallProcessController.Environment()
            environment.sample = { [] } // The owned dummy bundle is never launched.
            environment.signal = { _, _ in preconditionFailure("An owned metadata fixture received a signal") }
            return await UninstallProcessController.stop(app, environment: environment)
        }, plan: { app in planner.plan(for: app, homeDirectory: home.path) }, elevate: { _ in
            preconditionFailure("A user-owned native fixture must never request administrator uninstall")
        }, apply: { app, plan, data, appAlreadyRemoved in
            nativeApplies += 1
            precondition(plan.files.map(\.path) == [app.path] && data.isEmpty && !appAlreadyRemoved,
                         "Native apply received a cache/data path or an already-removed user-owned bundle")
            // Exercise the real native bundle guard, replacing only the Trash
            // destination with the nonce fixture's recoverable directory.
            let moved = core.applyCleanup(items: [.init(record: app.path, identity: app.appIdentity)],
                permanent: false, homeDirectory: home.path, allowedRoots: [app.path],
                allowApplicationBundle: true, trashHandler: { source in
                    precondition(source.path == selected.path && source.path.hasPrefix(fixture.path + "/")
                        && trashedBundle.path.hasPrefix(trash.path + "/")
                        && trashedBundle.deletingLastPathComponent().path == trash.path,
                                 "The native Trash handler escaped the owned fixture")
                    try fm.moveItem(at: source, to: trashedBundle)
                })
            precondition(moved.succeeded && moved.removedPaths == [app.path]
                && !fm.fileExists(atPath: app.path), "The native guard did not move the captured fixture body")
            return core.applyUninstall(app, plan: plan, homeDirectory: home.path,
                                       appAlreadyRemoved: true, includingData: data)
        })
        let job = UninstallJob(id: UUID(), app: selected, plan: original, dataPaths: Set(original.dataPaths), scope: .installationOnly)
        let result = await UninstallWorkflow(dependencies: dependencies).execute(job) { _ in }
        guard case .applied(let summary, _) = result else { preconditionFailure("Expected native installation-only result") }
        precondition(summary.succeeded && summary.removedPaths == [selected.path]
                     && !fm.fileExists(atPath: selected.path) && stops == 2 && nativeApplies == 1,
                     "The captured body was not removed through the guarded native workflow")
        precondition(fm.fileExists(atPath: trashedBundle.appendingPathComponent("Contents/Info.plist").path),
                     "The guarded native move did not leave a recoverable bundle in fixture Trash")
        precondition(before.allSatisfy { DeletionPlan.identity(at: $0.key) == $0.value },
                     "Installation-only changed automatic caches, optional data or another installation")
    }
}
