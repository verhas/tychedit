import Foundation

/// How the find bar matches.
struct FindOptions: Codable, Equatable, Sendable {
    var caseSensitive = false
    var wholeWords = false
    /// The query is a regular expression, and the replacement may use `$1`, `$2` ...
    var regex = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        caseSensitive = try c.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false
        wholeWords = try c.decodeIfPresent(Bool.self, forKey: .wholeWords) ?? false
        regex = try c.decodeIfPresent(Bool.self, forKey: .regex) ?? false
    }
}

/// Finding and replacing in text, for the find bar.
enum TextSearch {

    enum Failure: Error, Equatable {
        case invalidExpression(String)
    }

    /// The expression for `query`. A plain query is escaped; whole words means
    /// no letter, digit or underscore right before or after the match.
    static func expression(for query: String, options: FindOptions) throws -> NSRegularExpression {
        var pattern = options.regex ? query : NSRegularExpression.escapedPattern(for: query)
        if options.wholeWords {
            pattern = #"(?<![\p{L}\p{N}_])(?:"# + pattern + #")(?![\p{L}\p{N}_])"#
        }
        var flags: NSRegularExpression.Options = [.anchorsMatchLines]
        if !options.caseSensitive { flags.insert(.caseInsensitive) }
        do {
            return try NSRegularExpression(pattern: pattern, options: flags)
        } catch {
            throw Failure.invalidExpression(query)
        }
    }

    /// Why a regex replacement cannot work: it refers to a group the expression
    /// does not have. NSRegularExpression would put an empty string there
    /// without a word, which is how a replacement silently loses text.
    static func templateProblem(_ template: String, groups: Int) -> String? {
        let chars = Array(template)
        var i = 0
        var missing: [Int] = []
        while i < chars.count {
            if chars[i] == "\\" {
                i += 2
                continue
            }
            if chars[i] == "$", i + 1 < chars.count, let digit = chars[i + 1].wholeNumberValue {
                if digit > groups { missing.append(digit) }
                i += 2
                continue
            }
            i += 1
        }
        guard let first = missing.first else { return nil }
        let have = groups == 0 ? "no capturing groups" : groups == 1 ? "only 1 capturing group" : "only \(groups) capturing groups"
        return "The replacement uses $\(first), but the expression has \(have)"
    }

    /// Non-empty matches, in order; at most `limit`.
    static func matches(of expression: NSRegularExpression, in text: String, limit: Int = 50_000) -> [NSRange] {
        var ranges: [NSRange] = []
        expression.enumerateMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) { result, _, stop in
            guard let result, result.range.length > 0 else { return }
            ranges.append(result.range)
            if ranges.count >= limit { stop.pointee = true }
        }
        return ranges
    }

    /// The replacement for the match at `range`: the template with `$1`... filled
    /// in for a regular expression, the template as written otherwise.
    static func replacement(for range: NSRange, in text: String, expression: NSRegularExpression,
                            template: String, options: FindOptions) -> String? {
        guard let match = expression.firstMatch(in: text, options: [.anchored], range: NSRange(location: range.location, length: (text as NSString).length - range.location)),
              match.range == range else { return nil }
        let effective = options.regex ? template : NSRegularExpression.escapedTemplate(for: template)
        return expression.replacementString(for: match, in: text, offset: 0, template: effective)
    }

    /// The text with every match replaced, and how many there were.
    static func replacingAll(in text: String, expression: NSRegularExpression, template: String,
                             options: FindOptions) -> (text: String, count: Int) {
        let whole = NSRange(location: 0, length: (text as NSString).length)
        let count = matches(of: expression, in: text, limit: .max).count
        let effective = options.regex ? template : NSRegularExpression.escapedTemplate(for: template)
        return (expression.stringByReplacingMatches(in: text, range: whole, withTemplate: effective), count)
    }
}
