import Foundation

/// Entry-level view of /etc/hosts. Every edit rewrites or inserts whole lines and leaves
/// comments, blank lines and unrecognized text exactly as they were.
extension DeveloperNetworkService {
    struct HostsEntry: Identifiable, Equatable {
        let lineIndex: Int
        let enabled: Bool
        let address: String
        let hostnames: [String]
        let comment: String
        var id: Int { lineIndex }
        /// localhost / broadcasthost mappings stay as macOS installed them.
        var isSystem: Bool {
            hostnames.contains { name in
                let normalized = (name.hasSuffix(".") ? String(name.dropLast()) : name).lowercased()
                return normalized == "localhost" || normalized == "broadcasthost"
            }
        }
    }

    struct HostsGroup: Identifiable, Equatable {
        enum Kind: Equatable {
            case system
            case ungrouped
            case named(String)
        }
        let kind: Kind
        let headerLineIndex: Int?
        let entries: [HostsEntry]
        var id: String {
            switch kind {
            case .system: return "system"
            case .ungrouped: return "ungrouped"
            case .named: return "group-\(headerLineIndex ?? -1)"
            }
        }
        var enabledCount: Int { entries.filter(\.enabled).count }
    }

    enum HostsEntryProblem: Error, Equatable {
        case invalidAddress
        case missingHostname
        case invalidHostname(String)
        case protectedHostname
        case invalidComment
    }

    static func hostsGroups(_ text: String) -> [HostsGroup] {
        struct Block {
            var title: String?
            var header: Int?
            var entries: [HostsEntry] = []
        }
        var blocks = [Block()]
        for (index, rawLine) in text.components(separatedBy: "\n").enumerated() {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                // A blank line detaches a comment from the entries that follow it.
                if blocks[blocks.count - 1].entries.isEmpty, blocks.count > 1 {
                    blocks[blocks.count - 1].title = nil
                    blocks[blocks.count - 1].header = nil
                }
                continue
            }
            if let entry = parseHostsEntry(line, index: index, enabled: true) {
                blocks[blocks.count - 1].entries.append(entry)
                continue
            }
            guard trimmed.hasPrefix("#") else { continue }
            let body = String(trimmed.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            if let entry = parseHostsEntry(body, index: index, enabled: false) {
                blocks[blocks.count - 1].entries.append(entry)
                continue
            }
            let title = cleanedTitle(body)
            if blocks[blocks.count - 1].entries.isEmpty {
                if blocks[blocks.count - 1].title == nil, let title {
                    blocks[blocks.count - 1].title = title
                    blocks[blocks.count - 1].header = index
                }
            } else {
                blocks.append(Block(title: title, header: title == nil ? nil : index))
            }
        }
        var system: [HostsEntry] = []
        var ungrouped: [HostsEntry] = []
        var named: [HostsGroup] = []
        for block in blocks {
            system += block.entries.filter(\.isSystem)
            let custom = block.entries.filter { !$0.isSystem }
            let isSystemBlock = block.entries.contains(where: \.isSystem)
            if let title = block.title, !isSystemBlock {
                if !custom.isEmpty {
                    named.append(HostsGroup(kind: .named(title), headerLineIndex: block.header, entries: custom))
                }
            } else {
                ungrouped += custom
            }
        }
        var groups: [HostsGroup] = []
        if !system.isEmpty { groups.append(HostsGroup(kind: .system, headerLineIndex: nil, entries: system)) }
        if !ungrouped.isEmpty { groups.append(HostsGroup(kind: .ungrouped, headerLineIndex: nil, entries: ungrouped)) }
        return groups + named
    }

    private static func parseHostsEntry(_ line: String, index: Int, enabled: Bool) -> HostsEntry? {
        let fields = hostFields(line)
        guard fields.count >= 2, validAddress(fields[0]), fields.dropFirst().allSatisfy(validHostname) else {
            return nil
        }
        let comment = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .dropFirst().first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return HostsEntry(lineIndex: index, enabled: enabled, address: fields[0],
                          hostnames: Array(fields.dropFirst()), comment: comment)
    }

    private static func cleanedTitle(_ body: String) -> String? {
        let title = body.trimmingCharacters(in: CharacterSet(charactersIn: "-=*# \t"))
        return title.isEmpty ? nil : title
    }

