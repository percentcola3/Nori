import Darwin
import Foundation

/// A bounded, per-launch administrator session. The root broker executes only
/// bundled, allowlisted bridges and authenticates the app via the kernel peer identity.
actor PrivilegedSessionClient {
    static let shared = PrivilegedSessionClient()

    nonisolated static func shutdown() {
        SessionLifetimeRegistry.shared.cancel()
        SessionRequestRegistry.shared.cancelAll()
    }

    nonisolated static func cancellationGeneration(for owner: ObjectIdentifier) -> UInt64 {
        SessionRequestRegistry.shared.generation(for: owner)
    }

    nonisolated static func cancelRequests(for owner: ObjectIdentifier) {
        SessionRequestRegistry.shared.cancel(owner: owner)
    }

    private struct Session {
        let socketURL: URL
        let lifetime: SessionLifetime
        let transport: Task<RunResult, Never>
    }
    private struct StartResult {
        let session: Session?
        let result: RunResult
    }
    private var session: Session?
    private var starting: Task<StartResult, Never>?

    func authorize(bundle: URL, resources: URL, hash: String) async -> RunResult {
        if let starting {
            let outcome = await starting.value
            if session == nil { session = outcome.session }
            return outcome.result
        }
        if let session, session.lifetime.isActive {
            Self.publish("ready")
            return RunResult(output: "", exitCode: 0, timedOut: false)
        }
        session?.lifetime.cancel()
        session = nil
        Self.publish("authorizing")
        let task = Task { await Self.start(bundle: bundle, resources: resources, hash: hash) }
        starting = task
        let outcome = await task.value
        session = outcome.session
        starting = nil
        if outcome.result.succeeded {
            Self.publish("ready")
        } else {
            let result = outcome.result
            let cancelled = !result.timedOut && result.exitCode == 1 && result.diagnosticOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                .range(of: #"\A(?:\[stderr\] )?[0-9]+:[0-9]+: execution error: [^\r\n]* \(-128\)\z"#, options: .regularExpression) != nil
            Self.publish(cancelled ? "cancelled" : "failed")
        }
        return outcome.result
    }

    func run(relativePath: String, arguments: [String], resources: URL, timeout: TimeInterval, owner: ObjectIdentifier, generation: UInt64) async -> RunResult {
        guard let session, session.lifetime.isActive else { return Self.failure("Administrator session is not available.") }
        let mapped = arguments.map { $0 == resources.path ? PrivilegedSessionProtocol.stagedResourcesToken : $0 }
        let request = PrivilegedSessionProtocol.Request(id: UUID().uuidString, operation: "run",
            relativePath: relativePath, arguments: mapped, timeout: min(600, max(1, timeout)))
        // Never retry an operation automatically: a lost reply may follow a successful mutation.
        return await Self.exchange(socket: session.socketURL, request: request, timeout: min(600, max(1, timeout)) + 10, owner: owner, generation: generation)
    }

    func revoke() {
        session?.lifetime.cancel()
        session = nil
        starting?.cancel()
        Self.publish("ended")
    }

    private static func publish(_ state: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name("nori.administratorSessionStateDidChange"), object: state)
        }
    }

    private static func failure(_ text: String, code: Int32 = 77, timedOut: Bool = false) -> RunResult {
        RunResult(output: text, exitCode: code, timedOut: timedOut)
    }

    private static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func start(bundle: URL, resources: URL, hash: String) async -> StartResult {
        guard let lifetime = SessionLifetime() else {
            return .init(session: nil, result: failure("Could not create administrator session cancellation token."))
        }
        SessionLifetimeRegistry.shared.set(lifetime)
        let stage = "/private/var/tmp/com.nori.session." + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let socket = URL(fileURLWithPath: stage + "/ipc/s")
        let helper = "\"$stage_root/code/Nori.app/Contents/Helpers/NoriPrivilegedSession\""
        // Only the IPC directory is traversable by the user. All staged executable
        // code remains behind root-only mode 0700, even if ditto preserves user ownership.
        let command = [
            "set -eu", "umask 077", "[ \"$(/usr/bin/id -u)\" -eq 0 ] || exit 77",
            "stage_root=\(quote(stage))", "worker_pid=''",
            "terminate_tree() { local tree_pid=$1; local tree_child; for tree_child in $(/bin/ps -axo pid=,ppid= | /usr/bin/awk -v parent=\"$tree_pid\" '$2 == parent {print $1}'); do terminate_tree \"$tree_child\"; done; /bin/kill -TERM \"$tree_pid\" 2>/dev/null || true; }",
            "stage_created=0",
            "cleanup() { if [ -n \"$worker_pid\" ]; then terminate_tree \"$worker_pid\"; fi; if [ \"$stage_created\" -eq 1 ]; then case \"$stage_root\" in /private/var/tmp/com.nori.session.*) /bin/rm -rf -- \"$stage_root\" ;; esac; fi; }",
            "trap cleanup 0", "trap 'exit 129' HUP", "trap 'exit 130' INT", "trap 'exit 143' TERM",
            "[ -f \(quote(lifetime.url.path)) ] || exit 143",
            "/bin/mkdir -m 711 \"$stage_root\"", "stage_created=1",
            "/bin/mkdir -m 700 \"$stage_root/code\"", "/bin/mkdir -m 711 \"$stage_root/ipc\"",
            "/usr/bin/ditto --noqtn \(quote(bundle.path)) \"$stage_root/code/Nori.app\"",
            "/usr/sbin/chown -R -P root:wheel \"$stage_root/code/Nori.app\"",
            "/bin/chmod -R -P go-w \"$stage_root/code/Nori.app\"",
            "/usr/bin/codesign --verify --deep --strict \"$stage_root/code/Nori.app\"",
            "/usr/bin/codesign -d --verbose=4 \"$stage_root/code/Nori.app\" >\"$stage_root/code/signature.txt\" 2>&1",
            "actual_hash=$(/usr/bin/awk -F= '/^CDHash=/{print $2; exit}' \"$stage_root/code/signature.txt\")",
            "[ \"$actual_hash\" = \(quote(hash)) ] || exit 78",
            "[ -f \(helper) ] && [ ! -L \(helper) ] || exit 78",
            "[ -f \(quote(lifetime.url.path)) ] || exit 143",
            "/usr/bin/env -i HOME=/var/root USER=root LOGNAME=root PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR=/private/var/tmp TERM=dumb NO_COLOR=1 \(helper) --socket \(quote(socket.path)) --parent-pid \(getpid()) --parent-uid \(getuid()) --parent-hash \(quote(hash)) --cancel-file \(quote(lifetime.url.path)) & worker_pid=$!",
            "while /bin/kill -0 \"$worker_pid\" 2>/dev/null; do if [ ! -f \(quote(lifetime.url.path)) ]; then terminate_tree \"$worker_pid\"; break; fi; /bin/sleep 0.2; done",
            "worker_status=0", "wait \"$worker_pid\" || worker_status=$?", "worker_pid=''", "exit \"$worker_status\""
        ].joined(separator: "; ")
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        let completion = SessionBootstrapCompletion()
        let engine = MoleEngine()
        lifetime.setTransportStop { engine.cancelAll() }
        let transport = Task {
            guard lifetime.isActive else { return failure("Administrator authorization cancelled.", code: 130) }
            let result = await engine.run(executable: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: ["-e", source], environment: engine.standardEnvironment(includeHomebrew: false),
                timeout: PrivilegedSessionProtocol.maximumSessionLifetime + 60, cancellation: lifetime.cancel)
            completion.finish(result)
            lifetime.cancel()
            if completion.wasReady && SessionLifetimeRegistry.shared.isCurrent(lifetime) { publish("ended") }
            return result
        }
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline && !Task.isCancelled && lifetime.isActive {
            if let result = completion.result() { return .init(session: nil, result: result) }
            if FileManager.default.fileExists(atPath: socket.path) {
                let ping = await exchange(socket: socket,
                    request: .init(id: UUID().uuidString, operation: "ping", relativePath: "", arguments: [], timeout: 3), timeout: 4)
                if ping.succeeded && lifetime.isActive {
                    completion.markReady()
                    return .init(session: .init(socketURL: socket, lifetime: lifetime, transport: transport), result: ping)
                }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if let result = completion.result() { return .init(session: nil, result: result) }
        let wasCancelled = Task.isCancelled || !lifetime.isActive
        lifetime.cancel()
        return .init(session: nil, result: failure("Administrator authorization timed out or was cancelled.", code: wasCancelled ? 130 : 124, timedOut: !wasCancelled))
    }

    private static func exchange(socket: URL, request: PrivilegedSessionProtocol.Request, timeout: TimeInterval, owner: ObjectIdentifier? = nil, generation: UInt64? = nil) async -> RunResult {
        let cancellation = SessionSocketCancellation()
        let registration = UUID()
        if let owner { SessionRequestRegistry.shared.add(cancellation, id: registration, owner: owner, expectedGeneration: generation) }
        defer { if let owner { SessionRequestRegistry.shared.remove(id: registration, owner: owner) } }
        return await withTaskCancellationHandler(operation: {
            await Task.detached(priority: .userInitiated) {
                do {
                    let response = try SessionSocket.exchange(path: socket.path, request: request, timeout: timeout, cancellation: cancellation)
                    guard response.id == request.id else { return failure("Administrator session response mismatch.", code: 78) }
                    return RunResult(output: response.output, errorOutput: response.stderrOutput, exitCode: response.exitCode, timedOut: response.timedOut)
                } catch {
                    let timedOut = (error as NSError).domain == "NoriAdministratorSession" && (error as NSError).code == Int(ETIMEDOUT)
                    return failure("Administrator session: \(error.localizedDescription)",
                        code: cancellation.isCancelled ? 130 : timedOut ? 124 : 77, timedOut: timedOut && !cancellation.isCancelled)
                }
            }.value
        }, onCancel: { cancellation.cancel() })
    }
}

private final class SessionLifetime: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var ended = false
    private var stopTransport: (() -> Void)?
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return !ended }
    func setTransportStop(_ action: @escaping () -> Void) {
        lock.lock(); let alreadyEnded = ended; if !alreadyEnded { stopTransport = action }; lock.unlock()
        if alreadyEnded { action() }
    }
    init?() {
        url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nori-admin-session-\(UUID().uuidString).token")
        guard FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else { return nil }
    }
    func cancel() {
        lock.lock()
        guard !ended else { lock.unlock(); return }
        ended = true
        let stop = stopTransport
        stopTransport = nil
        lock.unlock()
        try? FileManager.default.removeItem(at: url)
        stop?()
    }
    deinit { cancel() }
}

