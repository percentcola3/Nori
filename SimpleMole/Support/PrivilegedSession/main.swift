import Foundation
import Darwin
import Security

private typealias Wire = PrivilegedSessionProtocol
private var shutdownRequested: sig_atomic_t = 0
private enum BrokerError: Error { case invalid(String) }
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw BrokerError.invalid(message) }
}
private func monotonic() -> Double {
    var time = timespec()
    clock_gettime(CLOCK_MONOTONIC, &time)
    return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
}
private func nonblocking(_ fd: Int32) -> Bool {
    let flags = fcntl(fd, F_GETFL)
    return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
}
private func closeOnExec(_ fd: Int32) -> Bool { fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 }
private func metadata(_ path: String) -> stat? {
    var result = stat()
    return lstat(path, &result) == 0 ? result : nil
}
private func canonical(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}
private struct Parent {
    let pid: pid_t
    let uid: uid_t
    let hash: String
    let seconds: UInt64
    let microseconds: UInt64
    static func info(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return count == MemoryLayout<proc_bsdinfo>.size ? info : nil
    }
    init(pid: pid_t, uid: uid_t, hash: String) throws {
        guard let info = Self.info(pid), info.pbi_uid == uid else { throw BrokerError.invalid("parent unavailable") }
        self.pid = pid; self.uid = uid; self.hash = hash
        seconds = info.pbi_start_tvsec; microseconds = info.pbi_start_tvusec
        try require(valid(), "parent signature invalid")
    }
    func alive() -> Bool {
        guard let info = Self.info(pid) else { return false }
        return info.pbi_uid == uid && info.pbi_start_tvsec == seconds && info.pbi_start_tvusec == microseconds
    }
    func valid(audit: Data? = nil) -> Bool {
        guard alive() else { return false }
        var code: SecCode?
        let attributes: [String: Any] = audit.map { [kSecGuestAttributeAudit as String: $0] }
            ?? [kSecGuestAttributePid as String: NSNumber(value: pid)]
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code) == errSecSuccess,
              let code, SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else { return false }
        var information: CFDictionary?
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let digest = dictionary[kSecCodeInfoUnique as String] as? Data else { return false }
        return digest.map { String(format: "%02x", $0) }.joined() == hash && alive()
    }
    func permits(_ fd: Int32) -> Bool {
        var peerUID: uid_t = 0; var peerGID: gid_t = 0
        var peerPID: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        // sys/un.h: SOL_LOCAL=0, LOCAL_PEERPID=2, LOCAL_PEERTOKEN=6.
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == uid,
              getsockopt(fd, 0, 2, &peerPID, &length) == 0,
              length == MemoryLayout<pid_t>.size, peerPID == pid else { return false }
        var token = audit_token_t()
        length = socklen_t(MemoryLayout<audit_token_t>.size)
        let result = withUnsafeMutablePointer(to: &token) { getsockopt(fd, 0, 6, $0, &length) }
        guard result == 0, length == MemoryLayout<audit_token_t>.size else { return false }
        return withUnsafeBytes(of: token) { valid(audit: Data($0)) }
    }
}

