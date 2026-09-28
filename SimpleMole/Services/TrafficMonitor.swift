import AppKit
import Combine
import Foundation

/// 系统流量监控：按应用累计 nettop 字节差分，并展示 lsof 连接与路由。
@MainActor
final class TrafficMonitorStore: ObservableObject {
    @Published private(set) var rows: [TrafficAppRow] = []
    @Published private(set) var endpointsByApp: [String: [TrafficEndpointRow]] = [:]
    @Published var sortOrder: TrafficSortOrder = .appTotal {
        didSet { rows = sortOrder.sorted(rows) }
    }
    @Published private(set) var sessionStartedAt = Date()
    @Published private(set) var historySaveFailed = false

    // 顶部汇总卡（会话 = 自上次重置累计）。
    @Published private(set) var tunnelDown: UInt64 = 0
    @Published private(set) var tunnelUp: UInt64 = 0
    @Published private(set) var physicalDown: UInt64 = 0
    @Published private(set) var physicalUp: UInt64 = 0
    @Published private(set) var sampling = false
    @Published private(set) var lastSample: Date?
    /// nettop 采样是否仍可用（失败时保留旧数据并提示）。
    @Published private(set) var bytesSourceAvailable = true

    /// 开启后即使不打开流量页也持续采样（后台记账用）。
    @Published var persistentMonitoring: Bool {
        didSet { defaults.set(persistentMonitoring, forKey: Self.persistentKey); syncPersistentTimer() }
    }
    private static let persistentKey = "SMNetMonPersistent"

    private let defaults: UserDefaults
    private var inFlight = false
    private var persistentTimer: Timer?
    private var pageVisible = false
    private var generation = 0
    private let historyURL: URL
    private let historyQueue = DispatchQueue(label: "com.nori.traffic-history", qos: .utility)
    private var lastHistorySave = Date.distantPast

    private struct AppAccumulator: Codable, Sendable {
        var down: UInt64 = 0
        var up: UInt64 = 0
        var rateDown: Double = 0
        var rateUp: Double = 0
        var name: String
        var bundleIdentifier: String?
        var representativePID: Int32 = 0
        var seen: Date = .distantPast
    }

    private var appTotals: [String: AppAccumulator] = [:]
    private var lastProcessBytes: [Int32: (inbound: UInt64, outbound: UInt64)] = [:]
    private var lastSampleTime: Date?
    private var routeCache: [String: (interface: String, expires: Date)] = [:]
    private var lastBytesSampleTime: Date?
    private var lastProcessNames: [Int32: String] = [:]
    private var lastInterfaceCounters: [String: (inbound: UInt64, outbound: UInt64)] = [:]
    private var currentConnectionCounts: [String: Int] = [:]
    private var bundleIdentities: [String: (key: String, name: String, bundleIdentifier: String?)] = [:]
    private var workspaceApps: [Int32: (bundleURL: URL, bundleIdentifier: String?,
                                        name: String)] = [:]
    private var processParents: [Int32: (ppid: Int32, comm: String, args: String)] = [:]
    /// appKey → 展示名。
    private var appDisplayNames: [String: String] = [:]

    init(defaults: UserDefaults = .standard, historyURL: URL? = nil) {
        self.defaults = defaults
        self.historyURL = historyURL ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Nori/traffic-monitor-session.json")
        persistentMonitoring = defaults.bool(forKey: Self.persistentKey)
        restoreHistory()
        if persistentMonitoring { syncPersistentTimer() }
    }

    // MARK: - 公共入口

    /// 由中央定时器（流量页可见时）驱动的一次采样。
    func tick() {
        guard !inFlight else { return }
        inFlight = true
        Task { [weak self] in
            await self?.sample()
            self?.inFlight = false
        }
    }

    func setPageVisible(_ visible: Bool) {
        pageVisible = visible
        syncPersistentTimer()
        if visible { tick() }
        else { saveHistory(force: true) }
    }

