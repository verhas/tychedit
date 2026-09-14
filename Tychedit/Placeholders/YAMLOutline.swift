import Foundation

/// The structure of a placeholder's YAML configuration, with source positions.
///
/// Not a YAML parser. It reads the block-style YAML mdship placeholders are
/// written in -- `key: value`, block scalars, nested mappings, `- ` sequences,
/// flow collections kept as text -- well enough to say which keys are present,
/// where each one and its value sit, and what shape the value has. That is what
/// validation, completion and navigation need; mdship's PyYAML does the real
/// parsing when it runs.
struct YAMLOutline: Sendable, Equatable {

    indirect enum Node: Sendable, Equatable {
        /// A plain or quoted scalar on the key's line; `text` is unquoted.
        case scalar(text: String, range: NSRange, quoted: Bool)
        /// `|` or `>` followed by indented lines.
        case block(range: NSRange)
        /// `[...]` or `{...}`, kept as source text.
        case flow(text: String, range: NSRange)
        case mapping([Entry])
        case sequence([Item])
        /// `key:` with nothing after it.
        case null
    }

    struct Entry: Sendable, Equatable {
        let key: String
        let keyRange: NSRange
        /// Zero-based line in the document.
        let line: Int
        let indent: Int
        var value: Node
    }

    struct Item: Sendable, Equatable {
        let dashRange: NSRange
        let line: Int
        var value: Node
    }

    struct Problem: Sendable, Equatable {
        let range: NSRange
        let message: String
    }

    var entries: [Entry] = []
    var problems: [Problem] = []

    func entry(_ key: String) -> Entry? {
        entries.first { $0.key == key }
    }

    // MARK: - Parsing

    /// Parses `config`, whose first character is at document offset `offset`
    /// on document line `line`.
    ///
    /// The first line is whatever followed the placeholder name, as in
    /// `<!--TOC min-level: 2`, so its leading space does not count as indentation.
    init(_ config: String, offset: Int, line firstLine: Int) {
        var lines: [Line] = []
        let ns = config as NSString
        var start = 0
        var number = firstLine
        while start <= ns.length {
            let newline = ns.range(of: "\n", options: [], range: NSRange(location: start, length: ns.length - start))
            let end = newline.location == NSNotFound ? ns.length : newline.location
            var text = ns.substring(with: NSRange(location: start, length: end - start))
            if text.hasSuffix("\r") { text.removeLast() }
            var skipped = 0
            if number == firstLine {
                // Ignore the separating space after the placeholder name.
                skipped = text.utf16.prefix { $0 == 32 || $0 == 9 }.count
                text = String(text.utf16.dropFirst(skipped)) ?? text
            }
            lines.append(Line(text: text, start: offset + start + skipped, number: number))
            number += 1
            if newline.location == NSNotFound { break }
            start = end + 1
        }
        var parser = Parser(lines: lines)
        entries = parser.mapping(indent: 0, topLevel: true)
        problems = parser.problems
    }

    struct Line: Sendable, Equatable {
        var text: String
        /// Document offset of `text`'s first character.
        var start: Int
        let number: Int

        var indent: Int { text.utf16.prefix { $0 == 32 }.count }
        var content: String { String(text.utf16.dropFirst(indent)) ?? text }
        var isBlankOrComment: Bool {
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || trimmed.hasPrefix("#")
        }
    }

    private struct Parser {
        var lines: [Line]
        var index = 0
        var problems: [Problem] = []

        init(lines: [Line]) {
            self.lines = lines
        }

        mutating func skipBlank() {
            while index < lines.count, lines[index].isBlankOrComment { index += 1 }
        }

