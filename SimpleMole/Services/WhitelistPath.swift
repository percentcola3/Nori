import Foundation

enum WhitelistPath {
    enum ValidationError: Error {
        case invalid
        case missing
    }

    /// Keep the engine's absolute-path/glob grammar, without evaluating shell input.
    static func normalized(_ rawPath: String, homeDirectory: String = NSHomeDirectory()) throws -> String {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.count >= 2,
           (path.first == "\"" && path.last == "\"" || path.first == "'" && path.last == "'") {
            path = String(path.dropFirst().dropLast())
        }
        if path.hasPrefix("file:") {
            guard let url = URL(string: path), url.isFileURL,
                  url.host == nil || url.host == "" || url.host == "localhost",
                  url.query == nil, url.fragment == nil else { throw ValidationError.invalid }
            path = url.path
        }
        for prefix in ["~", "${HOME}", "$HOME"] {
            if path == prefix || path.hasPrefix(prefix + "/") {
                path = homeDirectory + path.dropFirst(prefix.count)
                break
            }
        }
        guard path.hasPrefix("/"), !path.contains(".."),
              path.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ValidationError.invalid
        }
        while path.contains("//") { path = path.replacingOccurrences(of: "//", with: "/") }
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    static func validated(_ rawPath: String, homeDirectory: String = NSHomeDirectory()) throws -> String {
        let path = try normalized(rawPath, homeDirectory: homeDirectory)
        // Patterns can protect paths that will be created later, as in Mole's whitelist.
        let isPattern = path.contains { $0 == "*" || $0 == "?" || $0 == "[" }
        guard isPattern || FileManager.default.fileExists(atPath: path) else {
            throw ValidationError.missing
        }
        return path
    }
}