    // MARK: Validation

    static func validateHostsEntry(address: String, hostnames: [String], comment: String = "") throws {
        guard validAddress(address) else { throw HostsEntryProblem.invalidAddress }
        guard !hostnames.isEmpty else { throw HostsEntryProblem.missingHostname }
        for name in hostnames {
            guard validHostname(name) else { throw HostsEntryProblem.invalidHostname(name) }
            let normalized = (name.hasSuffix(".") ? String(name.dropLast()) : name).lowercased()
            guard normalized != "localhost", normalized != "broadcasthost" else {
                throw HostsEntryProblem.protectedHostname
            }
        }
        guard !comment.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw HostsEntryProblem.invalidComment
        }
    }

    /// Splits user input on whitespace and commas.
    static func hostnameList(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" || $0 == "\n" }).map(String.init)
    }

    static func hostsLine(address: String, hostnames: [String], comment: String, enabled: Bool) -> String {
        let note = comment.trimmingCharacters(in: .whitespaces)
        return (enabled ? "" : "# ") + address + "\t" + hostnames.joined(separator: " ")
            + (note.isEmpty ? "" : "\t# " + note)
    }

    // MARK: Edits

    static func settingHostsEntry(_ text: String, entry: HostsEntry, address: String, hostnames: [String],
                                  comment: String) throws -> String {
        try validateHostsEntry(address: address, hostnames: hostnames, comment: comment)
        return replacingLine(text, at: entry.lineIndex) { _ in
            hostsLine(address: address, hostnames: hostnames, comment: comment, enabled: entry.enabled)
        }
    }

    static func settingHostsEntries(_ text: String, entries: [HostsEntry], enabled: Bool) -> String {
        var result = text
        for entry in entries where !entry.isSystem && entry.enabled != enabled {
            result = replacingLine(result, at: entry.lineIndex) { line in
                let indent = String(line.prefix { $0 == " " || $0 == "\t" })
                let body = String(line.dropFirst(indent.count))
                if enabled {
                    return indent + String(body.drop { $0 == "#" }.drop { $0 == " " || $0 == "\t" })
                }
                return indent + "# " + body
            }
        }
        return result
    }

    static func removingHostsEntry(_ text: String, entry: HostsEntry) -> String {
        guard !entry.isSystem else { return text }
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(entry.lineIndex) else { return text }
        lines.remove(at: entry.lineIndex)
        return lines.joined(separator: "\n")
    }

    /// `group == nil` with a title creates a new commented group at the end of the file.
    static func addingHostsEntry(_ text: String, address: String, hostnames: [String], comment: String,
                                 to group: HostsGroup?, newGroupTitle: String? = nil) throws -> String {
        try validateHostsEntry(address: address, hostnames: hostnames, comment: comment)
        let line = hostsLine(address: address, hostnames: hostnames, comment: comment, enabled: true)
        var lines = text.components(separatedBy: "\n")
        let groups = hostsGroups(text)
        if let group, group.kind != .system {
            // Ungrouped mappings live in the block that holds the system defaults.
            let anchor = group.entries.map(\.lineIndex).max()
                ?? groups.first { $0.kind == .system }?.entries.map(\.lineIndex).max()
                ?? group.headerLineIndex
            if let anchor, lines.indices.contains(anchor) {
                lines.insert(line, at: anchor + 1)
                return lines.joined(separator: "\n")
            }
        }
        let title = newGroupTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw HostsEntryProblem.invalidComment
        }
        var appended = text
        if !appended.isEmpty, !appended.hasSuffix("\n") { appended += "\n" }
        if !title.isEmpty {
            if !appended.isEmpty, !appended.hasSuffix("\n\n") { appended += "\n" }
            appended += "# " + title + "\n"
        }
        return appended + line + "\n"
    }

    private static func replacingLine(_ text: String, at index: Int, _ transform: (String) -> String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(index) else { return text }
        let line = lines[index]
        let carriage = line.hasSuffix("\r")
        let body = carriage ? String(line.dropLast()) : line
        lines[index] = transform(body) + (carriage ? "\r" : "")
        return lines.joined(separator: "\n")
    }
}
