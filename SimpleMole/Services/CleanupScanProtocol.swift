import Foundation
import Darwin

/// Blocking pipe operations are confined to utility threads in both processes.
/// Polling bounds cancellation even if the peer stops reading or writing.
enum CleanupScanPipe {
    static func readFrame(_ fd: Int32, limit: Int, check: () throws -> Void) throws -> Data? {
        guard let header = try readExactly(4, fd: fd, allowEOF: true, check: check) else { return nil }
        let size = try CleanupScanProtocol.bodyLength(header, limit: limit)
        return try readExactly(size, fd: fd, allowEOF: false, check: check)
    }
    private static func readExactly(_ size: Int, fd: Int32, allowEOF: Bool,
                                    check: () throws -> Void) throws -> Data? {
        var result = Data()
        var bytes = [UInt8](repeating: 0, count: min(size, 64 * 1024))
        while result.count < size {
            try check()
            var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, 100)
            if ready < 0 { if errno == EINTR { continue }; throw CleanupScanProtocol.WireError.invalidFrame }
            if ready == 0 { continue }
            let count = Darwin.read(fd, &bytes, min(bytes.count, size - result.count))
            if count == 0 {
                if allowEOF && result.isEmpty { return nil }
                throw CleanupScanProtocol.WireError.truncatedFrame
            }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw CleanupScanProtocol.WireError.invalidFrame
            }
            result.append(contentsOf: bytes.prefix(count))
        }
        return result
    }
    static func write(_ data: Data, fd: Int32, check: () throws -> Void) throws {
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                try check()
                var item = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&item, 1, 100)
                if ready < 0 { if errno == EINTR { continue }; throw CleanupScanProtocol.WireError.invalidFrame }
                if ready == 0 { continue }
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), min(64 * 1024, raw.count - offset))
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw CleanupScanProtocol.WireError.invalidFrame
                }
                guard count > 0 else { throw CleanupScanProtocol.WireError.invalidFrame }
                offset += count
            }
        }
    }
    static func nonblocking(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw CleanupScanProtocol.WireError.invalidFrame
        }
    }
}

