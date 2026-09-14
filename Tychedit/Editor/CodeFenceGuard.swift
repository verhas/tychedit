import Foundation

/// Keeps a backtick code fence longer than any backtick run inside its code.
///
/// A fence of three backticks ends at the first line of three backticks, so
/// code that itself contains ``` -- typed, pasted, or joined by a deletion --
/// would cut the block short. When an edit inside a block makes the longest
/// run reach the fence's length, both fences grow to one more than that run.
enum CodeFenceGuard {

    typealias Edit = (range: NSRange, replacement: String)

    /// The fence edits needed after replacing `range` of `text` with
    /// `replacement`, in the coordinates of the text after that edit; last
    /// first, so they can be applied in order. Empty when nothing needs to change.
    static func edits(afterReplacing range: NSRange, in text: String, with replacement: String) -> [Edit] {
        let old = text as NSString
        let lines = LineIndex(old)
        guard let block = enclosingBlock(of: range, in: old, lines: lines) else { return [] }

        let delta = (replacement as NSString).length - range.length
        let new = old.replacingCharacters(in: range, with: replacement) as NSString
        // The code, in the new text: from after the opening fence's line to the
        // start of the closing fence's line, which moved by the edit.
        let contentStart = NSMaxRange(lines.fullRange(ofLine: block.openLine))
        let closeStart = block.closeStart + delta
        guard closeStart >= contentStart, closeStart + block.closeCount <= new.length else { return [] }
        let content = new.substring(with: NSRange(location: contentStart, length: closeStart - contentStart))

        let longest = longestBacktickRun(in: content)
        guard longest >= block.count else { return [] }
        let wanted = String(repeating: "`", count: longest + 1)
        return [
            (NSRange(location: closeStart, length: block.closeCount), wanted),
            (NSRange(location: block.openStart, length: block.count), wanted),
        ]
    }

    private struct Block {
        /// Where the opening backticks start, and how many there are.
        let openStart: Int
        let count: Int
        let openLine: Int
        /// Where the closing backticks start, and how many there are.
        let closeStart: Int
        let closeCount: Int
    }

    /// The backtick-fenced block whose code holds all of `range`.
    private static func enclosingBlock(of range: NSRange, in text: NSString, lines: LineIndex) -> Block? {
        var open: (fence: Fence, line: Int)?
        for line in 0..<lines.count {
            let content = lines.contentRange(ofLine: line)
            let lineText = text.substring(with: content)
            if let current = open {
                guard current.fence.isClosed(by: lineText) else { continue }
                let codeStart = NSMaxRange(lines.fullRange(ofLine: current.line))
                if current.fence.character == "`", range.location >= codeStart, NSMaxRange(range) <= content.location {
                    let openLine = lines.contentRange(ofLine: current.line)
                    let closeIndent = lineText.prefix { $0 == " " }.count
                    let closeCount = lineText.dropFirst(closeIndent).prefix { $0 == "`" }.count
                    return Block(openStart: openLine.location + current.fence.indent, count: current.fence.count,
                                 openLine: current.line,
                                 closeStart: content.location + closeIndent, closeCount: closeCount)
                }
                if content.location >= NSMaxRange(range) { return nil }
                open = nil
            } else if let fence = Fence.opening(lineText) {
                if content.location > NSMaxRange(range) { return nil }
                open = (fence, line)
            }
        }
        return nil
    }

    static func longestBacktickRun(in text: String) -> Int {
        var longest = 0
        var current = 0
        for unit in text.utf16 {
            if unit == 96 {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }
}
