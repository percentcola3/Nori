import Foundation

/// Presents backend diagnostics in the app language while retaining actionable
/// paths and process names. Keep the original messages in the task log.
enum TaskFeedbackDiagnostic {
    static func localized(_ messages: [String],
                          using localize: (String) -> String = { L10n.shared.t($0) }) -> [String] {
        var seen = Set<String>()
        return messages.compactMap { raw in
            guard let value = localizedMessage(raw, using: localize), seen.insert(value).inserted else { return nil }
            return value
        }
    }

    private static func localizedMessage(_ raw: String, using localize: (String) -> String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("Open-file check ") else { return nil }
        // Some UI-owned refusals are already localized at their source. Keep
        // those reasons and their paths when mixed with raw executor output.
        for key in reasonKeys {
            let translated = localize(key)
            if text == translated || text.hasPrefix(translated + "\n")
                || text.hasSuffix("\n" + translated) { return text }
        }
        let statusPrefix = "Package manager exited with status "
        if text.hasPrefix(statusPrefix),
           let status = text.dropFirst(statusPrefix.count).split(separator: ".").first,
           Int(status) != nil {
            return String(format: localize("task.reason.status"), String(status))
        }
        for rule in rules where text.hasPrefix(rule.prefix) {
            var detail = String(text.dropFirst(rule.prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if rule.prefix.hasSuffix("running ("), let separator = detail.range(of: "): ") {
                detail = String(detail[..<separator.lowerBound]) + "\n" + String(detail[separator.upperBound...])
            } else if !rule.prefix.hasSuffix(": ") && !rule.stripSystemError {
                detail = ""
            }
            if rule.stripSystemError, let separator = detail.range(of: ": ", options: .backwards) {
                detail = String(detail[..<separator.lowerBound])
            }
            let message = localize(rule.key)
            return detail.isEmpty ? message : message + "\n" + detail
        }
        // Config editors historically reported only the affected path.
        if text.hasPrefix("/") { return localize("task.reason.config") + "\n" + text }
        let lower = text.lowercased()
        if lower.contains("permission denied") || lower.contains("operation not permitted") {
            return localize("task.reason.remove")
        }
        return localize("task.failure.unknown")
    }

    private struct Rule {
        let prefix: String
        let key: String
        var stripSystemError = false
    }

    private static let reasonKeys = L10nTaskFeedbackTables.table(for: .en).keys.filter {
        $0.hasPrefix("task.reason.")
    }

    private static let rules: [Rule] = [
        .init(prefix: "Quit running Agent owners before uninstalling CLI: ", key: "task.reason.runningApps"),
        .init(prefix: "Kept Agent resource while its owner is running (", key: "task.reason.runningApps"),
        .init(prefix: "Skipped while owning application is running: ", key: "task.reason.runningApps"),
        .init(prefix: "The application is still running.", key: "task.reason.runningApps"),
        .init(prefix: "CLI uninstall was blocked because process state is unavailable.", key: "task.reason.runtimeUnknown"),
        .init(prefix: "Kept Agent resource because running applications could not be verified: ", key: "task.reason.runtimeUnknown"),
        .init(prefix: "Skipped because open-file state was unavailable: ", key: "task.reason.runtimeUnknown"),
        .init(prefix: "Skipped while the path is open: ", key: "task.reason.open"),
        .init(prefix: "Skipped database family that is open or changed: ", key: "task.reason.validation"),
        .init(prefix: "Skipped unsafe path literal: ", key: "task.reason.path"),
        .init(prefix: "Skipped outside authorized roots: ", key: "task.reason.path"),
        .init(prefix: "CLI installation path is no longer physical.", key: "task.reason.path"),
        .init(prefix: "Skipped symbolic link: ", key: "task.reason.path"),
        .init(prefix: "Skipped path that is already absent: ", key: "task.reason.absent"),
        .init(prefix: "Skipped protected content: ", key: "task.reason.protected"),
        .init(prefix: "Skipped path protected by whitelist: ", key: "task.reason.protected"),
        .init(prefix: "Skipped content that requires administrator access or cannot be deleted: ", key: "task.reason.remove"),
        .init(prefix: "Kept Agent resource because its cleanup policy does not allow the operation: ", key: "task.reason.protected"),
        .init(prefix: "Skipped changed or unavailable path: ", key: "task.reason.changed"),
        .init(prefix: "Skipped changed or unrecognized Agent link: ", key: "task.reason.changed"),
        .init(prefix: "Configuration changed or is a symbolic link: ", key: "task.reason.changed"),
        .init(prefix: "Skill configuration changed or is a symbolic link: ", key: "task.reason.changed"),
        .init(prefix: "Kept Skill link because it changed or is no longer recognized: ", key: "task.reason.changed"),
        .init(prefix: "Kept MCP installation because its path or scanned identity is no longer recognized: ", key: "task.reason.changed"),
        .init(prefix: "Kept MCP registration because its configuration path is no longer recognized: ", key: "task.reason.changed"),
        .init(prefix: "Kept Agent resource because it is no longer recognized by the catalog: ", key: "task.reason.changed"),
        .init(prefix: "CLI installation changed; scan again before uninstalling.", key: "task.reason.changed"),
        .init(prefix: "Application changed since it was scanned.", key: "task.reason.changed"),
        .init(prefix: "CLI Agent is not recognized; scan again before uninstalling.", key: "task.reason.changed"),
        .init(prefix: "Kept Agent resources because Skill registrations could not be verified: ", key: "task.reason.config"),
        .init(prefix: "Kept Skill body because its registrations could not be verified: ", key: "task.reason.config"),
        .init(prefix: "Unsupported or malformed Skill TOML configuration: ", key: "task.reason.config"),
        .init(prefix: "Failed to unlink Skill configuration: ", key: "task.reason.config"),
        .init(prefix: "Kept Agent resources because registration backups are unavailable or their configurations changed: ", key: "task.reason.backup"),
        .init(prefix: "Kept Skill because its registration configuration changed or could not be backed up: ", key: "task.reason.backup"),
        .init(prefix: "Kept MCP installation because a registration configuration changed or could not be backed up: ", key: "task.reason.backup"),
        .init(prefix: "Kept MCP configuration because it changed or could not be backed up: ", key: "task.reason.backup"),
        .init(prefix: "Failed to back up Skill configuration: ", key: "task.reason.backup"),
        .init(prefix: "Kept Agent resource because its selection or scanned identity is unavailable: ", key: "task.reason.validation"),
        .init(prefix: "Kept Skill because its scanned identity is unavailable: ", key: "task.reason.validation"),
        .init(prefix: "Skipped because final content validation failed: ", key: "task.reason.validation"),
        .init(prefix: "Could not access ", key: "task.reason.remove", stripSystemError: true),
        .init(prefix: "Failed secure removal of ", key: "task.reason.remove", stripSystemError: true),
        .init(prefix: "Failed to remove ", key: "task.reason.remove", stripSystemError: true),
        .init(prefix: "Failed to unlink Agent resource: ", key: "task.reason.remove"),
        .init(prefix: "CLI uninstall left installation paths in place: ", key: "task.reason.cli"),
        .init(prefix: "Package manager uninstall timed out.", key: "task.reason.cli"),
        .init(prefix: "Homebrew cask uninstall failed.", key: "task.reason.cli"),
        .init(prefix: "Cannot create uninstall log.", key: "task.reason.cli"),
        .init(prefix: "Package manager is unavailable for this installation.", key: "task.reason.managerUnavailable")
    ]
}
