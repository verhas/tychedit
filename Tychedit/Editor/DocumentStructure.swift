import Foundation

/// The document's headings as a tree, and moving whole sections within it.
///
/// A heading's section runs from the heading to the line before the next
/// heading of the same or a higher level, or to the end of the document -- so
/// moving a heading moves everything under it, subheadings included.
struct DocumentStructure: Sendable, Equatable {

    struct Entry: Sendable, Equatable {
        let level: Int
        let text: String
        /// Zero-based line of the heading.
        let line: Int
        /// A setext heading: the text line followed by === or ---.
        let setext: Bool
    }

    /// The headings that can be moved, in document order.
    let entries: [Entry]
    /// `parents[i]` is the index of heading `i`'s parent, nil at the top.
    let parents: [Int?]
    /// The level the top of the tree sits at: the shallowest heading.
    let rootLevel: Int
    let lineCount: Int

    /// Headings from the renderer, less the ones that must not move: those
    /// inside generated placeholder content, which mdship owns, and those that
    /// are not heading lines of their own (in a list or a quote).
    init(text: String, headings: [Heading], scan: PlaceholderScan) {
        let ns = text as NSString
        let index = LineIndex(ns)
        let managed = scan.placeholders.compactMap { placeholder -> ClosedRange<Int>? in
            guard let body = placeholder.bodyRange, body.length > 0 else { return nil }
            let first = index.line(containing: body.location)
            let last = index.line(containing: max(body.location, NSMaxRange(body) - 1))
            return first...last
        }
        var entries: [Entry] = []
        for heading in headings where heading.line < index.count {
            if managed.contains(where: { $0.contains(heading.line) }) { continue }
            let line = ns.substring(with: index.contentRange(ofLine: heading.line))
            let trimmed = line.drop { $0 == " " }
            if trimmed.hasPrefix("#") {
                entries.append(Entry(level: heading.level, text: heading.text, line: heading.line, setext: false))
            } else if heading.line + 1 < index.count {
                let next = ns.substring(with: index.contentRange(ofLine: heading.line + 1)).trimmingCharacters(in: .whitespaces)
                if !next.isEmpty, next.allSatisfy({ $0 == "=" }) || next.allSatisfy({ $0 == "-" }) {
                    entries.append(Entry(level: heading.level, text: heading.text, line: heading.line, setext: true))
                }
            }
        }
        self.entries = entries
        var parents: [Int?] = []
        var stack: [Int] = []
        for (i, entry) in entries.enumerated() {
            while let top = stack.last, entries[top].level >= entry.level { stack.removeLast() }
            parents.append(stack.last)
            stack.append(i)
        }
        self.parents = parents
        rootLevel = entries.map(\.level).min() ?? 1
        // A final newline ends the last line; it does not start another one.
        lineCount = text.hasSuffix("\n") ? index.count - 1 : index.count
    }

    func children(of parent: Int?) -> [Int] {
        entries.indices.filter { parents[$0] == parent }
    }

    /// The line after heading `i`'s section.
    func sectionEnd(_ i: Int) -> Int {
        let level = entries[i].level
        return entries[(i + 1)...].first { $0.level <= level }?.line ?? lineCount
    }

    /// Moves the sections of headings `selection` (consecutive, in document
    /// order) so they become children of `parent` at `childIndex` -- counted
    /// in `children(of: parent)` as it is before the move, the way an outline
    /// view proposes a drop. A new parent sets the level: one below it, with
    /// every heading in the moved sections shifted by as much.
    ///
    /// Returns the new text, or nil when the move is not possible: into its own
    /// section, or to a level outside 1...6.
    func move(_ selection: ClosedRange<Int>, toParent parent: Int?, childIndex: Int, in text: String) -> String? {
        guard selection.lowerBound >= 0, selection.upperBound < entries.count else { return nil }
        let blockStart = entries[selection.lowerBound].line
        let blockEnd = selection.map(sectionEnd).max() ?? blockStart
        let inBlock = { (i: Int) in entries[i].line >= blockStart && entries[i].line < blockEnd }
        if let parent, inBlock(parent) { return nil }

        // Where the sections go, in lines of the text as it is now.
        let siblings = children(of: parent)
        var insertLine: Int
        if childIndex < siblings.count {
            let sibling = siblings[childIndex]
            insertLine = inBlock(sibling) ? blockStart : entries[sibling].line
        } else if let parent {
            insertLine = sectionEnd(parent)
        } else {
            insertLine = lineCount
        }
        if insertLine > blockStart && insertLine < blockEnd { insertLine = blockStart }

        // The level: unchanged under the same parent, one below a new one.
        let first = selection.lowerBound
        let newLevel = parents[first] == parent ? entries[first].level : (parent.map { entries[$0].level } ?? rootLevel - 1) + 1
        let delta = newLevel - entries[first].level
        let moved = entries.indices.filter(inBlock)
        guard moved.allSatisfy({ (1...6).contains(entries[$0].level + delta) }) else { return nil }
        if delta == 0 && (insertLine == blockStart || insertLine == blockEnd) { return nil }

        var lines = LineIndex.split(text)
        let endsWithNewline = text.hasSuffix("\n")
        if endsWithNewline { lines.removeLast() }
        let crlf = text.contains("\r\n")

        // Rewrite the headings inside the block.
        var block = Array(lines[blockStart..<blockEnd])
        if delta != 0 {
            var removedUnderlines: [Int] = []
            for i in moved {
                let offset = entries[i].line - blockStart
                let level = entries[i].level + delta
                if entries[i].setext {
                    block[offset] = String(repeating: "#", count: level) + " " + block[offset].trimmingCharacters(in: .whitespaces)
                    removedUnderlines.append(offset + 1)
                } else {
                    let line = block[offset]
                    let indent = line.prefix { $0 == " " }
                    let rest = line.dropFirst(indent.count).drop { $0 == "#" }
                    block[offset] = indent + String(repeating: "#", count: level) + rest
                }
            }
            for offset in removedUnderlines.sorted(by: >) where offset < block.count {
                block.remove(at: offset)
            }
        }

        lines.removeSubrange(blockStart..<blockEnd)
        var at = insertLine > blockStart ? insertLine - (blockEnd - blockStart) : insertLine
        at = min(max(0, at), lines.count)
        // A heading needs its own paragraph: one blank line on either side.
        let isBlank = { (line: String) in line.trimmingCharacters(in: .whitespaces).isEmpty }
        while block.count > 1, let last = block.last, isBlank(last) { block.removeLast() }
        if at > 0, !isBlank(lines[at - 1]) {
            block.insert("", at: 0)
        }
        if at < lines.count, !isBlank(lines[at]) {
            block.append("")
        }
        lines.insert(contentsOf: block, at: at)

        let newline = crlf ? "\r\n" : "\n"
        let joined = lines.map { crlf && $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }.joined(separator: newline)
        return endsWithNewline ? joined + newline : joined
    }
}
