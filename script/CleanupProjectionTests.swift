import Foundation

private actor CompletionGate {
    var continuation: CheckedContinuation<Void, Never>?
    var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

@main
struct CleanupProjectionTests {
    @MainActor static var checks = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(condition(), message)
    }
    static let home = "/nori-synthetic/home"

    static func category(_ paths: [String], name: String = "Fixture", source: CleanupSource = .core,
                         guardKind: CleanupActivityGuard = .openFile) -> CleanupCategory {
        CleanupCategory(name: name, paths: paths, bytes: UInt64(paths.count),
            pathBytes: Dictionary(paths.map { ($0, UInt64(1)) }, uniquingKeysWith: { a, _ in a }),
            pathIdentities: [:], selected: false, source: source, risk: .safe,
            disposal: .permanentDelete, applyRoute: .genericTrash, activityGuard: guardKind)
    }
    static func rule(_ root: String, extra: [String] = []) -> AutoCleanupRule {
        AutoCleanupRule(directory: root, additionalRoots: extra.map { .init(directory: $0) },
                        policy: .retentionDays, sizeLimitBytes: 0, retentionDays: 7)
    }
    static func legacy(_ directory: String, rules: [AutoCleanupRule]) -> UUID? {
        let path = CleanupCoverageIndex.normalized(directory)
        for rule in rules {
            for directory in rule.directories {
                let root = CleanupCoverageIndex.normalized(directory)
                if path == root || path.hasPrefix(root + "/") { return rule.id }
            }
        }
        return nil
    }

    @MainActor static func semantics() {
        let parent = rule("/Synthetic/A", extra: ["/Synthetic/é", "/Synthetic/🙂"])
        let child = rule("/Synthetic/A/B")
        let roots = [parent, child]
        let index = CleanupCoverageIndex(rules: CleanupPresentation.ruleCatalog(roots))
        let queries = ["/Synthetic/A", "/Synthetic/A/B/x", "/Synthetic/A-other", "/Synthetic/A/../A/B/x",
                       "/Synthetic/A//B/x", "/Synthetic/é/x", "/Synthetic/e\u{301}/x", "/Synthetic/🙂/x",
                       "/Synthetic/A/\u{301}name", "/Synthetic/A/\u{200D}name", "/Synthetic/A/👨‍👩‍👧/x",
                       "./relative/../path", "/", "/Synthetic/A/B/../x"]
        for path in queries { check(index.ruleID(covering: path) == legacy(path, rules: roots), "coverage parity: " + path) }
        check(index.ruleID(covering: "/Synthetic/A/B/x") == parent.id, "first parent rule must precede deeper child")
        check(legacy("/Synthetic/A/\u{301}name", rules: roots) == nil, "combining mark must remain attached to slash")
        let reordered = CleanupCoverageIndex(rules: CleanupPresentation.ruleCatalog([child, parent]))
        check(reordered.ruleID(covering: "/Synthetic/A/B/x") == child.id, "reordered first rule precedence")
        let slash = [rule("/")]
        check(CleanupCoverageIndex(rules: CleanupPresentation.ruleCatalog(slash)).ruleID(covering: "/child")
              == legacy("/child", rules: slash), "malformed slash root parity")
        check(CleanupCoverageIndex().ruleID(covering: "/x") == nil, "removed rules must clear coverage")
        var stats = parent
        stats.isEnabled.toggle(); stats.lastRunAt = Date(); stats.lastCheckedAt = Date()
        stats.lastReclaimedBytes = 42; stats.executionCount = 19; stats.totalReclaimedBytes = 99
        check(CleanupPresentation.ruleCatalog([stats]) == CleanupPresentation.ruleCatalog([parent]), "stats/disabled state must not invalidate")
        check(CleanupCoverageIndex(rules: CleanupPresentation.ruleCatalog([stats])).ruleID(covering: "/Synthetic/A/x") == parent.id,
              "disabled rule is still configured")
        var cache = CleanupPresentationCache()
        check(!cache.updateRules(from: CleanupPresentation.ruleCatalog([parent]), to: CleanupPresentation.ruleCatalog([stats])), "statistics changed rules generation")
        check(cache.updateRules(from: CleanupPresentation.ruleCatalog(roots), to: CleanupPresentation.ruleCatalog([child, parent])), "rule reordering did not invalidate")
        check(cache.updateRules(from: CleanupPresentation.ruleCatalog(roots), to: []), "rule deletion did not invalidate")
        check(cache.updateRules(from: [], to: CleanupPresentation.ruleCatalog(roots)), "rule addition did not invalidate")
        stats.additionalRoots.append(.init(directory: "/another"))
        check(cache.updateRules(from: CleanupPresentation.ruleCatalog([parent]), to: CleanupPresentation.ruleCatalog([stats])), "additional root update did not invalidate")

        let trash = category([home + "/.Trash/old"])
        let developer = category([home + "/.cache/tool/old"], source: .developerCache)
        let messenger = category([home + "/Library/Caches/chat"], name: "WeChat")
        let system = category(["/private/var/log/old.1"])
        let input = [trash, developer, messenger, system]
        let result = CleanupPresentation.build(categories: input.map(CleanupPresentation.CategoryInput.init), index: index, home: home)!
        check(result.groups.last?.kind == .system, "system group must remain last")
        check(Set(result.groups.map(\.kind)) == [.trash, .developer, .messenger, .system], "group classification changed")
        check(result.categoryIndices[developer.id] == 1 && result.categoryIDs == input.map(\.id), "category identity/index projection")
        var changed = input
        changed[0].bytes = 25
        check(cache.updateInventory(from: input, to: changed), "bytes metadata did not invalidate")
        changed = input; changed[2].name = "Ordinary"
        check(cache.updateInventory(from: input, to: changed), "messenger name metadata did not invalidate")
        changed = input; changed[1].activityGuard = .appData
        check(cache.updateInventory(from: input, to: changed), "guard metadata did not invalidate")
        var ordering = category(["/Synthetic/a", "/Synthetic/b"])
        let token = ordering.pathOrderToken
        ordering.expanded.toggle(); ordering.setPathSelected("/Synthetic/a", selected: true)
        check(ordering.pathOrderToken == token, "selection/expand invalidated sort")
        ordering.paths[0] = "/Synthetic/c"
        check(ordering.pathOrderToken != token, "same-count replacement failed to invalidate sort")
        let next = ordering.pathOrderToken
        ordering.pathBytes["/Synthetic/b"] = 40
        check(ordering.pathOrderToken != next && ordering.pathsByDescendingSize.first == "/Synthetic/b", "size redistribution failed to invalidate sort")
        var calls = 0
        let cancelled = CleanupPresentation.build(categories: [trash].map(CleanupPresentation.CategoryInput.init), index: index,
            home: home, isCancelled: { calls += 1; return calls > 1 })
        check(cancelled == nil, "cancelled projection must not publish")
    }

    static func buildOffMain(_ input: [CleanupPresentation.CategoryInput], index: CleanupCoverageIndex) -> (CleanupPresentation, Bool) {
        let offMain = !Thread.isMainThread
        precondition(offMain, "large projection ran on the main thread")
        return (CleanupPresentation.build(categories: input, index: index, home: home)!, offMain)
    }

    @MainActor static func scale(_ count: Int) async {
        var inventory = [category((0..<count).map { home + "/.Trash/item-\($0)" })]
        let rules = [rule(home + "/unused", extra: [home + "/other1", home + "/other2", home + "/other3", home + "/other4", home + "/.Trash"])]
        let index = CleanupCoverageIndex(rules: CleanupPresentation.ruleCatalog(rules))
        var cache = CleanupPresentationCache()
        cache.updateInventory(from: [], to: inventory)
        let version = cache.version
        let input = inventory.map(CleanupPresentation.CategoryInput.init)
        var beats = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                beats += 1
                do { try await Task.sleep(nanoseconds: 1_000_000) } catch { return }
            }
        }
        let began = ProcessInfo.processInfo.systemUptime
        let (result, offMain) = await Task.detached(priority: .userInitiated) {
            buildOffMain(input, index: index)
        }.value
        let initial = ProcessInfo.processInfo.systemUptime - began
        heartbeat.cancel()
        check(offMain && beats > 0, "projection must leave MainActor free for heartbeat")
        check(cache.accept(result, version: version), "initial version rejected")
        check(result.coveredPaths[inventory[0].id]?.count == count && result.visitedPathCount == count, "large coverage lost paths")
        let start = ProcessInfo.processInfo.systemUptime
        for step in 0..<200 {
            let previous = inventory
            inventory[0].expanded.toggle()
            inventory[0].setPathSelected(inventory[0].paths[0], selected: step % 2 == 0)
            check(!cache.updateInventory(from: previous, to: inventory), "selection/expand rebuilt inventory")
            _ = cache.value.groups
            _ = cache.value.coveredPaths[inventory[0].id]?.count
            _ = cache.value.categoryIndices[inventory[0].id]
        }
        let subsequent = ProcessInfo.processInfo.systemUptime - start
        check(cache.version == version && cache.value.visitedPathCount == count, "200 interactions revisited inventory")
        let previous = inventory
        inventory[0].paths[0] = "/Synthetic/replaced-same-count"
        check(cache.updateInventory(from: previous, to: inventory), "same count/bytes replacement not detected")
        check(cache.value.groups.isEmpty && cache.version.inventory != version.inventory, "invalidated inventory kept stale view")
        let updated = CleanupPresentation.build(categories: inventory.map(CleanupPresentation.CategoryInput.init), index: index, home: home)!
        check(updated.coveredPaths[inventory[0].id]?.count == count - 1, "replacement coverage not refreshed")
        check(updated.groups.first?.kind == .cache, "replacement grouping not refreshed")
        print(String(format: "Presentation %d paths: initial=%.4fs, 200 selection/expand+input checks+cache reads=%.6fs, heartbeat=%d, visits=%d", count, initial, subsequent, beats, result.visitedPathCount))
    }

    @MainActor static func generationRace() async {
        var cache = CleanupPresentationCache()
        let old = category([home + "/.Trash/old"])
        cache.updateInventory(from: [], to: [old])
        let first = cache.version
        let lateInput = [CleanupPresentation.CategoryInput(old)]
        let gate = CompletionGate()
        let late = Task.detached { await gate.wait(); return CleanupPresentation.build(categories: lateInput, index: .init(), home: home)! }
        var new = old; new.paths = [home + "/.cache/new"]
        cache.updateInventory(from: [old], to: [new])
        let second = cache.version
        let result = CleanupPresentation.build(categories: [.init(new)], index: .init(), home: home)!
        check(cache.accept(result, version: second), "latest result rejected")
        await gate.open()
        let stale = await late.value
        check(!cache.accept(stale, version: first), "late old task overwrote newer inventory")
        check(cache.value.groups.first?.kind == .cache, "old task replaced current grouping")
        let olderRules = cache.version
        cache.updateRules(from: [], to: [.init(id: UUID(), directories: [home])])
        check(!cache.accept(result, version: olderRules), "old rule version overwrote latest rule catalog")
    }

    static func selectionOffMain(_ input: [CleanupSelectionPresentation.Input]) -> CleanupSelectionPresentation {
        precondition(!Thread.isMainThread, "partial selection sum ran on main thread")
        return CleanupSelectionPresentation.build(input)!
    }

    @MainActor static func partialSelectionScale(_ count: Int) async {
        var inventory = [category((0..<count).map { home + "/.Trash/partial-\($0)" })]
        inventory[0].selected = true
        var installer = category(["/nori-synthetic/installer.dmg"])
        installer.selected = true
        var selection = CleanupSelectionCache()
        var coverage = CleanupPresentationCache()
        coverage.updateInventory(from: [], to: inventory)
        let inventoryVersion = coverage.version
        let fullInput = CleanupSelectionPresentation.Input(inventory[0])
        check(fullInput.selectedPaths.isEmpty && fullInput.pathBytes.isEmpty, "full selection retained irrelevant large Set")
        selection.update(inventory.map(CleanupSelectionKey.init) + [CleanupSelectionKey(installer)])
        let full = CleanupSelectionPresentation.immediate([fullInput, .init(installer)])!
        check(full.visitedSelectedPaths == 0 && full.totalBytes == UInt64(count + 1), "all-selected scalar fast path")
        selection.accept(full, generation: selection.generation)

        let previous = inventory
        let oldToken = inventory[0].selectionToken
        let actionStart = ProcessInfo.processInfo.systemUptime
        inventory[0].setPathSelected(inventory[0].paths[0], selected: false)
        let actionTime = ProcessInfo.processInfo.systemUptime - actionStart
        check(inventory[0].selectionToken != oldToken, "selection mutation did not change scalar token")
        check(!coverage.updateInventory(from: previous, to: inventory), "large partial selection rebuilt coverage")
        check(selection.update(inventory.map(CleanupSelectionKey.init) + [CleanupSelectionKey(installer)]), "partial selection not invalidated")
        check(selection.value == nil, "pending selection exposed a false zero")
        let generation = selection.generation
        let input = inventory.map(CleanupSelectionPresentation.Input.init) + [.init(installer)]
        check(CleanupSelectionPresentation.immediate(input) == nil, "partial selection took a synchronous sum fallback")
        var beats = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                beats += 1
                do { try await Task.sleep(nanoseconds: 1_000_000) } catch { return }
            }
        }
        let began = ProcessInfo.processInfo.systemUptime
        let sizes = await Task.detached(priority: .userInitiated) { selectionOffMain(input) }.value
        let sumTime = ProcessInfo.processInfo.systemUptime - began
        heartbeat.cancel()
        check(beats > 0 && sizes.visitedSelectedPaths == count - 1, "large partial sum blocked main heartbeat")
        check(selection.accept(sizes, generation: generation), "current selection result rejected")
        check(sizes.bytesByCategory[inventory[0].id] == UInt64(count - 1), "partial row bytes mismatch")
        check(sizes.totalBytes == UInt64(count), "footer omitted installer or partial bytes")

        let renderStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<200 {
            let previous = inventory
            inventory[0].expanded.toggle()
            check(!selection.update(inventory.map(CleanupSelectionKey.init) + [CleanupSelectionKey(installer)]), "render/expand invalidated selection sum")
            check(!coverage.updateInventory(from: previous, to: inventory), "render/expand invalidated coverage")
            check(selection.value?.bytesByCategory[inventory[0].id] == UInt64(count - 1), "row cache became stale")
            check(selection.value?.totalBytes == UInt64(count), "footer cache became stale")
        }
        let renderTime = ProcessInfo.processInfo.systemUptime - renderStart
        check(selection.generation == generation && selection.value?.visitedSelectedPaths == count - 1,
              "200 render reads repeated selection sum")
        check(coverage.version == inventoryVersion, "selection affected inventory generation")

        let gate = CompletionGate()
        let late = Task.detached { await gate.wait(); return selectionOffMain(input) }
        inventory[0].selected = false
        selection.update(inventory.map(CleanupSelectionKey.init) + [CleanupSelectionKey(installer)])
        let latest = CleanupSelectionPresentation.immediate(inventory.map(CleanupSelectionPresentation.Input.init) + [.init(installer)])!
        selection.accept(latest, generation: selection.generation)
        await gate.open()
        let stale = await late.value
        check(!selection.accept(stale, generation: generation), "late old selection task overwrote new selection")
        check(selection.value?.totalBytes == 1, "old partial bytes replaced current installer-only total")
        var cancellations = 0
        check(CleanupSelectionPresentation.build(input, isCancelled: { cancellations += 1; return cancellations > 2 }) == nil,
              "cancelled selection sum published partial result")
        var small = category(["/nori-synthetic/a", "/nori-synthetic/b"])
        small.setPathSelected("/nori-synthetic/a", selected: true)
        let originalKey = CleanupSelectionKey(small)
        small.pathBytes["/nori-synthetic/a"] = 9
        check(CleanupSelectionKey(small) != originalKey, "redistributed path sizes did not invalidate selection key")
        check(CleanupSelectionPresentation.build([.init(small)])?.totalBytes == 9, "redistributed selected sizes stale")
        print(String(format: "Partial selection %d: Set action/COW=%.6fs, detached sum=%.6fs, 200 render/update/row+footer reads=%.6fs, heartbeat=%d, one sum visits=%d", count, actionTime, sumTime, renderTime, beats, sizes.visitedSelectedPaths))
    }

    @MainActor static func protectionChanges() {
        var item = category(["/nori-synthetic/protected/a", "/nori-synthetic/protected/b"])
        item.setPathSelected(item.paths[0], selected: true)
        let original = item
        var cache = CleanupSelectionCache()
        cache.update([.init(item)])
        let safeGeneration = cache.generation
        let safe = CleanupSelectionPresentation.build([.init(item)])!
        cache.accept(safe, generation: safeGeneration)
        check(CleanupSelectionPresentation.selectedCount(item) == 1 && safe.totalBytes == 1, "safe selectable count/bytes")
        item.risk = .protected
        check(item.id == original.id && item.paths == original.paths && item.selectionToken == original.selectionToken
              && item.pathOrderToken == original.pathOrderToken, "risk fixture changed inventory/selection tokens")
        check(item.selectedPathCount == 1 && CleanupSelectionPresentation.selectedCount(item) == 0,
              "protected raw selection must not enable category or installer action")
        check(cache.update([.init(item)]), "safe-to-protected did not invalidate unchanged-token key")
        let protectedGeneration = cache.generation
        let protectedInput = CleanupSelectionPresentation.Input(item)
        check(protectedInput.selectedPaths.isEmpty && protectedInput.pathBytes.isEmpty,
              "protected input retained a selected Set")
        let protectedResult = CleanupSelectionPresentation.immediate([protectedInput])!
        check(protectedResult.totalBytes == 0 && protectedResult.visitedSelectedPaths == 0,
              "protected selection must publish zero without summing")
        cache.accept(protectedResult, generation: protectedGeneration)
        check(!cache.accept(safe, generation: safeGeneration), "old safe bytes replaced protected result")
        item.risk = .safe
        check(cache.update([.init(item)]), "protected-to-safe did not invalidate unchanged-token key")
        check(CleanupSelectionPresentation.selectedCount(item) == 1, "restored safe count lost stored selection")
        check(!cache.accept(protectedResult, generation: protectedGeneration), "old protected bytes replaced restored safe result")
        let restored = CleanupSelectionPresentation.build([.init(item)])!
        cache.accept(restored, generation: cache.generation)
        check(cache.value?.totalBytes == safe.totalBytes, "safe size not restored")
        item.selected = true
        item.risk = .protected
        check(item.allSelected && CleanupSelectionPresentation.selectedCount(item) == 0, "full protected selection counted")
        check(CleanupSelectionPresentation.immediate([.init(item)])?.totalBytes == 0, "protected full selection used category bytes")
        check(CleanupSelectionPresentation.selectedCount(nil) == 0, "absent installer counted")
    }

    @MainActor static func main() async {
        semantics()
        protectionChanges()
        await scale(145_000)
        await scale(118_328)
        await generationRace()
        await partialSelectionScale(145_000)
        print("Cleanup presentation: \(checks) checks passed; synthetic only, no app or filesystem scan")
    }
}