private final class Broker {
    let parent: Parent
    let socketPath: String
    let cancelPath: String
    let resources: String
    let deadline = monotonic() + Wire.maximumSessionLifetime
    var listener: Int32 = -1
    init() throws {
        try require(getuid() == 0 && geteuid() == 0, "root required")
        try require([STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO].allSatisfy { fcntl($0, F_GETFD) >= 0 }, "missing standard descriptors")
        let args = Array(CommandLine.arguments.dropFirst())
        try require(args.count == 10, "invalid arguments")
        var options: [String: String] = [:]
        for index in stride(from: 0, to: args.count, by: 2) {
            try require(["--socket", "--parent-pid", "--parent-uid", "--parent-hash", "--cancel-file"].contains(args[index]) && options[args[index]] == nil, "invalid option")
            options[args[index]] = args[index + 1]
        }
        guard let pid = Int32(options["--parent-pid"] ?? ""), pid > 1,
              let uid = UInt32(options["--parent-uid"] ?? ""), uid > 0,
              let hash = options["--parent-hash"], hash.count == 40,
              hash.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let socket = options["--socket"], socket.hasPrefix("/"),
              let cancel = options["--cancel-file"], cancel.hasPrefix("/"), !cancel.contains("\0"), !socket.contains("\0") else { throw BrokerError.invalid("invalid identity arguments") }
        parent = try Parent(pid: pid, uid: uid, hash: hash.lowercased())
        socketPath = socket; cancelPath = cancel
        // PROC_PIDPATHINFO_MAXSIZE is (4 * MAXPATHLEN), an unimportable C macro.
        var executableBytes = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        try require(proc_pidpath(getpid(), &executableBytes, UInt32(executableBytes.count)) > 0, "cannot locate helper")
        let executable = URL(fileURLWithPath: String(cString: executableBytes)).resolvingSymlinksInPath()
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        try require(executable.lastPathComponent == "NoriPrivilegedSession" && executable.deletingLastPathComponent().lastPathComponent == "Helpers" && contents.lastPathComponent == "Contents", "invalid helper layout")
        let expectedResources = contents.appendingPathComponent("Resources").path
        try require(canonical(expectedResources) == expectedResources, "invalid staged resources")
        resources = expectedResources
        let app = contents.deletingLastPathComponent()
        let codeDirectory = app.deletingLastPathComponent()
        let stageDirectory = codeDirectory.deletingLastPathComponent()
        try require(codeDirectory.lastPathComponent == "code", "invalid staged code layout")
        for path in [executable.path, executable.deletingLastPathComponent().path, contents.path, app.path, codeDirectory.path, stageDirectory.path] {
            guard let item = metadata(path) else { throw BrokerError.invalid("missing staged ancestor") }
            try require(canonical(path) == path && item.st_uid == 0 && item.st_mode & 0o022 == 0, "untrusted staged code")
        }
        guard let codeInfo = metadata(codeDirectory.path), let stageInfo = metadata(stageDirectory.path) else { throw BrokerError.invalid("missing stage") }
        try require(codeInfo.st_mode & 0o777 == 0o700 && stageInfo.st_mode & 0o777 == 0o711, "invalid stage permissions")
        let directory = (socket as NSString).deletingLastPathComponent
        try require(directory == stageDirectory.appendingPathComponent("ipc").path, "invalid IPC layout")
        guard let item = metadata(directory) else { throw BrokerError.invalid("missing socket directory") }
        try require(canonical(directory) == directory && item.st_uid == 0 && item.st_mode & S_IFMT == S_IFDIR && item.st_mode & 0o777 == 0o711, "untrusted socket directory")
        try require(metadata(socket) == nil && active(), "session cancelled")
    }
    func active() -> Bool {
        guard shutdownRequested == 0, monotonic() < deadline, parent.alive(), let token = metadata(cancelPath) else { return false }
        return token.st_mode & S_IFMT == S_IFREG && token.st_uid == parent.uid && token.st_nlink == 1
    }
    func run() throws {
        _ = signal(SIGPIPE, SIG_IGN)
        for number in [SIGTERM, SIGINT, SIGHUP] { _ = signal(number) { _ in shutdownRequested = 1 } }
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        try require(listener >= 0, "socket failed")
        defer { close(listener); unlink(socketPath) }
        try require(closeOnExec(listener) && nonblocking(listener), "socket flags failed")
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8) + [0]
        try require(bytes.count <= MemoryLayout.size(ofValue: address.sun_path), "socket path too long")
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        try require(bound == 0, "bind failed")
        try require(chmod(socketPath, 0o600) == 0 && chown(socketPath, parent.uid, gid_t.max) == 0 && listen(listener, 8) == 0, "socket setup failed")
        while active() {
            var event = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&event, 1, 100) > 0 else { continue }
            let client = accept(listener, nil, nil)
            if client < 0 { continue }
            if closeOnExec(client) && nonblocking(client) && parent.permits(client) { handle(client) }
            close(client)
        }
    }
    func connected(_ fd: Int32) -> Bool {
        var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        if poll(&event, 1, 0) > 0 && event.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return false }
        var byte: UInt8 = 0
        let count = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        return count > 0 || (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR))
    }
    func handle(_ fd: Int32) {
        var frame = Data(); let readDeadline = monotonic() + 10
        var buffer = [UInt8](repeating: 0, count: 8192)
        while active() && monotonic() < readDeadline {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count == 0 { return }
            if count < 0 {
                if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { return }
                var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0); _ = poll(&event, 1, 100)
                continue
            }
            frame.append(contentsOf: buffer.prefix(count))
            if frame.count > Wire.maximumRequestBytes { return }
            if frame.contains(10) { break }
        }
        guard active(), parent.permits(fd), let request = try? Wire.decodeRequest(frame),
              (try? Wire.validate(request, parentUID: parent.uid)) != nil else { return }
        let response: Wire.Response
        if request.operation == "ping" {
            response = .init(id: request.id, output: "", stderrOutput: "", exitCode: 0, timedOut: false)
        } else {
            response = execute(request, client: fd)
        }
        guard active(), let data = try? Wire.encodeResponse(response) else { return }
        let writeDeadline = monotonic() + 10
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count && active() && monotonic() < writeDeadline {
                let count = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if count > 0 { offset += count }
                else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                    var event = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0); _ = poll(&event, 1, 100)
                } else { break }
            }
        }
    }
    func execute(_ request: Wire.Request, client: Int32) -> Wire.Response {
        func failure(_ message: String) -> Wire.Response { .init(id: request.id, output: "", stderrOutput: message, exitCode: 78, timedOut: false) }
        let script = resources + "/" + request.relativePath
        guard canonical(script) == script, let item = metadata(script), item.st_mode & S_IFMT == S_IFREG,
              item.st_uid == 0, item.st_mode & 0o022 == 0 else { return failure("Invalid staged script") }
        // Reject symlinks and mutable resource directory components as well as the leaf.
        var component = (script as NSString).deletingLastPathComponent
        while component.hasPrefix(resources) {
            guard let info = metadata(component), info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == 0, info.st_mode & 0o022 == 0 else { return failure("Invalid staged resources") }
            if component == resources { break }
            component = (component as NSString).deletingLastPathComponent
        }
        var outputPipe = [Int32](repeating: -1, count: 2), errorPipe = [Int32](repeating: -1, count: 2)
        guard pipe(&outputPipe) == 0 else { return failure("pipe failed") }
        guard pipe(&errorPipe) == 0 else { outputPipe.forEach { close($0) }; return failure("pipe failed") }
        guard (outputPipe + errorPipe).allSatisfy({ closeOnExec($0) }),
              nonblocking(outputPipe[0]), nonblocking(errorPipe[0]) else {
            (outputPipe + errorPipe).forEach { close($0) }
            return failure("pipe flags failed")
        }
        func setupFailure() -> Wire.Response {
            (outputPipe + errorPipe).forEach { close($0) }
            return failure("worker setup failed")
        }
        var actions: posix_spawn_file_actions_t?; var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return setupFailure() }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { return setupFailure() }
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t(); sigemptyset(&defaults)
        for number in [SIGPIPE, SIGTERM, SIGINT, SIGHUP] { sigaddset(&defaults, number) }
        var mask = sigset_t(); sigemptyset(&mask)
        guard posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, errorPipe[1], STDERR_FILENO) == 0,
              posix_spawn_file_actions_addchdir_np(&actions, resources) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawnattr_setsigmask(&attributes, &mask) == 0 else { return setupFailure() }
        for fd in outputPipe + errorPipe {
            guard posix_spawn_file_actions_addclose(&actions, fd) == 0 else { return setupFailure() }
        }
        let arguments = ["/bin/bash", script] + Wire.resolveArguments(request.arguments, stagedResourcesPath: resources)
        let environment = ["HOME=/var/root", "USER=root", "LOGNAME=root", "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR=/private/var/tmp", "TERM=dumb", "NO_COLOR=1"]
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        guard active(), connected(client), parent.permits(client) else { return setupFailure() }
        var pid: pid_t = 0
        let spawnResult = argv.withUnsafeBufferPointer { argvBuffer in envp.withUnsafeBufferPointer { envBuffer in
            posix_spawn(&pid, "/bin/bash", &actions, &attributes, UnsafeMutablePointer(mutating: argvBuffer.baseAddress!), UnsafeMutablePointer(mutating: envBuffer.baseAddress!))
        } }
        close(outputPipe[1]); close(errorPipe[1])
        defer { close(outputPipe[0]); close(errorPipe[0]) }
        guard spawnResult == 0 else { return failure("spawn failed: \(spawnResult)") }
        var output = Data(), errors = Data(); var status: Int32 = 0
        var childExited = false, stdoutOpen = true, stderrOpen = true
        var stopping: Double?; var timedOut = false
        let runDeadline = monotonic() + Wire.clampedTimeout(request.timeout)
        func drain(_ fd: Int32, _ data: inout Data, _ open: inout Bool) {
            var bytes = [UInt8](repeating: 0, count: 16384)
            // Bound work per iteration so a flooding worker cannot starve cancellation.
            for _ in 0..<16 {
                let count = read(fd, &bytes, bytes.count)
                if count > 0 { data.append(contentsOf: bytes.prefix(min(count, max(0, Wire.maximumOutputBytes - data.count)))) }
                else { if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) { open = false }; break }
            }
        }
        while true {
            if stdoutOpen { drain(outputPipe[0], &output, &stdoutOpen) }
            if stderrOpen { drain(errorPipe[0], &errors, &stderrOpen) }
            if !childExited {
                var info = siginfo_t()
                if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == pid { childExited = true }
            }
            let now = monotonic()
            if stopping == nil && (now >= runDeadline || !active() || !connected(client) || childExited) {
                timedOut = now >= runDeadline && !childExited
                stopping = now; _ = kill(-pid, SIGTERM)
            }
            if let stopped = stopping, now - stopped >= 0.5 {
                _ = kill(-pid, SIGKILL)
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                // Drain buffered bytes after killing remaining descendants, then close.
                if stdoutOpen { drain(outputPipe[0], &output, &stdoutOpen) }
                if stderrOpen { drain(errorPipe[0], &errors, &stderrOpen) }
                break
            }
            if childExited && !stdoutOpen && !stderrOpen {
                _ = kill(-pid, SIGKILL)
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                break
            }
            var events = [pollfd(fd: outputPipe[0], events: Int16(POLLIN), revents: 0), pollfd(fd: errorPipe[0], events: Int16(POLLIN), revents: 0)]
            _ = poll(&events, 2, 50)
        }
        let exitCode: Int32 = timedOut ? 124 : ((status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f))
        return .init(id: request.id, output: Wire.boundedOutput(output), stderrOutput: Wire.boundedOutput(errors), exitCode: exitCode, timedOut: timedOut)
    }
}

do { try Broker().run() }
catch { fputs("Nori privileged session refused: \(error)\n", stderr); exit(78) }
