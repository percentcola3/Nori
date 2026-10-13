import Foundation

/// The same Content-Length JSON-RPC transport used by the official Copilot SDK.
/// Only session metadata/list/delete calls are made; no agent turns are started.
final class AgentHistoryRPC: @unchecked Sendable {
    private let child: AgentHistoryProcess
    private let condition = NSCondition()
    private var buffer = Data()
    private var responses: [Int: [String: Any]] = [:]
    private var nextID = 0
    private var pending = Set<Int>()
    private var failure: String?
    var ownedProcessIDs: Set<Int32> { [child.process.processIdentifier] }

    init(context: AgentHistoryContext) throws {
        child = try AgentHistoryProcess(context: context,
            arguments: ["--headless", "--stdio", "--no-auto-update", "--no-auto-login"])
        child.output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive((try? handle.read(upToCount: 64 * 1024)) ?? Data())
        }
        try child.start()
    }

    func call(_ method: String, _ params: [String: Any] = [:]) async throws -> Data {
        let encoded = try JSONSerialization.data(withJSONObject: params)
        return try await Task.detached(priority: .utility) { try self.callBlocking(method, encoded) }.value
    }

    private func callBlocking(_ method: String, _ encodedParams: Data) throws -> Data {
        condition.lock(); defer { condition.unlock() }
        nextID += 1
        let id = nextID
        pending.insert(id)
        defer { pending.remove(id); responses.removeValue(forKey: id) }
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id,
            "method": method, "params": try JSONSerialization.jsonObject(with: encodedParams)])
        do {
            try child.input.fileHandleForWriting.write(contentsOf:
                Data("Content-Length: \(data.count)\r\n\r\n".utf8) + data)
        } catch { throw AgentHistoryFailure("agents.history.error.protocol") }
        let deadline = Date().addingTimeInterval(20)
        while responses[id] == nil && failure == nil {
            if !condition.wait(until: deadline) { throw AgentHistoryFailure("agents.history.error.timeout") }
        }
        if let failure { throw AgentHistoryFailure(failure) }
        guard let response = responses.removeValue(forKey: id) else {
            throw AgentHistoryFailure("agents.history.error.protocol")
        }
        if let error = response["error"] as? [String: Any] {
            if error["code"] as? Int == -32601 { throw AgentHistoryFailure("agents.history.error.unsupported") }
            throw AgentHistoryFailure("agents.history.error.api")
        }
        guard let result = response["result"] else { throw AgentHistoryFailure("agents.history.error.protocol") }
        return try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
    }

    private func receive(_ data: Data) {
        condition.lock(); defer { condition.unlock() }
        guard !data.isEmpty else { failure = "agents.history.error.protocol"; condition.broadcast(); return }
        buffer.append(data)
        guard buffer.count <= 8 * 1024 * 1024 else {
            failure = "agents.history.error.tooLarge"; condition.broadcast(); return
        }
        while let delimiter = buffer.range(of: Data("\r\n\r\n".utf8)) {
            guard delimiter.lowerBound < 8192,
                  let header = String(data: buffer[..<delimiter.lowerBound], encoding: .utf8),
                  let lengthLine = header.components(separatedBy: "\r\n").first(where: {
                      $0.lowercased().hasPrefix("content-length:")
                  }), let length = Int(lengthLine.dropFirst("Content-Length:".count)
                    .trimmingCharacters(in: .whitespaces)), length >= 0, length <= 8 * 1024 * 1024 else {
                failure = "agents.history.error.protocol"; condition.broadcast(); return
            }
            let end = delimiter.upperBound + length
            guard buffer.count >= end else { return }
            let payload = buffer.subdata(in: delimiter.upperBound..<end)
            buffer.removeSubrange(0..<end)
            guard let message = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
                failure = "agents.history.error.protocol"; condition.broadcast(); return
            }
            if let id = message["id"] as? Int, message["method"] == nil {
                if pending.contains(id) { responses[id] = message }
            } else if let id = message["id"], message["method"] != nil {
                // Permission/login/turn requests are not authorized by a history operation.
                let response: [String: Any] = ["jsonrpc": "2.0", "id": id,
                    "error": ["code": -32601, "message": "History-only client"]]
                if let body = try? JSONSerialization.data(withJSONObject: response) {
                    try? child.input.fileHandleForWriting.write(contentsOf:
                        Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body)
                }
            }
            condition.broadcast()
        }
    }

    func close() { child.close() }
    deinit { close() }
}
