import Foundation

/// A heading, for the navigation menu.
struct Heading: Sendable, Equatable, Identifiable {
    let level: Int
    let text: String
    /// Zero-based source line.
    let line: Int
    let anchor: String
    var id: Int { line }
}

/// Everything one pass over the document produces.
struct RenderResult: Sendable, Equatable {
    /// The preview's content: the inside of the page's content element.
    let html: String
    let headings: [Heading]
    let scan: PlaceholderScan

    static let empty = RenderResult(html: "", headings: [], scan: PlaceholderScan())
}

/// Markdown to HTML, with mdship placeholders made visible.
///
/// Written here rather than taken from a library for two reasons. mdship
/// placeholders are HTML comments, which every markdown library passes
/// through and every browser then hides -- exactly the parts this editor
/// exists to show. And each block carries `data-line`, its source line, which
/// is what lets the preview follow the editor's scrolling.
///
/// The dialect is CommonMark with the GitHub additions people rely on:
/// tables, task lists, strikethrough and bare URLs.
enum MarkdownRenderer {

    static func render(_ text: String) -> RenderResult {
        let scan = PlaceholderScanner.scan(text)
        let ns = text as NSString
        let index = LineIndex(ns)
        let lines = (0..<index.count).map { number -> SourceLine in
            var content = ns.substring(with: index.contentRange(ofLine: number))
            if content.hasSuffix("\r") { content.removeLast() }
            return SourceLine(text: content, number: number)
        }
        let context = Context(text: ns, index: index, lines: lines, scan: scan)
        let html = context.renderDocument()
        return RenderResult(html: html, headings: context.headings, scan: scan)
    }

    /// The document's link reference definitions, `[label]: url`, by normalized label.
    static func linkDefinitions(in text: String) -> [String: LinkReference] {
        let ns = text as NSString
        let index = LineIndex(ns)
        let lines = (0..<index.count).map { SourceLine(text: ns.substring(with: index.contentRange(ofLine: $0)), number: $0) }
        return Context.collectReferences(lines)
    }
}

/// One line of source, remembering where it came from.
struct SourceLine: Sendable, Equatable {
    var text: String
    let number: Int
}

private final class Context {

    let text: NSString
    let index: LineIndex
    let lines: [SourceLine]
    let scan: PlaceholderScan
    let inline: InlineRenderer
    private(set) var headings: [Heading] = []
    private var anchorCounts: [String: Int] = [:]
    /// Per-kind counters, so each placeholder card keeps a stable key while
    /// lines above it are added or removed. The preview uses the key to keep an
    /// expanded card expanded across refreshes.
    private var kindCounts: [PlaceholderKind: Int] = [:]

    init(text: NSString, index: LineIndex, lines: [SourceLine], scan: PlaceholderScan) {
        self.text = text
        self.index = index
        self.lines = lines
        self.scan = scan
        self.inline = InlineRenderer(references: Context.collectReferences(lines))
    }

    // MARK: - Document and placeholders

    func renderDocument() -> String {
        var html = ""
        var start = 0
        if let frontMatter = scan.frontMatter {
            let yaml = lines[(frontMatter.lowerBound + 1)..<frontMatter.upperBound].map(\.text).joined(separator: "\n")
            html += """
                <details class="mds-self mds-frontmatter" data-line="0" data-key="frontmatter">\
                <summary><span class="mds-badge">front matter</span></summary>\
                <pre class="mds-config">\(HTML.escape(yaml))</pre></details>\n
                """
            start = frontMatter.upperBound + 1
        }
        html += renderRegion(lines: start..<lines.count)
        return html
    }

