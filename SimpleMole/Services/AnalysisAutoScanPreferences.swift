import Foundation

/// Scheduled analysis only refreshes cached results; it never performs a file mutation.
enum AnalysisAutoScanInterval: String, CaseIterable, Codable, Identifiable, Sendable {
    case sixHours, daily, weekly

    var id: String { rawValue }
    var titleKey: String { "analyze.auto.interval.\(rawValue)" }

    var seconds: TimeInterval {
        switch self {
        case .sixHours: return 6 * 60 * 60
        case .daily: return 24 * 60 * 60
        case .weekly: return 7 * 24 * 60 * 60
        }
    }
}

struct AnalysisAutoScanPreferences: Codable, Equatable, Sendable {
    // Keep the storage key so existing intervals and retry timestamps carry forward.
    // Legacy enabledModes is ignored: every previously scanned category refreshes automatically.
    static let storageKey = "SMAnalysisAutoScanPreferences.v1"
    /// A failed background scan waits for the next hourly tick instead of looping.
    static let minimumRetryInterval: TimeInterval = 60 * 60

    private var intervals: [String: AnalysisAutoScanInterval] = [:]
    private var lastAttempts: [String: Date] = [:]

    func interval(for mode: AnalyzeMode) -> AnalysisAutoScanInterval {
        intervals[mode.rawValue] ?? .sixHours
    }

    mutating func setInterval(_ interval: AnalysisAutoScanInterval, for mode: AnalyzeMode) {
        intervals[mode.rawValue] = interval
    }

    mutating func noteAttempt(for mode: AnalyzeMode, at date: Date) {
        lastAttempts[mode.rawValue] = date
    }

    /// The caller must supply a completed scan date. New categories are never scanned automatically.
    func isDue(_ mode: AnalyzeMode, lastScanAt: Date?, now: Date = Date(), force: Bool = false) -> Bool {
        guard let lastScanAt else { return false }
        if let lastAttempt = lastAttempts[mode.rawValue],
           now.timeIntervalSince(lastAttempt) < Self.minimumRetryInterval { return false }
        return force || now.timeIntervalSince(lastScanAt) >= interval(for: mode).seconds
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return decoded
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
