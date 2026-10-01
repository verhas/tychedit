import Foundation

/// What the `number:` front-matter key asks `mdship update` to do with the
/// headings before it processes any placeholder.
struct NumberingSettings: Sendable, Equatable {
    /// True to number, false to remove numbering.
    var number: Bool
    var style: HeadingNumbering.Style = .period
    var skipTitle = false
    /// Numbering may change guarded generated content and re-sign it.
    var generated = false
    /// Renumber after the update, then regenerate the TOC.
    var postProcess = false
}

/// The `number:` front-matter key, read the way mdship reads it
/// (`read_numbering_config` in `mdship/markdown/headings.py`).
///
/// - No front matter, or no `number:` key: nothing happens to the headings.
/// - `number: true`: number in the period style. `number: false`: unnumber.
/// - A mapping of `style`, `skip-title`, `generated` and `post-process`
///   numbers with those options; anything else is an error that stops the
///   update, and the messages here are mdship's.
enum FrontMatterNumbering {

    /// The keys `number:` accepts, for validation and completion.
    static let options: [PlaceholderSchema.Parameter] = [
        .init("style", .choice(HeadingNumbering.Style.allCases.map(\.rawValue)),
              "Numbering style (default period): 1.2. / 1.2 / 1.2)"),
        .init("skip-title", .boolean, "Leave a single h1 title unnumbered (default false)"),
        .init("generated", .boolean,
              "Let numbering change generated content and recalculate its checksum (default false)"),
        .init("post-process", .boolean,
              "Renumber after the update, generated headings included, then regenerate the TOC (default false)"),
    ]

    /// The top-level key itself, for completion.
    static let key = PlaceholderSchema.Parameter(
        "number", .boolean,
        "Number headings on mdship update: true, false (remove numbering), or a mapping of style, skip-title, generated, post-process")

    struct Reading: Sendable, Equatable {
        /// Nil when there is no `number:` key or it has an error.
        var settings: NumberingSettings?
        var problems: [YAMLOutline.Problem] = []
        /// The `number:` key, where problems about the whole value go.
        var keyRange: NSRange?
        /// The `skip-title` value, where mdship's "more than one h1" error goes.
        var skipTitleRange: NSRange?
        /// The first line after the closing `---`, zero-based.
        var bodyStart: Int
    }

    /// The front matter as mdship sees it: the document starts with a `---`
    /// line, and the first later line that is exactly `---` closes it.
    /// Returns the closing line, or nil.
    static func closingLine(_ text: NSString, lines: LineIndex) -> Int? {
        guard lines.count > 1, text.substring(with: lines.contentRange(ofLine: 0)) == "---" else { return nil }
        return (1..<lines.count).first { text.substring(with: lines.contentRange(ofLine: $0)) == "---" }
    }

    /// Nil when the document has no front matter mdship would read.
    static func read(_ text: NSString, lines: LineIndex) -> Reading? {
        guard let close = closingLine(text, lines: lines) else { return nil }
        let start = lines.starts[1]
        let yaml = text.substring(with: NSRange(location: start, length: lines.starts[close] - start))
        var reading = Reading(bodyStart: close + 1)
        guard let entry = YAMLOutline(yaml, offset: start, line: 1).entry("number") else { return reading }
        reading.keyRange = entry.keyRange

        func problem(_ range: NSRange?, _ message: String) {
            reading.problems.append(YAMLOutline.Problem(range: range ?? entry.keyRange, message: message))
        }

        var options: [(key: String, keyRange: NSRange, value: YAMLOutline.Node)]
        switch entry.value {
        case .scalar(let text, _, let quoted):
            if !quoted, let flag = yamlBool(text) {
                reading.settings = NumberingSettings(number: flag)
            } else {
                problem(entry.keyRange, notAMapping(entry.value))
            }
            return reading
        case .mapping(let entries):
            options = entries.map { ($0.key, $0.keyRange, $0.value) }
        case .flow(let text, let range):
            guard let parsed = flowMapping(text, range: range) else {
                // A flow list, or a flow mapping too elaborate to read here:
                // mdship decides; the editor stays quiet rather than guess.
                if text.hasPrefix("[") { problem(entry.keyRange, notAMapping(entry.value)) }
                return reading
            }
            options = parsed
        default:
            problem(entry.keyRange, notAMapping(entry.value))
            return reading
        }

        var settings = NumberingSettings(number: true)
        let known = Self.options.map(\.name)
        for option in options where !known.contains(option.key) {
            problem(option.keyRange,
                    "Unknown front-matter 'number:' key(s): \(option.key). Allowed keys are \(known.joined(separator: ", "))")
        }
        for option in options {
            let range = option.value.range ?? option.keyRange
            switch option.key {
            case "style":
                if let text = option.value.scalarText, let style = HeadingNumbering.Style(rawValue: text) {
                    settings.style = style
                } else {
                    problem(range, "Front-matter 'number.style' must be 'period', 'space', or 'parenthesis', not \(pythonRepr(option.value))")
                }
            case "skip-title", "generated", "post-process":
                guard case .scalar(let text, _, false) = option.value, let flag = yamlBool(text) else {
                    problem(range, "Front-matter 'number.\(option.key)' must be true or false, not \(pythonRepr(option.value))")
                    continue
                }
                switch option.key {
                case "skip-title":
                    settings.skipTitle = flag
                    reading.skipTitleRange = range
                case "generated": settings.generated = flag
                default: settings.postProcess = flag
                }
            default:
                break
            }
        }
        if reading.problems.isEmpty { reading.settings = settings }
        return reading
    }

