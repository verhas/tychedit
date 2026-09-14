import Foundation

/// How a stretch of the editor's text looks.
struct TextStyle: Hashable, Sendable {

    enum Color: Hashable, Sendable {
        case text
        /// Inline code and fenced code blocks.
        case code
        /// HTML comments that are not placeholders, and front matter.
        case comment
        /// A placeholder's `<!--INCLUDE ... -->` and `<!--/INCLUDE-->`.
        case placeholder
        /// The YAML keys inside a placeholder's opening comment.
        case placeholderKey
        /// `<!--$name-->` and the marker closing a long variable reference.
        case variable
    }

    var bold = false
    var italic = false
    var strike = false
    /// 1...6 for heading lines, 0 otherwise.
    var heading = 0
    var color = Color.text

    static let plain = TextStyle()
}

/// A run of characters sharing one style.
struct StyleRun: Sendable, Equatable {
    let range: NSRange
    let style: TextStyle
}

/// Works out how each part of a markdown document is drawn in the editor.
///
/// Markdown markers stay visible and take the style of what they mark: the `**`
/// of bold text is bold too, as asked. The result covers the whole text, plain
/// runs included, so styling that no longer applies is removed as well.
enum SyntaxHighlighter {

    static func runs(in text: String, headings: [Heading], scan: PlaceholderScan) -> [StyleRun] {
        let ns = text as NSString
        let length = ns.length
        guard length > 0 else { return [] }
        let lines = LineIndex(ns)
        var styles = [TextStyle](repeating: .plain, count: length)
        // Ranges already claimed by code, comments and placeholders: no inline markup there.
        var claimed = IndexSet()

        func paint(_ range: NSRange, _ change: (inout TextStyle) -> Void) {
            guard range.location >= 0, range.length > 0 else { return }
            let end = min(length, NSMaxRange(range))
            for i in range.location..<end { change(&styles[i]) }
        }

        // Front matter.
        if let frontMatter = scan.frontMatter {
            let range = lines.fullRange(ofLines: frontMatter)
            paint(range) { $0.color = .comment }
            claimed.insert(integersIn: range.location..<NSMaxRange(range))
        }

        // Fenced code blocks, fences included.
        var fence: Fence?
        var fenceStart = 0
        for line in 0..<lines.count {
            let content = ns.substring(with: lines.contentRange(ofLine: line))
            if let open = fence {
                if open.isClosed(by: content) {
                    let range = lines.fullRange(ofLines: fenceStart...line)
                    paint(range) { $0.color = .code }
                    claimed.insert(integersIn: range.location..<NSMaxRange(range))
                    fence = nil
                }
            } else if let opening = Fence.opening(content) {
                fence = opening
                fenceStart = line
            }
        }
        if fence != nil {
            // Unclosed: code to the end, as the preview shows it.
            let range = lines.fullRange(ofLines: fenceStart...(lines.count - 1))
            paint(range) { $0.color = .code }
            claimed.insert(integersIn: range.location..<NSMaxRange(range))
        }

        // Headings: the whole line, larger and bold.
        for heading in headings where heading.line < lines.count {
            let range = lines.contentRange(ofLine: heading.line)
            if claimed.contains(range.location) { continue }
            paint(range) { $0.heading = heading.level; $0.bold = true }
            // A setext heading's underline.
            if heading.line + 1 < lines.count {
                let next = lines.contentRange(ofLine: heading.line + 1)
                let underline = ns.substring(with: next).trimmingCharacters(in: .whitespaces)
                if !underline.isEmpty, underline.allSatisfy({ $0 == "=" }) || underline.allSatisfy({ $0 == "-" }) {
                    paint(next) { $0.heading = heading.level; $0.bold = true }
                }
            }
        }

        // Placeholders: the comments, and the keys inside them.
        for placeholder in scan.placeholders {
            paint(placeholder.openRange) { $0.color = .placeholder }
            claimed.insert(integersIn: placeholder.openRange.location..<NSMaxRange(placeholder.openRange))
            let outline = YAMLOutline(placeholder.config,
                                      offset: placeholder.openRange.location + 4 + placeholder.kind.rawValue.utf16.count,
                                      line: placeholder.openLines.lowerBound)
            paintKeys(outline.entries) { range in paint(range) { $0.color = .placeholderKey; $0.bold = true } }
            if let close = placeholder.closeRange {
                paint(close) { $0.color = .placeholder }
                claimed.insert(integersIn: close.location..<NSMaxRange(close))
            }
        }
        for variable in scan.variables {
            let head = NSRange(location: variable.range.location, length: variable.valueRange.location - variable.range.location)
            paint(head) { $0.color = .variable }
            claimed.insert(integersIn: head.location..<NSMaxRange(head))
            let tailStart = NSMaxRange(variable.valueRange)
            let tail = NSRange(location: tailStart, length: NSMaxRange(variable.range) - tailStart)
            paint(tail) { $0.color = .variable }
            claimed.insert(integersIn: tail.location..<max(tail.location, NSMaxRange(tail)))
        }

        // Other HTML comments.
        for match in commentPattern.matches(in: text, range: NSRange(location: 0, length: length)) {
            let range = match.range
            if claimed.intersects(integersIn: range.location..<NSMaxRange(range)) { continue }
            paint(range) { $0.color = .comment }
            claimed.insert(integersIn: range.location..<NSMaxRange(range))
        }

        // Inline markup, line by line, outside everything claimed.
        for line in 0..<lines.count {
            let lineRange = lines.contentRange(ofLine: line)
            guard lineRange.length > 0 else { continue }
            if claimed.contains(integersIn: lineRange.location..<NSMaxRange(lineRange)) { continue }
            var content = ns.substring(with: lineRange)

            // Code spans first; their contents are masked so no emphasis is found inside.
            var masked = Array(content.utf16)
            for match in codeSpanPattern.matches(in: content, range: NSRange(location: 0, length: masked.count)) {
                let range = NSRange(location: lineRange.location + match.range.location, length: match.range.length)
                if claimed.intersects(integersIn: range.location..<NSMaxRange(range)) { continue }
                paint(range) { $0.color = .code }
                for i in match.range.location..<NSMaxRange(match.range) { masked[i] = 32 }
            }
            // Claimed characters inside the line (a variable reference, a comment) are masked too.
            for i in 0..<masked.count where claimed.contains(lineRange.location + i) { masked[i] = 32 }
            content = String(utf16CodeUnits: masked, count: masked.count)
            let whole = NSRange(location: 0, length: masked.count)

            for (pattern, change) in emphasis {
                for match in pattern.matches(in: content, range: whole) {
                    paint(NSRange(location: lineRange.location + match.range.location, length: match.range.length), change)
                }
            }
        }

        // Compress into runs.
        var runs: [StyleRun] = []
        var start = 0
        for i in 1...length where i == length || styles[i] != styles[start] {
            runs.append(StyleRun(range: NSRange(location: start, length: i - start), style: styles[start]))
            start = i
        }
        return runs
    }

