import Darwin
import Foundation

final class AgentHistoryOpenCode: NSObject, AgentHistoryBackend, URLSessionTaskDelegate, @unchecked Sendable {
    private let context: AgentHistoryContext
    private let child: AgentHistoryProcess
    private let base: URL
    private let authorization: String
    private lazy var http: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    private(set) var version = ""
    var ownedProcessIDs: Set<Int32> { [child.process.processIdentifier] }

    init(context: AgentHistoryContext) throws {
        self.context = context
        let port = try Self.availablePort()
        base = URL(string: "http://127.0.0.1:\(port)")!
        let password = UUID().uuidString + UUID().uuidString
        authorization = "Basic " + Data(("nori:" + password).utf8).base64EncodedString()
        child = try AgentHistoryProcess(context: context,
            arguments: ["serve", "--hostname", "127.0.0.1", "--port", String(port)],
            environment: ["OPENCODE_SERVER_USERNAME": "nori", "OPENCODE_SERVER_PASSWORD": password,
                          "OPENCODE_DISABLE_AUTOUPDATE": "1"])
        child.process.standardOutput = FileHandle.nullDevice
        super.init()
        try child.start()
    }

    func list() async throws -> [AgentHistorySession] {
        if version.isEmpty {
            let deadline = Date().addingTimeInterval(15)
            for _ in 0..<30 {
                if Date() >= deadline { break }
                guard child.process.isRunning else { throw AgentHistoryFailure("agents.history.error.unsupported") }
                if let health = try? await request("GET", path: ["global", "health"]) as? [String: Any],
                   health["healthy"] as? Bool == true, let nativeVersion = health["version"] as? String {
                    version = nativeVersion
                    break
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard !version.isEmpty else { throw AgentHistoryFailure("agents.history.error.unsupported") }
        }
        guard let items = try await request("GET", path: ["session"]) as? [[String: Any]], items.count <= 2000,
              let states = try await request("GET", path: ["session", "status"]) as? [String: [String: Any]] else {
            throw AgentHistoryFailure("agents.history.error.protocol")
        }
        let parents = Set(items.compactMap { $0["parentID"] as? String })
        var sessions: [AgentHistorySession] = []
        for item in items {
            guard let id = item["id"] as? String, AgentHistorySession.validID(id),
                  let cwd = item["directory"] as? String,
                  let title = item["title"] as? String, let time = item["time"] as? [String: Any],
                  let updated = time["updated"] as? NSNumber else {
                throw AgentHistoryFailure("agents.history.error.protocol")
            }
            guard URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path == context.project else { continue }
            var protection = AgentHistorySession.protection(in: item, project: cwd)
            if parents.contains(id) { protection = "agents.history.protected.related" }
            if let state = states[id] {
                guard let type = state["type"] as? String, ["idle", "busy", "retry"].contains(type) else {
                    throw AgentHistoryFailure("agents.history.error.protocol")
                }
                if type != "idle" { protection = "agents.history.protected.active" }
            }
            let metadata = try JSONSerialization.data(withJSONObject: item, options: [.sortedKeys])
            sessions.append(.init(provider: .opencode, sessionID: id, title: title, project: context.project,
                updatedAt: Date(timeIntervalSince1970: updated.doubleValue / 1000),
                fingerprint: AgentHistorySession.digest(metadata), metadata: metadata,
                protection: protection, transcript: nil, artifactRoot: nil))
        }
        guard Set(sessions.map(\.id)).count == sessions.count else { throw AgentHistoryFailure("agents.history.error.protocol") }
        return sessions.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    func prepareBackup(_ session: AgentHistorySession, to directory: URL) async throws {
        let info = try await request("GET", path: ["session", session.sessionID])
        guard let object = info as? [String: Any], object["id"] as? String == session.sessionID,
              let children = try await request("GET", path: ["session", session.sessionID, "children"]) as? [Any],
              children.isEmpty else { throw AgentHistoryFailure("agents.history.protected.related") }
        let messages = try await request("GET", path: ["session", session.sessionID, "message"])
        guard messages is [[String: Any]] else { throw AgentHistoryFailure("agents.history.error.protocol") }
        // Match OpenCode's export format. Its DB also contains credentials, so
        // we export the selected session through the API instead of copying it.
        try AgentHistoryBackup.writeJSON(["info": info, "messages": messages],
            to: directory.appendingPathComponent("opencode-export.json"))
        let diff = try await request("GET", path: ["session", session.sessionID, "diff"])
        guard diff is [[String: Any]] else { throw AgentHistoryFailure("agents.history.error.protocol") }
        try AgentHistoryBackup.writeJSON(diff, to: directory.appendingPathComponent("file-diffs.json"))
    }

    func delete(_ session: AgentHistorySession) async throws {
        guard AgentHistorySession.validID(session.sessionID),
              let children = try await request("GET", path: ["session", session.sessionID, "children"]) as? [Any],
              children.isEmpty else { throw AgentHistoryFailure("agents.history.protected.related") }
        guard try await request("DELETE", path: ["session", session.sessionID]) as? Bool == true else {
            throw AgentHistoryFailure("agents.history.error.api")
        }
    }

    private func request(_ method: String, path: [String]) async throws -> Any {
        var url = base
        for component in path { url.appendPathComponent(component) }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "directory", value: context.project)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        // Download to a temporary file, then impose a size limit before JSON
        // hydration. Large histories do not accumulate as an unbounded cache.
        let file: URL
        let response: URLResponse
        do { (file, response) = try await http.download(for: request) }
        catch { throw AgentHistoryFailure("agents.history.error.api") }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let status = response as? HTTPURLResponse, status.url?.host == "127.0.0.1",
              status.url?.port == base.port, (200..<300).contains(status.statusCode) else {
            throw AgentHistoryFailure("agents.history.error.api")
        }
        let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard bytes <= 8 * 1024 * 1024 else { throw AgentHistoryFailure("agents.history.error.tooLarge") }
        do { return try JSONSerialization.jsonObject(with: Data(contentsOf: file), options: [.fragmentsAllowed]) }
        catch { throw AgentHistoryFailure("agents.history.error.protocol") }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // The local authorization token must never follow an HTTP redirect.
        completionHandler(nil)
    }

    func close() { http.invalidateAndCancel(); child.close() }

    private static func availablePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentHistoryFailure("agents.history.error.launch") }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        guard bound == 0, named == 0 else { throw AgentHistoryFailure("agents.history.error.launch") }
        return UInt16(bigEndian: address.sin_port)
    }
}