        mutating func mapping(indent: Int, topLevel: Bool = false) -> [Entry] {
            var entries: [Entry] = []
            var seen: [String: Int] = [:]
            while true {
                skipBlank()
                guard index < lines.count else { break }
                let line = lines[index]
                if line.text.hasPrefix("\t") {
                    problems.append(Problem(range: NSRange(location: line.start, length: 1),
                                            message: "YAML does not allow tabs for indentation"))
                }
                if line.indent < indent { break }
                if line.indent > indent {
                    problems.append(Problem(range: range(of: line),
                                            message: "Unexpected indentation"))
                    index += 1
                    continue
                }
                let content = line.content
                if content.hasPrefix("- ") || content == "-" {
                    if topLevel {
                        problems.append(Problem(range: range(of: line),
                                                message: "A list item needs a key above it"))
                        index += 1
                        continue
                    }
                    break
                }
                guard let colon = Parser.keyColon(in: content) else {
                    problems.append(Problem(range: range(of: line),
                                            message: "Expected `key: value`"))
                    index += 1
                    continue
                }
                let rawKey = (content as NSString).substring(to: colon)
                let key = Parser.unquote(rawKey.trimmingCharacters(in: .whitespaces))
                let keyRange = NSRange(location: line.start + line.indent, length: (rawKey as NSString).length)
                let afterColon = colon + 1
                index += 1
                let value = self.value(after: afterColon, in: line, indent: indent)
                if let previous = seen[key] {
                    problems.append(Problem(range: keyRange,
                                            message: "Duplicate key '\(key)' (also on line \(previous + 1)); YAML keeps only the last one"))
                } else {
                    seen[key] = line.number
                }
                entries.append(Entry(key: key, keyRange: keyRange, line: line.number, indent: indent, value: value))
            }
            return entries
        }

        /// The value of the key whose colon ends at `column` of `line`.
        mutating func value(after column: Int, in line: Line, indent: Int) -> Node {
            let content = line.content as NSString
            let restRaw = content.substring(from: column)
            let leading = restRaw.utf16.prefix { $0 == 32 || $0 == 9 }.count
            let rest = String(restRaw.utf16.dropFirst(leading)) ?? restRaw
            let restStart = line.start + line.indent + column + leading

            if rest.isEmpty || rest.hasPrefix("#") {
                return nested(below: indent)
            }
            if rest.hasPrefix("|") || rest.hasPrefix(">") {
                let start = index
                while index < lines.count,
                      lines[index].content.trimmingCharacters(in: .whitespaces).isEmpty || lines[index].indent > indent {
                    index += 1
                }
                // Trailing blank lines are not part of the scalar.
                var end = index
                while end > start, lines[end - 1].content.trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
                let blockStart = start < end ? lines[start].start : restStart
                let blockEnd = start < end ? lines[end - 1].start + (lines[end - 1].text as NSString).length : restStart + (rest as NSString).length
                return .block(range: NSRange(location: blockStart, length: blockEnd - blockStart))
            }
            if rest.hasPrefix("[") || rest.hasPrefix("{") {
                var text = rest
                var depth = Parser.depth(rest)
                var end = restStart + (rest as NSString).length
                while depth > 0, index < lines.count {
                    text += "\n" + lines[index].text
                    depth += Parser.depth(lines[index].text)
                    end = lines[index].start + (lines[index].text as NSString).length
                    index += 1
                }
                return .flow(text: text, range: NSRange(location: restStart, length: end - restStart))
            }
            let (text, length, quoted) = Parser.scalar(rest)
            return .scalar(text: text, range: NSRange(location: restStart, length: length), quoted: quoted)
        }

        /// A mapping or sequence indented below a `key:` line -- or a sequence at
        /// the key's own indentation, which YAML also allows.
        mutating func nested(below indent: Int) -> Node {
            skipBlank()
            guard index < lines.count else { return .null }
            let next = lines[index]
            let isItem = next.content.hasPrefix("- ") || next.content == "-"
            if next.indent > indent {
                return isItem ? .sequence(sequence(indent: next.indent)) : .mapping(mapping(indent: next.indent))
            }
            if next.indent == indent && isItem {
                return .sequence(sequence(indent: indent))
            }
            return .null
        }

        mutating func sequence(indent: Int) -> [Item] {
            var items: [Item] = []
            while true {
                skipBlank()
                guard index < lines.count else { break }
                let line = lines[index]
                guard line.indent == indent, line.content.hasPrefix("- ") || line.content == "-" else { break }
                let dashRange = NSRange(location: line.start + indent, length: 1)
                let afterDash = line.content.dropFirst(1)
                let spaces = afterDash.utf16.prefix { $0 == 32 }.count
                let itemText = String(afterDash.utf16.dropFirst(spaces)) ?? ""
                let itemColumn = indent + 1 + spaces

                if itemText.isEmpty {
                    index += 1
                    items.append(Item(dashRange: dashRange, line: line.number, value: nested(below: indent)))
                } else if Parser.keyColon(in: itemText) != nil && !itemText.hasPrefix("\"") && !itemText.hasPrefix("'") {
                    // `- key: value`: the item is a mapping whose first key is on the
                    // dash line. Pretend that key starts its own line, indented to match.
                    // The text keeps its column, so its document offset is unchanged.
                    lines[index] = Line(text: String(repeating: " ", count: itemColumn) + itemText,
                                        start: line.start, number: line.number)
                    items.append(Item(dashRange: dashRange, line: line.number, value: .mapping(mapping(indent: itemColumn))))
                } else {
                    index += 1
                    let (text, length, quoted) = Parser.scalar(itemText)
                    let start = line.start + itemColumn
                    items.append(Item(dashRange: dashRange, line: line.number,
                                      value: .scalar(text: text, range: NSRange(location: start, length: length), quoted: quoted)))
                }
            }
            return items
        }

