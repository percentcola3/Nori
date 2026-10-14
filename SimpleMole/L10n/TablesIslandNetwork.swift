import Foundation

enum L10nIslandNetworkTables {
    static func table(for language: AppLanguage) -> [String: String] {
        switch language {
        case .auto: return [:]
        case .zhHans: return zhHans
        case .zhHant: return zhHans.mapValues { $0.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? $0 }
        default: return en
        }
    }
    private static let en: [String: String] = [
        "island.network.open": "Network diagnostics and speed test",
        "island.network.title": "Network diagnostics",
        "island.network.close": "Close network diagnostics",
        "island.network.host": "Host or IP address",
        "island.network.ping": "Ping",
        "island.network.speed": "Speed test",
        "island.network.start": "Start speed test",
        "island.network.jitter": "Jitter",
        "island.network.live": "Live throughput",
        "island.network.stop": "Stop",
        "island.network.latency": "Ping latency",
        "island.network.loss": "Packet loss",
        "island.network.download": "Download capacity",
        "island.network.upload": "Upload capacity",
        "island.network.idle": "Idle latency: %@ ms",
        "island.network.pinging": "Checking latency…",
        "island.network.measuring": "Measuring upload and download…",
        "island.network.stopped": "Stopped",
        "island.network.invalidHost": "Enter a valid hostname, IPv4 or IPv6 address.",
        "island.network.unavailable": "The system bandwidth testing tool is unavailable.",
        "island.network.timeout": "The test timed out. Try again later.",
        "island.network.failed": "Could not measure bandwidth. Check connectivity and try again.",
        "island.network.pingFailed": "Ping failed. Check the target address or whether ICMP is blocked.",
        "island.network.hint": "Ping measures latency; speed testing generates upload and download traffic. Stop at any time.",
        "island.network.hint.ping": "Ping measures latency and packet loss to the host (default google.com).",
        "island.network.hint.speed": "Speed testing generates upload and download traffic. Stop at any time.",
    ]
    private static let zhHans: [String: String] = [
        "island.network.open": "网络检测与测速",
        "island.network.title": "网络检测",
        "island.network.close": "关闭网络检测",
        "island.network.host": "域名或 IP 地址",
        "island.network.ping": "Ping 检测",
        "island.network.speed": "带宽测速",
        "island.network.start": "开始测速",
        "island.network.jitter": "抖动",
        "island.network.live": "实时速率",
        "island.network.stop": "停止",
        "island.network.latency": "Ping 延迟",
        "island.network.loss": "丢包率",
        "island.network.download": "下载带宽",
        "island.network.upload": "上传带宽",
        "island.network.idle": "空载延迟：%@ ms",
        "island.network.pinging": "正在检测延迟…",
        "island.network.measuring": "正在测量上下行带宽…",
        "island.network.stopped": "已停止",
        "island.network.invalidHost": "请输入有效的域名、IPv4 或 IPv6 地址。",
        "island.network.unavailable": "当前系统没有可用的带宽测速工具。",
        "island.network.timeout": "检测超时，请稍后重试。",
        "island.network.failed": "未能测量带宽，请检查网络后重试。",
        "island.network.pingFailed": "Ping 检测失败，请检查目标地址或 ICMP 是否被拦截。",
        "island.network.hint": "Ping 检测延迟；带宽测速会产生上下行流量，可随时停止。",
        "island.network.hint.ping": "Ping 检测到目标主机的延迟与丢包（默认 google.com）。",
        "island.network.hint.speed": "带宽测速会产生上下行流量，可随时停止。",
    ]
}
