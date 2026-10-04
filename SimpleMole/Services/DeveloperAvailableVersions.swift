import Foundation

struct DeveloperAvailableVersion: Identifiable, Equatable, Sendable {
    let version: String
    let isLTS: Bool
    var id: String { version }
}

struct DeveloperAvailableVersionQuery: Identifiable, Equatable, Sendable {
    let id = UUID()
    let manager: DeveloperManager
    let candidate: String
    let versions: [DeveloperAvailableVersion]
}

enum DeveloperAvailableVersions {
    static func parse(_ output: String, manager: DeveloperManager) -> [DeveloperAvailableVersion] {
        let text = output.replacingOccurrences(of: #"\u001B\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
        var seen: Set<String> = []
        var versions: [DeveloperAvailableVersion] = []
        for line in text.components(separatedBy: .newlines) {
            let values: [String]
            if manager == .sdkman {
                let columns = line.split(separator: "|", omittingEmptySubsequences: false)
                values = columns.count >= 3
                    ? [columns.last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""]
                    : line.split(whereSeparator: \.isWhitespace).map(String.init)
            } else {
                values = [line.trimmingCharacters(in: CharacterSet(charactersIn: " *→->\t")).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""]
            }
            for value in values {
                guard value.contains(where: \.isNumber), DeveloperToolchainService.validIdentifier(value), seen.insert(value).inserted else { continue }
                versions.append(.init(version: value, isLTS: manager == .nvm || line.localizedCaseInsensitiveContains("lts")))
            }
        }
        return versions.sorted { $0.version.localizedStandardCompare($1.version) == .orderedDescending }
    }
}