    /// Reset counters and baselines together; an already running sample may not
    /// publish pre-reset observations into the new session.
    func resetSession() {
        generation += 1
        sessionStartedAt = Date()
        appTotals.removeAll()
        lastProcessBytes.removeAll()
        lastProcessNames.removeAll()
        lastInterfaceCounters.removeAll()
        routeCache.removeAll()
        currentConnectionCounts.removeAll()
        lastSampleTime = nil
        lastBytesSampleTime = nil
        tunnelDown = 0; tunnelUp = 0
        physicalDown = 0; physicalUp = 0
        rows = []
        endpointsByApp = [:]
        saveHistory(force: true)
    }

    // MARK: - 采样

    private func sample() async {
        sampling = true
        defer { sampling = false }
        let sampleGeneration = generation
        async let processesResult = MoleEngine.shared.runRuntime("processes", timeout: 10)
        async let byteSnapshot = MoleEngine.shared.runBridge("bin/app_netmon.sh", arguments: ["bytes"], timeout: 20)
        async let flowSnapshot = MoleEngine.shared.runBridge("bin/app_netmon.sh", arguments: ["flows"], timeout: 15)
        let (processes, bytesResult, flowsResult) = await (processesResult, byteSnapshot, flowSnapshot)
        guard sampleGeneration == generation else { return }
        if processes.succeeded { refreshProcessContext(processes.output) }
        let now = Date()
        let elapsed = lastSampleTime.map { max(now.timeIntervalSince($0), 0.001) } ?? 0
        let bytesElapsed = lastBytesSampleTime.map { max(now.timeIntervalSince($0), 0.001) } ?? 0
        var pidDeltas: [Int32: (inbound: UInt64, outbound: UInt64)] = [:]
        if bytesResult.succeeded {
            let samples = Parsers.netmonProcessSamples(bytesResult.output)
            bytesSourceAvailable = !samples.isEmpty
            if !samples.isEmpty {
                var current: [Int32: (inbound: UInt64, outbound: UInt64)] = [:]
                var names: [Int32: String] = [:]
                for row in samples {
                    current[row.pid] = (row.bytesIn, row.bytesOut)
                    names[row.pid] = row.command
                    guard let previous = lastProcessBytes[row.pid], lastProcessNames[row.pid] == row.command else { continue }
                    let down = row.bytesIn >= previous.inbound ? row.bytesIn - previous.inbound : 0
                    let up = row.bytesOut >= previous.outbound ? row.bytesOut - previous.outbound : 0
                    pidDeltas[row.pid] = (down, up)
                }
                lastProcessBytes = current
                lastProcessNames = names
                lastBytesSampleTime = now
            }
        } else {
            bytesSourceAvailable = false
        }
        let flows = flowsResult.succeeded ? Parsers.netmonFlows(flowsResult.output) : []
        await sampleRoutes(for: flows, generation: sampleGeneration)
        guard sampleGeneration == generation else { return }
        sampleInterfaces(elapsed: elapsed)
        lastSampleTime = now
        accumulate(pidDeltas: pidDeltas, elapsed: bytesElapsed, flows: flows, samplesText: bytesResult.output)
        rebuildRows()
        lastSample = Date()
        saveHistory()
    }

