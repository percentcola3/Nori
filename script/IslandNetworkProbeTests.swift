import Foundation

@main
@MainActor
struct IslandNetworkProbeTests {
    static func main() async {
        let normal = "4 packets transmitted, 4 packets received, 0.0% packet loss\nround-trip min/avg/max/stddev = 4.2/8.3/10.8/1.4 ms"
        let ping = IslandNetworkProbeParser.ping(normal)!
        precondition(ping.averageMilliseconds == 8.3 && ping.lossPercent == 0 && ping.jitterMilliseconds == 1.4)
        precondition(IslandNetworkProbeParser.ping("4 packets transmitted, 0 packets received, 100.0% packet loss")?.averageMilliseconds == nil)
        precondition(IslandNetworkProbeParser.ping("4 packets transmitted, 3 packets received, 25.0% packet loss\nround-trip min/avg/max/std-dev = 1.0/2.0/3.0/0.5 ms")?.received == 3)
        for bad in ["", "4 packets transmitted, 5 packets received, 0.0% packet loss", "4 packets transmitted, 3 packets received, 0.0% packet loss", "4 packets transmitted, 4 packets received, 0.0% packet loss"] {
            precondition(IslandNetworkProbeParser.ping(bad) == nil)
        }
        let noSamples = IslandNetworkProbeParser.ping("4 packets transmitted, 0 packets received, 100.0% packet loss\nround-trip min/avg/max/stddev = 0/./1/0 ms")
        precondition(noSamples?.averageMilliseconds == nil && noSamples?.jitterMilliseconds == nil,
                     "No replies must never expose or index malformed latency samples")
        let bandwidth = IslandNetworkProbeParser.bandwidth(#"{"dl_throughput":200000000,"ul_throughput":40000000,"base_rtt":12.5}"#)!
        precondition(bandwidth.downloadMbps == 200 && bandwidth.uploadMbps == 40 && bandwidth.idleMilliseconds == 12.5)
        for (speed, category) in [(0.0, "slow"), (4.9, "slow"), (5, "basic"), (24.9, "basic"),
                                  (25, "good"), (99.9, "good"), (100, "fast")] {
            let result = IslandBandwidthResult(downloadMbps: speed, uploadMbps: 10, idleMilliseconds: nil)
            precondition(result.summaryKey == "island.network.summary." + category)
        }
        for bad in ["", "{}", #"{"dl_throughput":true,"ul_throughput":1}"#, #"{"dl_throughput":0,"ul_throughput":0}"#, #"{"dl_throughput":-1,"ul_throughput":10}"#, #"{"dl_throughput":10,"ul_throughput":10,"error_code":2}"#] {
            precondition(IslandNetworkProbeParser.bandwidth(bad) == nil)
        }
        for invalid in ["-c 100", "example.com;touch /tmp/oops", "https://example.com", "x\ny", "a..b", "999.1.1.1", "-x.example", String(repeating: "x", count: 64)] {
            precondition(IslandNetworkProbeParser.pingTarget(invalid) == nil)
        }
        precondition(IslandNetworkProbeParser.pingTarget(" example.com ")?.arguments.last == "example.com")
        precondition(IslandNetworkProbeParser.pingTarget("::1")?.executable == "/sbin/ping6")
        let controller = IslandNetworkProbe()
        controller.host = "127.0.0.1"
        controller.start(.ping)
        let deadline = Date().addingTimeInterval(6)
        while controller.running != nil && Date() < deadline { try? await Task.sleep(nanoseconds: 40_000_000) }
        precondition(controller.running == nil && controller.pingResult?.received == 4 && controller.errorKey == nil)
        let independentEngine = MoleEngine()
        let independentJob = Task {
            await independentEngine.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["1"],
                environment: independentEngine.standardEnvironment(), timeout: 3)
        }
        controller.start(.ping)
        try? await Task.sleep(nanoseconds: 100_000_000)
        controller.cancel()
        try? await Task.sleep(nanoseconds: 250_000_000)
        precondition(controller.running == nil && controller.stopped && controller.pingResult == nil)
        let independentResult = await independentJob.value
        precondition(independentResult.succeeded, "Stopping network diagnostics must not cancel other command engines")
        controller.host = "bad host"
        controller.start(.ping)
        precondition(controller.running == nil && controller.errorKey == "island.network.invalidHost")
        print("PASS: target validation, latency/loss parsing, bit/s to Mbps conversion, malformed/error results, real loopback ping and cancellation")
    }
}
