import Foundation

/// Switching short variable references to the marker form, for a value with spaces.
///
/// mdship puts a value after `<!--$name-->` only when the value has no spaces:
/// the short form's value runs to the end of the line, so a value with spaces
/// could not be told from the text after it. mdship then stops with
///
///     Variable 'name' value 'two words' contains spaces. Use the marker form: ...
///
/// and the fix is `<!--$name<MARKER>--><!--MARKER-->`, which mdship fills in.
enum VariableMarkerFix {

    struct Failure: Equatable, Sendable {
        let name: String
        let value: String
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"Variable '([a-zA-Z_][a-zA-Z0-9_.\[\]]*)' value '(.*)' contains spaces\. Use the marker form"#,
        options: [.dotMatchesLineSeparators])

    /// The variable mdship refused, from what it printed.
    static func failure(in output: String) -> Failure? {
        let ns = output as NSString
        guard let match = pattern.firstMatch(in: output, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Failure(name: ns.substring(with: match.range(at: 1)), value: ns.substring(with: match.range(at: 2)))
    }

    /// The shortest marker whose closing comment cannot turn up inside `value`:
    /// the empty marker when it can be, then 1, 2, ... A marker holds no `>`.
    static func marker(for value: String) -> String {
        var candidates = [""] + (1...9).map(String.init) + ["M", "MARKER"]
        candidates += (10...999).map(String.init)
        return candidates.first { !value.contains("<!--\($0)-->") } ?? UUID().uuidString
    }

    /// The short references to `name` in `text`, rewritten in the marker form.
    ///
    /// The old value -- the spaceless run after `-->` -- goes; mdship puts the
    /// new one between the markers. A value in backticks stays, since mdship
    /// keeps the backticks around the new value. Text after the old value on
    /// the line stays too.
    static func fix(_ failure: Failure, in text: String, variables: [VariableReference]) -> (text: String, count: Int) {
        let ns = text as NSString
        let marker = marker(for: failure.value)
        let result = NSMutableString(string: text)
        var count = 0
        for reference in variables.reversed() where reference.marker == nil && reference.name == failure.name {
            let opening = ns.substring(with: NSRange(location: reference.range.location,
                                                     length: reference.valueRange.location - reference.range.location))
            guard opening.hasSuffix("-->") else { continue }
            let head = String(opening.dropLast(3))
            let rest = ns.substring(with: reference.valueRange)
            let old = String(rest.prefix { !$0.isWhitespace })
            let kept = isBacktickWrapped(old) ? old : ""
            let replaced = NSRange(location: reference.range.location,
                                   length: (opening as NSString).length + (old as NSString).length)
            result.replaceCharacters(in: replaced, with: "\(head)<\(marker)>-->\(kept)<!--\(marker)-->")
            count += 1
        }
        return (result as String, count)
    }

    /// mdship's test: as many backticks at each end, with something between.
    private static func isBacktickWrapped(_ value: String) -> Bool {
        let leading = value.prefix { $0 == "`" }.count
        let trailing = value.reversed().prefix { $0 == "`" }.count
        return leading > 0 && leading == trailing && leading * 2 < value.count
    }
}
