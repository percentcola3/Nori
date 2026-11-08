import Darwin
import Foundation

@main
struct CleanupNonRemovableTests {
    static let fm = FileManager.default
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NSError(domain: message, code: 1) }
    }
    static func write(_ path: URL, _ data: Data = Data(repeating: 0x53, count: 256)) throws {
        try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: path)
    }
    static func item(_ path: URL) -> DeletionPlan.Item {
        .init(record: path.path, identity: DeletionPlan.identity(at: path.path) ?? "", metadata: DeletionPlan.Metadata.read(path.path))
    }
    static func category(_ path: URL) -> CleanupCategory {
        .init(name: "Nonce cache", paths: [path.path], bytes: 4096, selected: true,
              source: .core, risk: .safe, disposal: .permanentDelete, applyRoute: .genericTrash)
    }
    static func testPureMetadata() throws {
        let flags = [UF_IMMUTABLE, SF_IMMUTABLE, UF_APPEND, SF_APPEND, SF_RESTRICTED, SF_NOUNLINK, UF_DATAVAULT]
        for flag in flags {
            try expect(NativeCore.knownCleanupProtection(itemFlags: UInt32(flag), parentFlags: 0, filesystemFlags: 0) == .protectedFlags,
                       "An item protection flag was offered as permission-only")
            let parentReason = NativeCore.knownCleanupProtection(itemFlags: 0, parentFlags: UInt32(flag), filesystemFlags: 0)
            try expect(parentReason == (flag == SF_NOUNLINK ? nil : .protectedFlags),
                       "Parent content protection confused NOUNLINK with immutable/entitlement flags")
        }
        try expect(NativeCore.knownCleanupProtection(itemFlags: 0, parentFlags: 0,
                   filesystemFlags: UInt32(MNT_RDONLY)) == .readOnlyVolume, "Readonly volume was not known hard protection")
        try expect(NativeCore.knownCleanupProtection(itemFlags: 0, parentFlags: nil, filesystemFlags: nil) == nil,
                   "Missing probes became hard evidence")
        try expect(NativeCore.knownCleanupProtection(itemFlags: UInt32(UF_HIDDEN), parentFlags: UInt32(SF_NOUNLINK),
                   filesystemFlags: 0) == nil, "A harmless item flag or parent NOUNLINK quieted a removable child")
    }
    static func testExactNativeReceipts(in home: URL) throws {
        let root = home.appendingPathComponent(".Trash/exact-root")
        let child = root.appendingPathComponent("payload.cache")
        try write(child)
        let rootItem = item(root), childItem = item(child)
        let core = NativeCore(cleanupOpenFileProbe: { [] })
        core.knownCleanupProtectionForTesting = { $0 == root.path ? .protectedFlags : nil }
        // Whitelist and other soft guards must not obscure a proven hard root.
        try write(home.appendingPathComponent(".config/mole/whitelist"), Data((root.path + "\n").utf8))
        let result = core.applyCleanup(items: [rootItem, childItem, rootItem], permanent: true, homeDirectory: home.path)
        try expect(result.skipped == 2 && result.failed == 0 && result.removed == 0,
                   "Covered skip accounting changed or duplicate input was counted twice")
        try expect(result.retainedTargets == [.init(record: root.path, identity: rootItem.identity, reason: .protectedFlags, count: 1)],
                   "A parent's hard protection became an unproven child receipt")
        try expect(fm.fileExists(atPath: child.path), "A merged hard-root attempt deleted a child")
        try write(home.appendingPathComponent(".config/mole/whitelist"), Data())
        let retry = core.applyCleanup(items: [childItem], permanent: true, homeDirectory: home.path)
        try expect(retry.removed == 1 && retry.retainedTargets.isEmpty && !fm.fileExists(atPath: child.path),
                   "Exact child retry was suppressed by its separately retained parent")

        let readonly = home.appendingPathComponent(".Trash/readonly-root")
        let readonlyChild = readonly.appendingPathComponent("payload.cache")
        try write(readonlyChild)
        let submitted = [item(readonly), item(readonlyChild)]
        let exactPaths = Set(submitted.map(\.record))
        core.knownCleanupProtectionForTesting = { exactPaths.contains($0) ? .readOnlyVolume : nil }
        let retained = core.applyCleanup(items: submitted, permanent: true, homeDirectory: home.path)
        try expect(retained.skipped == 2 && retained.retainedTargets.count == 2
            && Set(retained.retainedTargets.map(\.record)) == exactPaths
            && retained.retainedTargets.allSatisfy { $0.count == 1 && $0.reason == .readOnlyVolume },
            "Independently confirmed nested readonly targets were coalesced")
        let wrapped = core.verifyUninstallResult(retained, files: [])
        try expect(wrapped.retainedTargets == retained.retainedTargets, "A result wrapper dropped retained targets")
        let report = try JSONDecoder().decode(AdministratorCleanupPlan.Report.self,
                    from: JSONEncoder().encode(AdministratorCleanupPlan.Report(retained)))
        try expect(report.retainedTargets == retained.retainedTargets, "Report coding dropped exact retained evidence")
    }
    static func testAdministratorExactPlan(in home: URL) throws {
        let root = home.appendingPathComponent("Library/Caches/com.example.exact-admin")
        let child = root.appendingPathComponent("payload.cache")
        try write(child)
        let rootItem = item(root), childItem = item(child)
        let core = NativeCore(cleanupOpenFileProbe: { [] })
        core.knownCleanupProtectionForTesting = { $0 == root.path ? .protectedFlags : nil }
        let result = AdministratorCleanupPlan.execute([rootItem, childItem].map {
            .init(path: $0.record, identity: $0.identity, metadata: $0.metadata)
        }, homeDirectory: home.path, core: core)
        try expect(result.retainedTargets == [.init(record: root.path, identity: rootItem.identity, reason: .protectedFlags, count: 1)]
            && result.removedPaths.contains(child.path) && !fm.fileExists(atPath: child.path),
            "Admin hard partition swallowed an independently removable original child")
    }
    static func testUnknownAndPrompt(in home: URL) throws {
        let path = home.appendingPathComponent("Library/Caches/com.example.prompt/payload.cache")
        try write(path)
        let captured = item(path)
        let core = NativeCore(cleanupOpenFileProbe: { [] })
        core.knownCleanupProtectionForTesting = { $0 == path.path ? .protectedFlags : nil }
        try expect(core.knownNonRemovableRoot(path.path, expectedIdentity: captured.identity) == .protectedFlags,
                   "A fresh identity-bound hard fact was lost")
        try expect(!core.requiresAdministratorDeletion(path.path, homeDirectory: home.path)
            && !core.administratorDeletionRootIsAdmissible(path.path, expectedIdentity: captured.identity, homeDirectory: home.path),
            "Hard refusal was promoted to administrator access")
        NativeCore.shared.knownCleanupProtectionForTesting = core.knownCleanupProtectionForTesting
        defer { NativeCore.shared.knownCleanupProtectionForTesting = nil }
        try expect(AdministratorCleanupPlan.confirmationItems([category(path)],
            administratorRequiredPaths: [path.path], homeDirectory: home.path).isEmpty,
            "Cached administrator evidence bypassed a hard root")
        try Data(repeating: 0x54, count: 256).write(to: path, options: .atomic)
        try expect(core.knownNonRemovableRoot(path.path, expectedIdentity: captured.identity) == nil,
                   "Replacement identity was quieted")
        let changed = core.applyCleanup(items: [captured], permanent: true, homeDirectory: home.path)
        try expect(changed.retainedTargets.isEmpty && changed.removed == 0 && fm.fileExists(atPath: path.path),
                   "A changed root obtained a receipt by copying expected identity")
        try expect(core.knownNonRemovableRoot(path.path + ".missing", expectedIdentity: captured.identity) == nil,
                   "A missing target became confirmed hard evidence")
        let alias = home.appendingPathComponent("Library/Caches/alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: path.deletingLastPathComponent())
        try expect(core.knownNonRemovableRoot(alias.appendingPathComponent(path.lastPathComponent).path,
                   expectedIdentity: item(path).identity) == nil, "Hard proof followed a symbolic ancestor")
    }
    static func testPermissionOnlyAndShell(in home: URL) throws {
        let directory = home.appendingPathComponent("Library/Caches/com.example.permission")
        let leaf = directory.appendingPathComponent("payload.cache")
        try write(leaf)
        let core = NativeCore(cleanupOpenFileProbe: { [] })
        try expect(chmod(directory.path, 0o555) == 0, "Cannot prepare owned mode fixture")
        defer { _ = chmod(directory.path, 0o755) }
        try expect(core.requiresAdministratorDeletion(leaf.path, homeDirectory: home.path)
            && core.administratorDeletionRootIsAdmissible(leaf.path, expectedIdentity: item(leaf).identity, homeDirectory: home.path)
            && core.knownNonRemovableRoot(leaf.path, expectedIdentity: item(leaf).identity) == nil,
            "Permission-only readable content was lost from supported escalation")
        try expect(chmod(directory.path, 0o755) == 0, "Cannot release owned mode fixture")
        let shell = home.appendingPathComponent("Library/Caches/com.example.nounlink-shell")
        let usable = shell.appendingPathComponent("usable.cache"), keep = shell.appendingPathComponent("keep.cache")
        let database = shell.appendingPathComponent("database.cache")
        try write(usable); try write(keep)
        var bytes = Data(repeating: 0x53, count: 256)
        bytes.replaceSubrange(0..<16, with: Data("SQLite format 3\0".utf8))
        try write(database, bytes)
        try write(home.appendingPathComponent(".config/mole/whitelist"), Data((keep.path + "\n").utf8))
        core.nounlinkCleanupShellsForTesting = [shell.path]
        let scan = core.preflightCleanupCategories([category(shell)], homeDirectory: home.path,
            control: CleanupScanControl(mode: .deep), includingAdministratorRequired: true)
        try expect(scan.succeeded && Set(scan.categories.flatMap(\.paths)) == [usable.path]
            && scan.administratorRequiredPaths.isEmpty,
            "NOUNLINK shell hid removable children, offered itself or bypassed child content guards")
        try expect(fm.fileExists(atPath: usable.path) && fm.fileExists(atPath: database.path), "Read-only shell preflight mutated files")
    }
    static func main() throws {
        try expect(geteuid() != 0 && CommandLine.arguments.count == 2, "Tests require unprivileged nonce fixture base")
        let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).resolvingSymlinksInPath()
        let fixture = base.appendingPathComponent(".cleanup-non-removable-fixture." + UUID().uuidString)
        try expect(fixture.path.hasPrefix(base.path + "/.cleanup-non-removable-fixture.") && mkdir(fixture.path, 0o700) == 0,
                   "Cannot create exclusive nonce fixture")
        var owned = stat()
        try expect(lstat(fixture.path, &owned) == 0, "Cannot bind nonce fixture")
        defer {
            var current = stat()
            if lstat(fixture.path, &current) == 0, current.st_dev == owned.st_dev, current.st_ino == owned.st_ino,
               fixture.path.hasPrefix(base.path + "/.cleanup-non-removable-fixture.") { try? fm.removeItem(at: fixture) }
        }
        let home = fixture.appendingPathComponent("home")
        try testPureMetadata()
        try testExactNativeReceipts(in: home)
        try testAdministratorExactPlan(in: home)
        try testUnknownAndPrompt(in: home)
        try testPermissionOnlyAndShell(in: home)
        print("PASS non-removable: pure flags/readonly/unknown, parent NOUNLINK, exact receipts/count1, nested readonly, removable child/admin plan, changed identity, cached prompt gate, permission-only and retained shell split")
    }
}