    /// Lines `range`, with every placeholder that starts in it rendered as a card
    /// and the markdown between them rendered normally.
    func renderRegion(lines range: Range<Int>) -> String {
        var html = ""
        var cursor = range.lowerBound
        let starting = scan.placeholders
            .filter { range.contains($0.openLines.lowerBound) }
            .sorted { $0.openRange.location < $1.openRange.location }
        for placeholder in starting where placeholder.openLines.lowerBound >= cursor {
            html += blocks(Array(lines[cursor..<placeholder.openLines.lowerBound]))
            html += renderPlaceholder(placeholder)
            cursor = min(range.upperBound, placeholder.lastLine + 1)
            if placeholder.isUnclosed {
                cursor = min(range.upperBound, placeholder.openLines.upperBound + 1)
            }
        }
        if cursor < range.upperBound {
            html += blocks(Array(lines[cursor..<range.upperBound]))
        }
        return html
    }

    func renderPlaceholder(_ placeholder: Placeholder) -> String {
        let kind = placeholder.kind
        let ordinal = kindCounts[kind, default: 0]
        kindCounts[kind] = ordinal + 1

        let problem = placeholder.isUnclosed || placeholder.integrity.blocksUpdate
        var classes = ["mds-ph", "mds-kind-\(kind.rawValue.lowercased())"]
        if placeholder.shape == .selfContained { classes.append("mds-self") }
        if problem { classes.append("mds-problem") }

        let summary = placeholder.summary.dropFirst(kind.rawValue.count)
            .trimmingCharacters(in: .whitespaces)
        var state = ""
        switch placeholder.integrity {
        case .none: break
        case .unrecorded: state = #"<span class="mds-state">not generated yet</span>"#
        case .intact: state = #"<span class="mds-state mds-ok">generated</span>"#
        case .edited: state = #"<span class="mds-state mds-bad">edited by hand: update will refuse</span>"#
        case .moved: state = #"<span class="mds-state mds-bad">changed length: update will refuse</span>"#
        case .overridden: state = #"<span class="mds-state">_yolo_: edits are overwritten</span>"#
        }
        if placeholder.isUnclosed {
            state += #"<span class="mds-state mds-bad">unclosed: expected &lt;!--/\#(HTML.escape(placeholder.terminator))--&gt;</span>"#
        }

        var html = "<section class=\"\(classes.joined(separator: " "))\" data-line=\"\(placeholder.openLines.lowerBound)\">"
        html += "<details class=\"mds-def\" data-key=\"\(kind.rawValue)-\(ordinal)\">"
        html += "<summary><span class=\"mds-badge\">\(kind.rawValue)</span>"
        if !summary.isEmpty {
            html += " <span class=\"mds-summary\">\(HTML.escape(summary))</span>"
        }
        html += " <span class=\"mds-role\">\(kind.role)</span>\(state)</summary>"
        html += "<pre class=\"mds-config\">\(HTML.escape(placeholder.config.trimmingCharacters(in: .newlines)))</pre>"
        html += "</details>"

        if placeholder.shape != .selfContained && !placeholder.isUnclosed {
            // Not yet generated: no empty frame.
            let body = renderBody(of: placeholder)
            if !body.isEmpty {
                html += "<div class=\"mds-body\">\(body)</div>"
            }
        }
        html += "</section>\n"
        return html
    }

    /// The managed content, rendered as markdown -- it can hold further placeholders.
    func renderBody(of placeholder: Placeholder) -> String {
        if placeholder.shape == .managedLine {
            guard let line = placeholder.managedLine else { return "" }
            return blocks([lines[line]])
        }
        guard let closeLine = placeholder.closeLine, let close = placeholder.closeRange else { return "" }
        let firstBodyLine = placeholder.openLines.upperBound + 1
        guard firstBodyLine <= closeLine else { return "" }

        var html = renderRegion(lines: firstBodyLine..<closeLine)
        // Generated content that runs straight into the closing tag, without a
        // newline, shares the tag's line.
        let lineStart = index.starts[closeLine]
        let before = text.substring(with: NSRange(location: lineStart, length: close.location - lineStart))
        if !before.trimmingCharacters(in: .whitespaces).isEmpty {
            html += blocks([SourceLine(text: before, number: closeLine)])
        }
        return html
    }

