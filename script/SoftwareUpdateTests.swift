import Foundation

enum AppLanguage: String, CaseIterable {
    case auto, en, zhHans, zhHant, ja, ko, de, fr, es, pt, it, ru, tr
}

@main
struct SoftwareUpdateTests {
    static func main() async throws {
        let routes: [String: String] = [
            "https://formulae.brew.sh/api/formula/jq.json": #"{"name":"jq","versions":{"stable":"2.10"},"revision":1}"#,
            "https://registry.npmjs.org/%40fixture%2Ftool/latest": #"{"name":"@fixture/tool","version":"2.0.0"}"#,
            "https://pypi.org/pypi/fixture_tool/json": #"{"info":{"name":"fixture-tool","version":"1.2.0"}}"#,
            "https://crates.io/api/v1/crates/ripgrep": #"{"crate":{"id":"ripgrep","max_stable_version":"15.0.0"}}"#,
            "https://formulae.brew.sh/api/cask/cursor.json": #"{"token":"cursor","version":"2.0.0"}"#,
            "https://formulae.brew.sh/api/cask/compound.json": #"{"token":"compound","version":"2.0.0,500"}"#,
            "https://itunes.apple.com/lookup?bundleId=com.fixture.mac&entity=macSoftware": #"{"results":[{"bundleId":"com.other.app","version":"99.0"},{"bundleId":"com.fixture.mac","version":"2.0"}]}"#,
            "https://example.com/appcast.xml": """
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
            <item><sparkle:version>5</sparkle:version><sparkle:shortVersionString>1.0.0</sparkle:shortVersionString><enclosure url="https://example.com/old.dmg"/></item>
            <item><sparkle:version>100</sparkle:version><sparkle:shortVersionString>2.0.0</sparkle:shortVersionString><sparkle:minimumSystemVersion>999.0</sparkle:minimumSystemVersion><enclosure/></item>
            <item><enclosure sparkle:version="101" sparkle:shortVersionString="2.0.1" sparkle:os="windows"/></item>
            <item><enclosure sparkle:version="102" sparkle:shortVersionString="2.0.2-beta.1"/></item>
            <item><enclosure sparkle:version="103" sparkle:shortVersionString="2.0.3" sparkle:arch="other-cpu"/></item>
            <item><sparkle:version>7</sparkle:version><sparkle:shortVersionString>1.1.0</sparkle:shortVersionString><enclosure sparkle:installationType="package"/></item>
            </channel></rss>
            """,
            "https://example.com/hostile.xml": #"<!DOCTYPE rss [<!ENTITY leak SYSTEM "file:///fixture/secret">]><rss><item>&leak;</item></rss>"#,
            "https://registry.npmjs.org/wrong/latest": #"{"name":"different-package","version":"99.0.0"}"#,
            "https://registry.npmjs.org/broken/latest": "temporarily unavailable"
        ]
        let service = SoftwareUpdateService { url in
            guard let value = routes[url.absoluteString] else { throw URLError(.resourceUnavailable) }
            return Data(value.utf8)
        }
        func check(_ source: SoftwareUpdateService.Source, installed: String,
                   expected: SoftwareUpdateResult.State, latest: String? = nil) async {
            let result = await service.check(.init(id: "fixture", installed: installed, source: source))
            precondition(result.state == expected && (latest == nil || result.latest == latest), "Wrong update result: \(result)")
        }
        await check(.formula("jq"), installed: "2.9_1", expected: .available, latest: "2.10_1")
        await check(.formula("jq"), installed: "2.10_1", expected: .current)
        await check(.npm("@fixture/tool"), installed: "1.0.0", expected: .available, latest: "2.0.0")
        await check(.pypi("fixture_tool"), installed: "1.2", expected: .current)
        await check(.crates("ripgrep"), installed: "14.1.0", expected: .available)
        await check(.cask("cursor"), installed: "1.0", expected: .available)
        await check(.cask("compound"), installed: "2.0.0", expected: .unsupported)
        await check(.appStore("com.fixture.mac"), installed: "1.0", expected: .available, latest: "2.0")
        await check(.npm("missing"), installed: "1.0", expected: .failed)
        await check(.npm("wrong"), installed: "1.0", expected: .failed)
        await check(.npm("broken"), installed: "1.0", expected: .failed)
        await check(.unsupported, installed: "1.0", expected: .unsupported)
        await check(.formula("jq"), installed: "development build", expected: .unsupported)
        await check(.appcast(URL(string: "https://example.com/appcast.xml")!, build: "6"),
                    installed: "1.0.0", expected: .available, latest: "1.1.0")
        await check(.appcast(URL(string: "https://example.com/appcast.xml")!, build: "7"),
                    installed: "1.1.0", expected: .current)
        await check(.appcast(URL(string: "https://example.com/hostile.xml")!, build: "6"),
                    installed: "1.0.0", expected: .failed)
        precondition(SoftwareUpdateService.compare("1.10", "1.9") == .orderedDescending)
        precondition(SoftwareUpdateService.compare("1.0", "1.0.0") == .orderedSame)
        precondition(SoftwareUpdateService.compare("1.0", "1.0-rc.1") == .orderedDescending)
        precondition(SoftwareUpdateService.compare("1.999999999999999999999999999", "1.0") == nil)
        let gitCrate = CommandLineTool(manager: .cargo, name: "ripgrep", version: "14.0", path: "/fixture/rg",
            bytes: 1, dependents: [], installedOnRequest: true, supportsPublicRegistryUpdates: false)
        precondition(SoftwareUpdateService.toolTarget(gitCrate).source == .unsupported)

        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Renamed.app")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let infoURL = root.appendingPathComponent("Contents/Info.plist")
        let info = ["CFBundleIdentifier": "com.todesktop.230313mzl4w4u92", "CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "6"]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: infoURL, options: .atomic)
        let app = UninstallApp(name: "Renamed", bundleID: info["CFBundleIdentifier"]!, source: "App", path: root.path, size: "1 KB")
        precondition(SoftwareUpdateService.appTarget(app).source == .cask("cursor"), "Use bundle identity instead of renamed filenames")
        try plist.write(to: infoURL, options: .atomic)
        precondition(SoftwareUpdateService.appTarget(app).source == .unsupported, "Discard a changed application snapshot")
        let english = L10nSoftwareUpdateTables.table(for: .en)
        for language in AppLanguage.allCases where language != .auto {
            let table = L10nSoftwareUpdateTables.table(for: language)
            precondition(Set(table.keys) == Set(english.keys) && table.values.allSatisfy { !$0.isEmpty })
            precondition(table["software.updates.available"]!.components(separatedBy: "%@").count == 2)
        }
        print("Software updates: package identity, numeric/revision/prerelease comparison, unknown/error states, compatible Sparkle builds, XML guards, app identity and translations passed")
        if CommandLine.arguments.contains("--network") {
            let live = SoftwareUpdateService()
            for source in [SoftwareUpdateService.Source.formula("jq"), .formula("openjdk@21"), .npm("typescript"), .pypi("ruff"), .crates("ripgrep"), .cask("cursor"), .appStore("com.crowdcafe.windowmagnet"),
                           .appcast(URL(string: "https://github.com/percentcola3/Nori/releases/latest/download/appcast-arm64.xml")!, build: "1")] {
                let result = await live.check(.init(id: "live", installed: "1.0", source: source))
                print("Live source \(source): \(result.state), latest=\(result.latest ?? "unknown")")
                fflush(stdout)
                precondition(result.state == .available || result.state == .current, "Live public version source failed")
            }
        }
    }
}
