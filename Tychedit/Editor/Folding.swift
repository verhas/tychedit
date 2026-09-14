import Foundation

/// A stretch of text that can be folded away behind its first line.
struct FoldRegion: Sendable, Equatable, Identifiable {

    enum Kind: Sendable, Equatable {
        /// A heading down to the next heading of the same or a higher level.
        case section(level: Int)
        /// A placeholder from its opening comment through its closing tag (or,
        /// for MERMAID, its image line).
        case placeholder(PlaceholderKind)
        /// Only the configuration inside a placeholder's opening comment:
        /// `<!--INCLUDE [from: file.md] -->` stays, with the content below it.
        case placeholderHeader(PlaceholderKind)
    }

    /// What the region is, independent of where it currently is: the text of
    /// its first line, which fold of that line it is, and how many regions
    /// before it share both. Survives edits above it, so a folded section stays
    /// folded while you type.
    struct Key: Sendable, Hashable {
        let firstLineText: String
        let isHeader: Bool
        let occurrence: Int
    }

    let key: Key
    let kind: Kind
    /// Zero-based, inclusive.
    let firstLine: Int
    let lastLine: Int
    /// The characters hidden when folded. They start at the end of the first
    /// line, so what follows the region continues right after that line.
    let hiddenRange: NSRange
    /// Shown in the badge that stands in for the hidden text.
    let label: String

    var id: Key { key }

    var isHeader: Bool { key.isHeader }

    static func regions(in text: String, headings: [Heading], scan: PlaceholderScan) -> [FoldRegion] {
        let ns = text as NSString
        let lines = LineIndex(ns)
        var found: [(first: Int, last: Int, kind: Kind, hidden: NSRange, label: String)] = []

        func endOfLine(_ line: Int) -> Int { NSMaxRange(lines.contentRange(ofLine: line)) }

        for (index, heading) in headings.enumerated() {
            let next = headings[(index + 1)...].first { $0.level <= heading.level }
            var last = (next?.line ?? lines.count) - 1
            // Blank lines before the next heading stay visible, as spacing.
            while last > heading.line,
                  ns.substring(with: lines.contentRange(ofLine: last)).trimmingCharacters(in: .whitespaces).isEmpty {
                last -= 1
            }
            guard last > heading.line else { continue }
            let start = endOfLine(heading.line)
            let count = last - heading.line
            found.append((heading.line, last, .section(level: heading.level),
                          NSRange(location: start, length: endOfLine(last) - start),
                          "\(count) line\(count == 1 ? "" : "s")"))
        }

        for placeholder in scan.placeholders {
            let first = placeholder.openLines.lowerBound
            guard first < lines.count else { continue }
            let label = firstParameter(of: placeholder)
            let start = endOfLine(first)

            // The header: up to the `-->`, which stays in view after the badge.
            let arrow = NSMaxRange(placeholder.openRange) - 3
            if placeholder.openLines.upperBound > first, arrow > start {
                found.append((first, placeholder.openLines.upperBound, .placeholderHeader(placeholder.kind),
                              NSRange(location: start, length: arrow - start), label))
            }

            // The whole placeholder, for those that own content below the comment.
            let last: Int? = switch placeholder.shape {
            case .paired: placeholder.closeLine
            case .managedLine: placeholder.managedLine
            case .selfContained: nil
            }
            if let last, last > first, last < lines.count {
                found.append((first, last, .placeholder(placeholder.kind),
                              NSRange(location: start, length: endOfLine(last) - start),
                              label.isEmpty ? "/\(placeholder.terminator)" : "\(label) … /\(placeholder.terminator)"))
            }
        }

        // Document order; on one line, the whole placeholder before its header.
        found.sort { lhs, rhs in
            if lhs.first != rhs.first { return lhs.first < rhs.first }
            return lhs.last > rhs.last
        }
        var seen: [Key: Int] = [:]
        return found.map { item in
            let firstText = ns.substring(with: lines.contentRange(ofLine: item.first))
            var isHeader = false
            if case .placeholderHeader = item.kind { isHeader = true }
            let base = Key(firstLineText: firstText, isHeader: isHeader, occurrence: 0)
            let occurrence = seen[base, default: 0]
            seen[base] = occurrence + 1
            return FoldRegion(key: Key(firstLineText: firstText, isHeader: isHeader, occurrence: occurrence),
                              kind: item.kind, firstLine: item.first, lastLine: item.last,
                              hiddenRange: item.hidden, label: item.label)
        }
    }

    /// `from: arrays-and-wanting-one.md` -- the first parameter a person wrote,
    /// so reordering the parameters chooses what a folded placeholder shows.
    static func firstParameter(of placeholder: Placeholder) -> String {
        let outline = YAMLOutline(placeholder.config,
                                  offset: placeholder.openRange.location + 4 + placeholder.kind.rawValue.utf16.count,
                                  line: placeholder.openLines.lowerBound)
        let written = outline.entries.first { entry in
            !entry.key.hasPrefix("_") || entry.key == "_yolo_"
        }
        guard let entry = written else { return "" }
        let value: String = switch entry.value {
        case .scalar(let text, _, _): text
        case .block: "…"
        case .flow(let text, _): text
        case .mapping, .sequence: "…"
        case .null: ""
        }
        let label = value.isEmpty ? entry.key : "\(entry.key): \(value)"
        return label.count > 60 ? String(label.prefix(59)) + "…" : label
    }
}
