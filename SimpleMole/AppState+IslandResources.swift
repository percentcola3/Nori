import AppKit
import Darwin
import Foundation

extension AppState {
    func refreshIslandProcesses(force: Bool = false) {
        guard !islandSampling, islandCleaningResource == nil,
              force || Date().timeIntervalSince(lastIslandSample) >= 2 else { return }
        Task { _ = await sampleIslandProcesses() }
    }

    /// 独立 CPU 基线，避免进程页抢用采样周期。
    private func sampleIslandProcesses() async -> [ProcessRow] {
        while islandSampling { try? await Task.sleep(nanoseconds: 50_000_000) }
        islandSampling = true
        defer { islandSampling = false }
        // 连续操作也保留足够的 CPU 时间差，避免紧接上一帧采样把排行刷新为全零。
        let remaining = 0.35 - Date().timeIntervalSince(lastIslandSample)
        if remaining > 0 {
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let applications: [(pid: Int32, name: String, startIdentity: String)] =
            NSWorkspace.shared.runningApplications.compactMap { app in
                guard !app.isTerminated, app.processIdentifier != ownPID,
                      app.activationPolicy == .regular,
                      let identity = RuntimeStore.nativeStartIdentity(for: app) else { return nil }
                return (app.processIdentifier, app.localizedName ?? "", identity)
            }
        let sampler = islandProcessSampler
        let needsBaseline = islandProcessRows.isEmpty
        let groups = await Task.detached(priority: .utility) {
            var samples = sampler.sample()
            if needsBaseline {
                try? await Task.sleep(nanoseconds: 350_000_000)
                samples = sampler.sample()
            }
            return ProcessAggregator.groups(samples: samples, applications: applications,
                                             ownPID: ownPID, detail: { "PID \($0)" },
                                             childDetail: { $0.name })
        }.value
        islandProcessRows = groups.map(\.app)
        topMemoryApps = Array(ProcessAggregator.sorted(groups, by: .memory).prefix(5).map(\.app))
        topCPUApps = Array(ProcessAggregator.sorted(groups, by: .cpu).prefix(5).map(\.app))
        lastIslandSample = Date()
        return islandProcessRows
    }

    private func islandApplication(for row: ProcessRow) -> NSRunningApplication? {
        guard row.uid == getuid(), row.pid > 1,
              row.pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: row.pid), !app.isTerminated,
              app.activationPolicy == .regular,
              RuntimeStore.nativeStartIdentity(for: app) == row.startIdentity,
              let path = app.executableURL?.path, !ProcessAggregator.isProtectedPath(path),
              !(app.bundleIdentifier ?? "").hasPrefix("com.nori.") else { return nil }
        return app
    }

    func canCloseIslandApp(_ row: ProcessRow) -> Bool { islandApplication(for: row) != nil }

    /// 单个关闭采用正常退出，应用可以显示保存提示；不会升级为强杀。
    func closeIslandApp(_ row: ProcessRow, resource: IslandResource) {
        guard islandCleaningResource == nil, !islandClosingPIDs.contains(row.pid),
              let app = islandApplication(for: row) else { return }
        islandClosingPIDs.insert(row.pid)
        islandResourceStatus[resource] = L10n.shared.tf("island.quit.request", row.name)
        Task {
            let requested = app.terminate()
            if requested {
                for _ in 0..<25 where !app.isTerminated {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            islandResourceStatus[resource] = L10n.shared.tf(
                app.isTerminated ? "island.quit.done" : "island.quit.pending", row.name)
            islandClosingPIDs.remove(row.pid)
            _ = await sampleIslandProcesses()
            resampleAfterMutation()
        }
    }

    func cleanIslandResource(_ resource: IslandResource) {
        guard islandCleaningResource == nil, islandClosingPIDs.isEmpty, !isBusy else {
            islandResourceStatus[resource] = L10n.shared.t("island.clean.busy")
            return
        }
        islandCleaningResource = resource
        islandResourceStatus[resource] = L10n.shared.t("island.clean.working")
        Task {
            let first = await sampleIslandProcesses()
            let previousCPU = Dictionary(first.map { ($0.signalToken, $0.cpu) }, uniquingKeysWith: { a, _ in a })
            try? await Task.sleep(nanoseconds: 600_000_000)
            let current = await sampleIslandProcesses()
            let sorted = current.sorted {
                resource == .cpu ? $0.cpu > $1.cpu : $0.memBytes > $1.memBytes
            }
            var requested: [NSRunningApplication] = []
            var attempted = 0
            for row in sorted {
                guard attempted < 3, let app = islandApplication(for: row),
                      IslandResourcePolicy.isEligible(
                        resource: resource, cpu: row.cpu, previousCPU: previousCPU[row.signalToken] ?? 0,
                        memoryBytes: row.memBytes, isHidden: app.isHidden, isActive: app.isActive,
                        isRegular: app.activationPolicy == .regular, isSameUser: row.uid == getuid(),
                        isOwnApp: row.pid == ProcessInfo.processInfo.processIdentifier,
                        executablePath: app.executableURL?.path ?? "", elapsed: row.elapsed) else { continue }
                attempted += 1
                if app.terminate() { requested.append(app) }
            }
            var cacheBytes = 0
            if resource == .memory {
                MosaicCache.shared.clear()
                URLCache.shared.removeAllCachedResponses()
                cacheBytes = malloc_zone_pressure_relief(nil, 0)
            }
            for _ in 0..<25 where requested.contains(where: { !$0.isTerminated }) {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            let closed = requested.filter(\.isTerminated).count
            let result: String
            if attempted > 0 {
                result = L10n.shared.tf("island.clean.result", closed, attempted - closed)
            } else {
                result = L10n.shared.t("island.clean.none")
            }
            islandResourceStatus[resource] = result + (resource == .memory
                ? " " + (cacheBytes > 0
                    ? L10n.shared.tf("island.clean.cache", ByteFormat.format(UInt64(cacheBytes)))
                    : L10n.shared.t("island.clean.cache.empty")) : "")
            _ = await sampleIslandProcesses()
            // Completion is observed by the rings: publish it only after the
            // post-cleanup sample, so the reveal uses current occupancy.
            islandCleaningResource = nil
            resampleAfterMutation()
        }
    }
}
