import Foundation

enum MenuBarCollectionPolicy {
    enum Backend: Equatable { case separator, nativeExperimental, unavailable }
    static func backend(majorVersion: Int) -> Backend {
        switch majorVersion {
        case 13...26: return .separator
        case 27: return .nativeExperimental
        default: return .unavailable
        }
    }
    static func allowedApps(running: Set<String>, selected: Set<String>,
                            candidates: Set<String>, own: String) -> [String] {
        let hidden = selected.intersection(candidates).filter { !$0.hasPrefix("com.apple.") && $0 != own }
        return running.subtracting(hidden).union([own]).sorted()
    }
    static func separatorLength(screenWidths: [CGFloat]) -> CGFloat? {
        guard let widest = screenWidths.max(), widest.isFinite, widest > 0, widest <= 5_000 else { return nil }
        return max(500, widest * 2)
    }
}
