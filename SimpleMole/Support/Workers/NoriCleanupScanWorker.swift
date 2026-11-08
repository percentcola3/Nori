import Foundation
import Darwin
import Security

/// Separate executable: never included in the Services glob of the GUI target.
/// It accepts one scan/preflight request on inherited pipes and exits. It has no
/// apply/delete/uninstall endpoint, command router, shell, or administrator path.
@main
struct NoriCleanupScanWorker {
    private struct Parent: Sendable {
        let pid: pid_t
        let uid: uid_t
        let seconds: UInt64
        let microseconds: UInt64
        init() throws {
            pid = getppid()
            guard getuid() == geteuid(), getuid() > 0, pid > 1,
                  let info = Self.info(pid), info.pbi_uid == getuid() else {
                throw CleanupScanProtocol.WireError.invalidRequest
            }
            uid = info.pbi_uid
            seconds = info.pbi_start_tvsec; microseconds = info.pbi_start_tvusec
            #if !NORI_CLEANUP_SCAN_PROCESS_TESTING
            guard Self.signatureValid(pid), alive else { throw CleanupScanProtocol.WireError.invalidRequest }
            #endif
        }
        /// Read-attribution seeds come only from the signed GUI parent. A
        /// standalone same-UID launcher is not a trusted observation producer.
        private static func signatureValid(_ pid: pid_t) -> Bool {
            var parent: SecCode?, own: SecCode?
            let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)]
            guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &parent) == errSecSuccess,
                  let parent, SecCodeCheckValidity(parent, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess,
                  SecCodeCopySelf([], &own) == errSecSuccess, let own,
                  SecCodeCheckValidity(own, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else { return false }
            func identity(_ code: SecCode) -> (String, Data)? {
                var value: SecStaticCode?, information: CFDictionary?
                guard SecCodeCopyStaticCode(code, [], &value) == errSecSuccess, let value,
                      SecCodeCopySigningInformation(value, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
                      let dictionary = information as? [String: Any],
                      let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String,
                      let certificate = (dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first else { return nil }
                return (identifier, SecCertificateCopyData(certificate) as Data)
            }
            guard let host = identity(parent), let worker = identity(own) else { return false }
            return host.0 == "com.nori.app" && worker.0 == CleanupScanProtocol.workerIdentifier && host.1 == worker.1
        }
        private static func info(_ pid: pid_t) -> proc_bsdinfo? {
            var value = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &value, size) == size ? value : nil
        }
        var alive: Bool {
            guard getppid() == pid, let current = Self.info(pid) else { return false }
            return current.pbi_uid == uid && current.pbi_start_tvsec == seconds
                && current.pbi_start_tvusec == microseconds
        }
    }
    private final class Writer: @unchecked Sendable {
        private let lock = NSLock()
        func send(_ frame: CleanupScanProtocol.Frame) throws {
            lock.lock(); defer { lock.unlock() }
            try CleanupScanPipe.write(CleanupScanProtocol.encodeFrame(frame), fd: STDOUT_FILENO, check: {})
        }
    }

    private static func terminateOwnGroup() -> Never {
        if getuid() == geteuid(), getpgrp() == getpid() { _ = kill(-getpid(), SIGKILL) }
        _exit(124)
    }

    static func main() async {
        do {
            guard CommandLine.arguments.count == 1, getuid() == geteuid(), getuid() > 0,
                  setpgid(0, 0) == 0, getpgrp() == getpid() else { throw CleanupScanProtocol.WireError.invalidRequest }
            let parent = try Parent()
            let started = ProcessInfo.processInfo.systemUptime
            // An independent GCD watchdog still runs if an FS syscall, pipe
            // write or Swift task becomes stuck. PID birth time prevents reuse.
            let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            watchdog.schedule(deadline: .now(), repeating: .milliseconds(200))
            watchdog.setEventHandler {
                if !parent.alive || ProcessInfo.processInfo.systemUptime - started >= CleanupScanProtocol.maximumLifetime {
                    terminateOwnGroup()
                }
            }
            watchdog.resume()
            defer { watchdog.cancel() }
            let request = try await Task.detached(priority: .utility) {
                guard let body = try CleanupScanPipe.readFrame(STDIN_FILENO,
                        limit: CleanupScanProtocol.maximumRequestBytes, check: {}),
                      try CleanupScanPipe.readFrame(STDIN_FILENO,
                        limit: CleanupScanProtocol.maximumRequestBytes, check: {}) == nil else {
                    throw CleanupScanProtocol.WireError.invalidRequest
                }
                let request = try CleanupScanProtocol.decodeRequest(body)
                guard request.parentPID == parent.pid, request.parentUID == parent.uid, parent.alive else {
                    throw CleanupScanProtocol.WireError.invalidRequest
                }
                return request
            }.value
            let writer = Writer()
            #if NORI_CLEANUP_SCAN_PROCESS_TESTING
            // Compiled only into the nonce test helper. Production has no
            // fixture mode or request-driven command/executable selection.
            if ["process-lifetime-descendant", "process-timeout-descendant"].contains((request.home as NSString).lastPathComponent) {
                _ = await Task.detached(priority: .utility) {
                    CleanupScanChildCommand.run("/bin/sleep", arguments: ["30"],
                        timeout: request.home.hasSuffix("process-timeout-descendant") ? 0.3 : 60,
                        onLaunch: { pid in
                            try? writer.send(.progress(.init(phase: "native", completed: 0, total: 1,
                                currentPath: "/fixture/\(pid)"), id: request.id))
                        })
                }.value
                _exit(66)
            }
            #endif
            let control = CleanupScanControl(mode: CleanupScanMode(rawValue: request.mode)!)
            let progress = CleanupScanProgressSink { event in
                do { try writer.send(.progress(event, id: request.id)) }
                catch { control.cancel() }
            }
            let scan = try await Task.detached(priority: .utility) {
                NativeCore.shared.importTrustedCleanupInspectionObservations(request.observations, homeDirectory: request.home)
                if request.operation == "preflight" {
                    let categories = try request.cachedCategories!.map { try $0.model() }
                    return NativeCore.shared.preflightCleanupCategories(categories,
                        homeDirectory: request.home, control: control,
                        includingAdministratorRequired: request.includingAdministratorRequired)
                }
                return await NativeCore.shared.scanCleanup(homeDirectory: request.home,
                    progress: progress, mode: CleanupScanMode(rawValue: request.mode)!, control: control,
                    agentPresence: request.presence?.model,
                    includingAdministratorRequired: request.includingAdministratorRequired,
                    excludingScannedRoots: request.excludingRoots)
            }.value
            // Building a DTO and encoding hundreds of thousands of paths must
            // also stay off the main executor of the child.
            try await Task.detached(priority: .utility) {
                let observations = NativeCore.shared.exportCleanupInspectionObservations(homeDirectory: request.home)
                try writer.send(.result(scan, observations: observations, id: request.id))
            }.value
        } catch {
            // Invalid/truncated input has no trusted request identity. A nonzero
            // exit is the only response; parent discards any partial inventory.
            _exit(65)
        }
    }
}
