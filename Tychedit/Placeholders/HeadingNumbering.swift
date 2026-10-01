import Foundation

/// mdship's heading numbering -- `add_heading_numbers` and
/// `remove_heading_numbers` in `mdship/markdown/headings.py` -- line for line.
///
/// Ported rather than approximated, quirks included, because the editor uses
/// it to tell which lines `mdship update` will rewrite: only lines starting
/// with ```` ``` ```` toggle a fence, a line that opens a multi-line HTML
/// comment is still checked while the lines after it are not, and the six
/// number-prefix patterns are stripped one after another.
enum HeadingNumbering {

    enum Style: String, CaseIterable, Sendable {
        case period, space, parenthesis

        /// `_format_number`: `1.2. `, `1.2 ` or `1.2) `.
        func prefix(_ numbers: [Int]) -> String {
            let joined = numbers.map(String.init).joined(separator: ".")
            switch self {
            case .period: return joined + ". "
            case .space: return joined + " "
            case .parenthesis: return joined + ") "
            }
        }
    }

    /// mdship refuses `skip-title` when there is more than one h1.
    struct SkipTitleError: Error, Equatable {
        let h1Count: Int
        var message: String { "--skip-title requires exactly one h1 heading, but found \(h1Count)" }
    }

    struct Heading: Equatable {
        /// Index into the lines.
        let index: Int
        let level: Int
        /// The text after the `#` run and its whitespace.
        let text: String
    }

    /// `lines` with numbering removed from every heading from `start` on.
    static func unnumber(_ lines: [String], from start: Int) -> [String] {
        var lines = lines
        for heading in headings(in: lines, from: start) {
            lines[heading.index] = String(repeating: "#", count: heading.level) + " " + stripNumber(heading.text)
        }
        return lines
    }

    /// `lines` with every heading from `start` on numbered afresh.
    static func number(_ lines: [String], from start: Int, style: Style, skipTitle: Bool) throws -> [String] {
        var lines = unnumber(lines, from: start)
        if skipTitle {
            let h1Count = eligibleLines(lines, from: start).filter { lines[$0].hasPrefix("# ") }.count
            if h1Count > 1 { throw SkipTitleError(h1Count: h1Count) }
        }
        var counters: [Int: Int] = [:]
        for heading in headings(in: lines, from: start) {
            if skipTitle && heading.level == 1 { continue }
            counters[heading.level, default: 0] += 1
            for level in counters.keys where level > heading.level {
                counters[level] = nil
            }
            let sequence = counters.keys.sorted().map { counters[$0]! }
            lines[heading.index] = String(repeating: "#", count: heading.level) + " "
                + style.prefix(sequence) + heading.text
        }
        return lines
    }

    /// The heading lines from `start` on that mdship's numbering touches.
    static func headings(in lines: [String], from start: Int) -> [Heading] {
        eligibleLines(lines, from: start).compactMap { index in
            let line = lines[index]
            let ns = line as NSString
            guard let match = headingPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
                return nil
            }
            return Heading(index: index, level: match.range(at: 1).length, text: ns.substring(with: match.range(at: 2)))
        }
    }

    /// Indices of the lines from `start` on outside fences and multi-line
    /// HTML comments. The state is tracked from the first line, front matter
    /// included, as mdship tracks it.
    static func eligibleLines(_ lines: [String], from start: Int) -> [Int] {
        var result: [Int] = []
        var inCode = false
        var inComment = false
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("```") { inCode.toggle() }
            let wasInComment = inComment
            let ns = line as NSString
            if inComment {
                if ns.range(of: "-->").location != NSNotFound { inComment = false }
            } else {
                let open = ns.range(of: "<!--")
                if open.location != NSNotFound {
                    let after = NSRange(location: open.location + 4, length: ns.length - open.location - 4)
                    if ns.range(of: "-->", options: [], range: after).location == NSNotFound { inComment = true }
                }
            }
            if index >= start && !inCode && !wasInComment { result.append(index) }
        }
        return result
    }

    /// The heading text with any number prefix removed, the patterns applied in mdship's order.
    static func stripNumber(_ text: String) -> String {
        numberPrefixes.reduce(text) { text, regex in
            regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length),
                                           withTemplate: "")
        }
    }

    // `try!` is safe: the patterns are constants, and a typo fails every test.
    // `.` must match a trailing `\r` as Python's does.
    private static let headingPattern = try! NSRegularExpression(
        pattern: #"^(#{1,6})\s+(.+)$"#, options: [.dotMatchesLineSeparators])
    private static let numberPrefixes = [
        #"^(\d+\.)+(\d+)\) "#,
        #"^(\d+\.)+(\d+)\. "#,
        #"^(\d+\.)+(\d+) "#,
        #"^\d+\) "#,
        #"^\d+\. "#,
        #"^\d+ "#,
    ].map { try! NSRegularExpression(pattern: $0) }
}
