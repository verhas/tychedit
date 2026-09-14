import Foundation

/// The mdship placeholder types, spelled as they are in the document.
enum PlaceholderKind: String, Sendable, CaseIterable {
    // Variable sources: define variables, generate nothing.
    case set = "SET"
    case importFile = "IMPORT"
    case slurp = "SLURP"
    case sip = "SIP"
    case sup = "SUP"
    // Content managers: own the text between the opening and closing tag.
    case template = "TEMPLATE"
    case jinja2 = "JINJA2"
    case include = "INCLUDE"
    case toc = "TOC"
    case python = "PYTHON"
    case ai = "AI"
    // Owns exactly the one line after the opening comment.
    case mermaid = "MERMAID"

    /// Names that take a closing `<!--/NAME-->`. A closing tag with any other
    /// name, found outside every placeholder, is ordinary text -- mdship ignores
    /// it, and a stray `<!--/MERMAID-->` from before MERMAID lost its closing
    /// tag is exactly that.
    static let pairedNames: Set<String> = ["TEMPLATE", "JINJA2", "INCLUDE", "TOC", "PYTHON", "AI"]

    /// A word for the placeholder's role, for the status bar and the preview.
    var role: String {
        switch self {
        case .set, .importFile, .slurp, .sip, .sup: "variable source"
        case .template, .jinja2: "template"
        case .include: "include"
        case .toc: "table of contents"
        case .python: "script"
        case .ai: "AI generated"
        case .mermaid: "diagram"
        }
    }
}

/// How much of the document a placeholder owns.
enum PlaceholderShape: Sendable, Equatable {
    /// Just the opening comment. SET, IMPORT, SLURP, SIP, SUP, PYTHON define:.
    case selfContained
    /// Opening comment, managed content, closing tag.
    case paired
    /// Opening comment and the single line after it. MERMAID.
    case managedLine
}

/// What mdship will think of the managed content on the next `mdship update`.
///
/// mdship records `_content_generated_: <length>:md5:<hash>` in the opening
/// comment when it writes managed content, and refuses to overwrite content
/// that no longer matches. Showing that while the file is being edited is the
/// point: the editor can say "this edit will be refused" before anyone runs
/// the tool.
enum Integrity: Sendable, Equatable {
    /// Not applicable: the placeholder manages no content.
    case none
    /// No `_content_generated_` yet: the next update overwrites without asking.
    case unrecorded
    /// Content matches what mdship wrote.
    case intact
    /// The closing tag is where mdship left it, but the text between changed.
    case edited
    /// The content changed length, so the closing tag moved.
    case moved
    /// `_yolo_: true` -- mdship accepts manual edits and overwrites anyway.
    case overridden

    /// The update would stop with an integrity error.
    var blocksUpdate: Bool { self == .edited || self == .moved }
}

/// One mdship placeholder found in the document.
struct Placeholder: Sendable, Equatable, Identifiable {

    let kind: PlaceholderKind
    let shape: PlaceholderShape
    /// `<!--KIND` through `-->`.
    let openRange: NSRange
    /// First and last line of the opening comment.
    let openLines: ClosedRange<Int>
    /// The text between the kind name and `-->`: the YAML configuration.
    let config: String
    /// The name the closing tag must carry: the kind, or `_terminate_`.
    let terminator: String
    /// The text mdship owns and rewrites. Nil while unclosed, or for
    /// self-contained placeholders.
    var bodyRange: NSRange?
    /// `<!--/TERMINATOR-->`, once found.
    var closeRange: NSRange?
    var closeLine: Int?
    /// For MERMAID: the line holding the generated image reference.
    var managedLine: Int?
    var integrity: Integrity

    var id: Int { openRange.location }

    /// The last line belonging to the placeholder.
    var lastLine: Int {
        closeLine ?? managedLine ?? openLines.upperBound
    }

    /// Everything the placeholder covers, for "is the caret in it".
    var fullRange: NSRange {
        let end = [closeRange.map(NSMaxRange), bodyRange.map(NSMaxRange), NSMaxRange(openRange)]
            .compactMap { $0 }.max() ?? NSMaxRange(openRange)
        return NSRange(location: openRange.location, length: end - openRange.location)
    }

    var isUnclosed: Bool { shape == .paired && closeRange == nil }

