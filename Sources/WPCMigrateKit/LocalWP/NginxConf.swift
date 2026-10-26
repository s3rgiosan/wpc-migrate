import Foundation

/// One statement directly inside an nginx block: a directive ending in `;`, a
/// nested block, or a Handlebars section tag such as `{{#unless …}}`.
public struct NginxStatement: Sendable, Equatable {
    /// The statement as written, from its first word to its `;` or `}`, with
    /// the indentation of its first line taken off every line.
    public var text: String
    /// `text` without comments and with whitespace collapsed, for comparing.
    public var key: String
    /// The directive name, or the whole tag for a Handlebars section.
    public var name: String

    /// Whether LocalWP fills in part of it, as in `listen {{port}};`.
    public var isTemplated: Bool {
        text.contains("{{")
    }
}

/// Reads LocalWP's nginx `.hbs` templates, which are nginx config with
/// Handlebars tags in them.
public enum NginxConf {
    /// The statements directly inside the first top-level `server` block, or
    /// nil when there is none or its braces don't balance.
    public static func serverStatements(in source: String) -> [NginxStatement]? {
        guard let topLevel = statements(in: source),
              let server = topLevel.first(where: { $0.name == "server" && $0.text.hasSuffix("}") }),
              let open = server.text.firstIndex(of: "{") else { return nil }
        let body = server.text[server.text.index(after: open)..<server.text.index(before: server.text.endIndex)]
        return statements(in: String(body))
    }

    /// The server-block statements of `site` that `stock` doesn't have, in the
    /// order they appear, or nil when either file has no server block.
    public static func additions(in site: String, comparedTo stock: String) -> [NginxStatement]? {
        guard let siteStatements = serverStatements(in: site),
              let stockStatements = serverStatements(in: stock) else { return nil }
        var remaining: [String: Int] = [:]
        for statement in stockStatements {
            remaining[statement.key, default: 0] += 1
        }
        return siteStatements.filter { statement in
            guard let count = remaining[statement.key], count > 0 else { return true }
            remaining[statement.key] = count - 1
            return false
        }
    }

    /// Splits `source` into its top-level statements, or returns nil when its
    /// braces don't balance.
    static func statements(in source: String) -> [NginxStatement]? {
        let chars = Array(source)
        var result: [NginxStatement] = []
        var start: Int?
        var depth = 0
        var index = 0

        func append(_ range: ClosedRange<Int>) {
            var lineStart = range.lowerBound
            while lineStart > 0, chars[lineStart - 1] != "\n" { lineStart -= 1 }
            let indent = String(chars[lineStart..<range.lowerBound])
            let lines = String(chars[range]).components(separatedBy: "\n").map { line in
                indent.allSatisfy(\.isWhitespace) && line.hasPrefix(indent) ? String(line.dropFirst(indent.count)) : line
            }
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let key = normalized(text)
            result.append(NginxStatement(text: text, key: key, name: name(of: key)))
        }

        while index < chars.count {
            let char = chars[index]
            if char == "{", index + 1 < chars.count, chars[index + 1] == "{" {
                let end = handlebarsEnd(chars, from: index)
                let tag = String(chars[index...min(end, chars.count - 1)])
                let isSection = tag.hasPrefix("{{#") || tag.hasPrefix("{{/") || tag.hasPrefix("{{^") || tag.hasPrefix("{{else")
                if depth == 0, start == nil, isSection {
                    append(index...min(end, chars.count - 1))
                } else if start == nil {
                    start = index
                }
                index = end + 1
                continue
            }
            if char == "#" {
                while index < chars.count, chars[index] != "\n" { index += 1 }
                continue
            }
            if char == "\"" || char == "'" {
                if start == nil { start = index }
                index += 1
                while index < chars.count, chars[index] != char {
                    index += chars[index] == "\\" ? 2 : 1
                }
                index += 1
                continue
            }
            if start == nil, !char.isWhitespace {
                start = index
            }
            switch char {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth < 0 { return nil }
                if depth == 0, let first = start {
                    append(first...index)
                    start = nil
                }
            case ";":
                if depth == 0, let first = start {
                    append(first...index)
                    start = nil
                }
            default:
                break
            }
            index += 1
        }
        return depth == 0 ? result : nil
    }

    /// The index of the closing `}` of the `{{…}}` tag that starts at `index`.
    private static func handlebarsEnd(_ chars: [Character], from index: Int) -> Int {
        var end = index + 2
        while end + 1 < chars.count, !(chars[end] == "}" && chars[end + 1] == "}") {
            end += 1
        }
        return end + 1
    }

    /// Drops `#` comments outside quotes and Handlebars tags, and collapses whitespace.
    private static func normalized(_ text: String) -> String {
        var output = ""
        var quote: Character?
        var inComment = false
        var tagDepth = 0
        var previous: Character?
        for char in text {
            if inComment {
                if char == "\n" { inComment = false; output.append(" ") }
                continue
            }
            if let open = quote {
                output.append(char)
                if char == open, previous != "\\" { quote = nil }
            } else if char == "{", previous == "{" {
                tagDepth += 1
                output.append(char)
            } else if char == "}", previous == "}", tagDepth > 0 {
                tagDepth -= 1
                output.append(char)
            } else if char == "#", tagDepth == 0 {
                inComment = true
            } else {
                if char == "\"" || char == "'" { quote = char }
                output.append(char)
            }
            previous = char
        }
        return output.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The first word of a normalized statement, or the whole tag for a section.
    private static func name(of key: String) -> String {
        if key.hasPrefix("{{") { return key }
        return String(key.prefix { !$0.isWhitespace && $0 != "{" && $0 != ";" })
    }
}