private final class SessionBootstrapCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var value: RunResult?
    private var ready = false
    var wasReady: Bool { lock.lock(); defer { lock.unlock() }; return ready }
    func markReady() { lock.lock(); ready = true; lock.unlock() }
    func finish(_ result: RunResult) { lock.lock(); value = result; lock.unlock() }
    func result() -> RunResult? { lock.lock(); defer { lock.unlock() }; return value }
}

private final class SessionSocketCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func attach(_ descriptor: Int32) { lock.lock(); fd = descriptor; if cancelled { shutdown(fd, SHUT_RDWR) }; lock.unlock() }
    func detach() { lock.lock(); fd = -1; lock.unlock() }
    func cancel() { lock.lock(); cancelled = true; if fd >= 0 { shutdown(fd, SHUT_RDWR) }; lock.unlock() }
}

private final class SessionLifetimeRegistry: @unchecked Sendable {
    static let shared = SessionLifetimeRegistry()
    private let lock = NSLock()
    private var lifetime: SessionLifetime?
    func set(_ value: SessionLifetime) { lock.lock(); let previous = lifetime; lifetime = value; lock.unlock(); previous?.cancel() }
    func isCurrent(_ value: SessionLifetime) -> Bool { lock.lock(); defer { lock.unlock() }; return lifetime === value }
    func cancel() { lock.lock(); let previous = lifetime; lifetime = nil; lock.unlock(); previous?.cancel() }
}

