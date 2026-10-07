import Foundation

struct SoftwareUpdateResult: Equatable, Sendable {
    enum State: Equatable, Sendable { case current, available, unsupported, failed }
    let installed: String
    var latest: String? = nil
    let state: State
    var source: String = ""
    var updatePage: URL? = nil
    var latestBuild: String? = nil
    var storeID: Int? = nil
}

actor SoftwareUpdateService {
    enum Source: Equatable, Sendable {
        case formula(String), cask(String), npm(String), pypi(String), crates(String)
        case appcast(URL, build: String), appStore(String), unsupported
    }
    struct Target: Equatable, Sendable {
        let id: String
        let installed: String
        let source: Source
    }
    typealias Fetch = @Sendable (URL) async throws -> Data
    private let fetch: Fetch
    private var cache: [URL: (Date, Data)] = [:]

    init(fetch: @escaping Fetch = { url in try await SoftwareUpdateService.request(url) }) { self.fetch = fetch }

    nonisolated static func appKey(_ app: UninstallApp) -> String {
        "app:" + app.id + ":" + app.appIdentity + ":" + app.infoIdentity
    }
    nonisolated static func toolKey(_ tool: CommandLineTool) -> String {
        "cli:" + tool.id + ":" + tool.path + ":" + tool.version
    }

    nonisolated static func appTarget(_ app: UninstallApp, cask: String? = nil) -> Target {
        let id = appKey(app)
        guard DeletionPlan.identity(at: app.path + "/Contents/Info.plist") == app.infoIdentity,
              let data = boundedFile(app.path + "/Contents/Info.plist"),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              info["CFBundleIdentifier"] as? String == app.bundleID else {
            return .init(id: id, installed: "", source: .unsupported)
        }
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        if let feed = info["SUFeedURL"] as? String, let url = URL(string: feed), usableURL(url) {
            return .init(id: id, installed: version,
                         source: .appcast(url, build: info["CFBundleVersion"] as? String ?? version))
        }
        if FileManager.default.fileExists(atPath: app.path + "/Contents/_MASReceipt/receipt") {
            return .init(id: id, installed: version, source: .appStore(app.bundleID))
        }
        // Exact bundle IDs select the stable version directory, even when the
        // app was downloaded directly. Never infer a package from its filename.
        let knownCasks = ["com.todesktop.230313mzl4w4u92": "cursor", "com.google.Chrome": "google-chrome",
                          "com.microsoft.VSCode": "visual-studio-code", "com.docker.docker": "docker-desktop",
                          "org.mozilla.firefox": "firefox",
                          "com.tinyspeck.slackmacgap": "slack", "com.spotify.client": "spotify",
                          "org.videolan.vlc": "vlc", "com.microsoft.teams2": "microsoft-teams"]
        if let token = cask ?? knownCasks[app.bundleID], validPackage(token), !token.contains("/") {
            return .init(id: id, installed: version, source: .cask(token))
        }
        return .init(id: id, installed: version, source: .unsupported)
    }

    nonisolated static func toolTarget(_ tool: CommandLineTool) -> Target {
        let name = tool.updatePackageName ?? tool.name
        var source: Source = .unsupported
        if tool.supportsPublicRegistryUpdates, validPackage(name) {
            switch tool.manager {
            case .homebrew: source = .formula(name)
            case .npm, .pnpm: source = .npm(name)
            case .pipx, .uv: source = .pypi(name)
            case .cargo: source = .crates(name)
            case .local, .go: break
            }
        }
        return .init(id: toolKey(tool), installed: tool.version, source: source)
    }

    func check(_ target: Target) async -> SoftwareUpdateResult {
        guard target.source != .unsupported, Self.versionParts(target.installed) != nil else {
            return .init(installed: target.installed, state: .unsupported)
        }
        do {
            let latest: String
            let source: String
            var page: URL? = nil
            var storeID: Int? = nil
            switch target.source {
            case .formula(let name):
                let object = try await json("https://formulae.brew.sh/api/formula/\(Self.segment(name)).json")
                guard object["name"] as? String == name,
                      let stable = (object["versions"] as? [String: Any])?["stable"] as? String else { throw Failure.invalid }
                let revision = object["revision"] as? Int ?? 0
                latest = stable + (revision > 0 ? "_\(revision)" : "")
                source = "Homebrew"
            case .cask(let name):
                let object = try await json("https://formulae.brew.sh/api/cask/\(Self.segment(name)).json")
                guard object["token"] as? String == name, let version = object["version"] as? String else { throw Failure.invalid }
                latest = version.components(separatedBy: ",").first ?? version
                source = "Homebrew"
                if let homepage = object["homepage"] as? String, let url = URL(string: homepage), Self.usableURL(url) { page = url }
                if version.contains(","), Self.compare(latest, target.installed) == .orderedSame {
                    return .init(installed: target.installed, state: .unsupported, source: source)
                }
            case .npm(let name):
                let object = try await json("https://registry.npmjs.org/\(Self.segment(name))/latest")
                guard object["name"] as? String == name, let version = object["version"] as? String else { throw Failure.invalid }
                latest = version; source = "npm"
            case .pypi(let name):
                let object = try await json("https://pypi.org/pypi/\(Self.segment(name))/json")
                guard let info = object["info"] as? [String: Any], let actual = info["name"] as? String,
                      Self.pythonName(actual) == Self.pythonName(name), let version = info["version"] as? String else { throw Failure.invalid }
                latest = version; source = "PyPI"
            case .crates(let name):
                let object = try await json("https://crates.io/api/v1/crates/\(Self.segment(name))")
                guard let crate = object["crate"] as? [String: Any], crate["id"] as? String == name,
                      let version = crate["max_stable_version"] as? String else { throw Failure.invalid }
                latest = version; source = "crates.io"
            case .appStore(let bundleID):
                var components = URLComponents(string: "https://itunes.apple.com/lookup")!
                components.queryItems = [.init(name: "bundleId", value: bundleID), .init(name: "entity", value: "macSoftware")]
                let object = try await json(components.url!)
                guard let item = (object["results"] as? [[String: Any]])?.first(where: { $0["bundleId"] as? String == bundleID }),
                      let version = item["version"] as? String else { throw Failure.invalid }
                latest = version; source = "App Store"
                storeID = item["trackId"] as? Int
                if let id = storeID { page = URL(string: "macappstore://itunes.apple.com/app/id\(id)") }
            case .appcast(let url, let installedBuild):
                let data = try await payload(url)
                let items = try Self.feedItems(data)
                #if arch(arm64)
                let architecture = "arm64"
                #else
                let architecture = "x86_64"
                #endif
                let system = ProcessInfo.processInfo.operatingSystemVersion
                let macOS = "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
                let compatible = items.filter {
                    ($0.os.isEmpty || $0.os == "macos") && ($0.architecture.isEmpty || $0.architecture == architecture)
                        && ($0.minimumSystem.isEmpty || Self.compare($0.minimumSystem, macOS).map { $0 != .orderedDescending } == true)
                        && Self.stable($0.displayVersion.isEmpty ? $0.build : $0.displayVersion)
                }
                guard let item = compatible.filter({ Self.versionParts($0.build) != nil }).max(by: {
                    Self.compare($0.build, $1.build) == .orderedAscending
                }), let order = Self.compare(item.build, installedBuild) else { throw Failure.invalid }
                return .init(installed: target.installed, latest: item.displayVersion.isEmpty ? item.build : item.displayVersion,
                             state: order == .orderedDescending ? .available : .current, source: "Sparkle", latestBuild: item.build)
            case .unsupported: return .init(installed: target.installed, state: .unsupported)
            }
            guard Self.stable(latest), let order = Self.compare(latest, target.installed) else { throw Failure.invalid }
            return .init(installed: target.installed, latest: latest,
                         state: order == .orderedDescending ? .available : .current, source: source, updatePage: page, storeID: storeID)
        } catch {
            cache.removeAll()
            return .init(installed: target.installed, state: .failed)
        }
    }

    private enum Failure: Error { case invalid }
    private func json(_ address: String) async throws -> [String: Any] { try await json(URL(string: address)!) }
    private func json(_ url: URL) async throws -> [String: Any] {
        let data = try await payload(url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalid }
        return object
    }
    private func payload(_ url: URL) async throws -> Data {
        guard Self.usableURL(url), !Task.isCancelled else { throw Failure.invalid }
        if let (date, data) = cache[url], Date().timeIntervalSince(date) < 3600 { return data }
        let data = try await fetch(url)
        guard data.count <= Self.payloadLimit(url), !Task.isCancelled else { throw Failure.invalid }
        cache[url] = (Date(), data)
        return data
    }
    func clearCache() { cache.removeAll() }
    nonisolated static func request(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Nori-Version-Check/1.0", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 25
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        // PyPI includes the release history in its JSON metadata. Its official
        // endpoint needs a larger bound than third-party appcast feeds.
        if url.host == "pypi.org" {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.url?.host == "pypi.org", data.count <= payloadLimit(url) else { throw Failure.invalid }
            return data
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url.map(usableURL) == true, response.expectedContentLength <= 1_048_576 else { throw Failure.invalid }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1_048_576, !Task.isCancelled else { throw Failure.invalid }
            data.append(byte)
        }
        return data
    }
    nonisolated private static func usableURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil
    }
    nonisolated private static func payloadLimit(_ url: URL) -> Int {
        url.host == "pypi.org" ? 16_777_216 : 1_048_576
    }
    nonisolated private static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_."))) ?? ""
    }
    nonisolated private static func validPackage(_ value: String) -> Bool {
        value.range(of: #"^(?:@[A-Za-z0-9_.-]+/)?[A-Za-z0-9][A-Za-z0-9@_.+-]{0,127}$"#, options: .regularExpression) != nil
    }
    nonisolated private static func pythonName(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: #"[-_.]+"#, with: "-", options: .regularExpression)
    }
    nonisolated private static func boundedFile(_ path: String) -> Data? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber,
              size.intValue <= 1_048_576 else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// Version comparison is conservative: unfamiliar strings never mean current.
    nonisolated static func versionParts(_ value: String) -> [Int]? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(pattern: #"^v?([0-9]+(?:[._][0-9]+)*)(?:[-+].*)?$"#),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        let strings = value[range].split(whereSeparator: { $0 == "." || $0 == "_" })
        let parts = strings.compactMap { Int($0) }
        return parts.isEmpty || parts.count != strings.count ? nil : parts
    }
    nonisolated static func stable(_ value: String) -> Bool {
        versionParts(value) != nil && value.range(of: #"(?i)(alpha|beta|rc|preview|nightly|dev|[0-9](?:a|b)[0-9])"#, options: .regularExpression) == nil
    }
    nonisolated static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard let a = versionParts(lhs), let b = versionParts(rhs) else { return nil }
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0, right = index < b.count ? b[index] : 0
            if left != right { return left < right ? .orderedAscending : .orderedDescending }
        }
        if stable(lhs) != stable(rhs) { return stable(lhs) ? .orderedDescending : .orderedAscending }
        return .orderedSame
    }

    struct FeedItem {
        var build = "", displayVersion = "", minimumSystem = "", os = "", architecture = ""
    }
    private final class FeedParser: NSObject, XMLParserDelegate {
        var items: [FeedItem] = []
        var item: FeedItem?
        var field = "", text = ""
        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            let name = element.components(separatedBy: ":").last ?? element
            if name == "item" { item = FeedItem() }
            if name == "enclosure", var current = item {
                current.build = attributes["sparkle:version"] ?? current.build
                current.displayVersion = attributes["sparkle:shortVersionString"] ?? current.displayVersion
                current.os = attributes["sparkle:os"] ?? ""
                current.architecture = attributes["sparkle:arch"] ?? ""
                item = current
            }
            field = name; text = ""
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            let name = element.components(separatedBy: ":").last ?? element
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if name == field, !value.isEmpty {
                if name == "version" { item?.build = value }
                if name == "shortVersionString" { item?.displayVersion = value }
                if name == "minimumSystemVersion" { item?.minimumSystem = value }
            }
            if name == "item", let item { items.append(item); self.item = nil }
            field = ""; text = ""
        }
    }
    nonisolated static func feedItems(_ data: Data) throws -> [FeedItem] {
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8),
              !text.uppercased().contains("<!DOCTYPE"), !text.uppercased().contains("<!ENTITY") else { throw Failure.invalid }
        let delegate = FeedParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.items.isEmpty else { throw Failure.invalid }
        return delegate.items
    }
}
