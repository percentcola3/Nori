import Foundation

@main
struct TrafficAttributionTests {
    static func main() throws {
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw NSError(domain: "TrafficAttributionTests", code: 1,
                                           userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let chrome = "/Applications/Google Chrome.app"
        try expect(TrafficAttribution.applicationURL(in: chrome + "/Contents/MacOS/Google Chrome")?.path == chrome,
                   "Main executable did not map to app")
        try expect(TrafficAttribution.applicationURL(in: chrome + "/Contents/Frameworks/Helper.app/Contents/MacOS/Helper")?.path == chrome,
                   "Browser helper was split into another app")
        try expect(TrafficAttribution.applicationURL(in: "/usr/bin/python3") == nil,
                   "CLI process invented an app")
        try expect(TrafficAttribution.applicationURL(in: "/Applications/Foo.application/bin") == nil,
                   "Non-app extension was accepted")

        try expect(TrafficAttribution.exitKind(remote: "127.0.0.1:7890", interface: nil) == .loopback,
                   "Local ports must not imply a particular proxy client")
        try expect(TrafficAttribution.exitKind(remote: "[::1]:5432", interface: nil) == .loopback,
                   "Local socket was labeled proxy")
        try expect(TrafficAttribution.exitKind(remote: "1.1.1.1:443", interface: nil) == .unknown,
                   "Missing route was mislabeled direct")
        try expect(TrafficAttribution.exitKind(remote: "1.1.1.1:443", interface: "unknown") == .unknown,
                   "Failed route was mislabeled direct")
        try expect(TrafficAttribution.exitKind(remote: "1.1.1.1:443", interface: "utun4") == .tunnel,
                   "TUN was mislabeled as a proxy node")
        try expect(TrafficAttribution.exitKind(remote: "1.1.1.1:443", interface: "en0") == .direct,
                   "Physical route was missed")

        print("Traffic attribution: app helpers, loopback and unknown routes passed")
    }
}