private final class SessionRequestRegistry: @unchecked Sendable {
    static let shared = SessionRequestRegistry()
    private let lock = NSLock()
    private var requests: [ObjectIdentifier: [UUID: SessionSocketCancellation]] = [:]
    private var generations: [ObjectIdentifier: UInt64] = [:]
    func generation(for owner: ObjectIdentifier) -> UInt64 { lock.lock(); defer { lock.unlock() }; return generations[owner, default: 0] }
    func add(_ value: SessionSocketCancellation, id: UUID, owner: ObjectIdentifier, expectedGeneration: UInt64?) {
        lock.lock()
        if let expectedGeneration, generations[owner, default: 0] != expectedGeneration {
            lock.unlock(); value.cancel(); return
        }
        requests[owner, default: [:]][id] = value
        lock.unlock()
    }
    func remove(id: UUID, owner: ObjectIdentifier) {
        lock.lock(); requests[owner]?[id] = nil
        if requests[owner]?.isEmpty == true { requests[owner] = nil }
        lock.unlock()
    }
    func cancel(owner: ObjectIdentifier) {
        lock.lock(); generations[owner, default: 0] &+= 1
        let active = requests.removeValue(forKey: owner); lock.unlock()
        active?.values.forEach { $0.cancel() }
    }
    func cancelAll() {
        lock.lock(); let active = requests.values.flatMap { $0.values }; requests.removeAll(); lock.unlock()
        active.forEach { $0.cancel() }
    }
}