    // MARK: - Blocks

    /// Renders a run of lines as block elements. `tight` renders paragraphs
    /// without `<p>`, as in a list whose items have no blank lines between them.
    func blocks(_ lines: [SourceLine], tight: Bool = false) -> String {
        var html = ""
        var paragraph: [SourceLine] = []
        var i = 0

        func flushParagraph() {
            guard let first = paragraph.first else { return }
            let content = paragraph.map { $0.text.drop(while: { $0 == " " || $0 == "\t" }) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespaces)
            let rendered = inline.render(content)
            html += tight ? rendered + "\n" : "<p data-line=\"\(first.number)\">\(rendered)</p>\n"
            paragraph.removeAll()
        }

        while i < lines.count {
            let line = lines[i]
            let text = Context.expandLeadingTabs(line.text)
            let indent = Context.indentation(text)

            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // Indented code cannot interrupt a paragraph.
            if indent >= 4 && paragraph.isEmpty {
                var code: [String] = []
                var j = i
                while j < lines.count {
                    let candidate = Context.expandLeadingTabs(lines[j].text)
                    if candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                        code.append("")
                    } else if Context.indentation(candidate) >= 4 {
                        code.append(String(candidate.dropFirst(4)))
                    } else {
                        break
                    }
                    j += 1
                }
                while code.last == "" { code.removeLast() }
                html += "<pre data-line=\"\(line.number)\"><code>\(HTML.escape(code.joined(separator: "\n")))\n</code></pre>\n"
                i = j
                continue
            }

            // Setext heading: a paragraph underlined with === or ---.
            if !paragraph.isEmpty && indent < 4 {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && (trimmed.allSatisfy { $0 == "=" } || trimmed.allSatisfy { $0 == "-" }) {
                    let level = trimmed.first == "=" ? 1 : 2
                    let content = paragraph.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
                    html += heading(level: level, raw: content, line: paragraph[0].number)
                    paragraph.removeAll()
                    i += 1
                    continue
                }
            }

            if let fence = Fence.opening(text) {
                flushParagraph()
                var code: [String] = []
                var j = i + 1
                while j < lines.count, !fence.isClosed(by: lines[j].text) {
                    code.append(Context.removeIndent(lines[j].text, upTo: fence.indent))
                    j += 1
                }
                let language = fence.info.split(separator: " ").first.map(String.init) ?? ""
                let languageClass = language.isEmpty ? "" : " class=\"language-\(HTML.escape(language))\""
                let body = code.isEmpty ? "" : HTML.escape(code.joined(separator: "\n")) + "\n"
                html += "<pre data-line=\"\(line.number)\"><code\(languageClass)>\(body)</code></pre>\n"
                i = min(j + 1, lines.count)
                continue
            }

            if let (level, content) = Context.atxHeading(text) {
                flushParagraph()
                html += heading(level: level, raw: content, line: line.number)
                i += 1
                continue
            }

            if Context.isThematicBreak(text) {
                flushParagraph()
                html += "<hr data-line=\"\(line.number)\">\n"
                i += 1
                continue
            }

            if indent < 4, text.drop(while: { $0 == " " }).hasPrefix(">") {
                flushParagraph()
                var quoted: [SourceLine] = []
                var j = i
                while j < lines.count {
                    let candidate = lines[j].text
                    let stripped = candidate.drop(while: { $0 == " " })
                    if stripped.hasPrefix(">") {
                        var rest = stripped.dropFirst()
                        if rest.first == " " { rest = rest.dropFirst() }
                        quoted.append(SourceLine(text: String(rest), number: lines[j].number))
                    } else if !candidate.trimmingCharacters(in: .whitespaces).isEmpty,
                              let previous = quoted.last, !previous.text.trimmingCharacters(in: .whitespaces).isEmpty,
                              !Context.startsBlock(candidate) {
                        // Lazy continuation of the quoted paragraph.
                        quoted.append(lines[j])
                    } else {
                        break
                    }
                    j += 1
                }
                html += "<blockquote data-line=\"\(line.number)\">\n\(blocks(quoted))</blockquote>\n"
                i = j
                continue
            }

            if let marker = ListMarker(text), paragraph.isEmpty || marker.canInterruptParagraph {
                flushParagraph()
                let (listHTML, next) = list(lines, from: i, first: marker)
                html += listHTML
                i = next
                continue
            }

            if paragraph.isEmpty, text.contains("|"), i + 1 < lines.count,
               let alignments = Context.tableDelimiter(lines[i + 1].text),
               Context.cells(text).count == alignments.count {
                let (tableHTML, next) = table(lines, from: i, alignments: alignments)
                html += tableHTML
                i = next
                continue
            }

            if indent < 4, let end = htmlBlockEnd(lines, from: i, interruptingParagraph: !paragraph.isEmpty) {
                flushParagraph()
                let raw = lines[i...end].map(\.text).joined(separator: "\n")
                html += raw + "\n"
                i = end + 1
                continue
            }

            if paragraph.isEmpty, indent < 4, Context.isReferenceDefinition(text) {
                i += 1
                continue
            }

            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        return html
    }