#if NORI_CLEANUP_SCAN_WORKER
/// Foundation.Process starts a new process group for every command on macOS.
/// This worker-only launcher keeps the scanner's fixed read-only probes in the
/// worker group so cancellation/watchdog termination also reaches descendants.
/// It is never linked as a command endpoint in the GUI or the wire protocol.
enum CleanupScanChildCommand {
    static func run(_ executable: String, arguments: [String],
                    environment: [String: String]? = nil, timeout: TimeInterval = 10,
                    maximumOutputBytes: Int = 16 * 1024 * 1024,
                    onLaunch: ((pid_t) -> Void)? = nil) -> (succeeded: Bool, output: String) {
        guard getuid() == geteuid(), getuid() > 0, getpgrp() == getpid(),
              permitted(executable, arguments: arguments), timeout.isFinite, timeout > 0,
              maximumOutputBytes > 0, maximumOutputBytes <= 256 * 1024 * 1024,
              !arguments.contains(where: { $0.contains("\0") }) else { return (false, "") }
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { return (false, "") }
        var writeFD = descriptors[1]
        defer {
            close(descriptors[0])
            if writeFD >= 0 { close(writeFD) }
        }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return (false, "") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return (false, "") }
        defer { posix_spawnattr_destroy(&attributes) }
        var mask = sigset_t()
        sigemptyset(&mask)
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK)
        guard posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, descriptors[0]) == 0,
              posix_spawn_file_actions_addclose(&actions, writeFD) == 0,
              posix_spawnattr_setsigmask(&attributes, &mask) == 0,
              posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setpgroup(&attributes, getpgrp()) == 0 else { return (false, "") }
        let supplied = environment ?? ProcessInfo.processInfo.environment
        guard supplied.allSatisfy({ !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }) else {
            return (false, "")
        }
        var pid: pid_t = 0
        let spawnError = withStrings([executable] + arguments) { argv in
            withStrings(supplied.map { "\($0.key)=\($0.value)" }) { envp in
                posix_spawn(&pid, executable, &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
            }
        }
        guard spawnError == 0 else { return (false, "") }
        close(writeFD); writeFD = -1
        onLaunch?(pid)
        do { try CleanupScanPipe.nonblocking(descriptors[0]) } catch { terminateOwnGroup() }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var output = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var eof = false, exited = false
        var status: Int32 = 0
        while !eof || !exited {
            if ProcessInfo.processInfo.systemUptime >= deadline { terminateOwnGroup() }
            if !exited {
                let waited = waitpid(pid, &status, WNOHANG)
                if waited == pid { exited = true }
                else if waited < 0 && errno != EINTR { terminateOwnGroup() }
            }
            if !eof {
                var item = pollfd(fd: descriptors[0], events: Int16(POLLIN), revents: 0)
                let ready = poll(&item, 1, 50)
                if ready < 0 && errno != EINTR { terminateOwnGroup() }
                if ready > 0 {
                    let count = Darwin.read(descriptors[0], &buffer, buffer.count)
                    if count == 0 { eof = true }
                    else if count > 0 {
                        guard output.count <= maximumOutputBytes - count else { terminateOwnGroup() }
                        output.append(contentsOf: buffer.prefix(count))
                    } else if errno != EINTR && errno != EAGAIN { terminateOwnGroup() }
                }
            } else if !exited { _ = poll(nil, 0, 20) }
        }
        guard status == 0, let text = String(data: output, encoding: .utf8) else { return (false, "") }
        return (true, text)
    }

    private static func permitted(_ executable: String, arguments: [String]) -> Bool {
        switch executable {
        case "/usr/sbin/lsof": return true
        case "/usr/bin/xcode-select": return arguments == ["-p"]
        case "/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git":
            guard arguments.count >= 3, arguments[0] == "-C" else { return false }
            return ["status", "symbolic-ref", "rev-parse", "for-each-ref"].contains(arguments[2])
        case "/opt/homebrew/bin/brew", "/usr/local/bin/brew": return arguments.first == "list"
        #if NORI_CLEANUP_SCAN_PROCESS_TESTING
        case "/bin/sleep": return arguments == ["30"]
        #endif
        default: return false
        }
    }
    private static func withStrings<T>(_ strings: [String], body: (UnsafeMutableBufferPointer<UnsafeMutablePointer<CChar>?>) -> T) -> T {
        var pointers = strings.map { strdup($0) }
        defer { for pointer in pointers { free(pointer) } }
        pointers.append(nil)
        return pointers.withUnsafeMutableBufferPointer { buffer in body(buffer) }
    }
    private static func terminateOwnGroup() -> Never {
        // Every launch above explicitly joins our verified same-UID group.
        // Timeout/output failure ends the entire read-only scan, fail closed.
        if getuid() == geteuid(), getpgrp() == getpid() { _ = kill(-getpid(), SIGKILL) }
        _exit(124)
    }
}
#endif

/// A single read-only request and a stream of progress followed by exactly one
/// terminal frame. No mutation or executable/command field exists on this wire.
enum CleanupScanProtocol {
    static let version = 2
    static let workerName = "NoriCleanupScanWorker"
    static let workerIdentifier = "com.nori.app.cleanup-scan-worker"
    static let maximumRequestBytes = 256 * 1024 * 1024
    static let maximumFrameBytes = 256 * 1024 * 1024
    static let maximumProgressBytes = 64 * 1024
    static let maximumProgressFrames = 100_000
    static let maximumLifetime: TimeInterval = 30 * 60

    enum WireError: Error, CustomStringConvertible {
        case invalidRequest, invalidFrame, oversizedFrame, truncatedFrame, invalidMetadata
        var description: String {
            switch self {
            case .invalidRequest: return "Invalid cleanup scan request."
            case .invalidFrame: return "Invalid cleanup scan worker protocol."
            case .oversizedFrame: return "Cleanup scan worker reply exceeds its limit."
            case .truncatedFrame: return "Truncated cleanup scan worker reply."
            case .invalidMetadata: return "Invalid cleanup scan metadata."
            }
        }
    }

