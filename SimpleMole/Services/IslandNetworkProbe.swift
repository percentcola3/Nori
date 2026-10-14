import Foundation
import Darwin
import Combine

struct IslandPingResult: Equatable {
    let sent: Int
    let received: Int
    let lossPercent: Double
    let averageMilliseconds: Double?
    let jitterMilliseconds: Double?
}

struct IslandBandwidthResult: Equatable {
    let downloadMbps: Double
    let uploadMbps: Double
    let idleMilliseconds: Double?
}

enum IslandNetworkProbeParser {
    static func pingTarget(_ input: String) -> (executable: String, arguments: [String])? {
        let host = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host.utf8.count <= 253, !host.hasPrefix("-") else { return nil }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            return ("/sbin/ping6", ["-n", "-c", "4", "-i", "0.4", host])
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") }) else { return nil }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) {
            var ipv4 = in_addr()
            guard inet_pton(AF_INET, host, &ipv4) == 1 else { return nil }
        }
        return ("/sbin/ping", ["-n", "-c", "4", "-i", "0.4", "-W", "1500", "-t", "8", host])
    }

    static func ping(_ output: String) -> IslandPingResult? {
        guard let counts = captures(#"(\d+) packets transmitted,\s*(\d+) (?:packets )?received,\s*([\d.]+)% packet loss"#, output),
              let sent = Int(counts[0]), let received = Int(counts[1]), let loss = Double(counts[2]),
              sent > 0, received >= 0, received <= sent, loss.isFinite, (0...100).contains(loss),
              abs(loss - Double(sent - received) / Double(sent) * 100) <= 0.11 else { return nil }
        let times = captures(#"(?:round-trip|rtt)[^\n=]*=\s*([\d.]+)/([\d.]+)/([\d.]+)/([\d.]+)\s*ms"#, output)?.compactMap(Double.init)
        if received > 0 {
            guard let times, times.count == 4, times.allSatisfy({ $0.isFinite && $0 >= 0 }),
                  times[0] <= times[1], times[1] <= times[2] else { return nil }
        }
        return IslandPingResult(sent: sent, received: received, lossPercent: loss,
                                averageMilliseconds: received > 0 ? times?[1] : nil,
                                jitterMilliseconds: received > 0 ? times?[3] : nil)
    }

    static func bandwidth(_ output: String) -> IslandBandwidthResult? {
        guard let data = output.data(using: .utf8),
              let values = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              values["error_code"] == nil || number(values["error_code"]) == 0,
              let download = number(values["dl_throughput"]), let upload = number(values["ul_throughput"]),
              download >= 0, upload >= 0, download > 0 || upload > 0 else { return nil }
        let idle = number(values["base_rtt"]).flatMap { $0 >= 0 ? $0 : nil }
        return IslandBandwidthResult(downloadMbps: download / 1_000_000, uploadMbps: upload / 1_000_000,
                                     idleMilliseconds: idle)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }
    private static func captures(_ pattern: String, _ output: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: output).map { String(output[$0]) } }
    }
}

@MainActor
final class IslandNetworkProbe: ObservableObject {
    enum Mode: Equatable { case ping, bandwidth }
    @Published var host = "google.com"
    @Published private(set) var running: Mode?
    @Published private(set) var pingResult: IslandPingResult?
    @Published private(set) var bandwidthResult: IslandBandwidthResult?
    @Published private(set) var errorKey: String?
    @Published private(set) var stopped = false
    // This engine owns only these diagnostics. Cancelling never affects cleanup,
    // uninstall, developer commands or another network measurement instance.
    private let engine = MoleEngine()
    private var task: Task<Void, Never>?
    private var generation = 0

    func start(_ mode: Mode) {
        guard running == nil else { return }
        let command: (String, [String], TimeInterval)
        switch mode {
        case .ping:
            guard let target = IslandNetworkProbeParser.pingTarget(host) else {
                errorKey = "island.network.invalidHost"; return
            }
            command = (target.executable, target.arguments, 10)
            pingResult = nil
        case .bandwidth:
            guard FileManager.default.isExecutableFile(atPath: "/usr/bin/networkQuality") else {
                errorKey = "island.network.unavailable"; return
            }
            // -c is supported from the tool's original macOS release. Bound the
            // entire command through the process runner rather than newer flags.
            command = ("/usr/bin/networkQuality", ["-c"], 45)
            bandwidthResult = nil
        }
        generation += 1
        let token = generation
        running = mode
        stopped = false
        errorKey = nil
        let environment = engine.standardEnvironment(["LC_ALL": "C", "LANG": "C"], includeHomebrew: false)
        task = Task { [weak self, engine] in
            let result = await engine.run(executable: URL(fileURLWithPath: command.0), arguments: command.1,
                                          environment: environment, timeout: command.2, captureLimit: 65_536)
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.running = nil
            if result.timedOut { self.errorKey = "island.network.timeout"; return }
            guard !result.outputTruncated else { self.errorKey = "island.network.failed"; return }
            switch mode {
            case .ping:
                // ping's nonzero exit with a valid loss summary is useful data.
                if let parsed = IslandNetworkProbeParser.ping(result.output) { self.pingResult = parsed }
                else { self.errorKey = "island.network.pingFailed" }
            case .bandwidth:
                if result.succeeded, let parsed = IslandNetworkProbeParser.bandwidth(result.output) {
                    self.bandwidthResult = parsed
                } else { self.errorKey = "island.network.failed" }
            }
        }
    }

    func cancel() {
        let wasRunning = running != nil
        generation += 1
        task?.cancel()
        task = nil
        engine.cancelAll()
        running = nil
        if wasRunning { stopped = true }
    }
}
