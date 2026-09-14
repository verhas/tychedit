import Foundation

/// An open fenced code block: ``` or ~~~, at least three of them.
///
/// Shared by the placeholder scanner and the markdown renderer, because both
/// must agree on what is code. A placeholder shown inside a code fence is an
/// example, not a placeholder -- mdship itself skips those, and so does the
/// preview.
struct Fence: Sendable, Equatable {

    let character: Character
    let count: Int
    /// Leading spaces of the opening line, removed from the code lines too.
    let indent: Int
    /// The info string: `swift` in ```swift. Empty when absent.
    let info: String

    /// The fence that `line` opens, if it opens one.
    ///
    /// `maxIndent` is 3 for CommonMark. The placeholder scanner passes a larger
    /// value because mdship recognises a fence at any indentation -- a code
    /// block inside a list item is indented further than three spaces.
    static func opening(_ line: String, maxIndent: Int = 3) -> Fence? {
        var indent = 0
        var rest = Substring(line)
        while let first = rest.first, first == " " {
            indent += 1
            rest = rest.dropFirst()
        }
        guard indent <= maxIndent, let marker = rest.first, marker == "`" || marker == "~" else {
            return nil
        }
        let run = rest.prefix { $0 == marker }.count
        guard run >= 3 else { return nil }
        let info = rest.dropFirst(run).trimmingCharacters(in: .whitespaces)
        // A backtick in a backtick fence's info string makes it an inline code
        // span instead, as in ```not a fence```.
        if marker == "`" && info.contains("`") { return nil }
        return Fence(character: marker, count: run, indent: indent, info: info)
    }

    /// Whether `line` closes this fence: the same character, at least as many,
    /// and nothing else on the line but spaces.
    func isClosed(by line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let trimmedEnd = trimmed.hasSuffix("\r") ? String(trimmed.dropLast()) : trimmed
        guard trimmedEnd.count >= count else { return false }
        return trimmedEnd.allSatisfy { $0 == character }
    }
}