    struct Presence: Codable, Sendable {
        let applicationDirs: [String]
        let searchPath: [String]
        let applicationPathsByName: [String: [String]]
        init(_ value: AgentPresenceContext) {
            applicationDirs = value.applicationDirs
            searchPath = value.searchPath
            applicationPathsByName = value.applicationPathsByName
        }
        var model: AgentPresenceContext {
            AgentPresenceContext(applicationDirs: applicationDirs, searchPath: searchPath,
                                 applicationPathsByName: applicationPathsByName)
        }
    }

    struct Request: Codable, Sendable {
        let version: Int
        let operation: String
        let id: UUID
        let parentPID: Int32
        let parentUID: UInt32
        let home: String
        let mode: String
        let presence: Presence?
        let includingAdministratorRequired: Bool
        let excludingRoots: Set<String>
        let cachedCategories: [Category]?
        /// Live read attribution only; never loaded from the display cache.
        let observations: [NativeCore.CleanupInspectionObservation]

        init(home: String, mode: CleanupScanMode, presence: AgentPresenceContext?,
             includingAdministratorRequired: Bool, excludingRoots: Set<String>,
             parentPID: Int32, parentUID: UInt32, cachedCategories: [CleanupCategory]? = nil,
             observations: [NativeCore.CleanupInspectionObservation] = []) {
            version = CleanupScanProtocol.version
            operation = cachedCategories == nil ? "scan" : "preflight"
            self.cachedCategories = cachedCategories?.map(Category.init)
            self.observations = observations
            id = UUID()
            self.parentPID = parentPID
            self.parentUID = parentUID
            self.home = home
            self.mode = mode.rawValue
            self.presence = presence.map(Presence.init)
            self.includingAdministratorRequired = includingAdministratorRequired
            self.excludingRoots = excludingRoots
        }
    }

    struct Progress: Codable, Sendable {
        let phase: String
        let completed: Int
        let total: Int
        let currentPath: String
        init(_ value: CleanupScanProgressEvent) {
            phase = value.phase; completed = value.completed
            total = value.total; currentPath = value.currentPath
        }
        func model() throws -> CleanupScanProgressEvent {
            guard ["discovery", "occupancy", "native"].contains(phase),
                  completed >= 0, total >= 0, completed <= total || total == 0,
                  currentPath.utf8.count <= 16_384, !currentPath.contains("\0") else {
                throw WireError.invalidFrame
            }
            return .init(phase: phase, completed: completed, total: total, currentPath: currentPath)
        }
    }

    /// All scanner-owned metadata is explicit. Presentation's pathOrderToken is
    /// intentionally regenerated by CleanupCategory's initializer in the parent.
    struct Category: Codable, Sendable {
        let id: UUID
        let name: String
        let paths: [String]
        let bytes: UInt64
        let pathBytes: [String: UInt64]
        let pathIdentities: [String: String]
        let retentionClass: AgentRetentionClass?
        let pathActivity: [String: Date]
        let pathNotes: [String: String]
        let pathRetentionBlocked: Set<String>
        let selectedPaths: Set<String>
        let expanded: Bool
        let source: String
        let risk: String
        let disposal: String
        let applyRoute: String
        let activityGuard: String
        let retention: TimeInterval
        let reasonKey: String
        let activityOwners: [String]
        let uninstallDataOwner: UninstallDataOwner?

        init(_ value: CleanupCategory) {
            id = value.id; name = value.name; paths = value.paths; bytes = value.bytes
            pathBytes = value.pathBytes; pathIdentities = value.pathIdentities
            retentionClass = value.retentionClass; pathActivity = value.pathActivity
            pathNotes = value.pathNotes; pathRetentionBlocked = value.pathRetentionBlocked
            selectedPaths = value.selectedPaths; expanded = value.expanded
            source = value.source.rawValue; risk = value.risk.rawValue
            disposal = value.disposal.rawValue; applyRoute = value.applyRoute.rawValue
            activityGuard = value.activityGuard.rawValue; retention = value.retention
            reasonKey = value.reasonKey; activityOwners = value.activityOwners
            uninstallDataOwner = value.uninstallDataOwner
        }

