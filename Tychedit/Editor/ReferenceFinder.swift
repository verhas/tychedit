import Foundation

/// Something the caret or a Command-click can follow.
enum Reference: Sendable, Equatable {
    /// A web address, opened in the browser.
    case web(URL)
    /// A file, opened in a Tychedit window when it is text.
    case file(URL, NavigationTarget?)
    /// A heading in this document.
    case anchor(String)
    /// A place in this document, such as where a variable is defined.
    case location(Int)
}

/// Finds the reference at a position in a markdown document: a link, an image,
/// a path in a placeholder, a variable reference.
enum ReferenceFinder {

    static func reference(in text: String, at offset: Int, documentURL: URL?,
                          scan: PlaceholderScan, fileReferences: [FileReference],
                          definitions: [String: LinkReference]) -> Reference? {
        func holds(_ range: NSRange) -> Bool {
            offset >= range.location && offset <= NSMaxRange(range)
        }

        if let file = fileReferences.first(where: { holds($0.range) }) {
            return .file(file.url, file.target)
        }
        // The `<!--$name-->` part of a variable reference leads to the definition;
        // its value is ordinary text.
        if let variable = scan.variables.first(where: {
            holds(NSRange(location: $0.range.location, length: $0.valueRange.location - $0.range.location))
        }), let definition = definitionLocation(of: variable.name, in: text, scan: scan) {
            return .location(definition)
        }

        let ns = text as NSString
        let lines = LineIndex(ns)
        let lineRange = lines.contentRange(ofLine: lines.line(containing: offset))
        let line = ns.substring(with: lineRange)
        let local = offset - lineRange.location
        let whole = NSRange(location: 0, length: (line as NSString).length)
        let directory = documentURL?.deletingLastPathComponent()

        func inside(_ range: NSRange) -> Bool {
            range.location != NSNotFound && local >= range.location && local <= NSMaxRange(range)
        }
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : (line as NSString).substring(with: range)
        }

        for match in inlineLink.matches(in: line, range: whole) where inside(match.range) {
            if let destination = group(match, 1) {
                return resolve(destination, directory: directory)
            }
        }
        for match in referenceLink.matches(in: line, range: whole) where inside(match.range) {
            let label = group(match, 2).flatMap { $0.isEmpty ? nil : $0 } ?? group(match, 1) ?? ""
            if let definition = definitions[LinkReference.normalize(label)] {
                return resolve(definition.url, directory: directory)
            }
        }
        for match in definitionLine.matches(in: line, range: whole) where inside(match.range) {
            if let destination = group(match, 2) {
                return resolve(destination, directory: directory)
            }
        }
        for pattern in [autolink, htmlAttribute, bareURL] {
            for match in pattern.matches(in: line, range: whole) where inside(match.range) {
                if let destination = group(match, 1) {
                    return resolve(destination, directory: directory)
                }
            }
        }
        for match in shortcutLink.matches(in: line, range: whole) where inside(match.range) {
            if let label = group(match, 1), let definition = definitions[LinkReference.normalize(label)] {
                return resolve(definition.url, directory: directory)
            }
        }
        return nil
    }

    /// A link destination as a reference: web, in-page anchor, or file with an
    /// optional anchor.
    static func resolve(_ raw: String, directory: URL?) -> Reference? {
        var destination = raw.trimmingCharacters(in: .whitespaces)
        if destination.hasPrefix("<") && destination.hasSuffix(">") {
            destination = String(destination.dropFirst().dropLast())
        }
        guard !destination.isEmpty else { return nil }
        if destination.hasPrefix("#") {
            return .anchor(String(destination.dropFirst()))
        }
        if destination.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*:"#, options: .regularExpression) != nil {
            if destination.lowercased().hasPrefix("file:"), let url = URL(string: destination) {
                return .file(url, url.fragment.map { .anchor($0) })
            }
            return URL(string: destination).map { .web($0) }
        }
        if destination.lowercased().hasPrefix("www.") {
            return URL(string: "http://" + destination).map { .web($0) }
        }
        var path = destination
        var target: NavigationTarget?
        if let hash = destination.firstIndex(of: "#") {
            path = String(destination[..<hash])
            target = .anchor(String(destination[destination.index(after: hash)...]))
        }
        path = path.removingPercentEncoding ?? path
        guard let url = PlaceholderValidator.resolve(path, against: directory) else { return nil }
        return .file(url, target)
    }

    /// Where the variable `name` -- or its top-level part -- is defined: the
    /// SET key, or the IMPORT/SLURP/SIP/SUP whose `name` it falls under.
    static func definitionLocation(of name: String, in text: String, scan: PlaceholderScan) -> Int? {
        let root = String(name.prefix { $0 != "." && $0 != "[" })
        var best: (Int, Int)?  // (location, matched name length)
        for placeholder in scan.placeholders {
            let outline = YAMLOutline(placeholder.config,
                                      offset: placeholder.openRange.location + 4 + placeholder.kind.rawValue.utf16.count,
                                      line: placeholder.openLines.lowerBound)
            switch placeholder.kind {
            case .set:
                if let entry = outline.entry(root) {
                    return entry.keyRange.location
                }
            case .importFile, .slurp, .sip, .sup:
                if let entry = outline.entry("name"), let defined = entry.value.scalarText,
                   name == defined || name.hasPrefix(defined + ".") || name.hasPrefix(defined + "["),
                   defined.count > (best?.1 ?? -1) {
                    best = (entry.value.range?.location ?? entry.keyRange.location, defined.count)
                }
            default:
                break
            }
        }
        return best?.0
    }

    private static let inlineLink = try! NSRegularExpression(
        pattern: #"!?\[(?:[^\[\]]|\[[^\]]*\])*\]\(\s*(<[^>]*>|[^)\s]+)(?:\s+(?:"[^"]*"|'[^']*'|\([^)]*\)))?\s*\)"#)
    private static let referenceLink = try! NSRegularExpression(pattern: #"!?\[([^\]]+)\]\[([^\]]*)\]"#)
    private static let definitionLine = try! NSRegularExpression(pattern: #"^ {0,3}\[([^\]]+)\]:\s*(\S+)"#)
    private static let autolink = try! NSRegularExpression(pattern: #"<([A-Za-z][A-Za-z0-9+.\-]*:[^>\s]+)>"#)
    private static let htmlAttribute = try! NSRegularExpression(pattern: #"(?:href|src)\s*=\s*"([^"]+)""#)
    private static let bareURL = try! NSRegularExpression(pattern: #"((?:https?://|www\.)[^\s<>)\]"']+)"#)
    private static let shortcutLink = try! NSRegularExpression(pattern: #"\[([^\]]+)\]"#)
}
