import Foundation

private struct ToolParserFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct ToolCleanupParserTests {
    private static var checks = 0

    static func main() throws {
        let records = [
            "npm|@scope/package", "pnpm|@types/node", "brew|homebrew/core/node@22",
            "brew-cask|example-cask", "cargo|example_crate", "dotnet|dotnet.ef", "pipx|example-tool"
        ]
        let rows = records.enumerated().map { "0\t工具 \($0.offset)\t\($0.element)" }
        let categories = Parsers.toolCategories(rows.joined(separator: "\n") + "\n")
        try expect(categories.count == records.count, "zero-size rows from all seven managers must remain visible")
        for (index, category) in categories.enumerated() {
            let record = records[index]
            try expect(category.name == "工具 \(index)" && category.paths == [record], "preserve label, order and the exact owner record")
            try expect(category.bytes == 0 && category.pathBytes[record] == 0, "unknown occupancy must stay zero, never a fabricated reclaim promise")
            try expect(category.source == .tool && category.risk == .warning, "owner packages require manual review")
            try expect(category.disposal == .command && category.applyRoute == .toolCommand, "owner packages must route through commands")
            try expect(!category.selected && category.selectedPathCount == 0 && category.selectedSubset == nil,
                       "Warning packages must not be selected by default")
            try expect(category.canSelect && !category.quickCleanEligible, "manual command selection must remain separate from Quick Clean")
            var selected = category
            selected.selected = true
            try expect(selected.selectedPathCount == 1 && selected.selectedPathBytes == 0,
                       "explicit selection must work even when occupancy is unknown")
        }

        let known = Parsers.toolCategories("4096\tKnown package\tnpm|known-package")
        try expect(known.count == 1 && known[0].bytes == 4096 && known[0].pathBytes["npm|known-package"] == 4096,
                   "known occupancy must be preserved")
        let maximum = Parsers.toolCategories("18446744073709551615\tLarge package\tcargo|large-package")
        try expect(maximum.count == 1 && maximum[0].bytes == UInt64.max, "valid UInt64 occupancy must not overflow or be truncated")

        let malformedRows = [
            "", "error: npm inventory query failed (status 1)",
            "0\tMissing record", "0\tExtra column\tnpm|package\textra", "0\t\tnpm|package",
            "unknown\tUnknown occupancy\tnpm|package", "-1\tNegative occupancy\tnpm|package",
            "18446744073709551616\tOverflow\tnpm|package",
            "0\tUnknown owner\tunknown|package", "0\tEmpty owner\t|package",
            "0\tEmpty package\tnpm|", "0\tNo separator\tnpm-package",
            "0\tExtra separator\tnpm|package|other", "0\tCase changed\tNPM|package",
            "0\tWhitespace\tnpm|two packages", "0\tSemicolon\tnpm|package;touch-injected",
            "0\tSubstitution\tnpm|$(touch-injected)", "0\tBackticks\tnpm|`touch-injected`",
            "0\tSingle quote\tnpm|'package'", "0\tDouble quote\tnpm|\"package\"",
            "0\tBackslash\tnpm|package\\name", "0\tNon-ASCII\tnpm|包名",
            "0\tControl character\tnpm|package\u{0000}", "0\tCarriage return\tnpm|package\r"
        ]
        for row in malformedRows {
            try expect(Parsers.toolCategories(row).isEmpty, "reject malformed or injected record: " + row.debugDescription)
        }
        for manager in ["npm", "pnpm", "brew", "brew-cask", "cargo", "dotnet", "pipx"] {
            try expect(Parsers.toolCategories("0\tOption injection\t\(manager)|--all").isEmpty,
                       "reject option injection for " + manager)
        }

        // One malformed row or a stderr-like diagnostic must not erase valid
        // sibling rows from an incomplete inventory. The caller owns exit status.
        let mixed = Parsers.toolCategories(([rows[0]] + malformedRows + [rows[1]]).joined(separator: "\n"))
        try expect(mixed.map(\.paths) == [[records[0]], [records[1]]], "partial inventories must preserve only valid sibling rows in order")
        try expect(mixed.allSatisfy { !$0.selected && $0.risk == .warning }, "partial results remain visible and unselected")
        print("ok - \(checks) tool cleanup parser checks: seven managers, zero bytes, scoped packages, malformed/injected rows and Warning selection")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        checks += 1
        guard condition else { throw ToolParserFailure(description: message) }
    }
}
