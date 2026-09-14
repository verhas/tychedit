import Foundation

/// Where each line of a text starts, in UTF-16 offsets.
///
/// UTF-16 because that is the unit NSTextView, NSString and NSRange count in.
/// Every position that crosses between the model and the editor is one of
/// these, so the conversion happens nowhere else.
///
/// Lines are separated by "\n". A "\r\n" file keeps its "\r" at the end of
/// each line's content, which is harmless for display and means the text is
/// written back exactly as it was read.
struct LineIndex: Sendable, Equatable {

    /// `starts[i]` is the offset of the first character of line `i`.
    let starts: [Int]
    /// Length of the whole text.
    let length: Int

    init(_ text: NSString) {
        var starts = [0]
        let length = text.length
        // Reading through a buffer: characterAtIndex per character is a message
        // send each, and this runs on every keystroke.
        let chunk = 4096
        var buffer = [unichar](repeating: 0, count: chunk)
        var offset = 0
        while offset < length {
            let count = min(chunk, length - offset)
            text.getCharacters(&buffer, range: NSRange(location: offset, length: count))
            for i in 0..<count where buffer[i] == 10 {
                starts.append(offset + i + 1)
            }
            offset += count
        }
        self.starts = starts
        self.length = length
    }

    init(_ text: String) {
        self.init(text as NSString)
    }

    /// Number of lines. An empty text, and a text ending in a newline, both
    /// have a last, empty line -- the one the caret sits on after the newline.
    var count: Int { starts.count }

    /// The zero-based line holding `offset`. Offsets past the end give the last line.
    func line(containing offset: Int) -> Int {
        // Binary search for the last start that is <= offset.
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }

    /// The line's characters, without its terminating newline.
    func contentRange(ofLine line: Int) -> NSRange {
        let start = starts[line]
        let end = line + 1 < starts.count ? starts[line + 1] - 1 : length
        return NSRange(location: start, length: end - start)
    }

    /// The line's characters including its newline, if it has one.
    func fullRange(ofLine line: Int) -> NSRange {
        let start = starts[line]
        let end = line + 1 < starts.count ? starts[line + 1] : length
        return NSRange(location: start, length: end - start)
    }

    /// The column of `offset` within its line, zero-based, in UTF-16 units.
    func column(of offset: Int) -> Int {
        offset - starts[line(containing: offset)]
    }

    /// The lines of `text`, without terminators.
    static func split(_ text: String) -> [String] {
        // "\r\n" is one Character in Swift, so splitting on "\n" alone would
        // leave a CRLF file in one piece.
        text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }).map(String.init)
    }

    /// Lines from `first` through `last`, inclusive, as one range including the
    /// last line's newline.
    func fullRange(ofLines lines: ClosedRange<Int>) -> NSRange {
        let start = starts[lines.lowerBound]
        let end = NSMaxRange(fullRange(ofLine: lines.upperBound))
        return NSRange(location: start, length: end - start)
    }
}
