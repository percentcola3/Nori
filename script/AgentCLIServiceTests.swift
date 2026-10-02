import Darwin
import Foundation

@main
struct AgentCLIServiceTests {
    static func main() throws {
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            .standardizedFileURL
        let fm = FileManager.default
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        let home = fixture.appendingPathComponent("home with 'quotes $value", isDirectory: true).path
        let prefix = home + "/.nvm/versions/node/v99.0.0"
        let bin = prefix + "/bin"
        let package = prefix + "/lib/node_modules/@openai/codex"
        let npmScript = prefix + "/lib/node_modules/npm/bin/npm-cli.js"
        let launcher = bin + "/codex"
        let codex = AgentCatalog.definitions.first { $0.id == "codex" }!
        let context = AgentPresenceContext(applicationDirs: [], searchPath: [bin])
        let idle = RunningApplicationSnapshot()

        // npm's real launcher uses /usr/bin/env node. The fake runtime only
        // launches this fixture script; no installed CLI/package manager runs.
        try executable(bin + "/node", "#!/bin/sh\nexec /bin/sh \"$@\"\n")
        try executable(npmScript, "#!/usr/bin/env node\n"
            + "[ \"$HOME\" = " + quote(home) + " ] || exit 31\n"
            + "[ \"${PATH%%:*}\" = " + quote(bin) + " ] || exit 32\n"
            + "[ \"$1\" = uninstall ] && [ \"$2\" = --global ] && [ \"$3\" = --prefix ] || exit 33\n"
            + "[ \"$4\" = " + quote(prefix) + " ] && [ \"$5\" = @openai/codex ] || exit 34\n"
            + "/bin/rm -rf -- \"$4/lib/node_modules/@openai/codex\" \"$4/bin/codex\"\n")
        try fm.createSymbolicLink(atPath: bin + "/npm", withDestinationPath: npmScript)
        try createCodex(package: package, launcher: launcher)
        let shared = package + "/shared.bin"
        let outsideLink = home + "/shared-outside-cli.bin"
        try Data(repeating: 0x7d, count: 128 * 1024).write(to: URL(fileURLWithPath: shared))
        try fm.linkItem(atPath: shared, toPath: outsideLink)
        let sharedAllocation = allocatedBytes(shared)

        let managed = installation(codex, home: home, context: context, launcher: launcher)
        expect(managed.manager == .npm && managed.managerExecutable == bin + "/npm",
               "Bind a global npm installation to its own package manager")
        let active = AgentCLIService.uninstall(managed, home: home,
            running: RunningApplicationSnapshot(processNames: ["codex"]), permanent: true)
        expect(!active.succeeded && active.failed > 0
               && active.messages.contains(where: { $0.contains("running Agent owners") && $0.contains("codex") })
               && AgentCatalog.exists(package),
               "Name active Agent owners in the uninstall refusal")
        let unavailable = AgentCLIService.uninstall(managed, home: home, running: .unavailable, permanent: true)
        expect(!unavailable.succeeded && unavailable.failed > 0
               && unavailable.messages.contains(where: { $0.contains("process state is unavailable") })
               && AgentCatalog.exists(package),
               "Distinguish unavailable process state from a running Agent")
        let removed = AgentCLIService.uninstall(managed, home: home, running: idle, permanent: true)
        expect(removed.succeeded && !AgentCatalog.exists(package) && !AgentCatalog.exists(launcher),
               "Run npm with its installed runtime first and the requested HOME: \(removed.messages)")
        expect(removed.reclaimedBytes > 0 && removed.reclaimedBytes < sharedAllocation
               && AgentCatalog.exists(outsideLink),
               "Count confirmed package allocation without claiming an outside hard link was freed")

        // A manager that exits zero without removing anything must never
        // authorize the subsequent user-data cleanup.
        try createCodex(package: package, launcher: launcher)
        try executable(npmScript, "#!/usr/bin/env node\nexit 0\n")
        let noOp = installation(codex, home: home, context: context, launcher: launcher)
        let kept = AgentCLIService.uninstall(noOp, home: home, running: idle, permanent: true)
        expect(!kept.succeeded && kept.failed > 0 && AgentCatalog.exists(package)
               && AgentCatalog.exists(launcher)
               && kept.messages.contains(where: { $0.contains(package) && $0.contains("left installation") }),
               "Report remaining installation paths when a manager silently does nothing")
        expect(kept.reclaimedBytes == 0, "A no-op manager must report no reclaimed space")

        try executable(npmScript, "#!/usr/bin/env node\nexit 23\n")
        let broken = installation(codex, home: home, context: context, launcher: launcher)
        let failed = AgentCLIService.uninstall(broken, home: home, running: idle, permanent: true)
        expect(!failed.succeeded && failed.failed > 0
               && failed.messages.contains(where: { $0.contains("status 23") }),
               "Report a package-manager failure even without diagnostic output")
        expect(failed.reclaimedBytes == 0, "A failed manager that deleted nothing must report no reclaimed space")

        let partialFile = package + "/partial-cache.bin"
        try Data(repeating: 0x6b, count: 64 * 1024).write(to: URL(fileURLWithPath: partialFile))
        let partialAllocation = allocatedBytes(partialFile)
        let firstPass = fixture.appendingPathComponent("partial-uninstall-first-pass").path
        try executable(npmScript, "#!/usr/bin/env node\n"
            + "if [ -e " + quote(firstPass) + " ]; then\n"
            + " /bin/rm -rf -- " + quote(package) + " " + quote(launcher) + "\n exit 0\nfi\n"
            + "/bin/rm -f -- " + quote(partialFile) + " " + quote(launcher) + "\n"
            + "/usr/bin/touch " + quote(firstPass) + "\nexit 23\n")
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: package)
        let partialInstallation = installation(codex, home: home, context: context, launcher: launcher)
        let partial = AgentCLIService.uninstall(partialInstallation, home: home, running: idle, permanent: true)
        expect(partial.removed > 0 && partial.failed > 0 && !partial.succeeded
               && partial.reclaimedBytes == partialAllocation && AgentCatalog.exists(package)
               && !AgentCatalog.exists(launcher),
               "Preserve actual reclaimed allocation from a partial failed uninstall without authorizing data cleanup")
        expect(DeletionPlan.identity(at: package) != partialInstallation.identities[package]
               && AgentCLIService.installations(for: codex, home: home, presence: context).isEmpty,
               "The partial fixture changes package directory mtime and removes the discovery launcher")
        guard let resume = partial.retryInstallation else { fatalError("Partial uninstall must carry a frozen retry proof") }
        expect(!partial.requiresRescan && resume.id == partialInstallation.id
               && resume.managedPaths == partialInstallation.managedPaths
               && resume.executablePaths == partialInstallation.executablePaths
               && resume.identities == partialInstallation.identities,
               "Resume retains the original package, manager, file identities, and installation path envelope")
        let resumed = AgentCLIService.uninstall(resume, home: home, running: idle, permanent: true)
        expect(resumed.succeeded && resumed.reclaimedBytes > 0
               && !AgentCatalog.exists(package) && !AgentCatalog.exists(launcher),
               "A confirmed partial uninstall can rerun its original manager after its launcher disappears")