    /// 为尚无路由缓存的远端地址批量查一次出口接口。
    private func sampleRoutes(for flows: [NetmonFlow], generation sampleGeneration: Int) async {
        let now = Date()
        routeCache = routeCache.filter { $0.value.expires > now }
        var missing: [String] = []
        for flow in flows {
            let host = TrafficAttribution.remoteHost(flow.remote)
            guard TrafficAttribution.isRoutableAddress(host), routeCache[host] == nil,
                  !missing.contains(host) else { continue }
            missing.append(host)
            if missing.count >= 40 { break }
        }
        guard !missing.isEmpty,
              let script = MoleEngine.shared.resourceURL("bin/app_netmon.sh") else { return }
        let stdinData = Data((missing.joined(separator: "\n") + "\n").utf8)
        let result = await MoleEngine.shared.run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [script.path, "routes"],
            environment: MoleEngine.shared.standardEnvironment(),
            currentDirectory: MoleEngine.shared.resourcesURL,
            stdinData: stdinData,
            timeout: 30)
        guard result.succeeded, sampleGeneration == generation else { return }
        for route in Parsers.netmonRoutes(result.output) {
            routeCache[route.address] = (route.interface, Date().addingTimeInterval(5))
        }
    }

    /// 接口级差分用于交叉参考；不同接口可能承载同一批数据，不相加。
    private func sampleInterfaces(elapsed: TimeInterval) {
        let counters = SystemMetrics.interfaceCounters()
        guard elapsed > 0, !lastInterfaceCounters.isEmpty else {
            lastInterfaceCounters = counters
            return
        }
        for (name, counter) in counters {
            guard let previous = lastInterfaceCounters[name] else { continue }
            let deltaIn = counter.inbound >= previous.inbound
                ? counter.inbound - previous.inbound : 0
            let deltaOut = counter.outbound >= previous.outbound
                ? counter.outbound - previous.outbound : 0
            if name.hasPrefix("utun") {
                tunnelDown += deltaIn
                tunnelUp += deltaOut
            } else if name.hasPrefix("en") || name.hasPrefix("bridge") {
                physicalDown += deltaIn
                physicalUp += deltaOut
            }
        }
        lastInterfaceCounters = counters
    }

    // MARK: - 归因

    private func refreshProcessContext(_ text: String) {
        var apps: [Int32: (URL, String?, String)] = [:]
        for application in NSWorkspace.shared.runningApplications where !application.isTerminated {
            let pid = application.processIdentifier
            guard pid > 0, let bundleURL = application.bundleURL else { continue }
            apps[pid] = (bundleURL,
                         application.bundleIdentifier,
                         application.localizedName ?? bundleURL.lastPathComponent)
        }
        workspaceApps = apps

        var parents: [Int32: (Int32, String, String)] = [:]
        for line in text.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 10,
                  let pid = Int32(parts[0]), let ppid = Int32(parts[1]), pid > 0 else { continue }
            parents[pid] = (ppid, parts[8], parts[9...].joined(separator: "\t"))
        }
        processParents = parents
        for (_, app) in apps {
            _ = identityForBundle(app.0, preferredName: app.2, preferredIdentifier: app.1)
        }
    }

    /// Aggregate browser/Electron helpers into the outer app, consistently for
    /// NSWorkspace, executable paths and parent processes.
    private func identityForBundle(_ url: URL, preferredName: String? = nil,
                                   preferredIdentifier: String? = nil)
        -> (key: String, name: String, bundleIdentifier: String?) {
        let outer = TrafficAttribution.applicationURL(in: url.path) ?? url.standardizedFileURL
        if let cached = bundleIdentities[outer.path] { return cached }
        let bundle = Bundle(url: outer)
        let identifier = bundle?.bundleIdentifier ?? (outer == url ? preferredIdentifier : nil)
        let name = (outer == url ? preferredName : nil)
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? outer.deletingPathExtension().lastPathComponent
        let key = identifier.map { "app:\($0)" } ?? "app-path:\(outer.path)"
        let identity = (key, name, identifier)
        bundleIdentities[outer.path] = identity
        appDisplayNames[key] = name
        return identity
    }

    private func identityFromPath(_ path: String) -> (key: String, name: String, bundleIdentifier: String?)? {
        guard let url = TrafficAttribution.applicationURL(in: path) else { return nil }
        return identityForBundle(url)
    }

    private func identityFromProcess(_ record: (ppid: Int32, comm: String, args: String))
        -> (key: String, name: String, bundleIdentifier: String?)? {
        if let identity = identityFromPath(record.comm) { return identity }
        // app_runtime's whitespace-delimited ps bridge can put the tail of a
        // spaced executable path into args. Reconstruct that leading path only
        // when it resolves to an actual app directory.
        if let url = TrafficAttribution.applicationURL(in: record.comm + " " + record.args),
           FileManager.default.fileExists(atPath: url.path) {
            return identityForBundle(url)
        }
        return nil
    }

    private func appIdentity(pid: Int32, commFallback: String?)
        -> (key: String, name: String, bundleIdentifier: String?) {
        if let app = workspaceApps[pid] {
            return identityForBundle(app.bundleURL, preferredName: app.name, preferredIdentifier: app.bundleIdentifier)
        }
        if let record = processParents[pid], let identity = identityFromProcess(record) { return identity }
        var current = processParents[pid]?.ppid ?? 0
        var visited: Set<Int32> = [pid]
        while current > 1, visited.count < 10, visited.insert(current).inserted {
            if let app = workspaceApps[current] {
                return identityForBundle(app.bundleURL, preferredName: app.name, preferredIdentifier: app.bundleIdentifier)
            }
            if let record = processParents[current], let identity = identityFromProcess(record) { return identity }
            current = processParents[current]?.ppid ?? 0
        }
        let fallback = commFallback ?? processParents[pid]?.comm ?? "process"
        let name = (fallback as NSString).lastPathComponent
        let key = "comm:\(name)"
        appDisplayNames[key] = name
        return (key, name, nil)
    }

    // MARK: - 累计与发布

    private func accumulate(pidDeltas: [Int32: (inbound: UInt64, outbound: UInt64)],
                            elapsed: TimeInterval,
                            flows: [NetmonFlow],
                            samplesText: String) {
        let samples = Parsers.netmonProcessSamples(samplesText)
        var commByPID: [Int32: String] = [:]
        for sampleRow in samples { commByPID[sampleRow.pid] = sampleRow.command }

        for (pid, delta) in pidDeltas {
            let identity = appIdentity(pid: pid, commFallback: commByPID[pid])
            var accumulator = appTotals[identity.key]
                ?? AppAccumulator(name: identity.name,
                                  bundleIdentifier: identity.bundleIdentifier)
            accumulator.down += delta.inbound
            accumulator.up += delta.outbound
            accumulator.name = identity.name
            accumulator.bundleIdentifier = identity.bundleIdentifier
            accumulator.representativePID = pid
            accumulator.seen = Date()
            appTotals[identity.key] = accumulator
        }
        if elapsed > 0 {
            for key in Array(appTotals.keys) {
                appTotals[key]?.rateDown = 0
                appTotals[key]?.rateUp = 0
            }
            for (pid, delta) in pidDeltas {
                let identity = appIdentity(pid: pid, commFallback: commByPID[pid])
                appTotals[identity.key]?.rateDown += Double(delta.inbound) / elapsed
                appTotals[identity.key]?.rateUp += Double(delta.outbound) / elapsed
            }
        }

        rebuildEndpoints(flows: flows)
    }

    private func rebuildEndpoints(flows: [NetmonFlow]) {
        var endpoints: [String: [TrafficEndpointRow]] = [:]
        var flowCounts: [String: Int] = [:]
        for flow in flows {
            let identity = appIdentity(pid: flow.pid, commFallback: flow.command)
            flowCounts[identity.key, default: 0] += 1
            let kind = exitKind(remote: flow.remote)
            let row = TrafficEndpointRow(appKey: identity.key, remote: flow.remote,
                proto: flow.proto, kind: kind, activeConnections: 1)
            if let index = endpoints[identity.key]?.firstIndex(where: { $0.id == row.id }) {
                endpoints[identity.key]?[index].activeConnections += 1
            } else {
                endpoints[identity.key, default: []].append(row)
            }
        }
        currentConnectionCounts = flowCounts
        for (key, list) in endpoints {
            endpoints[key] = list.sorted {
                if $0.activeConnections != $1.activeConnections { return $0.activeConnections > $1.activeConnections }
                return $0.id < $1.id
            }
        }
        endpointsByApp = endpoints
    }

    private func exitKind(remote: String) -> TrafficExitKind {
        let cached = routeCache[TrafficAttribution.remoteHost(remote)]
        let interface = cached.flatMap { $0.expires > Date() ? $0.interface : nil }
        return TrafficAttribution.exitKind(remote: remote, interface: interface)
    }

    private func rebuildRows() {
        var built: [TrafficAppRow] = []
        let allKeys = Set(appTotals.keys).union(endpointsByApp.keys)
        for key in allKeys {
            let totals = appTotals[key]
            let endpointCount = currentConnectionCounts[key] ?? 0
            let kinds = TrafficExitKind.allCases.filter { kind in
                endpointsByApp[key]?.contains(where: { $0.kind == kind }) ?? false
            }
            let name = totals?.name ?? appDisplayNames[key] ?? String(key.dropFirst(key.hasPrefix("comm:") ? 5 : 4))
            built.append(TrafficAppRow(appKey: key, displayName: name,
                bundleIdentifier: totals?.bundleIdentifier,
                representativePID: totals?.representativePID ?? 0,
                sessionDown: totals?.down ?? 0, sessionUp: totals?.up ?? 0,
                rateDown: totals?.rateDown ?? 0, rateUp: totals?.rateUp ?? 0,
                connectionCount: endpointCount, exitKinds: kinds))
        }
        rows = sortOrder.sorted(built)
    }

    // MARK: - Session persistence

    private struct History: Codable, Sendable {
        var version = 2
        var startedAt: Date
        var appTotals: [String: AppAccumulator]
        var names: [String: String]
        var tunnelDown: UInt64
        var tunnelUp: UInt64
        var physicalDown: UInt64
        var physicalUp: UInt64
    }

    private func restoreHistory() {
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return }
        do {
            let data = try Data(contentsOf: historyURL)
            let history = try JSONDecoder().decode(History.self, from: data)
            guard history.version == 2 else { return }
            sessionStartedAt = history.startedAt
            appTotals = history.appTotals.mapValues { value in
                var value = value
                value.rateDown = 0; value.rateUp = 0; value.representativePID = 0
                return value
            }
            appDisplayNames = history.names
            tunnelDown = history.tunnelDown; tunnelUp = history.tunnelUp
            physicalDown = history.physicalDown; physicalUp = history.physicalUp
            rebuildEndpoints(flows: [])
            rebuildRows()
        } catch {
            historySaveFailed = true
        }
    }

    private func saveHistory(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastHistorySave) >= 5 else { return }
        lastHistorySave = Date()
        let snapshot = History(startedAt: sessionStartedAt, appTotals: appTotals,
            names: appDisplayNames, tunnelDown: tunnelDown, tunnelUp: tunnelUp,
            physicalDown: physicalDown, physicalUp: physicalUp)
        let url = historyURL
        historyQueue.async { [weak self] in
            let failed: Bool
            do {
                let data = try JSONEncoder().encode(snapshot)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                failed = false
            } catch { failed = true }
            Task { @MainActor [weak self] in self?.historySaveFailed = failed }
        }
    }

    func flushHistoryForTermination() {
        persistentTimer?.invalidate()
        persistentTimer = nil
        saveHistory(force: true)
        historyQueue.sync {}
    }

    // MARK: - 工具

    private func syncPersistentTimer() {
        if persistentMonitoring || pageVisible, persistentTimer == nil {
            persistentTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) {
                [weak self] _ in
                Task { @MainActor [weak self] in self?.tick() }
            }
        } else if !persistentMonitoring && !pageVisible, let timer = persistentTimer {
            timer.invalidate()
            persistentTimer = nil
        }
    }
}
