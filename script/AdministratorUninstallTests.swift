import Darwin
import Foundation

// Keep the real service and worker; replace only the system authorization UI.
final class MoleEngine {
    static let shared = MoleEngine()
    var response = RunResult(output: "Authorization cancelled", exitCode: 1, timedOut: false)
    var inspect: ((String, [String]) throws -> Void)?
    var manifest: String?
    var calls = 0

    func runPrivilegedBridge(_ path: String, arguments: [String],
                             timeout: TimeInterval) async -> RunResult {
        calls += 1
        manifest = arguments.last
        do { try inspect?(path, arguments) }
        catch { fatalError("Invalid administrator request: \(error)") }
        return response
    }
}

@main
struct AdministratorUninstallTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: message, code: 1) }
    }

    static func main() async throws {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let appURL = URL(fileURLWithPath: "/Applications/NoriAdminUninstallFixture-\(UUID().uuidString).app")
        defer { try? fm.removeItem(at: appURL) }
        let identifier = "com.example.nori-admin-uninstall-fixture"
        let info = appURL.appendingPathComponent("Contents/Info.plist")
        func createApp() throws -> UninstallApp {
            try fm.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(fromPropertyList:
                ["CFBundleIdentifier": identifier, "CFBundleName": "Fixture"], format: .xml, options: 0)
            try plist.write(to: info)
            return UninstallApp(name: "Fixture", bundleID: identifier, source: "Fixture",
                                path: appURL.path, size: "1 KB")
        }
        func request(_ app: UninstallApp) -> AdministratorUninstallPlan.Request {
            .init(app: app, metadata: DeletionPlan.Metadata.read(app.path)!)
        }
        let core = NativeCore(cleanupOpenFileProbe: { [] })
        let app = try createApp()
        let planned = request(app)
        try expect(!core.uninstallRequiresAdministrator(app.path), "User-owned app unnecessarily elevates")
        try expect(core.uninstallRequiresAdministrator("/System/Applications"), "Root-owned app directory misses elevation")
        try expect(!core.uninstallRequiresAdministrator(home.path + "/absent.app"), "Missing app elevated")

        // A changed Info.plist or a replacement bundle cannot cross authorization.
        try Data("changed".utf8).write(to: info)
        let changed = AdministratorUninstallPlan.execute(planned, home: home.path, uid: getuid(), core: core)
        try expect(changed.removed == 0 && changed.failed == 1 && fm.fileExists(atPath: app.path),
                   "Changed app was removed")
        try fm.removeItem(at: appURL)
        let fresh = try createApp()
        let freshRequest = request(fresh)
        let wrongID = UninstallApp(name: fresh.name, bundleID: "com.example.different", source: fresh.source,
            path: fresh.path, size: fresh.size, appIdentity: fresh.appIdentity, infoIdentity: fresh.infoIdentity)
        let mismatch = AdministratorUninstallPlan.execute(request(wrongID), home: home.path, uid: getuid(), core: core)
        try expect(mismatch.removed == 0 && mismatch.failed == 1, "Bundle ID mismatch passed")
        let selfApp = UninstallApp(name: "Nori", bundleID: "com.nori.app", source: "Fixture", path: fresh.path, size: "")
        try expect(!AdministratorUninstallPlan.allows(selfApp), "Nori can uninstall itself as administrator")
        let outside = UninstallApp(name: "Fixture", bundleID: identifier, source: "Fixture",
                                   path: home.path + "/Other.app", size: "", appIdentity: "1:2:3", infoIdentity: "1:2:3")
        try expect(!AdministratorUninstallPlan.allows(outside), "Administrator route accepts arbitrary paths")
        let occupied = AdministratorUninstallPlan.execute(freshRequest, home: home.path, uid: getuid(),
            core: NativeCore(cleanupOpenFileProbe: { [info.path] }))
        try expect(!occupied.succeeded && occupied.removed == 0 && occupied.skipped == 1,
                   "Administrator bypassed open-file protection or reported false success")
        let unknown = AdministratorUninstallPlan.execute(freshRequest, home: home.path, uid: getuid(),
            core: NativeCore(cleanupOpenFileProbe: { nil }))
        try expect(!unknown.succeeded && unknown.removed == 0 && unknown.skipped == 1,
                   "Unknown open-file state allowed removal or reported false success")

        // The privileged lsof snapshot sees system metadata readers that the
        // user's snapshot misses. Only read-only metadata can survive a Trash
        // move; execution, mapped files, writes and unknown access still block.
        let parsed = NativeCore.openFileRecords(from: """
        p123
        cmdworker_shared
        f7
        ar
        n\(info.path)
        ftxt
        n\(appURL.path)/Contents/MacOS/Fixture
        p456
        cWriter
        f8
        au
        n\(info.path)
        """)
        try expect(parsed.count == 3 && parsed[0].isReadOnlyBundleMetadata,
                   "Read-only metadata observer was not recognized")
        try expect(!parsed[1].isReadOnlyBundleMetadata && parsed[1].access.isEmpty
                   && !parsed[2].isReadOnlyBundleMetadata && parsed[2].pid == 456,
                   "Executable/write handle or stale access classified as metadata")
        let observers = NativeCore.openFileRecords(from: """
        p330
        cUserEventAgent
        f12
        ar
        n\(appURL.path)
        p331
        cBlueStacks
        f12
        ar
        n\(appURL.path)
        p332
        cUserEventAgent
        fcwd
        ar
        n\(appURL.path)
        """)
        try expect(observers.count == 3 && observers[0].isObserverDirectoryHandle(onBundle: appURL.path)
                   && !observers[1].isObserverDirectoryHandle(onBundle: appURL.path)
                   && !observers[2].isObserverDirectoryHandle(onBundle: appURL.path)
                   && !observers[0].isObserverDirectoryHandle(onBundle: appURL.path + "/Contents"),
                   "only a system agent's read-only bundle directory handle may be ignored")
        for record in parsed.dropFirst() {
            let busy = AdministratorUninstallPlan.execute(freshRequest, home: home.path, uid: getuid(),
                core: NativeCore(cleanupOpenFileRecordsProbe: { [parsed[0], record] }))
            try expect(!busy.succeeded && busy.removed == 0 && busy.skipped == 1
                       && busy.messages.contains(where: { $0.contains("PID \(record.pid)") }),
                       "Active app/write handle bypassed occupancy or lost diagnostic")
        }
        let metadataObserverCore = NativeCore(cleanupOpenFileRecordsProbe: { [parsed[0]] })
        let permanent = metadataObserverCore.applyCleanup(items: [.init(record: fresh.path,
            identity: fresh.appIdentity, metadata: freshRequest.metadata)], permanent: true,
            homeDirectory: home.path, allowedRoots: [fresh.path], allowApplicationBundle: true)
        try expect(permanent.removed == 0 && permanent.skipped == 1 && fm.fileExists(atPath: fresh.path),
                   "Metadata exception leaked into permanent deletion")

        let trash = home.appendingPathComponent(".Trash")
        let outsideTrash = home.appendingPathComponent("outside-trash")
        try fm.createDirectory(at: outsideTrash, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: trash, withDestinationURL: outsideTrash)
        let symlinkTrash = AdministratorUninstallPlan.execute(freshRequest, home: home.path, uid: getuid(), core: core)
        try expect(symlinkTrash.removed == 0 && symlinkTrash.failed == 1 && fm.fileExists(atPath: app.path),
                   "Symlinked Trash accepted")
        try fm.removeItem(at: trash)
        try fm.createDirectory(at: trash, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o755])
        let publicTrash = AdministratorUninstallPlan.execute(freshRequest, home: home.path, uid: getuid(), core: core)
        try expect(publicTrash.removed == 0 && publicTrash.failed == 1, "Public Trash accepted")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: trash.path)
        let collision = trash.appendingPathComponent(appURL.lastPathComponent)
        try Data("keep existing trash".utf8).write(to: collision)
        let metadataReader = try FileHandle(forReadingFrom: info)
        defer { try? metadataReader.close() }
        let moved = AdministratorUninstallPlan.execute(freshRequest, home: home.path, uid: getuid(),
                                                       core: metadataObserverCore)
        try expect(moved.removed == 1 && moved.succeeded && moved.removedPaths == [fresh.path],
                   "Application was not moved to requesting user's Trash: \(moved.messages)")
        try expect(!fm.fileExists(atPath: fresh.path), "Application remains after successful move")
        let stillReadable = try metadataReader.readToEnd()
        try expect(stillReadable?.isEmpty == false, "Trash move invalidated the read-only metadata handle")
        let existingTrash = try Data(contentsOf: collision)
        try expect(existingTrash == Data("keep existing trash".utf8), "Existing Trash overwritten")
        let trashedApps = try fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)
            .filter { $0 != collision && $0.pathExtension == "app" }
        try expect(trashedApps.count == 1 && fm.fileExists(atPath: trashedApps[0].appendingPathComponent("Contents/Info.plist").path),
                   "Moved bundle is not recoverable")

        // Normal follow-up counts the already moved app once, without scanning it again.
        let residue = home.appendingPathComponent("Library/Caches/\(identifier)/entry")
        try fm.createDirectory(at: residue.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: residue)
        let files: [UninstallFile] = [.init(bytes: 1, label: "App", path: fresh.path),
                                    .init(bytes: 3, label: "Cache", path: residue.path)]
        let followUpPlan = UninstallPlan(files: files, needsAdmin: true, isBrewCask: false,
                                        caskToken: "-", includesProtectedAppData: true, scannedAt: Date())
        try fm.removeItem(at: residue)
        let followUp = core.applyUninstall(fresh, plan: followUpPlan, homeDirectory: home.path, appAlreadyRemoved: true)
        try expect(followUp.removed == 1 && followUp.removedPaths == [fresh.path], "Elevated app count/identity lost")

        let authApp = try createApp()
        let blockedPlan = UninstallPlan(files: [.init(bytes: 1, label: "App", path: authApp.path)],
            needsAdmin: false, isBrewCask: false, caskToken: "-", includesProtectedAppData: true, scannedAt: Date())
        let blocked = NativeCore(cleanupOpenFileProbe: { [info.path] })
            .applyUninstall(authApp, plan: blockedPlan, homeDirectory: home.path)
        try expect(blocked.failed == 1 && blocked.removed == 0, "One blocked bundle counted twice")
        let engine = MoleEngine.shared
        engine.inspect = { path, args in
            try expect(path == "bin/app_uninstall_admin.sh" && args[0] == String(getuid()), "Wrong privileged bridge/account")
            let data = AdministratorCleanupPlan.readPrivatePlan(args[1], owner: getuid())
            try expect(data != nil, "Manifest is not private and account-bound")
            let decoded = try JSONDecoder().decode(AdministratorUninstallPlan.Request.self, from: data!)
            try expect(decoded.app == authApp && decoded.metadata == DeletionPlan.Metadata.read(authApp.path),
                       "Service lost reviewed app identity")
        }
        let cancelled = await AdministratorUninstallService.apply(authApp)
        try expect(!cancelled.succeeded && cancelled.removed == 0 && fm.fileExists(atPath: authApp.path),
                   "Cancelled authorization changed application")
        try expect(!fm.fileExists(atPath: engine.manifest!), "Private manifest leaked after cancellation")
        let fakeSuccess = NativeCore.ApplySummary(removed: 1, skipped: 0, failed: 0, messages: [], removedPaths: [authApp.path])
        let report = try JSONEncoder().encode(AdministratorCleanupPlan.Report(fakeSuccess))
        engine.response = RunResult(output: AdministratorUninstallPlan.reportPrefix + String(decoding: report, as: UTF8.self),
                                    exitCode: 0, timedOut: false)
        let reported = await AdministratorUninstallService.apply(authApp)
        try expect(reported.removed == 1 && reported.removedPaths == [authApp.path], "Valid report was rejected")
        let badReport = try JSONEncoder().encode(AdministratorCleanupPlan.Report(
            .init(removed: 1, skipped: 0, failed: 0, messages: [], removedPaths: ["/Applications/Other.app"])))
        engine.response = RunResult(output: AdministratorUninstallPlan.reportPrefix + String(decoding: badReport, as: UTF8.self),
                                    exitCode: 0, timedOut: false)
        let refusedReport = await AdministratorUninstallService.apply(authApp)
        try expect(refusedReport.failed == 1 && refusedReport.removed == 0, "Mismatched report accepted")
        let reappeared = core.applyUninstall(authApp, plan: followUpPlan, homeDirectory: home.path, appAlreadyRemoved: true)
        try expect(reappeared.failed == 1 && reappeared.removed == 0, "Reappeared app is removed without reauthorization")
        print("Administrator uninstall: identity, scope, Trash, occupancy, cancellation and reports passed")
    }
}