    func heading(level: Int, raw: String, line: Int) -> String {
        var anchor = HTML.anchor(for: raw)
        let seen = anchorCounts[anchor, default: 0]
        anchorCounts[anchor] = seen + 1
        if seen > 0 { anchor += "-\(seen)" }
        let plain = raw.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        headings.append(Heading(level: level, text: plain, line: line, anchor: anchor))
        return "<h\(level) id=\"\(HTML.escape(anchor))\" data-line=\"\(line)\">\(inline.render(raw))</h\(level)>\n"
    }

    // MARK: Lists

    struct ListMarker {
        let ordered: Bool
        /// `-`, `+`, `*`, `.` or `)`: items of one list share it.
        let symbol: Character
        let start: Int
        let indent: Int
        /// Column where the item's content starts.
        let contentIndent: Int
        let rest: String

        init?(_ line: String) {
            let chars = Array(line)
            var i = 0
            while i < chars.count, chars[i] == " " { i += 1 }
            guard i <= 3, i < chars.count else { return nil }
            indent = i

            if "-+*".contains(chars[i]) {
                ordered = false
                symbol = chars[i]
                start = 1
                i += 1
            } else {
                var digits = ""
                while i < chars.count, chars[i].isASCII, chars[i].isNumber, digits.count < 9 {
                    digits.append(chars[i])
                    i += 1
                }
                guard !digits.isEmpty, i < chars.count, chars[i] == "." || chars[i] == ")" else { return nil }
                ordered = true
                symbol = chars[i]
                start = Int(digits) ?? 1
                i += 1
            }

            let markerEnd = i
            if markerEnd == chars.count {
                contentIndent = markerEnd + 1
                rest = ""
                return
            }
            guard chars[markerEnd] == " " || chars[markerEnd] == "\t" else { return nil }
            var spaces = 0
            while i < chars.count, chars[i] == " " { spaces += 1; i += 1 }
            if i == chars.count {
                contentIndent = markerEnd + 1
                rest = ""
            } else if spaces > 4 {
                // Five or more spaces: the item starts with indented code.
                contentIndent = markerEnd + 1
                rest = String(chars[(markerEnd + 1)...])
            } else {
                contentIndent = markerEnd + max(spaces, 1)
                rest = String(chars[i...])
            }
        }

        /// CommonMark: only a non-empty bullet, or an ordered item numbered 1,
        /// may interrupt a paragraph -- so "in 2024. we" does not become a list.
        var canInterruptParagraph: Bool {
            !rest.isEmpty && (!ordered || start == 1)
        }

