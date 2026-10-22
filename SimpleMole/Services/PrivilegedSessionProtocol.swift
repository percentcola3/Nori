import Foundation

/// Each connection carries one UTF-8 JSON line and one response line.
enum PrivilegedSessionProtocol {
    static let stagedResourcesToken = "__NORI_STAGED_RESOURCES__"
    static let maximumRequestBytes = 256 * 1024
    static let maximumOutputBytes = 1024 * 1024
    static let maximumSessionLifetime: TimeInterval = 8 * 60 * 60
    static let allowedRelativePaths: Set<String> = [
        "bin/app_cleanup_admin.sh", "bin/app_uninstall_admin.sh",
        "bin/app_optimize_admin.sh", "bin/app_memory_reclaim.sh",
        "bin/app_dev_hosts.sh", "bin/app_net_fixproxy.sh", "bin/app_dev_xcode.sh"
    ]
    struct Request: Codable, Sendable {
        let id: String
        let operation: String
        let relativePath: String
        let arguments: [String]
        let timeout: Double
    }
    struct Response: Codable, Sendable {
        let id: String
        let output: String
        let stderrOutput: String
        let exitCode: Int32
        let timedOut: Bool
    }
    enum WireError: Error { case invalidRequest, oversizedFrame, invalidFrame }
    static func validate(_ request: Request) throws {
        guard !request.id.isEmpty, request.id.utf8.count <= 256,
              !request.id.contains("\0"), request.timeout.isFinite,
              request.arguments.allSatisfy({ !$0.contains("\0") }) else { throw WireError.invalidRequest }
        switch request.operation {
        case "ping":
            guard request.relativePath.isEmpty, request.arguments.isEmpty else { throw WireError.invalidRequest }
        case "run":
            guard allowedRelativePaths.contains(request.relativePath), validArguments(request) else { throw WireError.invalidRequest }
        default: throw WireError.invalidRequest
        }
    }
    static func validate(_ request: Request, parentUID: UInt32) throws {
        try validate(request)
        if ["bin/app_cleanup_admin.sh", "bin/app_uninstall_admin.sh", "bin/app_optimize_admin.sh", "bin/app_dev_hosts.sh"].contains(request.relativePath) {
            guard request.arguments.first == String(parentUID) else { throw WireError.invalidRequest }
        }
    }
    private static func validArguments(_ request: Request) -> Bool {
        let args = request.arguments
        func uid(_ value: String) -> Bool { UInt32(value).map { $0 > 0 && String($0) == value } ?? false }
        func absolutePath(_ value: String) -> Bool {
            value.hasPrefix("/") && value.split(separator: "/").allSatisfy { $0 != "." && $0 != ".." } && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        }
        switch request.relativePath {
        case "bin/app_memory_reclaim.sh": return args.isEmpty
        case "bin/app_cleanup_admin.sh", "bin/app_uninstall_admin.sh":
            return args.count == 2 && uid(args[0]) && absolutePath(args[1])
        case "bin/app_optimize_admin.sh":
            let tasks: Set<String> = ["dns", "network-stack", "periodic", "permissions", "spotlight", "disk-verify"]
            return (2...7).contains(args.count) && uid(args[0]) && args.dropFirst().allSatisfy { tasks.contains($0) } && Set(args.dropFirst()).count == args.count - 1
        case "bin/app_dev_hosts.sh":
            return args.count == 4 && uid(args[0]) && ["apply", "apply-flush"].contains(args[1])
                && args[2].utf8.count == 64 && args[2].utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
                && args[3].utf8.count <= 87384 && Data(base64Encoded: args[3]).map { $0.count <= 65536 } == true
        case "bin/app_net_fixproxy.sh":
            return args.count == 2 && !args[0].isEmpty && !args[0].hasPrefix("-") && args[0].utf8.count <= 256
                && !args[0].unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) && ["http", "https", "socks", "pac"].contains(args[1])
        case "bin/app_dev_xcode.sh":
            if args == ["license"] { return true }
            guard args.count == 2 && args[0] == "select" && absolutePath(args[1]) else { return false }
            let parts = args[1].split(separator: "/", omittingEmptySubsequences: false)
            return parts.count == 5 && parts[0].isEmpty && parts[1] == "Applications" && parts[2].hasSuffix(".app") && parts[3] == "Contents" && parts[4] == "Developer"
        default: return false
        }
    }
    static func clampedTimeout(_ timeout: Double) -> Double { min(600, max(1, timeout)) }
    static func resolveArguments(_ arguments: [String], stagedResourcesPath: String) -> [String] {
        arguments.map { $0 == stagedResourcesToken ? stagedResourcesPath : $0 }
    }
    static func boundedOutput(_ data: Data) -> String {
        let decoded = String(decoding: data.prefix(maximumOutputBytes), as: UTF8.self)
        guard decoded.utf8.count > maximumOutputBytes else { return decoded }
        var bytes = Data(decoded.utf8.prefix(maximumOutputBytes))
        while String(data: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        return String(data: bytes, encoding: .utf8) ?? ""
    }
    static func encodeRequest(_ request: Request) throws -> Data {
        try validate(request)
        let data = try encodeLine(request)
        guard data.count <= maximumRequestBytes else { throw WireError.oversizedFrame }
        return data
    }
    static func decodeRequest(_ data: Data) throws -> Request {
        guard data.count <= maximumRequestBytes else { throw WireError.oversizedFrame }
        let body = try payload(data)
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              Set(object.keys) == Set(["id", "operation", "relativePath", "arguments", "timeout"]) else { throw WireError.invalidRequest }
        let request = try JSONDecoder().decode(Request.self, from: body)
        try validate(request)
        return request
    }
    static func encodeResponse(_ response: Response) throws -> Data { try encodeLine(response) }
    static func decodeResponse(_ data: Data) throws -> Response {
        try JSONDecoder().decode(Response.self, from: payload(data))
    }
    private static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(10)
        return data
    }
    private static func payload(_ data: Data) throws -> Data {
        guard data.last == 10, !data.dropLast().contains(10) else { throw WireError.invalidFrame }
        return data.dropLast()
    }
}
