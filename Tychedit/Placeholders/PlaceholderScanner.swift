import CryptoKit
import Foundation

/// Finds mdship placeholders the way mdship does.
///
/// The rules follow `mdship/markdown.py` -- `_validate_placeholder_structure`,
/// `_find_placeholder` and the MERMAID processor -- so what the editor reports
/// is what `mdship update` would report:
///
/// - An opening comment starts a line (indentation allowed): `<!--INCLUDE`.
/// - Placeholders in fenced code blocks and in front matter are examples, not
///   placeholders.
/// - TEMPLATE, JINJA2, INCLUDE, TOC, AI and PYTHON `run:` close with
///   `<!--/NAME-->`, or `<!--/X-->` when the configuration says `_terminate_: X`.
/// - MERMAID owns the one line after its comment, which ends at a `-->` that
///   starts a line.
/// - `_content_generated_: <length>:md5:<hash>` pins the managed content. The
///   length counts Unicode code points (Python's `len`), not UTF-16 units.
///
/// Pure and `Sendable`: it runs off the main thread on every edit.
enum PlaceholderScanner {

    static func scan(_ text: String) -> PlaceholderScan {
        var scanner = Scanner(text: text)
        scanner.run()
        return scanner.result
    }

    // MARK: - Regular expressions

    // `try!` is safe: the patterns are constants, and a typo fails every test.
    private static let closingTag = try! NSRegularExpression(pattern: #"^<!--/(\w+)-->"#)
    private static let terminate = try! NSRegularExpression(
        pattern: #"_terminate_\s*:\s*["']?(\w+)["']?"#)
    private static let contentGenerated = try! NSRegularExpression(
        pattern: #"_content_generated_\s*:\s*(\d+)\s*:md5:\s*([0-9a-fA-F]+)"#)
    private static let yolo = try! NSRegularExpression(
        pattern: #"(?:^|\s)_yolo_\s*:\s*(?:true|yes|on)\b"#, options: [.caseInsensitive])
    private static let pythonRun = try! NSRegularExpression(pattern: #"(?:^|\s)run\s*:"#)
    private static let pythonDefine = try! NSRegularExpression(pattern: #"(?:^|\s)define\s*:"#)
    // mdship's own two patterns, verbatim apart from the escaping.
    private static let variableWithMarker = try! NSRegularExpression(
        pattern: #"<!--(\$\{?)([a-zA-Z_][a-zA-Z0-9_.\[\]]*)(\}?)<([^>]*)>-->(.*?)<!--\4-->"#,
        options: [.dotMatchesLineSeparators])
    private static let variableWithoutMarker = try! NSRegularExpression(
        pattern: #"<!--(\$\{?)([a-zA-Z_][a-zA-Z0-9_.\[\]]*)(\}?)-->([^\n]*)"#)

    private static func firstMatch(_ regex: NSRegularExpression, in string: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: string, range: NSRange(location: 0, length: (string as NSString).length))
    }

    private static func matches(_ regex: NSRegularExpression, in string: String) -> Bool {
        firstMatch(regex, in: string) != nil
    }

    // MARK: - The scan

    private struct Scanner {
        let text: String
        let ns: NSString
        let lines: LineIndex
        var result = PlaceholderScan()
        /// Indices into `result.placeholders` of paired placeholders still open.
        var stack: [Int] = []
        /// Lines inside fenced code, where variable references are not replaced.
        var codeLines = IndexSet()

        init(text: String) {
            self.text = text
            self.ns = text as NSString
            self.lines = LineIndex(ns)
        }

        func lineText(_ line: Int) -> String {
            ns.substring(with: lines.contentRange(ofLine: line))
        }

        /// A problem covering the rest of `line` from `location`.
        mutating func issue(_ line: Int, _ location: Int, _ message: String, _ severity: PlaceholderIssue.Severity = .error) {
            let end = NSMaxRange(lines.contentRange(ofLine: line))
            let range = NSRange(location: location, length: max(0, end - location))
            result.issues.append(PlaceholderIssue(line: line, range: range, message: message, severity: severity))
        }

        mutating func run() {
            var lineNumber = skipFrontMatter()
            var fence: Fence?

            while lineNumber < lines.count {
                let line = lineText(lineNumber)

                if let open = fence {
                    codeLines.insert(lineNumber)
                    if open.isClosed(by: line) { fence = nil }
                    lineNumber += 1
                    continue
                }
                if let opening = Fence.opening(line, maxIndent: .max) {
                    codeLines.insert(lineNumber)
                    fence = opening
                    lineNumber += 1
                    continue
                }

                let indent = line.utf16.prefix { $0 == 32 || $0 == 9 }.count
                let lineStart = lines.starts[lineNumber]
                let trimmed = String(line.utf16.dropFirst(indent)) ?? ""

                if trimmed.hasPrefix("<!--/") {
                    if let match = PlaceholderScanner.firstMatch(PlaceholderScanner.closingTag, in: trimmed) {
                        let name = (trimmed as NSString).substring(with: match.range(at: 1))
                        close(name: name,
                              range: NSRange(location: lineStart + indent, length: match.range.length),
                              line: lineNumber)
                    }
                    lineNumber += 1
                    continue
                }

                if trimmed.hasPrefix("<!--"), let kind = kind(openedBy: trimmed) {
                    guard let next = open(kind, at: lineStart + indent, line: lineNumber) else {
                        // An opening comment that never ends swallows the rest
                        // of the document; nothing after it is a placeholder.
                        break
                    }
                    lineNumber = next
                    continue
                }

                lineNumber += 1
            }

            for index in stack {
                let placeholder = result.placeholders[index]
                issue(placeholder.openLines.lowerBound, placeholder.openRange.location,
                      "Unclosed <!--\(placeholder.kind.rawValue)--> placeholder. Expected closing tag <!--/\(placeholder.terminator)-->")
            }
            result.issues.sort { $0.location < $1.location }
            findVariables()
        }

        /// Front matter is YAML between `---` lines at the very top.
        mutating func skipFrontMatter() -> Int {
            guard lines.count > 1, lineText(0).trimmingCharacters(in: .whitespaces) == "---" else { return 0 }
            for line in 1..<lines.count {
                let content = lineText(line).trimmingCharacters(in: .whitespaces)
                if content == "---" || content == "..." {
                    result.frontMatter = 0...line
                    return line + 1
                }
            }
            return 0
        }

        /// The placeholder kind named right after `<!--`, followed by a space,
        /// a newline, `-->` or the end of the line -- so `<!--SETUP` is not SET.
        func kind(openedBy trimmed: String) -> PlaceholderKind? {
            let afterOpen = trimmed.dropFirst(4)
            let name = afterOpen.prefix { $0.isUppercase || $0.isNumber }
            guard let kind = PlaceholderKind(rawValue: String(name)) else { return nil }
            let rest = afterOpen.dropFirst(name.count)
            if rest.isEmpty || rest.hasPrefix("-->") { return kind }
            if let next = rest.first, next.isWhitespace { return kind }
            return nil
        }

        /// Records a placeholder whose comment starts at `start`, and returns
        /// the line to continue from, or nil when the comment never ends.
        mutating func open(_ kind: PlaceholderKind, at start: Int, line: Int) -> Int? {
            let nameEnd = start + 4 + kind.rawValue.utf16.count
            // MERMAID's comment ends at a `-->` starting a line, so that a
            // diagram arrow cannot end it early. (mdship: `<!--MERMAID(.*?)\n-->`.)
            let ending = kind == .mermaid ? "\n-->" : "-->"
            let searchRange = NSRange(location: nameEnd, length: ns.length - nameEnd)
            let found = ns.range(of: ending, options: [], range: searchRange)
            guard found.location != NSNotFound else {
                issue(line, start, "Opening <!--\(kind.rawValue)--> comment is never closed with -->.")
                return nil
            }
            let config = ns.substring(with: NSRange(location: nameEnd, length: found.location - nameEnd))
            // The comment ends here even when the `-->` is inside a quoted value,
            // exactly as mdship ends it; say so, since nothing else on screen does.
            let arrow = kind == .mermaid ? NSRange(location: found.location + 1, length: 3) : found
            let arrowLine = lines.line(containing: arrow.location)
            let beforeArrow = ns.substring(with: NSRange(location: lines.starts[arrowLine],
                                                         length: arrow.location - lines.starts[arrowLine]))
            if CommentText.endsInsideQuotes(beforeArrow) {
                result.issues.append(PlaceholderIssue(
                    line: arrowLine, range: arrow,
                    message: "Line \(arrowLine + 1): this --> is inside a quoted value, but it still ends the comment: mdship reads the \(kind.rawValue) configuration only up to here. In a regular expression write --[>] instead.",
                    severity: .error))
            }
            let openEnd = NSMaxRange(found)
            let openRange = NSRange(location: start, length: openEnd - start)
            let lastOpenLine = lines.line(containing: openEnd - 1)

            let shape: PlaceholderShape
            switch kind {
            case .set, .importFile, .slurp, .sip, .sup:
                shape = .selfContained
            case .mermaid:
                shape = .managedLine
            case .python:
                // define: mode defines variables and owns nothing. Anything
                // else is paired, as in mdship, so a marker missing both keys
                // is at least reported as unclosed.
                let isRun = PlaceholderScanner.matches(PlaceholderScanner.pythonRun, in: config)
                let isDefine = PlaceholderScanner.matches(PlaceholderScanner.pythonDefine, in: config)
                shape = !isRun && isDefine ? .selfContained : .paired
            case .template, .jinja2, .include, .toc, .ai:
                shape = .paired
            }

            var terminator = kind.rawValue
            if shape == .paired, let match = PlaceholderScanner.firstMatch(PlaceholderScanner.terminate, in: config) {
                terminator = (config as NSString).substring(with: match.range(at: 1))
            }

            var placeholder = Placeholder(
                kind: kind, shape: shape, openRange: openRange, openLines: line...lastOpenLine,
                config: config, terminator: terminator, bodyRange: nil, closeRange: nil, closeLine: nil,
                managedLine: nil, integrity: shape == .selfContained || kind == .ai ? .none : .unrecorded)

            // Only PYTHON honours _yolo_: the other processors check the content
            // hash regardless, so there an edited block still stops the update.
            let yolo = kind == .python && PlaceholderScanner.matches(PlaceholderScanner.yolo, in: config)
            let recorded = recordedContent(in: config)

            switch shape {
            case .selfContained:
                result.placeholders.append(placeholder)
                return lastOpenLine + 1

            case .managedLine:
                let managed = lastOpenLine + 1
                placeholder.managedLine = managed < lines.count ? managed : nil
                if let recorded {
                    // The recorded length covers "\n" + image line + "\n".
                    if let length = utf16Length(ofScalars: recorded.length, from: openEnd) {
                        let body = NSRange(location: openEnd, length: length)
                        placeholder.bodyRange = body
                        placeholder.integrity = yolo ? .overridden
                            : md5(ns.substring(with: body)) == recorded.hash ? .intact : .edited
                    } else {
                        placeholder.integrity = yolo ? .overridden : .moved
                    }
                } else if let managed = placeholder.managedLine {
                    placeholder.bodyRange = lines.fullRange(ofLine: managed)
                    if !lineText(managed).trimmingCharacters(in: .whitespaces).isEmpty {
                        issue(managed, lines.starts[managed],
                              "Line \(line + 1): MERMAID placeholder has no _content_generated_ entry but the line after --> is not empty. Leave it empty: it is the slot for the generated image reference.")
                    }
                }
                if placeholder.integrity.blocksUpdate {
                    reportIntegrity(placeholder)
                }
                result.placeholders.append(placeholder)
                return lastOpenLine + 1

            case .paired:
                if let recorded {
                    let closing = "<!--/\(terminator)-->"
                    if let length = utf16Length(ofScalars: recorded.length, from: openEnd),
                       hasText(closing, at: openEnd + length) {
                        let body = NSRange(location: openEnd, length: length)
                        let close = NSRange(location: openEnd + length, length: closing.utf16.count)
                        placeholder.bodyRange = body
                        placeholder.closeRange = close
                        placeholder.closeLine = lines.line(containing: close.location)
                        placeholder.integrity = yolo ? .overridden
                            : md5(ns.substring(with: body)) == recorded.hash ? .intact : .edited
                        if placeholder.integrity.blocksUpdate { reportIntegrity(placeholder) }
                        result.placeholders.append(placeholder)
                        // Found by position, the way mdship finds it: whatever
                        // the managed content holds -- even text that looks like
                        // a closing tag -- is skipped, not scanned.
                        return placeholder.closeLine! + 1
                    }
                    placeholder.integrity = yolo ? .overridden : .moved
                    if !yolo { reportIntegrity(placeholder) }
                }
                result.placeholders.append(placeholder)
                stack.append(result.placeholders.count - 1)
                return lastOpenLine + 1
            }
        }

        mutating func reportIntegrity(_ placeholder: Placeholder) {
            let name = placeholder.kind.rawValue
            let line = placeholder.openLines.lowerBound
            let message = switch placeholder.integrity {
            case .moved:
                "Line \(line + 1): \(name) managed content changed length since mdship wrote it. mdship update will refuse; delete the _content_generated_ line to accept losing the edits."
            default:
                "Line \(line + 1): \(name) managed content was edited by hand. mdship update will refuse; delete the _content_generated_ line to accept losing the edits."
            }
            issue(line, placeholder.openRange.location, message, .warning)
        }

        mutating func close(name: String, range: NSRange, line: Int) {
            guard let top = stack.last else {
                if PlaceholderKind.pairedNames.contains(name) {
                    issue(line, range.location, "Line \(line + 1): Found closing <!--/\(name)--> without a matching opening tag")
                }
                return
            }
            func matches(_ index: Int) -> Bool {
                let open = result.placeholders[index]
                return name == open.terminator || name == open.kind.rawValue
            }
            if matches(top) {
                finish(top, closeRange: range, line: line)
                stack.removeLast()
                return
            }
            let opened = result.placeholders[top]
            issue(line, range.location,
                  "Line \(line + 1): Closing <!--/\(name)--> does not match opening <!--\(opened.kind.rawValue)--> at line \(opened.openLines.lowerBound + 1). Expected <!--/\(opened.terminator)-->")
            // Recover when the tag closes something further out, so one typo
            // does not turn the rest of the document into an error.
            if let outer = stack.lastIndex(where: matches) {
                for inner in stack[(outer + 1)...] {
                    let unclosed = result.placeholders[inner]
                    issue(unclosed.openLines.lowerBound, unclosed.openRange.location,
                          "Unclosed <!--\(unclosed.kind.rawValue)--> placeholder. Expected closing tag <!--/\(unclosed.terminator)-->")
                }
                finish(stack[outer], closeRange: range, line: line)
                stack.removeSubrange(outer...)
            }
        }

        mutating func finish(_ index: Int, closeRange: NSRange, line: Int) {
            let openEnd = NSMaxRange(result.placeholders[index].openRange)
            result.placeholders[index].closeRange = closeRange
            result.placeholders[index].closeLine = line
            result.placeholders[index].bodyRange = NSRange(location: openEnd, length: max(0, closeRange.location - openEnd))
        }

        // MARK: Variable references

        mutating func findVariables() {
            let whole = NSRange(location: 0, length: ns.length)
            var found: [VariableReference] = []

            func excluded(_ location: Int) -> Bool {
                let line = lines.line(containing: location)
                if codeLines.contains(line) { return true }
                if let frontMatter = result.frontMatter, frontMatter.contains(line) { return true }
                // Inside a placeholder's own comment -- a TEMPLATE's `$var` is
                // the template's business, not a reference.
                return result.placeholders.contains {
                    location > $0.openRange.location && location < NSMaxRange($0.openRange)
                }
            }

            for match in PlaceholderScanner.variableWithMarker.matches(in: text, range: whole) where !excluded(match.range.location) {
                found.append(VariableReference(
                    name: ns.substring(with: match.range(at: 2)),
                    marker: ns.substring(with: match.range(at: 4)),
                    range: match.range,
                    valueRange: match.range(at: 5),
                    line: lines.line(containing: match.range.location)))
            }
            let long = found
            for match in PlaceholderScanner.variableWithoutMarker.matches(in: text, range: whole) where !excluded(match.range.location) {
                if long.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) { continue }
                found.append(VariableReference(
                    name: ns.substring(with: match.range(at: 2)),
                    marker: nil,
                    range: match.range,
                    valueRange: match.range(at: 4),
                    line: lines.line(containing: match.range.location)))
            }
            result.variables = found.sorted { $0.range.location < $1.range.location }
        }

        // MARK: Helpers

        func recordedContent(in config: String) -> (length: Int, hash: String)? {
            guard let match = PlaceholderScanner.firstMatch(PlaceholderScanner.contentGenerated, in: config) else { return nil }
            let nsConfig = config as NSString
            guard let length = Int(nsConfig.substring(with: match.range(at: 1))) else { return nil }
            return (length, nsConfig.substring(with: match.range(at: 2)).lowercased())
        }

        /// The UTF-16 length of the next `count` code points after `offset`, or
        /// nil when the text is shorter than that.
        func utf16Length(ofScalars count: Int, from offset: Int) -> Int? {
            let scalars = text.unicodeScalars
            let start = String.Index(utf16Offset: offset, in: text)
            guard let end = scalars.index(start, offsetBy: count, limitedBy: scalars.endIndex) else { return nil }
            return end.utf16Offset(in: text) - offset
        }

        func hasText(_ string: String, at offset: Int) -> Bool {
            let length = string.utf16.count
            guard offset >= 0, offset + length <= ns.length else { return false }
            return ns.substring(with: NSRange(location: offset, length: length)) == string
        }

        func md5(_ string: String) -> String {
            Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }
}
