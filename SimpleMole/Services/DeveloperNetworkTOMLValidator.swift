import Foundation

/// A bounded TOML syntax reader for configuration edits. Unsupported constructs
/// are rejected before a backup or mutation; parsed text is never executed.
enum DeveloperNetworkTOMLValidator {
    struct Document { let sourceConfigured: Bool }
    static func validate(_ text: String) throws -> Document {
        guard text.utf8.count <= 1_048_576 else { throw DeveloperNetworkToolsService.Failure.unsafeConfig }
        var reader = Reader(bytes: Array(text.utf8))
        try reader.document()
        return Document(sourceConfigured: reader.sourceConfigured)
    }
    private struct Reader {
        let bytes: [UInt8]
        var index = 0
        var scope: [String] = []
        var sourceConfigured = false
        var assigned: Set<String> = []
        var tables: Set<String> = []
        var arraySequence = 0
        var arrayScope = ""
        var byte: UInt8? { index < bytes.count ? bytes[index] : nil }
        mutating func document() throws {
            while true {
                whitespace(lines: true)
                guard let nextByte = byte else { return }
                if nextByte == 91 {
                    index += 1
                    let array = self.byte == 91
                    if array { index += 1 }
                    let key = try dottedKey()
                    try consume(93)
                    if array { try consume(93); arraySequence += 1; arrayScope = "#\(arraySequence)" }
                    else { arrayScope = ""; guard tables.insert(key.joined(separator: "\0")).inserted else { try fail() } }
                    scope = key
                    if key.first == "source" { sourceConfigured = true }
                } else {
                    let key = try dottedKey()
                    try consume(61)
                    if (scope + key).first == "source" { sourceConfigured = true }
                    let name = (scope + key).joined(separator: "\0") + arrayScope
                    guard assigned.insert(name).inserted else { try fail() }
                    whitespace(lines: false)
                    try value(depth: 0)
                }
                whitespace(lines: false)
                guard byte == nil || byte == 10 || byte == 13 else { try fail() }
                if byte == 13 { index += 1; try consume(10) }
                else if byte == 10 { index += 1 }
            }
        }
        mutating func dottedKey() throws -> [String] {
            var result: [String] = []
            while true {
                whitespace(lines: false, comments: false)
                let component: String
                if byte == 34 || byte == 39 { component = try string(key: true) }
                else {
                    let start = index
                    while let character = byte, (48...57).contains(character) || (65...90).contains(character) || (97...122).contains(character) || character == 45 || character == 95 { index += 1 }
                    guard index > start else { try fail() }
                    component = String(decoding: bytes[start..<index], as: UTF8.self)
                }
                result.append(component)
                whitespace(lines: false, comments: false)
                if byte != 46 { return result }
                index += 1
            }
        }
        mutating func value(depth: Int) throws {
            guard depth < 64 else { try fail() }
            whitespace(lines: false, comments: false)
            guard let byte else { try fail() }
            switch byte {
            case 34, 39: _ = try string(key: false)
            case 91:
                index += 1; whitespace(lines: true)
                if self.byte == 93 { index += 1; return }
                while true {
                    try value(depth: depth + 1); whitespace(lines: true)
                    if self.byte == 93 { index += 1; return }
                    try consume(44); whitespace(lines: true)
                    if self.byte == 93 { index += 1; return }
                }
            case 123:
                index += 1; whitespace(lines: false)
                if self.byte == 125 { index += 1; return }
                var keys: Set<String> = []
                while true {
                    let key = try dottedKey().joined(separator: "\0")
                    guard keys.insert(key).inserted else { try fail() }
                    try consume(61); try value(depth: depth + 1); whitespace(lines: false)
                    if self.byte == 125 { index += 1; return }
                    try consume(44); whitespace(lines: false)
                }
            default:
                let start = index
                while let character = self.byte, ![10, 13, 44, 93, 125, 35].contains(character) { index += 1 }
                let literal = String(decoding: bytes[start..<index], as: UTF8.self).trimmingCharacters(in: .whitespaces)
                let patterns = [#"^(true|false|[+-]?inf|[+-]?nan)$"#,
                                #"^[+-]?(0|[1-9](?:_?[0-9])*)$"#,
                                #"^0x[0-9A-Fa-f](?:_?[0-9A-Fa-f])*$"#,
                                #"^0o[0-7](?:_?[0-7])*$"#, #"^0b[01](?:_?[01])*$"#,
                                #"^[+-]?(?:0|[1-9](?:_?[0-9])*)(?:\.[0-9](?:_?[0-9])*(?:[eE][+-]?[0-9](?:_?[0-9])*)?|[eE][+-]?[0-9](?:_?[0-9])*)$"#]
                guard patterns.contains(where: { literal.range(of: $0, options: .regularExpression) != nil }) else { try fail() }
            }
        }
        mutating func string(key: Bool) throws -> String {
            guard let quote = byte else { try fail() }
            index += 1
            var multiline = false
            if !key, index + 1 < bytes.count, bytes[index] == quote, bytes[index + 1] == quote {
                multiline = true; index += 2
            }
            var output: [UInt8] = []
            while let character = byte {
                if character == quote {
                    if !multiline { index += 1; return String(decoding: output, as: UTF8.self) }
                    if index + 2 < bytes.count, bytes[index + 1] == quote, bytes[index + 2] == quote {
                        index += 3
                        var additional = 0
                        while byte == quote, additional < 2 { output.append(quote); index += 1; additional += 1 }
                        return String(decoding: output, as: UTF8.self)
                    }
                }
                guard character >= 32 || character == 9 || (multiline && (character == 10 || character == 13)) else { try fail() }
                if character == 92, quote == 34 {
                    index += 1
                    guard let escape = byte else { try fail() }
                    if multiline, [9, 10, 13, 32].contains(escape) {
                        whitespace(lines: true, comments: false); continue
                    }
                    if escape == 117 || escape == 85 {
                        index += 1
                        let count = escape == 117 ? 4 : 8
                        guard index + count <= bytes.count else { try fail() }
                        let raw = String(decoding: bytes[index..<(index + count)], as: UTF8.self)
                        guard let number = UInt32(raw, radix: 16), let scalar = UnicodeScalar(number) else { try fail() }
                        output += String(scalar).utf8; index += count; continue
                    }
                    let escapes: [UInt8: UInt8] = [98: 8, 116: 9, 110: 10, 102: 12, 114: 13, 34: 34, 92: 92]
                    guard let replacement = escapes[escape] else { try fail() }
                    output.append(replacement); index += 1; continue
                }
                guard multiline || character != 10 && character != 13 else { try fail() }
                output.append(character); index += 1
            }
            try fail()
        }
        mutating func whitespace(lines: Bool, comments: Bool = true) {
            while let character = byte {
                if character == 32 || character == 9 || (lines && (character == 10 || character == 13)) { index += 1 }
                else if comments, character == 35 {
                    while let character = byte, character != 10 && character != 13 { index += 1 }
                    if !lines { return }
                } else { return }
            }
        }
        mutating func consume(_ expected: UInt8) throws {
            whitespace(lines: false, comments: false)
            guard byte == expected else { try fail() }
            index += 1
        }
        func fail() throws -> Never { throw DeveloperNetworkToolsService.Failure.unsafeConfig }
    }
}
