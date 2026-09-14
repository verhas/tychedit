import Foundation

/// A link reference definition: `[label]: url "title"`.
struct LinkReference: Sendable, Equatable {
    let url: String
    let title: String?

    /// Labels match case-insensitively with runs of whitespace collapsed.
    static func normalize(_ label: String) -> String {
        label.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Renders the inline content of one block -- a paragraph, a heading, a table
/// cell -- to HTML.
///
/// Covers what documents actually use: code spans, emphasis and strong
/// emphasis (with CommonMark's delimiter rules, so `snake_case_names` stay
/// intact), strikethrough, links and images (inline and by reference),
/// autolinks, raw inline HTML, entities, backslash escapes and hard breaks.
///
/// mdship's variable references are HTML comments, which a browser would
/// swallow without a trace. They are rendered as small labels instead, so the
/// preview shows which text belongs to which variable.
struct InlineRenderer: Sendable {

    var references: [String: LinkReference] = [:]

    func render(_ text: String) -> String {
        var run = Run(chars: Array(text), renderer: self)
        run.tokenize()
        run.processEmphasis()
        return run.output()
    }

    // MARK: - Tokens

    private struct Piece {
        enum Kind { case html, delimiter }
        let kind: Kind
        var html = ""
        // Delimiter runs only.
        var character: Character = " "
        var count = 0
        var originalCount = 0
        var canOpen = false
        var canClose = false
        var active = true
        var openTags: [String] = []
        var closeTags: [String] = []

        static func html(_ html: String) -> Piece { Piece(kind: .html, html: html) }
    }

    private struct Run {
        let chars: [Character]
        let renderer: InlineRenderer
        var pieces: [Piece] = []
        var text = ""
        /// Markers of long-form variable references still waiting for their
        /// closing `<!--MARKER-->`.
        var openMarkers: [String] = []

        init(chars: [Character], renderer: InlineRenderer) {
            self.chars = chars
            self.renderer = renderer
        }

        mutating func flush() {
            if !text.isEmpty {
                pieces.append(.html(text))
                text = ""
            }
        }

        mutating func emit(_ html: String) {
            flush()
            pieces.append(.html(html))
        }

        func character(at index: Int) -> Character? {
            index >= 0 && index < chars.count ? chars[index] : nil
        }

        func string(_ range: Range<Int>) -> String {
            String(chars[max(0, range.lowerBound)..<min(chars.count, range.upperBound)])
        }

        func hasPrefix(_ prefix: String, at index: Int) -> Bool {
            var i = index
            for character in prefix {
                guard i < chars.count, chars[i] == character else { return false }
                i += 1
            }
            return true
        }

        // MARK: Tokenizing

        mutating func tokenize() {
            var i = 0
            while i < chars.count {
                let c = chars[i]
                switch c {
                case "\\":
                    if let next = character(at: i + 1), HTML.isASCIIPunctuation(next) {
                        text += HTML.escape(String(next))
                        i += 2
                    } else if character(at: i + 1) == "\n" {
                        emit("<br>\n")
                        i += 2
                    } else {
                        text += "\\"
                        i += 1
                    }

                case "`":
                    let length = runLength(at: i, of: "`")
                    if let close = closingBackticks(from: i + length, length: length) {
                        var code = string((i + length)..<close).replacingOccurrences(of: "\n", with: " ")
                        if code.count >= 2, code.first == " ", code.last == " ", !code.allSatisfy({ $0 == " " }) {
                            code = String(code.dropFirst().dropLast())
                        }
                        emit("<code>\(HTML.escape(code))</code>")
                        i = close + length
                    } else {
                        text += String(repeating: "`", count: length)
                        i += length
                    }

                case "<":
                    if let (html, length) = angleBracket(at: i) {
                        emit(html)
                        i += length
                    } else {
                        text += "&lt;"
                        i += 1
                    }

                case "!" where character(at: i + 1) == "[":
                    if let (html, length) = link(at: i + 1, image: true) {
                        emit(html)
                        i += 1 + length
                    } else {
                        text += "!"
                        i += 1
                    }

                case "[":
                    if let (html, length) = link(at: i, image: false) {
                        emit(html)
                        i += length
                    } else {
                        text += "["
                        i += 1
                    }

                case "*", "_", "~":
                    let length = runLength(at: i, of: c)
                    if c == "~" && length > 2 {
                        text += String(repeating: "~", count: length)
                        i += length
                        continue
                    }
                    addDelimiter(c, at: i, length: length)
                    i += length

                case "&":
                    if let entity = entity(at: i) {
                        text += entity
                        i += entity.count
                    } else {
                        text += "&amp;"
                        i += 1
                    }

                case "\n":
                    // Two trailing spaces make a hard break; otherwise trailing
                    // spaces before a line break are dropped.
                    let hard = text.hasSuffix("  ")
                    while text.hasSuffix(" ") { text.removeLast() }
                    if hard {
                        emit("<br>\n")
                    } else {
                        text += "\n"
                    }
                    i += 1
                    while character(at: i) == " " { i += 1 }

                case "h", "w":
                    if let (html, length) = bareURL(at: i) {
                        emit(html)
                        i += length
                    } else {
                        text.append(c)
                        i += 1
                    }

                case "\"":
                    text += "&quot;"
                    i += 1

                case ">":
                    text += "&gt;"
                    i += 1

                default:
                    text.append(c)
                    i += 1
                }
            }
            flush()
        }

        func runLength(at index: Int, of character: Character) -> Int {
            var i = index
            while i < chars.count, chars[i] == character { i += 1 }
            return i - index
        }

        /// The start of a backtick run of exactly `length`, at or after `from`.
        func closingBackticks(from: Int, length: Int) -> Int? {
            var i = from
            while i < chars.count {
                if chars[i] == "`" {
                    let run = runLength(at: i, of: "`")
                    if run == length { return i }
                    i += run
                } else {
                    i += 1
                }
            }
            return nil
        }

        /// A delimiter run, classified by CommonMark's flanking rules.
        mutating func addDelimiter(_ c: Character, at index: Int, length: Int) {
            let before = character(at: index - 1) ?? " "
            let after = character(at: index + length) ?? " "
            let beforeSpace = before.isWhitespace
            let afterSpace = after.isWhitespace
            let beforePunct = before.isPunctuation || before.isSymbol
            let afterPunct = after.isPunctuation || after.isSymbol

            let leftFlanking = !afterSpace && (!afterPunct || beforeSpace || beforePunct)
            let rightFlanking = !beforeSpace && (!beforePunct || afterSpace || afterPunct)

            var piece = Piece(kind: .delimiter)
            piece.character = c
            piece.count = length
            piece.originalCount = length
            if c == "_" {
                // Intraword underscores are literal: snake_case stays snake_case.
                piece.canOpen = leftFlanking && (!rightFlanking || beforePunct)
                piece.canClose = rightFlanking && (!leftFlanking || afterPunct)
            } else {
                piece.canOpen = leftFlanking
                piece.canClose = rightFlanking
            }
            flush()
            pieces.append(piece)
        }

        // MARK: Angle brackets: comments, autolinks, HTML

        mutating func angleBracket(at index: Int) -> (String, Int)? {
            if hasPrefix("<!--", at: index) {
                return comment(at: index)
            }
            // Only look a bounded distance ahead: a stray `<` in a long
            // paragraph should not make every keystroke scan the rest of it.
            let lookahead = string(index..<(index + 512))
            let nsLookahead = lookahead as NSString
            let whole = NSRange(location: 0, length: nsLookahead.length)

            if let match = InlineRenderer.autolink.firstMatch(in: lookahead, options: .anchored, range: whole) {
                let url = nsLookahead.substring(with: match.range(at: 1))
                return ("<a href=\"\(HTML.escapeURL(url))\">\(HTML.escape(url))</a>",
                        nsLookahead.substring(with: match.range).count)
            }
            if let match = InlineRenderer.emailAutolink.firstMatch(in: lookahead, options: .anchored, range: whole) {
                let address = nsLookahead.substring(with: match.range(at: 1))
                return ("<a href=\"mailto:\(HTML.escapeURL(address))\">\(HTML.escape(address))</a>",
                        nsLookahead.substring(with: match.range).count)
            }
            if let match = InlineRenderer.htmlTag.firstMatch(in: lookahead, options: .anchored, range: whole) {
                let tag = nsLookahead.substring(with: match.range)
                return (tag, tag.count)
            }
            return nil
        }

        /// `<!-- ... -->`. Invisible, except for mdship variable references.
        mutating func comment(at index: Int) -> (String, Int)? {
            var end = index + 4
            while end < chars.count, !hasPrefix("-->", at: end) { end += 1 }
            guard end < chars.count else { return nil }
            let body = string((index + 4)..<end)
            let length = end + 3 - index
            let nsBody = body as NSString

            if let match = InlineRenderer.variableComment.firstMatch(
                in: body, options: .anchored, range: NSRange(location: 0, length: nsBody.length)) {
                let name = nsBody.substring(with: match.range(at: 1))
                let hasMarker = match.range(at: 2).location != NSNotFound
                if hasMarker {
                    openMarkers.append(nsBody.substring(with: match.range(at: 3)))
                }
                let title = "Variable $\(name): mdship update replaces the value that follows"
                return ("<span class=\"mds-var\" title=\"\(HTML.escape(title))\">$\(HTML.escape(name))</span>", length)
            }
            if let position = openMarkers.lastIndex(of: body) {
                openMarkers.remove(at: position)
                return ("<span class=\"mds-var-end\"></span>", length)
            }
            return ("", length)
        }

        /// `https://...` or `www....` written out in the text.
        func bareURL(at index: Int) -> (String, Int)? {
            if let previous = character(at: index - 1), previous.isLetter || previous.isNumber { return nil }
            guard hasPrefix("https://", at: index) || hasPrefix("http://", at: index) || hasPrefix("www.", at: index)
            else { return nil }
            var end = index
            while end < chars.count, !chars[end].isWhitespace, chars[end] != "<" { end += 1 }
            // Trailing punctuation belongs to the sentence, not the URL -- and so
            // does a closing parenthesis that has no opening one in the URL.
            while end > index, let last = character(at: end - 1) {
                if "?!.,:*_~'\"".contains(last) {
                    end -= 1
                } else if last == ")" {
                    let url = string(index..<end)
                    if url.filter({ $0 == ")" }).count > url.filter({ $0 == "(" }).count {
                        end -= 1
                    } else {
                        break
                    }
                } else {
                    break
                }
            }
            let url = string(index..<end)
            guard url.count > 8 || (url.hasPrefix("www.") && url.count > 4) else { return nil }
            let href = url.hasPrefix("www.") ? "http://" + url : url
            return ("<a href=\"\(HTML.escapeURL(href))\">\(HTML.escape(url))</a>", end - index)
        }

        func entity(at index: Int) -> String? {
            let lookahead = string(index..<(index + 40))
            let ns = lookahead as NSString
            guard let match = InlineRenderer.entityPattern.firstMatch(
                in: lookahead, options: .anchored, range: NSRange(location: 0, length: ns.length)) else { return nil }
            return ns.substring(with: match.range)
        }

        // MARK: Links

        /// A link or image whose `[` is at `index`: the HTML and how many
        /// characters it used, counted from `index`.
        func link(at index: Int, image: Bool) -> (String, Int)? {
            guard let close = closingBracket(from: index) else { return nil }
            let label = string((index + 1)..<close)
            var position = close + 1
            var url: String
            var title: String?

            if character(at: position) == "(", let inline = inlineDestination(from: position + 1) {
                url = inline.url
                title = inline.title
                position = inline.end
            } else {
                var referenceLabel = label
                if character(at: position) == "[", let end = closingBracket(from: position) {
                    let explicit = string((position + 1)..<end)
                    if !explicit.isEmpty { referenceLabel = explicit }
                    position = end + 1
                }
                guard let reference = renderer.references[LinkReference.normalize(referenceLabel)] else {
                    return nil
                }
                url = reference.url
                title = reference.title
            }

            let titleAttribute = title.map { " title=\"\(HTML.escape($0))\"" } ?? ""
            if image {
                let alt = label.replacingOccurrences(of: #"[*_`\[\]]"#, with: "", options: .regularExpression)
                return ("<img src=\"\(HTML.escapeURL(url))\" alt=\"\(HTML.escape(alt))\"\(titleAttribute)>", position - index)
            }
            return ("<a href=\"\(HTML.escapeURL(url))\"\(titleAttribute)>\(renderer.render(label))</a>", position - index)
        }

        /// The `]` matching the `[` at `index`, skipping escapes and code spans.
        func closingBracket(from index: Int) -> Int? {
            var depth = 0
            var i = index
            while i < chars.count {
                switch chars[i] {
                case "\\":
                    i += 2
                    continue
                case "`":
                    let length = runLength(at: i, of: "`")
                    if let close = closingBackticks(from: i + length, length: length) {
                        i = close + length
                        continue
                    }
                    i += length
                    continue
                case "[":
                    depth += 1
                case "]":
                    depth -= 1
                    if depth == 0 { return i }
                default:
                    break
                }
                i += 1
            }
            return nil
        }

        /// `(url "title")`, starting just after the `(`.
        func inlineDestination(from start: Int) -> (url: String, title: String?, end: Int)? {
            var i = start
            func skipSpace() { while i < chars.count, chars[i] == " " || chars[i] == "\n" { i += 1 } }
            skipSpace()

            var url = ""
            if character(at: i) == "<" {
                i += 1
                while i < chars.count, chars[i] != ">", chars[i] != "\n" { url.append(chars[i]); i += 1 }
                guard character(at: i) == ">" else { return nil }
                i += 1
            } else {
                var depth = 0
                while i < chars.count, !chars[i].isWhitespace {
                    if chars[i] == "\\", let next = character(at: i + 1), HTML.isASCIIPunctuation(next) {
                        url.append(next)
                        i += 2
                        continue
                    }
                    if chars[i] == "(" { depth += 1 }
                    if chars[i] == ")" {
                        if depth == 0 { break }
                        depth -= 1
                    }
                    url.append(chars[i])
                    i += 1
                }
            }
            skipSpace()

            var title: String?
            if let opener = character(at: i), opener == "\"" || opener == "'" || opener == "(" {
                let closer: Character = opener == "(" ? ")" : opener
                var value = ""
                i += 1
                while i < chars.count, chars[i] != closer {
                    if chars[i] == "\\", let next = character(at: i + 1), next == closer {
                        value.append(next)
                        i += 2
                        continue
                    }
                    value.append(chars[i])
                    i += 1
                }
                guard i < chars.count else { return nil }
                i += 1
                title = value
                skipSpace()
            }
            guard character(at: i) == ")" else { return nil }
            return (url, title, i + 1)
        }

        // MARK: Emphasis

        /// CommonMark's delimiter algorithm, without the performance tricks.
        mutating func processEmphasis() {
            var closerIndex = 0
            while closerIndex < pieces.count {
                let closer = pieces[closerIndex]
                guard closer.kind == .delimiter, closer.active, closer.canClose, closer.count > 0 else {
                    closerIndex += 1
                    continue
                }
                var openerIndex = closerIndex - 1
                var matched: Int?
                while openerIndex >= 0 {
                    let opener = pieces[openerIndex]
                    if opener.kind == .delimiter, opener.active, opener.canOpen, opener.count > 0,
                       opener.character == closer.character {
                        if closer.character == "~" {
                            if opener.count == closer.count { matched = openerIndex; break }
                        } else if (opener.canClose || closer.canOpen)
                                    && (opener.originalCount + closer.originalCount) % 3 == 0
                                    && !(opener.originalCount % 3 == 0 && closer.originalCount % 3 == 0) {
                            // The "rule of three": skip, keep looking further out.
                        } else {
                            matched = openerIndex
                            break
                        }
                    }
                    openerIndex -= 1
                }

                guard let opener = matched else {
                    closerIndex += 1
                    continue
                }
                let use: Int
                let tag: String
                if closer.character == "~" {
                    use = closer.count
                    tag = "del"
                } else if pieces[opener].count >= 2 && closer.count >= 2 {
                    use = 2
                    tag = "strong"
                } else {
                    use = 1
                    tag = "em"
                }
                pieces[opener].count -= use
                pieces[closerIndex].count -= use
                pieces[opener].openTags.append("<\(tag)>")
                pieces[closerIndex].closeTags.append("</\(tag)>")
                // Delimiters between a matched pair can no longer match anything
                // outside it.
                for between in (opener + 1)..<closerIndex where pieces[between].kind == .delimiter {
                    pieces[between].active = false
                }
                if pieces[closerIndex].count == 0 {
                    closerIndex += 1
                }
            }
        }

        func output() -> String {
            var html = ""
            for piece in pieces {
                switch piece.kind {
                case .html:
                    html += piece.html
                case .delimiter:
                    html += piece.closeTags.joined()
                    html += String(repeating: piece.character, count: piece.count)
                    // Matched innermost first, so the outermost tag opens first.
                    html += piece.openTags.reversed().joined()
                }
            }
            return html
        }
    }

    // MARK: - Patterns

    private static let autolink = try! NSRegularExpression(
        pattern: #"<([A-Za-z][A-Za-z0-9+.\-]{1,31}:[^<>\s]*)>"#)
    private static let emailAutolink = try! NSRegularExpression(
        pattern: #"<([A-Za-z0-9.!#$%&'*+/=?^_`{|}~\-]+@[A-Za-z0-9](?:[A-Za-z0-9\-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9\-]{0,61}[A-Za-z0-9])?)*)>"#)
    private static let htmlTag = try! NSRegularExpression(
        pattern: #"</?[A-Za-z][A-Za-z0-9\-]*(?:\s+[A-Za-z_:][A-Za-z0-9_.:\-]*(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'=<>`]+))?)*\s*/?>"#)
    private static let entityPattern = try! NSRegularExpression(
        pattern: #"&(?:#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});"#)
    /// The inside of `<!--$name-->` or `<!--${name}<MARKER>-->`.
    private static let variableComment = try! NSRegularExpression(
        pattern: #"\$\{?([a-zA-Z_][a-zA-Z0-9_.\[\]]*)\}?(<([^>]*)>)?$"#)
}