    /// A top-level scalar from the YAML configuration: `from`, `name`, `file`.
    ///
    /// Not a YAML parser, and it does not need to be one: this only labels the
    /// placeholder in the preview and the navigation menu. mdship does the real
    /// parsing when it runs.
    func value(forKey key: String) -> String? {
        let lines = config.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
        for (index, rawLine) in lines.enumerated() {
            var line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine
            // The first line is whatever followed the kind name, as in
            // `<!--TOC min-level: 2`, so its leading space means nothing. Any
            // other indented line belongs to a nested mapping, not the top level.
            if index == 0 {
                line = line.drop { $0 == " " || $0 == "\t" }
            }
            guard line.hasPrefix(key + ":") else { continue }
            var value = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty || value == "|" || value == ">" ? nil : value
        }
        return nil
    }

    /// A short description: `INCLUDE from: src/api.py`.
    var summary: String {
        let key: String? = switch kind {
        case .include, .importFile, .slurp, .sip: "from"
        case .ai, .sup: "name"
        case .mermaid: "file"
        case .python: config.range(of: #"(^|\s)run\s*:"#, options: .regularExpression) != nil ? "run" : "define"
        case .set, .template, .jinja2, .toc: nil
        }
        if let key, let value = value(forKey: key) {
            return "\(kind.rawValue) \(key): \(value)"
        }
        return kind.rawValue
    }
}

/// A variable reference: `<!--$name-->value` or `<!--$name<M>-->value<!--M-->`.
struct VariableReference: Sendable, Equatable {
    /// The variable, without `$` and braces: `config.authors[0]`.
    let name: String
    /// The marker of the long form; nil for the short form.
    let marker: String?
    /// The whole reference, value and closing marker included.
    let range: NSRange
    /// The text `mdship update` replaces with the variable's value. In the short
    /// form that is the rest of the line -- mdship's pattern runs to the newline.
    let valueRange: NSRange
    let line: Int
}

/// Something mdship would reject, found while scanning.
struct PlaceholderIssue: Sendable, Equatable {
    enum Severity: Sendable { case error, warning }
    /// Who found it: the editor while you type, or mdship when it last ran.
    enum Source: Sendable { case editor, mdship }

    /// Zero-based line.
    let line: Int
    /// The text the problem is about, underlined in the editor.
    let range: NSRange
    let message: String
    let severity: Severity
    var source: Source = .editor

    /// UTF-16 offset to put the caret on.
    var location: Int { range.location }
}

/// Every placeholder, variable reference and problem in a document.
struct PlaceholderScan: Sendable, Equatable {
    var placeholders: [Placeholder] = []
    var variables: [VariableReference] = []
    var issues: [PlaceholderIssue] = []
    /// Lines of the YAML front matter, delimiters included.
    var frontMatter: ClosedRange<Int>?

    /// What the caret at `offset` is inside, innermost first.
    func context(at offset: Int) -> CaretContext? {
        func contains(_ range: NSRange) -> Bool {
            offset >= range.location && offset <= NSMaxRange(range)
        }
        if let variable = variables.first(where: { contains($0.valueRange) }) {
            return .variableValue(variable)
        }
        if let variable = variables.first(where: { contains($0.range) }) {
            return .variableReference(variable)
        }
        // Innermost placeholder: the smallest range that holds the caret.
        let holding = placeholders.filter { contains($0.fullRange) }
            .sorted { $0.fullRange.length < $1.fullRange.length }
        for placeholder in holding {
            if offset > placeholder.openRange.location && offset < NSMaxRange(placeholder.openRange) {
                return .definition(placeholder)
            }
            if let body = placeholder.bodyRange, offset >= body.location, offset <= NSMaxRange(body),
               offset > NSMaxRange(placeholder.openRange) || body.length == 0 {
                return .managedContent(placeholder)
            }
        }
        return nil
    }
}

/// Where the caret is, in placeholder terms.
enum CaretContext: Sendable, Equatable {
    /// Inside the opening comment: editing the configuration.
    case definition(Placeholder)
    /// Inside text mdship generates.
    case managedContent(Placeholder)
    /// On the `<!--$name-->` part of a variable reference.
    case variableReference(VariableReference)
    /// On the value mdship replaces.
    case variableValue(VariableReference)
}
