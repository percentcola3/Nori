import Foundation

enum AnalyzeMode: String, CaseIterable, Identifiable {
    case disk, largeFiles, duplicates, videos, images
    var id: String { rawValue }
    static let menuOrder: [Self] = [.disk, .largeFiles, .duplicates, .videos, .images]
}

enum AppLanguage: String, CaseIterable {
    case auto, zhHans = "zh-Hans", zhHant = "zh-Hant", en, ja, ko, de, fr, es, pt, it, ru, tr
}

enum AnalysisInventoryKind { case disk }
struct AnalysisFixtureSnapshot {
    var home: String
    var roots: [String]
}
final class AnalysisFixtureCache {
    var snapshots: [AnalysisInventoryKind: AnalysisFixtureSnapshot] = [:]
    func restore() -> [AnalysisInventoryKind: AnalysisFixtureSnapshot] { snapshots }
}
enum AnalysisInventoryWorker {
    static func defaultRoots(home: String, kind: AnalysisInventoryKind) -> [String] {
        [home, "/fixture/system/logs", "/fixture/system/temporary"]
    }
}

final class AnalysisFixturePermissions {
    var fullDiskAccessGranted = true
    private(set) var refreshCount = 0
    func refresh() { refreshCount += 1 }
}

@MainActor
final class AppState {
    let fixtureDefaults: UserDefaults
    var analysisAutoScanPreferences = AnalysisAutoScanPreferences()
    var analyzeMode = AnalyzeMode.images
    var externallyBusy = false
    var forcedAnalysisBusy = false
    var isAnalysisTaskBusy: Bool { forcedAnalysisBusy || isAnalyzing || isScanningDuplicates || isDeletingAnalysisFiles }
    var isBusy: Bool { externallyBusy || isAnalysisTaskBusy }
    var isAnalyzing = false
    var isScanningDuplicates = false
    var isDeletingAnalysisFiles = false
    var analyzingMode: AnalyzeMode?
    var taskNotice: String?
    let permissionCenter = AnalysisFixturePermissions()
    let analysisInventoryCache = AnalysisFixtureCache()
    var scannedAt: [AnalyzeMode: Date] = [:]
    private(set) var started: [AnalyzeMode] = []

    init(defaults: UserDefaults) { fixtureDefaults = defaults }
    func analysisHasScanned(_ mode: AnalyzeMode) -> Bool { scannedAt[mode] != nil }
    func analysisScanDate(for mode: AnalyzeMode) -> Date? { scannedAt[mode] }
    func scanAnalysisMode(_ mode: AnalyzeMode, forceFull: Bool = false) {
        precondition(!forceFull, "An automatic scan requested a full rescan")
        precondition(!isAnalyzing, "The scheduler overlapped two scans")
        started.append(mode)
        analyzingMode = mode
        isAnalyzing = true
    }
    func finish(success: Bool) {
        if success, let analyzingMode { scannedAt[analyzingMode] = Date() }
        analyzingMode = nil
        isAnalyzing = false
        runScheduledAnalysisScans()
    }
}