        // A same-name replacement manifest cannot inherit the accepted retry.
        try createCodex(package: package, launcher: launcher)
        try Data(repeating: 0x6b, count: 64 * 1024).write(to: URL(fileURLWithPath: partialFile))
        try fm.removeItem(atPath: firstPass)
        let replaceable = installation(codex, home: home, context: context, launcher: launcher)
        let beforeReplacement = AgentCLIService.uninstall(replaceable, home: home, running: idle, permanent: true)
        guard let frozenResume = beforeReplacement.retryInstallation else { fatalError("Expected a retry proof") }
        try Data("{\"name\":\"@openai/codex\",\"replacement\":true}".utf8)
            .write(to: URL(fileURLWithPath: package + "/package.json"), options: .atomic)
        let replacement = AgentCLIService.uninstall(frozenResume, home: home, running: idle, permanent: true)
        expect(replacement.removed == 0 && replacement.requiresRescan && AgentCatalog.exists(package),
               "A replaced package manifest requires a fresh scan instead of authorizing partial retry")

        // The same accepted envelope may not resume once its package proof is gone.
        try fm.removeItem(atPath: package)
        try createCodex(package: package, launcher: launcher)
        try executable(npmScript, "#!/usr/bin/env node\n/bin/rm -f -- "
            + quote(package + "/package.json") + " " + quote(launcher) + "\nexit 23\n")
        let unprovable = installation(codex, home: home, context: context, launcher: launcher)
        let missingManifest = AgentCLIService.uninstall(unprovable, home: home, running: idle, permanent: true)
        expect(missingManifest.removed > 0 && missingManifest.retryInstallation == nil
               && missingManifest.requiresRescan && AgentCatalog.exists(package),
               "Missing package ownership proof offers a fresh scan rather than an impossible retry")