private enum SessionSocket {
    private static func error(_ message: String, code: Int = Int(errno)) -> NSError { NSError(domain: "NoriAdministratorSession", code: code, userInfo: [NSLocalizedDescriptionKey: message]) }

    static func exchange(path: String, request: PrivilegedSessionProtocol.Request, timeout: TimeInterval, cancellation: SessionSocketCancellation) throws -> PrivilegedSessionProtocol.Response {
        var directory = stat()
        let parent = (path as NSString).deletingLastPathComponent
        guard lstat(parent, &directory) == 0, directory.st_uid == 0,
              directory.st_mode & S_IFMT == S_IFDIR, directory.st_mode & 0o022 == 0 else { throw error("Untrusted session directory.") }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw error("Could not open session connection.") }
        cancellation.attach(fd)
        defer { cancellation.detach(); close(fd) }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw error("Could not protect session connection.") }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw error("Session path is too long.") }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            path.utf8CString.withUnsafeBytes { source in destination.copyBytes(from: source) }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw error("Could not configure session connection.") }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        func wait(_ events: Int16) throws {
            while true {
                guard !cancellation.isCancelled else { throw error("Operation cancelled.") }
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw error("Administrator request timed out.", code: Int(ETIMEDOUT)) }
                var descriptor = pollfd(fd: fd, events: events, revents: 0)
                let ready = poll(&descriptor, 1, 100)
                if ready > 0 {
                    guard descriptor.revents & Int16(POLLERR | POLLNVAL) == 0 else { throw error("Administrator session connection failed.") }
                    if descriptor.revents & events != 0 { return }
                    if descriptor.revents & Int16(POLLHUP) != 0 { throw error("Administrator session disconnected.") }
                } else if ready < 0 && errno != EINTR { throw error("Administrator session polling failed.") }
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if connected != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { throw error("Administrator session disconnected; authorize again.") }
            try wait(Int16(POLLOUT))
            var pendingError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &pendingError, &length) == 0, pendingError == 0 else { throw error("Could not connect to administrator session.") }
        }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == 0 else { throw error("Untrusted administrator session peer.") }
        let encoded = try PrivilegedSessionProtocol.encodeRequest(request)
        var sent = 0
        while sent < encoded.count {
            try wait(Int16(POLLOUT))
            let count = encoded.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: sent), encoded.count - sent) }
            if count > 0 { sent += count } else if errno != EAGAIN && errno != EINTR { throw error("Could not send administrator request.") }
        }
        var received = Data()
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while received.count < 16 * 1024 * 1024 {
            try wait(Int16(POLLIN))
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 {
                received.append(contentsOf: bytes.prefix(count))
                if let newline = received.firstIndex(of: 10) {
                    return try JSONDecoder().decode(PrivilegedSessionProtocol.Response.self, from: received.prefix(upTo: newline))
                }
            } else if count == 0 { throw error("Administrator session ended without a result.") }
            else if errno != EAGAIN && errno != EINTR { throw error("Could not read administrator result.") }
        }
        throw error("Administrator result exceeded the limit.")
    }
}