@main
struct AnalysisAutomationTests {
    @MainActor
    static func main() {
        let suite = "NoriAnalysisAutomationFixture." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let now = Date(timeIntervalSince1970: 10_000_000)
        let old = now.addingTimeInterval(-7 * 60 * 60)
        var prefs = AnalysisAutoScanPreferences()
        for mode in AnalyzeMode.allCases {
            precondition(prefs.isDue(mode, lastScanAt: old, now: now), "Automatic scanning was not enabled by default")
        }
        precondition(!prefs.isDue(.images, lastScanAt: nil, now: now, force: true), "Never-scanned category was eligible")
        precondition(!prefs.isDue(.images, lastScanAt: now.addingTimeInterval(-5 * 60 * 60), now: now))
        precondition(prefs.isDue(.images, lastScanAt: old, now: now))
        prefs.noteAttempt(for: .images, at: now)
        precondition(!prefs.isDue(.images, lastScanAt: old, now: now, force: true), "A failed attempt could loop")
        precondition(prefs.isDue(.images, lastScanAt: old, now: now.addingTimeInterval(60 * 60)))
        prefs.setInterval(.weekly, for: .images)
        precondition(!prefs.isDue(.images, lastScanAt: old, now: now.addingTimeInterval(60 * 60)))
        prefs.save(to: defaults)
        precondition(AnalysisAutoScanPreferences.load(from: defaults) == prefs)

        // Previously unchecked auto-scan settings must not disable the default scheduler.
        let legacy = Data(#"{"enabledModes":[],"intervals":{"images":"weekly"},"lastAttempts":{}}"#.utf8)
        defaults.set(legacy, forKey: AnalysisAutoScanPreferences.storageKey)
        let migrated = AnalysisAutoScanPreferences.load(from: defaults)
        precondition(migrated.interval(for: .images) == .weekly, "Migration discarded an existing schedule")
        precondition(migrated.isDue(.videos, lastScanAt: old, now: now), "Legacy disabled modes remained disabled")
        precondition(migrated.isDue(.images, lastScanAt: old, now: now.addingTimeInterval(8 * 24 * 60 * 60)))
        precondition(!migrated.isDue(.images, lastScanAt: nil, now: now, force: true))

        let state = AppState(defaults: defaults)
        let due = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        state.scannedAt = [.disk: due.addingTimeInterval(-4), .largeFiles: due.addingTimeInterval(-3),
                          .duplicates: due.addingTimeInterval(-2), .videos: due]
        // Images has never been scanned; the current sidebar selection must stay on it.
        state.externallyBusy = true
        state.forcedAnalysisBusy = true
        state.runScheduledAnalysisScans()
        precondition(state.started.isEmpty && state.permissionCenter.refreshCount == 0)
        state.forcedAnalysisBusy = false
        state.isDeletingAnalysisFiles = true
        state.runScheduledAnalysisScans()
        precondition(state.started.isEmpty)
        state.isDeletingAnalysisFiles = false
        state.taskNotice = "another tab's notice"
        state.permissionCenter.fullDiskAccessGranted = false
        state.runScheduledAnalysisScans()
        precondition(state.started.isEmpty)
        state.permissionCenter.fullDiskAccessGranted = true
        state.runScheduledAnalysisScans()
        precondition(state.started == [.disk] && state.isBusy,
                     "Another tab's active task or result notice blocked the read-only scheduler")
        state.taskNotice = nil
        precondition(state.analyzeMode == .images, "The scheduler changed the selected sidebar item")
        state.runScheduledAnalysisScans(force: true)
        precondition(state.started == [.disk], "The scheduler started overlapping work")
        state.finish(success: false)
        precondition(state.started == [.disk, .largeFiles], "A failed category blocked other due categories")
        state.finish(success: true)
        precondition(state.started == [.disk, .largeFiles, .duplicates])
        state.finish(success: true)
        precondition(state.started == [.disk, .largeFiles, .duplicates, .videos])
        state.finish(success: true)
        precondition(state.started == [.disk, .largeFiles, .duplicates, .videos], "The never-scanned category ran automatically")
        precondition(state.analyzeMode == .images)
        precondition(!AnalysisAutoScanPreferences.load(from: defaults).isDue(.disk, lastScanAt: due), "Attempt backoff was not persisted")

        let manuallyCancelled = AppState(defaults: defaults)
        manuallyCancelled.scannedAt[.images] = due
        manuallyCancelled.noteAnalysisScanAttempt(for: .images)
        manuallyCancelled.runScheduledAnalysisScans()
        precondition(manuallyCancelled.started.isEmpty, "A cancelled manual scan restarted immediately through automation")

        let upgraded = AppState(defaults: defaults)
        upgraded.scannedAt[.disk] = Date()
        upgraded.analysisAutoScanPreferences.setInterval(.weekly, for: .disk)
        upgraded.analysisInventoryCache.snapshots[.disk] = .init(home: "/fixture/home", roots: ["/fixture/home"])
        upgraded.permissionCenter.fullDiskAccessGranted = false
        upgraded.runScheduledAnalysisScans()
        precondition(upgraded.started.isEmpty, "Scope expansion bypassed the full-disk-access gate")
        upgraded.permissionCenter.fullDiskAccessGranted = true
        upgraded.runScheduledAnalysisScans()
        precondition(upgraded.started == [.disk], "A recent home-only disk cache waited for its normal weekly interval")
        // Partial scope reads are persisted with all requested roots, so they
        // do not look like an unattempted schema expansion on completion.
        upgraded.analysisInventoryCache.snapshots[.disk]?.roots =
            AnalysisInventoryWorker.defaultRoots(home: "/fixture/home", kind: .disk)
        upgraded.finish(success: false)
        upgraded.runScheduledAnalysisScans(force: true)
        precondition(upgraded.started == [.disk], "A partial scope expansion immediately retried")
        upgraded.analysisAutoScanPreferences.noteAttempt(for: .disk,
            at: Date().addingTimeInterval(-AnalysisAutoScanPreferences.minimumRetryInterval - 1))
        upgraded.runScheduledAnalysisScans()
        precondition(upgraded.started == [.disk], "An attempted partial scope expansion ignored the normal scan interval")

        let failedExpansion = AppState(defaults: defaults)
        failedExpansion.scannedAt[.disk] = Date()
        failedExpansion.analysisInventoryCache.snapshots[.disk] = .init(home: "/fixture/home", roots: ["/fixture/home"])
        failedExpansion.runScheduledAnalysisScans()
        failedExpansion.finish(success: false)
        precondition(failedExpansion.started == [.disk], "A failed migration looped while its home-only snapshot remained unchanged")
        failedExpansion.analysisAutoScanPreferences.noteAttempt(for: .disk,
            at: Date().addingTimeInterval(-AnalysisAutoScanPreferences.minimumRetryInterval - 1))
        failedExpansion.runScheduledAnalysisScans()
        precondition(failedExpansion.started == [.disk, .disk], "An incomplete scope expansion could not retry after backoff")

        let expression = try! NSRegularExpression(pattern: "%[0-9$]*[ld@f]+|%%")
        func placeholders(_ value: String) -> [String] {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            return expression.matches(in: value, range: range).map { (value as NSString).substring(with: $0.range) }
        }
        let english = L10nAnalysisTables.table(for: .en)
        let browserKeys = ["analyze.section.disk", "analyze.scan.action.disk", "analyze.scan.detail.disk",
                           "analyze.browser.home", "analyze.browser.empty", "analyze.browser.folder",
                           "analyze.browser.back", "analyze.browser.selection", "analyze.browser.used",
                           "analyze.browser.available", "analyze.browser.total", "analyze.browser.size"]
        let englishMedia = L10nMediaTables.table(for: .en)
        precondition(englishMedia["analyze.section.largeFiles"] == "Large files")
        precondition(L10nMediaTables.table(for: .zhHans)["analyze.section.largeFiles"] == "大文件")
        precondition(L10nMediaTables.table(for: .zhHant)["analyze.section.largeFiles"] == "大檔案")
        for language in [AppLanguage.zhHans, .zhHant] {
            let translated = L10nAnalysisTables.table(for: language)
            precondition(Set(translated.keys) == Set(english.keys))
            for (key, value) in english { precondition(placeholders(value) == placeholders(translated[key]!)) }
            let translatedMedia = L10nMediaTables.table(for: language)
            precondition(Set(translatedMedia.keys) == Set(englishMedia.keys))
            for (key, value) in englishMedia {
                precondition(placeholders(value) == placeholders(translatedMedia[key]!))
            }
        }
        for language in AppLanguage.allCases {
            let translated = L10nAnalysisTables.table(for: language)
            precondition(!translated.isEmpty && translated.values.allSatisfy { !$0.isEmpty })
            for key in browserKeys {
                let resolved = translated[key] ?? english[key]
                precondition(resolved != nil && resolved != key && !resolved!.isEmpty,
                             "Disk-browser copy has no translation or English fallback: " + key)
            }
            let translatedMedia = L10nMediaTables.table(for: language)
            precondition(translatedMedia["analyze.section.largeFiles"] != nil,
                         "Large-file category is no longer translated")
        }
        print("Analysis automation: incremental refresh, legacy scope expansion, partial retry backoff, per-tab/permission gating, sequential refresh and localization passed")
    }
}
