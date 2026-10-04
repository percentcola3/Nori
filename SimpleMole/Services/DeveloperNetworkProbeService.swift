import Foundation

/// HEAD requests with a fixed eight-second cap and no response body. Direct
/// means bypassing explicit/system proxy settings; a VPN/TUN route still applies.
enum DeveloperNetworkProbeService {
    struct Result: Identifiable, Equatable {
        let url: String
        let route: String
        let status: Int
        let milliseconds: Int?
        var id: String { url + ":" + route }
        var reached: Bool { status > 0 }
    }
    static let targets = ["https://github.com", "https://raw.githubusercontent.com", "https://registry.npmjs.org",
                          "https://pypi.org/simple/", "https://proxy.golang.org", "https://registry-1.docker.io/v2/"]
    static func probe(_ url: String, proxy: String?, engine: MoleEngine) async -> Result {
        let route = proxy == nil ? "dev.network.direct" : "dev.network.viaProxy"
        guard DeveloperNetworkToolsService.validHTTPS(url), proxy.map(DeveloperNetworkToolsService.validProxyURL) ?? true else {
            return Result(url: url, route: route, status: 0, milliseconds: nil)
        }
        let arguments = ["-q", "--silent", "--show-error", "--head", "--output", "/dev/null",
                         "--max-time", "8", "--connect-timeout", "8", "--proto", "=https", "--max-redirs", "0",
                         "--write-out", "%{http_code}\t%{time_total}", "--proxy", proxy ?? "", "--noproxy", proxy == nil ? "*" : "", "--url", url]
        // No shell command or curl config participates in the request.
        let result = await engine.run(executable: URL(fileURLWithPath: "/usr/bin/curl"), arguments: arguments,
                                      environment: engine.standardEnvironment(includeHomebrew: false), timeout: 9)
        let fields = result.output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\t")
        guard result.succeeded, fields.count == 2, let status = Int(fields[0]), let seconds = Double(fields[1]) else {
            return Result(url: url, route: route, status: 0, milliseconds: nil)
        }
        return Result(url: url, route: route, status: status, milliseconds: Int(seconds * 1_000))
    }
}
