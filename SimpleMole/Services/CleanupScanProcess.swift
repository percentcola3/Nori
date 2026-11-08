import Foundation
import Darwin
import Security

/// The app's only cleanup discovery transport. Launch, signature checks, pipe IO,
/// DTO conversion and JSON all run on a utility executor, never on MainActor.
enum CleanupScanProcess {
    private struct Worker: Sendable {
        let url: URL
        /// Captured before spawn; nil is available only in the test build.
        let codeDirectoryHash: Data?
    }
    private struct ChildIdentity {
        let pid: pid_t
        let uid: uid_t
        let seconds: UInt64
        let microseconds: UInt64
        init?(_ pid: pid_t) {
            guard let info = Self.info(pid), info.pbi_uid == getuid() else { return nil }
            self.pid = pid; uid = info.pbi_uid
            seconds = info.pbi_start_tvsec; microseconds = info.pbi_start_tvusec
        }
        private static func info(_ pid: pid_t) -> proc_bsdinfo? {
            var value = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &value, size) == size ? value : nil
        }
        var isCurrent: Bool {
            guard let current = Self.info(pid) else { return false }
            return current.pbi_uid == uid && current.pbi_start_tvsec == seconds
                && current.pbi_start_tvusec == microseconds
        }
    }
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func cancel() { lock.lock(); value = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    private enum ProcessError: Error, CustomStringConvertible {
        case unavailable, untrusted, cancelled, timeout, exit(Int32), worker(String)
        var description: String {
            switch self {
            case .unavailable: return "Cleanup scan worker is unavailable."
            case .untrusted: return "Cleanup scan worker signature or bundle layout is invalid."
            case .cancelled: return "Scan cancelled."
            case .timeout: return "Cleanup scan worker timed out."
            case .exit(let code): return "Cleanup scan worker exited with status \(code)."
            case .worker(let message): return message
            }
        }
    }

    static func scanCleanup(homeDirectory: String = NSHomeDirectory(),
                            progress: CleanupScanProgressSink? = nil,
                            mode: CleanupScanMode = .quick,
                            control: CleanupScanControl? = nil,
                            agentPresence: AgentPresenceContext? = nil,
                            includingAdministratorRequired: Bool = false,
                            excludingScannedRoots: Set<String> = [],
                            cachedCategories: [CleanupCategory]? = nil) async -> NativeCore.CleanupScan {
        await perform(homeDirectory: homeDirectory, progress: progress, mode: mode,
            control: control, agentPresence: agentPresence,
            includingAdministratorRequired: includingAdministratorRequired,
            excludingScannedRoots: excludingScannedRoots, cachedCategories: cachedCategories,
            resolveWorker: { try verifiedWorker() })
    }

    private static func perform(homeDirectory: String, progress: CleanupScanProgressSink?,
                                mode: CleanupScanMode, control: CleanupScanControl?,
                                agentPresence: AgentPresenceContext?, includingAdministratorRequired: Bool,
                                excludingScannedRoots: Set<String>, cachedCategories: [CleanupCategory]?,
                                resolveWorker: @escaping @Sendable () throws -> Worker) async -> NativeCore.CleanupScan {
        let cancellation = Cancellation()
        return await withTaskCancellationHandler {
            if Task.isCancelled { cancellation.cancel() }
            return await Task.detached(priority: .utility) {
                do {
                    let check = {
                        if cancellation.isCancelled || control?.isCancelled == true { throw ProcessError.cancelled }
                    }
                    try check()
                    let worker = try resolveWorker()
                    try check()
                    let request = CleanupScanProtocol.Request(home: homeDirectory, mode: mode,
                        presence: agentPresence, includingAdministratorRequired: includingAdministratorRequired,
                        excludingRoots: excludingScannedRoots, parentPID: getpid(), parentUID: getuid(),
                        cachedCategories: cachedCategories,
                        observations: NativeCore.shared.exportCleanupInspectionObservations(homeDirectory: homeDirectory))
                    let reply = try run(worker: worker, request: request, progress: progress, check: check)
                    try check()
                    // Only a validated launched peer, matching request/frame ID,
                    // complete terminal reply and normal exit reach this edge.
                    // These live observations are never read from CleanupCache.
                    NativeCore.shared.importTrustedCleanupInspectionObservations(reply.observations, homeDirectory: homeDirectory)
                    return reply.scan
                } catch {
                    // A broken/missing worker must never become an in-process
                    // fallback or publish partial categories as successful.
                    return NativeCore.CleanupScan(categories: [], succeeded: false,
                        error: String(describing: error), diagnostics: "cleanup scan process: \(error)")
                }
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func run(worker: Worker, request: CleanupScanProtocol.Request,
                            progress: CleanupScanProgressSink?, check: @escaping () throws -> Void) throws
        -> (scan: NativeCore.CleanupScan, observations: [NativeCore.CleanupInspectionObservation]) {
        let started = ProcessInfo.processInfo.systemUptime
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = worker.url
        process.arguments = []
        // Preserve the parent's configured cache aliases; remove loader and
        // injection variables rather than supplying a shell or a login profile.
        process.environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("DYLD_") && !$0.key.hasPrefix("LD_") && $0.key != "__XPC_DYLD_FRAMEWORK_PATH"
        }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .utility
        let body = try CleanupScanProtocol.encodeRequest(request)
        try check()
        try process.run()
        let childIdentity = ChildIdentity(process.processIdentifier)
        input.fileHandleForReading.closeFile()
        output.fileHandleForWriting.closeFile()
        defer {
            input.fileHandleForWriting.closeFile()
            output.fileHandleForReading.closeFile()
            stop(process, identity: childIdentity)
        }
        guard childIdentity != nil else { throw ProcessError.untrusted }
        var terminalAt: TimeInterval?
        let deadlineCheck = {
            try check()
            let now = ProcessInfo.processInfo.systemUptime
            if now - started >= CleanupScanProtocol.maximumLifetime
                || terminalAt.map({ now - $0 >= 2 }) == true {
                throw ProcessError.timeout
            }
        }
        try verifyLaunchedWorker(process, expected: worker)
        try CleanupScanPipe.nonblocking(input.fileHandleForWriting.fileDescriptor)
        try CleanupScanPipe.nonblocking(output.fileHandleForReading.fileDescriptor)
        try CleanupScanPipe.write(body, fd: input.fileHandleForWriting.fileDescriptor, check: deadlineCheck)
        input.fileHandleForWriting.closeFile()
        var terminal: CleanupScanProtocol.Frame?
        var frames = 0
        var progressBytes = 0
        while let bytes = try CleanupScanPipe.readFrame(output.fileHandleForReading.fileDescriptor,
                    limit: CleanupScanProtocol.maximumFrameBytes, check: deadlineCheck) {
            guard terminal == nil else { throw CleanupScanProtocol.WireError.invalidFrame }
            let frame = try CleanupScanProtocol.decodeFrame(bytes, id: request.id)
            if frame.kind == "progress" {
                frames += 1
                progressBytes += bytes.count
                guard frames <= CleanupScanProtocol.maximumProgressFrames,
                      progressBytes <= CleanupScanProtocol.maximumFrameBytes else {
                    throw CleanupScanProtocol.WireError.oversizedFrame
                }
                if let event = frame.progress { progress?.send(try event.model()) }
            } else {
                terminal = frame
                terminalAt = ProcessInfo.processInfo.systemUptime
            }
        }
        // EOF alone is insufficient: require a successful exit as well. A peer
        // that closes stdout and stalls gets only a short completion grace.
        let exitDeadline = ProcessInfo.processInfo.systemUptime + 2
        while process.isRunning {
            try deadlineCheck()
            guard ProcessInfo.processInfo.systemUptime < exitDeadline else { throw ProcessError.timeout }
            _ = poll(nil, 0, 25)
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw ProcessError.exit(process.terminationStatus)
        }
        guard let terminal else { throw CleanupScanProtocol.WireError.truncatedFrame }
        if let message = terminal.error { throw ProcessError.worker(message) }
        guard let scan = terminal.scan else { throw CleanupScanProtocol.WireError.invalidFrame }
        try deadlineCheck()
        return (try scan.model(), terminal.observations)
    }

    private static func stop(_ process: Process, identity: ChildIdentity?) {
        guard process.isRunning else { return }
        // Only our still-live, birth-time-bound same-UID group leader may be
        // addressed as a group. The read-only worker and its POSIX children
        // share this group, so ignoring TERM cannot leave a grandchild behind.
        if let identity, identity.isCurrent, getpgid(identity.pid) == identity.pid {
            _ = kill(-identity.pid, SIGKILL)
            process.waitUntilExit()
            return
        }
        // Before the child has established its own group it cannot yet accept
        // a scan request or create descendants. Never signal an unknown group.
        if let identity, !identity.isCurrent { return }
        process.terminate()
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { _ = poll(nil, 0, 20) }
        if process.isRunning, identity?.isCurrent != false { _ = kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    private static func verifyLaunchedWorker(_ process: Process, expected: Worker) throws {
        #if NORI_CLEANUP_SCAN_PROCESS_TESTING
        if expected.codeDirectoryHash == nil { return }
        #endif
        guard let expectedHash = expected.codeDirectoryHash else { throw ProcessError.untrusted }
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: process.processIdentifier)]
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code) == errSecSuccess,
              let code, SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            throw ProcessError.untrusted
        }
        var staticCode: SecStaticCode?, information: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              dictionary[kSecCodeInfoIdentifier as String] as? String == CleanupScanProtocol.workerIdentifier,
              dictionary[kSecCodeInfoUnique as String] as? Data == expectedHash else { throw ProcessError.untrusted }
    }

    private static func verifiedWorker() throws -> Worker {
        let bundle = Bundle.main
        guard bundle.bundleIdentifier == "com.nori.app" else { throw ProcessError.untrusted }
        let helper = bundle.bundleURL.appendingPathComponent("Contents/Helpers/" + CleanupScanProtocol.workerName)
        var info = stat()
        guard lstat(helper.path, &info) == 0 else { throw ProcessError.unavailable }
        guard info.st_mode & S_IFMT == S_IFREG, access(helper.path, X_OK) == 0,
              helper.resolvingSymlinksInPath().path == helper.path else { throw ProcessError.untrusted }
        var running: SecCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCheckValidity(running, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            throw ProcessError.untrusted
        }
        var host: SecStaticCode?, child: SecStaticCode?
        guard SecCodeCopyStaticCode(running, [], &host) == errSecSuccess, let host,
              SecStaticCodeCreateWithPath(helper as CFURL, [], &child) == errSecSuccess, let child,
              SecStaticCodeCheckValidity(child, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            throw ProcessError.untrusted
        }
        func identity(_ code: SecStaticCode) -> (identifier: String, certificate: Data, hash: Data)? {
            var information: CFDictionary?
            guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
                  let dictionary = information as? [String: Any],
                  let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String,
                  let hash = dictionary[kSecCodeInfoUnique as String] as? Data,
                  let cert = (dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first else { return nil }
            return (identifier, SecCertificateCopyData(cert) as Data, hash)
        }
        guard let hostIdentity = identity(host), hostIdentity.0 == "com.nori.app",
              let childIdentity = identity(child), childIdentity.0 == CleanupScanProtocol.workerIdentifier,
              hostIdentity.1 == childIdentity.1 else { throw ProcessError.untrusted }
        return Worker(url: helper, codeDirectoryHash: childIdentity.hash)
    }

    #if NORI_CLEANUP_SCAN_PROCESS_TESTING
    /// Compiled only into the isolated test runner. Production has no injectable
    /// executable path, environment switch, or fallback worker location.
    static func testScan(worker: URL, home: String, mode: CleanupScanMode = .quick,
                         control: CleanupScanControl? = nil, progress: CleanupScanProgressSink? = nil,
                         cachedCategories: [CleanupCategory]? = nil,
                         expectedCodeHash: Data? = nil) async -> NativeCore.CleanupScan {
        await perform(homeDirectory: home, progress: progress, mode: mode, control: control,
            agentPresence: AgentPresenceContext(applicationDirs: [], searchPath: []),
            includingAdministratorRequired: true, excludingScannedRoots: [], cachedCategories: cachedCategories,
            resolveWorker: { Worker(url: worker, codeDirectoryHash: expectedCodeHash) })
    }
    #endif
}
