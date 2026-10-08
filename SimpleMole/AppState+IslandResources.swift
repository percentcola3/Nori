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
            if !app.isTerminated {
                presentTaskFailure(message: islandResourceStatus[resource] ?? "", details: [row.name],
                    detailsAreLocalized: true)
            }
            _ = await sampleIslandProcesses()
            resampleAfterMutation()
        }
    }

    func cleanIslandResource(_ resource: IslandResource) {
        guard islandCleaningResource == nil, islandClosingPIDs.isEmpty else {
            islandResourceStatus[resource] = L10n.shared.t("island.clean.busy")
            return
        }
        islandCleaningResource = resource
        islandResourceStatus[resource] = L10n.shared.t("island.clean.working")
        let running = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        let applicationPIDs = Set(running.map(\.processIdentifier))
        let home = NSHomeDirectory()
        let inUseRoots = running.flatMap { app -> [String] in
            var roots = app.bundleURL.map { [$0.path] } ?? []
            for owner in [app.localizedName, app.bundleIdentifier, app.bundleURL?.deletingPathExtension().lastPathComponent]
                .compactMap({ $0 }) where !owner.isEmpty {
                roots += [home + "/Library/Application Support/" + owner, home + "/Library/Caches/" + owner]
            }
            return roots
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let bundlePath = Bundle.main.bundlePath
        Task {
            let residuals = await Task.detached(priority: .userInitiated) { () -> [(IslandResourcePolicy.Residual, [Int32: ProcessIdentity])] in
                let sampler = ProcessSampler()
                let first = sampler.sample()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let current = sampler.sample()
                let previous = Dictionary(first.map { ($0.identity, $0.cpuPercent) }, uniquingKeysWith: { a, _ in a })
                let managed = IslandResourcePolicy.managedPIDs(fromLaunchctlList:
                    SystemMetrics.commandOutput("/bin/launchctl", arguments: ["list"]) ?? "")
                let facts = current.map { sample in
                    IslandResourcePolicy.ProcessFacts(pid: sample.pid, ppid: sample.ppid, uid: sample.uid,
                        name: sample.name, path: sample.path, cpu: sample.cpuPercent,
                        previousCPU: previous[sample.identity] ?? 0, residentBytes: sample.residentBytes,
                        elapsed: sample.elapsed, isZombie: sample.isZombie, isExiting: sample.isExiting)
                }
                let identities = Dictionary(current.map { ($0.pid, $0.identity) }, uniquingKeysWith: { a, _ in a })
                return IslandResourcePolicy.residuals(resource: resource, processes: facts,
                    applicationPIDs: applicationPIDs, managedPIDs: managed, ownPID: ownPID,
                    uid: getuid(), ownBundlePath: bundlePath, inUseRoots: inUseRoots).map { ($0, identities) }
            }.value
            if resource == .memory { MosaicCache.shared.clear() }
            var ended = 0, freed: UInt64 = 0
            var remaining: [String] = []
            for (residual, identities) in residuals {
                var allGone = true
                for pid in residual.pids {
                    guard let identity = identities[pid] else { continue }
                    if !(await ProcessTerminator.terminateThenKill(identity, grace: 1.5)) { allGone = false }
                }
                if allGone { ended += 1; freed += residual.residentBytes } else { remaining.append(residual.name) }
            }
            let result = residuals.isEmpty
                ? L10n.shared.t("island.clean.none")
                : resource == .memory
                    ? L10n.shared.tf("island.clean.result.memory", ended, ByteFormat.format(freed), remaining.count)
                    : L10n.shared.tf("island.clean.result", ended, remaining.count)
            islandResourceStatus[resource] = result
            if !remaining.isEmpty {
                presentTaskFailure(message: result, details: remaining, detailsAreLocalized: true)
            }
            _ = await sampleIslandProcesses()
            // Completion is observed by the rings: publish it only after the
            // post-cleanup sample, so the reveal uses current occupancy.
            islandCleaningResource = nil
            resampleAfterMutation()
        }
    }
}