        func model() throws -> CleanupCategory {
            guard let source = CleanupSource(rawValue: source),
                  let risk = CleanupRisk(rawValue: risk),
                  let disposal = CleanupDisposal(rawValue: disposal),
                  let applyRoute = CleanupApplyRoute(rawValue: applyRoute),
                  let activityGuard = CleanupActivityGuard(rawValue: activityGuard),
                  retention.isFinite, retention >= 0, paths.allSatisfy(CleanupScanProtocol.validPath) else {
                throw WireError.invalidMetadata
            }
            let known = Set(paths)
            guard known.count == paths.count,
                  Set(pathBytes.keys).isSubset(of: known),
                  Set(pathIdentities.keys).isSubset(of: known),
                  Set(pathActivity.keys).isSubset(of: known),
                  Set(pathNotes.keys).isSubset(of: known),
                  pathRetentionBlocked.isSubset(of: known), selectedPaths.isSubset(of: known),
                  risk != .protected || selectedPaths.isEmpty else { throw WireError.invalidMetadata }
            // Explicit identities, even an empty map, prevent model construction
            // from consulting the filesystem while decoding a worker snapshot.
            var result = CleanupCategory(id: id, name: name, paths: paths, bytes: bytes,
                pathBytes: pathBytes, pathIdentities: pathIdentities, retentionClass: retentionClass,
                pathActivity: pathActivity, pathNotes: pathNotes, pathRetentionBlocked: pathRetentionBlocked,
                selected: false, expanded: expanded, source: source, risk: risk, disposal: disposal,
                applyRoute: applyRoute, activityGuard: activityGuard, retention: retention, reasonKey: reasonKey)
            result = result.selectingPaths(selectedPaths)
            result.activityOwners = activityOwners
            result.uninstallDataOwner = uninstallDataOwner
            return result
        }
    }

    struct Scan: Codable, Sendable {
        let categories: [Category]
        let succeeded: Bool
        let error: String?
        let deferredPaths: [String]
        let diagnostics: String
        let administratorRequiredPaths: Set<String>
        let completedRoots: Set<String>
        init(_ value: NativeCore.CleanupScan) {
            categories = value.categories.map(Category.init)
            succeeded = value.succeeded; error = value.error
            deferredPaths = value.deferredPaths; diagnostics = value.diagnostics
            administratorRequiredPaths = value.administratorRequiredPaths
            completedRoots = value.completedRoots
        }
        func model() throws -> NativeCore.CleanupScan {
            guard deferredPaths.allSatisfy(CleanupScanProtocol.validPath),
                  administratorRequiredPaths.allSatisfy(CleanupScanProtocol.validPath),
                  completedRoots.allSatisfy(CleanupScanProtocol.validPath) else { throw WireError.invalidMetadata }
            return try NativeCore.CleanupScan(categories: categories.map { try $0.model() },
                succeeded: succeeded, error: error, deferredPaths: deferredPaths, diagnostics: diagnostics,
                administratorRequiredPaths: administratorRequiredPaths, completedRoots: completedRoots)
        }
    }

    struct Frame: Codable, Sendable {
        let version: Int
        let id: UUID
        let kind: String
        let progress: Progress?
        let scan: Scan?
        let error: String?
        let observations: [NativeCore.CleanupInspectionObservation]
        static func progress(_ value: CleanupScanProgressEvent, id: UUID) -> Frame {
            .init(version: CleanupScanProtocol.version, id: id, kind: "progress",
                  progress: Progress(value), scan: nil, error: nil, observations: [])
        }
        static func result(_ value: NativeCore.CleanupScan,
                           observations: [NativeCore.CleanupInspectionObservation] = [], id: UUID) -> Frame {
            .init(version: CleanupScanProtocol.version, id: id, kind: "result",
                  progress: nil, scan: Scan(value), error: nil, observations: observations)
        }
        static func failure(_ message: String, id: UUID) -> Frame {
            .init(version: CleanupScanProtocol.version, id: id, kind: "error",
                  progress: nil, scan: nil, error: message, observations: [])
        }
        func validate(id: UUID) throws {
            guard version == CleanupScanProtocol.version, self.id == id,
                  observations.count <= 100_000 else { throw WireError.invalidFrame }
            switch kind {
            case "progress":
                guard progress != nil, scan == nil, error == nil, observations.isEmpty else { throw WireError.invalidFrame }
            case "result":
                guard progress == nil, scan != nil, error == nil else { throw WireError.invalidFrame }
            case "error":
                guard progress == nil, scan == nil, observations.isEmpty, let error, !error.isEmpty,
                      error.utf8.count <= maximumProgressBytes else { throw WireError.invalidFrame }
            default: throw WireError.invalidFrame
            }
        }
    }