    /// What `mdship update` does to the lines first: number or unnumber
    /// everything after the front matter.
    static func apply(_ settings: NumberingSettings, to lines: [String], bodyStart: Int) throws -> [String] {
        settings.number
            ? try HeadingNumbering.number(lines, from: bodyStart, style: settings.style, skipTitle: settings.skipTitle)
            : HeadingNumbering.unnumber(lines, from: bodyStart)
    }

    // MARK: - YAML as PyYAML reads it

    /// PyYAML's booleans; any other spelling is a string.
    static func yamlBool(_ text: String) -> Bool? {
        switch text {
        case "true", "True", "TRUE", "yes", "Yes", "YES", "on", "On", "ON": true
        case "false", "False", "FALSE", "no", "No", "NO", "off", "Off", "OFF": false
        default: nil
        }
    }

    private static let nulls: Set<String> = ["", "~", "null", "Null", "NULL"]

    /// How mdship's message shows the offending value: Python's `repr` for
    /// scalars, a description for anything bigger.
    static func pythonRepr(_ node: YAMLOutline.Node) -> String {
        switch node {
        case .null:
            return "None"
        case .scalar(let text, _, let quoted):
            if !quoted {
                if let flag = yamlBool(text) { return flag ? "True" : "False" }
                if nulls.contains(text) { return "None" }
                if Int(text) != nil || Double(text) != nil { return text }
            }
            return text.contains("'") && !text.contains("\"") ? "\"\(text)\"" : "'\(text)'"
        default:
            return node.shapeName
        }
    }

    private static func notAMapping(_ node: YAMLOutline.Node) -> String {
        "Front-matter 'number:' must be true, false, or a mapping of \(options.map(\.name).joined(separator: ", ")), not \(pythonRepr(node))"
    }

    /// A one-level flow mapping, `{style: space, generated: true}`, every value
    /// a plain or quoted scalar. Nil for anything else.
    static func flowMapping(_ text: String, range: NSRange) -> [(key: String, keyRange: NSRange, value: YAMLOutline.Node)]? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return nil }
        let inner = trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        if inner.isEmpty { return [] }
        var result: [(key: String, keyRange: NSRange, value: YAMLOutline.Node)] = []
        for pair in inner.split(separator: ",", omittingEmptySubsequences: false) {
            guard let colon = pair.firstIndex(of: ":") else { return nil }
            let key = pair[..<colon].trimmingCharacters(in: .whitespaces)
            var value = pair[pair.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !"{[".contains(value.first ?? " ") else { return nil }
            var quoted = false
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
                quoted = true
            }
            let node: YAMLOutline.Node = value.isEmpty && !quoted ? .null : .scalar(text: value, range: range, quoted: quoted)
            result.append((key, range, node))
        }
        return result
    }
}
