import Foundation

@main
struct PrivilegedSessionProtocolTests {
    typealias Wire = PrivilegedSessionProtocol
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError(message) }
    }
    static func rejects(_ message: String, _ operation: () throws -> Void) {
        checks += 1
        do { try operation(); fatalError("Accepted \(message)") } catch {}
    }
    static func main() throws {
        let ping = Wire.Request(id: "ping-1", operation: "ping", relativePath: "", arguments: [], timeout: 3)
        let pingData = try Wire.encodeRequest(ping)
        let decodedPing = try Wire.decodeRequest(pingData)
        expect(decodedPing.id == ping.id && decodedPing.operation == "ping", "Ping round trip")
        let scripts: Set<String> = ["bin/app_cleanup_admin.sh", "bin/app_uninstall_admin.sh", "bin/app_optimize_admin.sh", "bin/app_memory_reclaim.sh", "bin/app_dev_hosts.sh", "bin/app_net_fixproxy.sh", "bin/app_dev_xcode.sh"]
        expect(Wire.allowedRelativePaths == scripts, "Privileged entrypoints changed without review")
        let validArguments: [String: [String]] = [
            "bin/app_cleanup_admin.sh": ["501", "/tmp/space 中文 ';$(never-run);'.json"],
            "bin/app_uninstall_admin.sh": ["501", "/tmp/uninstall.json"],
            "bin/app_optimize_admin.sh": ["501", "dns", "permissions"],
            "bin/app_memory_reclaim.sh": [],
            "bin/app_dev_hosts.sh": ["501", "apply-flush", String(repeating: "a", count: 64), Data("line\nbreak中文".utf8).base64EncodedString()],
            "bin/app_net_fixproxy.sh": ["Wi-Fi 中文 ';$(never-run);'", "http"],
            "bin/app_dev_xcode.sh": ["select", "/Applications/Xcode.app/Contents/Developer"]
        ]
        for script in scripts {
            let request = Wire.Request(id: UUID().uuidString, operation: "run", relativePath: script,
                arguments: validArguments[script]!, timeout: 900)
            let encoded = try Wire.encodeRequest(request)
            expect(encoded.filter { $0 == 10 }.count == 1, "Exactly one delimiter")
            let decoded = try Wire.decodeRequest(encoded)
            expect(decoded.arguments == request.arguments && decoded.relativePath == script, "Arguments preserved without shell evaluation")
        }
        for path in ["/bin/bash", "bin/../bin/app_dev_hosts.sh", "../bin/app_dev_hosts.sh", "bin//app_dev_hosts.sh", "bin/app_dev_hosts.sh/", "bin/app_runtime.sh", "bin/app_apply.sh", "bin/app_dev_hosts.sh\0"] {
            rejects("unsafe path \(path)") {
                try Wire.validate(.init(id: "r", operation: "run", relativePath: path, arguments: [], timeout: 5))
            }
        }
        for request in [
            Wire.Request(id: "r", operation: "shell", relativePath: "", arguments: [], timeout: 5),
            .init(id: "", operation: "ping", relativePath: "", arguments: [], timeout: 5),
            .init(id: String(repeating: "x", count: 257), operation: "ping", relativePath: "", arguments: [], timeout: 5),
            .init(id: "r", operation: "ping", relativePath: "bin/app_dev_hosts.sh", arguments: [], timeout: 5),
            .init(id: "r", operation: "ping", relativePath: "", arguments: ["x"], timeout: 5),
            .init(id: "r", operation: "run", relativePath: "bin/app_dev_hosts.sh", arguments: ["nul\0arg"], timeout: 5),
            .init(id: "r", operation: "ping", relativePath: "", arguments: [], timeout: .infinity),
            .init(id: "r", operation: "ping", relativePath: "", arguments: [], timeout: .nan)
        ] { rejects("invalid request") { try Wire.validate(request) } }
        rejects("missing delimiter") { _ = try Wire.decodeRequest(pingData.dropLast()) }
        rejects("multiple frames") { _ = try Wire.decodeRequest(pingData + pingData) }
        rejects("missing fields") { _ = try Wire.decodeRequest(Data("{\"id\":\"r\"}\n".utf8)) }
        rejects("wrong field types") { _ = try Wire.decodeRequest(Data("{\"id\":1,\"operation\":\"ping\",\"relativePath\":\"\",\"arguments\":[],\"timeout\":3}\n".utf8)) }
        rejects("oversized incoming frame") { _ = try Wire.decodeRequest(Data(repeating: 32, count: Wire.maximumRequestBytes + 1)) }
        rejects("oversized outgoing request") {
            _ = try Wire.encodeRequest(.init(id: "r", operation: "run", relativePath: "bin/app_dev_hosts.sh", arguments: [String(repeating: "x", count: Wire.maximumRequestBytes)], timeout: 3))
        }
        var boundaryData = Data(pingData.dropLast())
        boundaryData.append(Data(repeating: 32, count: Wire.maximumRequestBytes - boundaryData.count - 1))
        boundaryData.append(10)
        expect(boundaryData.count == Wire.maximumRequestBytes, "Maximum frame includes delimiter")
        _ = try Wire.decodeRequest(boundaryData)
        rejects("unknown field") { _ = try Wire.decodeRequest(Data("{\"id\":\"r\",\"operation\":\"ping\",\"relativePath\":\"\",\"arguments\":[],\"timeout\":3,\"environment\":{}}\n".utf8)) }
        for script in scripts {
            let args = validArguments[script]!
            let request = Wire.Request(id: "r", operation: "run", relativePath: script, arguments: args, timeout: 3)
            try Wire.validate(request, parentUID: 501)
            if ["bin/app_cleanup_admin.sh", "bin/app_uninstall_admin.sh", "bin/app_optimize_admin.sh", "bin/app_dev_hosts.sh"].contains(script) {
                rejects("UID mismatch") { try Wire.validate(request, parentUID: 502) }
            }
            rejects("extra bridge argument") {
                try Wire.validate(.init(id: "r", operation: "run", relativePath: script, arguments: args + ["unexpected"], timeout: 3))
            }
        }
        for (path, args) in [
            ("bin/app_cleanup_admin.sh", ["501", "../manifest.json"]),
            ("bin/app_uninstall_admin.sh", ["0", "/tmp/manifest.json"]),
            ("bin/app_optimize_admin.sh", ["501", "arbitrary-task"]),
            ("bin/app_optimize_admin.sh", ["501", "dns", "dns"]),
            ("bin/app_dev_hosts.sh", ["501", "validate", String(repeating: "a", count: 64), ""]),
            ("bin/app_dev_hosts.sh", ["501", "apply", String(repeating: "a", count: 64), "bad*base64"]),
            ("bin/app_dev_xcode.sh", ["select", "/Applications/../tmp/Evil.app/Contents/Developer"]),
            ("bin/app_net_fixproxy.sh", ["-option", "http"]),
            ("bin/app_net_fixproxy.sh", ["Wi-Fi", "arbitrary-proxy"])
        ] {
            rejects("invalid bridge arguments") { try Wire.validate(.init(id: "r", operation: "run", relativePath: path, arguments: args, timeout: 3)) }
        }
        expect(Wire.clampedTimeout(-10) == 1 && Wire.clampedTimeout(0) == 1 && Wire.clampedTimeout(90) == 90 && Wire.clampedTimeout(900) == 600, "Timeout clamp")
        let token = Wire.stagedResourcesToken
        let expanded = Wire.resolveArguments([token, token + "/bin", "prefix" + token, "", "literal"], stagedResourcesPath: "/fixture/Nori.app/Contents/Resources")
        expect(expanded == ["/fixture/Nori.app/Contents/Resources", token + "/bin", "prefix" + token, "", "literal"], "Only exact tokens expand")
        let response = Wire.Response(id: "r", output: "out\n", stderrOutput: "err\n", exitCode: -1, timedOut: true)
        let decodedResponse = try Wire.decodeResponse(Wire.encodeResponse(response))
        expect(decodedResponse.id == response.id && decodedResponse.output == "out\n" && decodedResponse.stderrOutput == "err\n" && decodedResponse.exitCode == -1 && decodedResponse.timedOut, "Response fields round trip")
        expect(Wire.boundedOutput(Data("hello\n中文".utf8)) == "hello\n中文", "Output retains valid text")
        expect(Wire.boundedOutput(Data(repeating: 255, count: Wire.maximumOutputBytes)).utf8.count <= Wire.maximumOutputBytes, "Invalid UTF-8 remains bounded")
        expect(Wire.boundedOutput(Data(repeating: 97, count: Wire.maximumOutputBytes + 10)).utf8.count == Wire.maximumOutputBytes, "Large output truncates")
        print("Privileged protocol: \(checks) checks passed; no authorization or privileged execution")
    }
}
