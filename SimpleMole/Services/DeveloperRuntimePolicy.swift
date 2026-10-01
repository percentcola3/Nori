import Foundation

enum DeveloperRuntimePolicy {
    /// Other managers own their package metadata and must use their own commands.
    static func canClean(_ entry: DevEnvEntry) -> Bool {
        entry.kind == "runtime" && entry.manager == "nvm"
    }

    static func ownerRemovalCommand(_ entry: DevEnvEntry) -> String? {
        let version = entry.versionLabel
        guard entry.isManager, !version.isEmpty else { return nil }
        let quoted = "'" + version.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        switch entry.manager.lowercased() {
        case "pyenv": return "pyenv uninstall " + quoted
        case "rbenv": return "rbenv uninstall " + quoted
        case "rustup": return "rustup toolchain uninstall " + quoted
        case "fnm": return "fnm uninstall " + quoted
        case "asdf": return "asdf uninstall " + (entry.path.contains("/installs/nodejs/") ? "nodejs " : "node ") + quoted
        default: return nil
        }
    }
}