        func continues(_ other: ListMarker) -> Bool {
            ordered == other.ordered && symbol == other.symbol
        }
    }

    func list(_ lines: [SourceLine], from start: Int, first: ListMarker) -> (String, Int) {
        var items: [(marker: ListMarker, lines: [SourceLine], number: Int)] = []
        var current: [SourceLine] = [SourceLine(text: first.rest, number: lines[start].number)]
        var marker = first
        var itemStart = lines[start].number
        var previousBlank = false
        var j = start + 1

        while j < lines.count {
            let raw = lines[j]
            let text = Context.expandLeadingTabs(raw.text)
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                current.append(SourceLine(text: "", number: raw.number))
                previousBlank = true
                j += 1
                continue
            }
            let indent = Context.indentation(text)
            if indent >= marker.contentIndent {
                current.append(SourceLine(text: String(text.dropFirst(marker.contentIndent)), number: raw.number))
                previousBlank = false
                j += 1
                continue
            }
            if !Context.isThematicBreak(text), let next = ListMarker(text), next.continues(first) {
                items.append((marker, current, itemStart))
                marker = next
                itemStart = raw.number
                current = [SourceLine(text: next.rest, number: raw.number)]
                previousBlank = false
                j += 1
                continue
            }
            if !previousBlank && !Context.startsBlock(text) && ListMarker(text) == nil {
                current.append(SourceLine(text: text.trimmingCharacters(in: .whitespaces), number: raw.number))
                j += 1
                continue
            }
            break
        }
        items.append((marker, current, itemStart))

        // Blank lines after the last item belong to whatever follows the list.
        while let last = items.last?.lines.last, last.text.isEmpty, items[items.count - 1].lines.count > 1 {
            items[items.count - 1].lines.removeLast()
            j -= 1
        }

        // Loose when any item ends in a blank line before the next item, or
        // holds a blank line between two of its own blocks.
        var loose = false
        for (index, item) in items.enumerated() {
            var itemLines = item.lines
            var trailingBlank = false
            while itemLines.count > 1, itemLines.last?.text.isEmpty == true {
                itemLines.removeLast()
                trailingBlank = true
            }
            if trailingBlank && index < items.count - 1 { loose = true }
            if itemLines.dropFirst().contains(where: { $0.text.isEmpty }) {
                // A blank line inside a fenced code block does not count, but
                // telling those apart costs a parse; treating it as loose only
                // adds paragraph spacing.
                loose = true
            }
        }