    static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 16_384 && !path.contains("\0")
            && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }

    static func validate(_ request: Request) throws {
        guard request.version == version,
              (request.operation == "scan" && request.cachedCategories == nil)
                || (request.operation == "preflight" && request.cachedCategories != nil),
              request.parentPID > 1,
              CleanupScanMode(rawValue: request.mode) != nil, validPath(request.home), request.home != "/",
              request.excludingRoots.allSatisfy(validPath), request.observations.count <= 100_000 else { throw WireError.invalidRequest }
        if let presence = request.presence {
            guard presence.applicationDirs.allSatisfy(validPath), presence.searchPath.allSatisfy(validPath),
                  presence.applicationPathsByName.values.joined().allSatisfy(validPath) else { throw WireError.invalidRequest }
        }
    }

    static func encodeRequest(_ value: Request) throws -> Data {
        try validate(value)
        return try encode(value, limit: maximumRequestBytes)
    }
    static func decodeRequest(_ body: Data) throws -> Request {
        guard body.count <= maximumRequestBytes else { throw WireError.oversizedFrame }
        let value = try JSONDecoder().decode(Strict<Request>.self, from: body).value
        try validate(value)
        return value
    }
    static func encodeFrame(_ value: Frame) throws -> Data {
        try value.validate(id: value.id)
        return try encode(value, limit: value.kind == "progress" ? maximumProgressBytes : maximumFrameBytes)
    }
    static func decodeFrame(_ body: Data, id: UUID) throws -> Frame {
        guard body.count <= maximumFrameBytes else { throw WireError.oversizedFrame }
        let value = try JSONDecoder().decode(Strict<Frame>.self, from: body).value
        try value.validate(id: id)
        if value.kind == "progress", body.count > maximumProgressBytes { throw WireError.oversizedFrame }
        return value
    }
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    /// Inspect top-level keys using the same decoder, avoiding a second full
    /// JSONSerialization object graph for very large preflight inventories.
    private struct Strict<Value: Decodable>: Decodable {
        let value: Value
        init(from decoder: Decoder) throws {
            let allowed: Set<String> = Value.self == Request.self
                ? ["version", "operation", "id", "parentPID", "parentUID", "home", "mode", "presence", "includingAdministratorRequired", "excludingRoots", "cachedCategories", "observations"]
                : ["version", "id", "kind", "progress", "scan", "error", "observations"]
            let container = try decoder.container(keyedBy: Key.self)
            guard Set(container.allKeys.map(\.stringValue)).isSubset(of: allowed) else { throw WireError.invalidFrame }
            value = try Value(from: decoder)
        }
    }
    private static func encode<T: Encodable>(_ value: T, limit: Int) throws -> Data {
        let body = try JSONEncoder().encode(value)
        guard !body.isEmpty, body.count <= limit else { throw WireError.oversizedFrame }
        var count = UInt32(body.count).bigEndian
        var framed = withUnsafeBytes(of: &count) { Data($0) }
        framed.append(body)
        return framed
    }
    static func bodyLength(_ header: Data, limit: Int) throws -> Int {
        guard header.count == 4 else { throw WireError.truncatedFrame }
        let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size > 0, size <= limit else { throw WireError.oversizedFrame }
        return Int(size)
    }
}