        let nativeRoot = home + "/.local/share/claude/versions"
        let nativeLauncher = home + "/.local/bin/claude"
        let nativeAgent = AgentCatalog.definitions.first { $0.id == "claude-code" }!
        try executable(nativeRoot + "/version-one", "#!/bin/sh\nexit 0\n")
        try Data(repeating: 0x74, count: 64 * 1024)
            .write(to: URL(fileURLWithPath: nativeRoot + "/payload.bin"))
        try fm.createDirectory(atPath: (nativeLauncher as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: nativeLauncher, withDestinationPath: nativeRoot + "/version-one")
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: nativeRoot)
        let native = installation(nativeAgent, home: home,
            context: .init(applicationDirs: [], searchPath: [home + "/.local/bin"]), launcher: nativeLauncher)
        var nativeChildren = 0
        var blockedNativeFile: String?
        var injectedNativeFailure = false
        let nativeCore = NativeCore(cleanupOpenFileProbe: { [] })
        let nativePartial = AgentCLIService.uninstall(native, home: home, running: idle, permanent: true,
            core: nativeCore,
            onCurrentFile: { path in
                guard path.hasPrefix(nativeRoot + "/") else { return }
                nativeChildren += 1
                if nativeChildren == 2 {
                    injectedNativeFailure = chflags(path, UInt32(UF_IMMUTABLE)) == 0
                    blockedNativeFile = path
                }
            })
        if let blockedNativeFile { _ = chflags(blockedNativeFile, 0) }
        expect(injectedNativeFailure && nativePartial.removed > 0 && nativePartial.failed > 0
               && nativePartial.reclaimedBytes > 0 && AgentCatalog.exists(nativeRoot)
               && DeletionPlan.identity(at: nativeRoot) != native.identities[nativeRoot],
               "Native uninstall preserves real partial removals when a later child cannot be deleted")
        guard let nativeResume = nativePartial.retryInstallation else { fatalError("Native partial work needs a retry proof") }
        let nativeRetried = AgentCLIService.uninstall(nativeResume, home: home, running: idle,
            permanent: true, core: nativeCore)
        expect(nativeRetried.succeeded && !AgentCatalog.exists(nativeRoot) && !AgentCatalog.exists(nativeLauncher),
               "Native partial uninstall resumes the same directory despite its own mtime change")

        try fm.removeItem(atPath: package)
        try createCodex(package: package, launcher: launcher)
        let changed = installation(codex, home: home, context: context, launcher: launcher)
        let marker = fixture.appendingPathComponent("manager-launched-after-change").path
        try executable(npmScript, "#!/usr/bin/env node\n/usr/bin/touch " + quote(marker) + "\n")
        let stale = AgentCLIService.uninstall(changed, home: home, running: idle, permanent: true)
        expect(!stale.succeeded && stale.failed > 0 && !AgentCatalog.exists(marker),
               "Reject a manager replaced after the installation scan")

        print("Agent CLI service tests passed")
    }

    private static func installation(_ agent: AgentDefinition, home: String,
                                     context: AgentPresenceContext, launcher: String) -> AgentCLIInstallation {
        AgentCLIService.installations(for: agent, home: home, presence: context)
            .first { $0.executablePaths.contains(launcher) }!
    }

    private static func allocatedBytes(_ path: String) -> UInt64 {
        var metadata = stat()
        precondition(lstat(path, &metadata) == 0)
        return UInt64(max(0, metadata.st_blocks)) * 512
    }

    private static func createCodex(package: String, launcher: String) throws {
        try executable(package + "/bin/codex.js", "#!/bin/sh\nexit 0\n")
        try Data("{\"name\":\"@openai/codex\"}".utf8)
            .write(to: URL(fileURLWithPath: package + "/package.json"))
        try FileManager.default.createSymbolicLink(atPath: launcher,
            withDestinationPath: package + "/bin/codex.js")
    }

    private static func executable(_ path: String, _ source: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try source.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
            exit(1)
        }
        print("PASS: " + message)
    }
}
