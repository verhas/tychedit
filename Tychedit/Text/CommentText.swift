import Foundation

/// Where `-->` sits on a line of placeholder configuration: in the YAML itself,
/// or inside a quoted value.
///
/// The distinction matters because mdship ignores it. mdship ends an opening
/// comment at the first `-->` whatever surrounds it, so `start: "<!-- a -->"`
/// ends the comment in the middle of the string, and the rest of the
/// configuration is lost. The scanner reports that; completion reads past it,
/// so the parameters are still offered while the problem is being fixed.
enum CommentText {

    /// Whether `line` has a `-->` that is not inside a quoted value.
    static func hasClosingArrow(_ line: some StringProtocol) -> Bool {
        scan(Array(line)).arrowOutsideQuotes
    }

    /// Whether the end of `prefix` is inside a quoted value -- that is, whether
    /// a `-->` right after it would be in the middle of a string.
    static func endsInsideQuotes(_ prefix: some StringProtocol) -> Bool {
        scan(Array(prefix)).openQuote != nil
    }

    private static func scan(_ chars: [Character]) -> (arrowOutsideQuotes: Bool, openQuote: Character?) {
        var quote: Character?
        // The last character that was not a space: a quote only opens a value
        // at the start of one, so the apostrophe in `don't` is just a letter.
        var previous: Character?
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let open = quote {
                if c == open { quote = nil }
            } else if c == "\"" || c == "'", previous == nil || ":-[,{".contains(previous!) {
                quote = c
            } else if c == "-", i + 2 < chars.count, chars[i + 1] == "-", chars[i + 2] == ">" {
                return (true, nil)
            }
            if !c.isWhitespace { previous = c }
            i += 1
        }
        return (false, quote)
    }
}