        func range(of line: Line) -> NSRange {
            NSRange(location: line.start + line.indent, length: (line.content as NSString).length)
        }

        /// The UTF-16 position of the colon ending a key, if the text starts with one.
        static func keyColon(in content: String) -> Int? {
            let chars = Array(content.utf16)
            var i = 0
            if let quote = chars.first, quote == 34 || quote == 39 {
                i = 1
                while i < chars.count, chars[i] != quote { i += 1 }
                i += 1
                guard i < chars.count, chars[i] == 58 else { return nil }
                return i
            }
            while i < chars.count {
                if chars[i] == 58 && (i + 1 == chars.count || chars[i + 1] == 32 || chars[i + 1] == 9) {
                    return i > 0 ? i : nil
                }
                // A flow collection or a comment is not a key.
                if chars[i] == 35 && i > 0 && chars[i - 1] == 32 { return nil }
                i += 1
            }
            return nil
        }

        static func unquote(_ text: String) -> String {
            if text.count >= 2, let first = text.first, first == "\"" || first == "'", text.last == first {
                return String(text.dropFirst().dropLast())
            }
            return text
        }

        /// A scalar's value, its source length and whether it was quoted.
        static func scalar(_ rest: String) -> (String, Int, Bool) {
            let ns = rest as NSString
            if let first = rest.first, first == "\"" || first == "'" {
                let quote = first == "\"" ? unichar(34) : unichar(39)
                var i = 1
                while i < ns.length {
                    if ns.character(at: i) == quote {
                        // '' inside single quotes is an escaped quote.
                        if quote == 39, i + 1 < ns.length, ns.character(at: i + 1) == 39 { i += 2; continue }
                        break
                    }
                    if quote == 34 && ns.character(at: i) == 92 { i += 1 }
                    i += 1
                }
                let end = min(i + 1, ns.length)
                let inner = ns.substring(with: NSRange(location: 1, length: max(0, min(i, ns.length) - 1)))
                return (inner, end, true)
            }
            // A comment starts at " #".
            var text = rest
            if let comment = rest.range(of: " #") {
                text = String(rest[..<comment.lowerBound])
            }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return (trimmed, (trimmed as NSString).length, false)
        }

        static func depth(_ text: String) -> Int {
            var depth = 0
            var quote: Character?
            for c in text {
                if let q = quote {
                    if c == q { quote = nil }
                    continue
                }
                switch c {
                case "\"", "'": quote = c
                case "[", "{": depth += 1
                case "]", "}": depth -= 1
                default: break
                }
            }
            return depth
        }
    }
}

extension YAMLOutline.Node {
    /// The scalar text, when the value is a scalar.
    var scalarText: String? {
        if case .scalar(let text, _, _) = self { return text }
        return nil
    }

    /// Where the value sits in the document, when it is on one line or block.
    var range: NSRange? {
        switch self {
        case .scalar(_, let range, _), .block(let range), .flow(_, let range): range
        case .mapping, .sequence, .null: nil
        }
    }

    /// A scalar's text without its quotes: where a path or name actually is.
    var textRange: NSRange? {
        guard case .scalar(_, let range, let quoted) = self else { return nil }
        guard quoted, range.length >= 2 else { return range }
        return NSRange(location: range.location + 1, length: range.length - 2)
    }

    var shapeName: String {
        switch self {
        case .scalar: "a single value"
        case .block: "a block of text"
        case .flow: "an inline list or mapping"
        case .mapping: "a mapping"
        case .sequence: "a list"
        case .null: "empty"
        }
    }
}