    private static func paintKeys(_ entries: [YAMLOutline.Entry], _ paint: (NSRange) -> Void) {
        for entry in entries {
            paint(entry.keyRange)
            switch entry.value {
            case .mapping(let children):
                paintKeys(children, paint)
            case .sequence(let items):
                for item in items {
                    if case .mapping(let children) = item.value { paintKeys(children, paint) }
                }
            default:
                break
            }
        }
    }

    private static let commentPattern = try! NSRegularExpression(pattern: #"<!--[\s\S]*?-->"#)
    private static let codeSpanPattern = try! NSRegularExpression(pattern: #"(`+)(?!`)(.+?)(?<!`)\1(?!`)"#)

    /// Emphasis, strongest first. Underscores only count at word boundaries,
    /// so `snake_case_names` stay plain.
    private static let emphasis: [(NSRegularExpression, @Sendable (inout TextStyle) -> Void)] = [
        (try! NSRegularExpression(pattern: #"\*\*\*(?=\S)(.+?)(?<=\S)\*\*\*"#), { $0.bold = true; $0.italic = true }),
        (try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])___(?=\S)(.+?)(?<=\S)___(?![A-Za-z0-9_])"#), { $0.bold = true; $0.italic = true }),
        (try! NSRegularExpression(pattern: #"\*\*(?=\S)(.+?)(?<=\S)\*\*"#), { $0.bold = true }),
        (try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])__(?=\S)(.+?)(?<=\S)__(?![A-Za-z0-9_])"#), { $0.bold = true }),
        (try! NSRegularExpression(pattern: #"(?<![*\\])\*(?=[^\s*])(.+?)(?<=[^\s*\\])\*(?!\*)"#), { $0.italic = true }),
        (try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_\\])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![A-Za-z0-9_])"#), { $0.italic = true }),
        (try! NSRegularExpression(pattern: #"~~(?=\S)(.+?)(?<=\S)~~"#), { $0.strike = true }),
    ]
}