        let tag = first.ordered ? "ol" : "ul"
        let startAttribute = first.ordered && first.start != 1 ? " start=\"\(first.start)\"" : ""
        var html = "<\(tag)\(startAttribute) data-line=\"\(lines[start].number)\">\n"
        for item in items {
            var itemLines = item.lines
            var taskBox = ""
            if let firstLine = itemLines.first {
                let content = firstLine.text
                if content.hasPrefix("[ ] ") || content == "[ ]" {
                    taskBox = "<input type=\"checkbox\" disabled> "
                    itemLines[0].text = String(content.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                } else if content.lowercased().hasPrefix("[x] ") || content.lowercased() == "[x]" {
                    taskBox = "<input type=\"checkbox\" checked disabled> "
                    itemLines[0].text = String(content.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
            }
            let taskClass = taskBox.isEmpty ? "" : " class=\"task\""
            html += "<li\(taskClass) data-line=\"\(item.number)\">\(taskBox)\(blocks(itemLines, tight: !loose))</li>\n"
        }
        html += "</\(tag)>\n"
        return (html, j)
    }

    // MARK: Tables

    enum Alignment { case none, left, center, right }

    func table(_ lines: [SourceLine], from start: Int, alignments: [Alignment]) -> (String, Int) {
        func style(_ column: Int) -> String {
            switch alignments[column] {
            case .none: ""
            case .left: " style=\"text-align:left\""
            case .center: " style=\"text-align:center\""
            case .right: " style=\"text-align:right\""
            }
        }
        var html = "<div class=\"table-wrap\" data-line=\"\(lines[start].number)\"><table>\n<thead><tr>"
        for (column, cell) in Context.cells(lines[start].text).enumerated() {
            html += "<th\(style(column))>\(inline.render(cell))</th>"
        }
        html += "</tr></thead>\n<tbody>\n"
        var j = start + 2
        while j < lines.count {
            let text = lines[j].text
            if text.trimmingCharacters(in: .whitespaces).isEmpty || Context.startsBlock(text) { break }
            var cells = Context.cells(text)
            if cells.count < alignments.count {
                cells += Array(repeating: "", count: alignments.count - cells.count)
            }
            html += "<tr data-line=\"\(lines[j].number)\">"
            for column in 0..<alignments.count {
                html += "<td\(style(column))>\(inline.render(cells[column]))</td>"
            }
            html += "</tr>\n"
            j += 1
        }
        html += "</tbody></table></div>\n"
        return (html, j)
    }

    static func tableDelimiter(_ line: String) -> [Alignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.allSatisfy({ "|:- \t".contains($0) }) else { return nil }
        let cells = Context.cells(trimmed)
        var alignments: [Alignment] = []
        for cell in cells {
            let c = cell.trimmingCharacters(in: .whitespaces)
            guard c.contains("-") else { return nil }
            switch (c.hasPrefix(":"), c.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (true, false): alignments.append(.left)
            case (false, true): alignments.append(.right)
            case (false, false): alignments.append(.none)
            }
        }
        return alignments.isEmpty ? nil : alignments
    }

    /// A row split at unescaped pipes outside code spans.
    static func cells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") && !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
        var cells: [String] = []
        var cell = ""
        var inCode = false
        var escaped = false
        for c in trimmed {
            if escaped {
                // `\|` is a literal pipe; other escapes are left for the inline pass.
                cell += c == "|" ? "|" : "\\\(c)"
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "`" {
                inCode.toggle()
                cell.append(c)
            } else if c == "|" && !inCode {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(c)
            }
        }
        if escaped { cell += "\\" }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }

    // MARK: Raw HTML

    private static let blockTags: Set<String> = [
        "address", "article", "aside", "blockquote", "body", "center", "dd", "details", "dialog", "div", "dl", "dt",
        "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr",
        "html", "iframe", "legend", "li", "main", "nav", "ol", "p", "picture", "section", "summary", "table",
        "tbody", "td", "tfoot", "th", "thead", "tr", "ul", "video", "audio", "source", "img", "br", "a", "span",
        "sup", "sub", "kbd", "b", "i", "em", "strong", "pre", "style",
    ]

    /// The last line of a raw HTML block starting at `start`, or nil if the
    /// line does not start one.
    func htmlBlockEnd(_ lines: [SourceLine], from start: Int, interruptingParagraph: Bool) -> Int? {
        let text = lines[start].text.drop(while: { $0 == " " })
        guard text.hasPrefix("<") else { return nil }

        if text.hasPrefix("<!--") {
            // `<!--$var-->value` at the start of a line is text with a variable
            // reference in it, not a comment block to hide.
            if text.hasPrefix("<!--$") { return nil }
            for j in start..<lines.count where lines[j].text.contains("-->") {
                if j == start, let close = text.range(of: "-->"), !text[close.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty {
                    // Something follows the comment on its line: leave it to the paragraph.
                    return nil
                }
                return j
            }
            return lines.count - 1
        }

        let name = text.dropFirst(text.hasPrefix("</") ? 2 : 1).prefix { $0.isLetter || $0.isNumber }.lowercased()
        guard !name.isEmpty else { return nil }
        if name == "pre" || name == "script" || name == "style" || name == "textarea" {
            for j in start..<lines.count where lines[j].text.lowercased().contains("</\(name)>") {
                return j
            }
            return lines.count - 1
        }
        guard Context.blockTags.contains(name) || !interruptingParagraph else { return nil }
        // A line holding only an inline element, such as a badge image followed
        // by text, reads better as a paragraph; a line that is only a tag is a block.
        if !Context.blockTags.contains(name) {
            let isWholeLineTag = text.trimmingCharacters(in: .whitespaces).hasSuffix(">")
            guard isWholeLineTag else { return nil }
        }
        var j = start
        while j + 1 < lines.count, !lines[j + 1].text.trimmingCharacters(in: .whitespaces).isEmpty {
            j += 1
        }
        return j
    }

    // MARK: Line classification

    static func expandLeadingTabs(_ line: String) -> String {
        guard line.contains("\t") else { return line }
        var column = 0
        var result = ""
        var index = line.startIndex
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            if line[index] == "\t" {
                let spaces = 4 - column % 4
                result += String(repeating: " ", count: spaces)
                column += spaces
            } else {
                result += " "
                column += 1
            }
            index = line.index(after: index)
        }
        return result + line[index...]
    }

    static func indentation(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    static func removeIndent(_ line: String, upTo count: Int) -> String {
        let spaces = min(count, indentation(line))
        return String(line.dropFirst(spaces))
    }

    static func atxHeading(_ line: String) -> (Int, String)? {
        let indent = indentation(line)
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        let hashes = rest.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let afterHashes = rest.dropFirst(hashes)
        guard afterHashes.isEmpty || afterHashes.first == " " || afterHashes.first == "\t" else { return nil }
        var content = afterHashes.trimmingCharacters(in: .whitespaces)
        // An optional closing run of #, separated by a space.
        if let range = content.range(of: #"(^|\s)#+$"#, options: .regularExpression) {
            content = String(content[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return (hashes, content)
    }

    static func isThematicBreak(_ line: String) -> Bool {
        guard indentation(line) <= 3 else { return false }
        let marks = line.filter { !$0.isWhitespace }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    /// Whether a line would start a block of its own, ending a paragraph.
    static func startsBlock(_ line: String) -> Bool {
        let text = expandLeadingTabs(line)
        let stripped = text.drop(while: { $0 == " " })
        return atxHeading(text) != nil
            || isThematicBreak(text)
            || Fence.opening(text) != nil
            || stripped.hasPrefix(">")
            || (ListMarker(text)?.canInterruptParagraph ?? false)
    }

    // MARK: Link references

    private static let referencePattern = try! NSRegularExpression(
        pattern: #"^ {0,3}\[([^\]]+)\]:\s*(<[^>]*>|\S+)(?:\s+("[^"]*"|'[^']*'|\([^)]*\)))?\s*$"#)

    static func isReferenceDefinition(_ line: String) -> Bool {
        referencePattern.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    static func collectReferences(_ lines: [SourceLine]) -> [String: LinkReference] {
        var references: [String: LinkReference] = [:]
        var fence: Fence?
        for line in lines {
            if let open = fence {
                if open.isClosed(by: line.text) { fence = nil }
                continue
            }
            if let opening = Fence.opening(line.text) {
                fence = opening
                continue
            }
            let ns = line.text as NSString
            guard let match = referencePattern.firstMatch(in: line.text, range: NSRange(location: 0, length: ns.length))
            else { continue }
            let label = LinkReference.normalize(ns.substring(with: match.range(at: 1)))
            var url = ns.substring(with: match.range(at: 2))
            if url.hasPrefix("<") && url.hasSuffix(">") { url = String(url.dropFirst().dropLast()) }
            var title: String?
            if match.range(at: 3).location != NSNotFound {
                title = String(ns.substring(with: match.range(at: 3)).dropFirst().dropLast())
            }
            // The first definition of a label wins.
            if references[label] == nil {
                references[label] = LinkReference(url: url, title: title)
            }
        }
        return references
    }
}
