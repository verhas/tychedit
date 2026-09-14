import Foundation

/// The small amount of HTML knowledge the renderer needs.
enum HTML {

    /// Text content: `&`, `<` and `>`, and quotes so the same function is safe
    /// inside attribute values.
    static func escape(_ text: some StringProtocol) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default: result.append(character)
            }
        }
        return result
    }

    /// A URL for an `href` or `src`: spaces encoded, quotes escaped, anything
    /// already percent-encoded left alone.
    static func escapeURL(_ url: String) -> String {
        escape(url.replacingOccurrences(of: " ", with: "%20"))
    }

    /// The anchor mdship gives a heading, so that links in a generated TOC
    /// land where `mdship toc` meant them to: lower case, spaces and
    /// underscores to hyphens, everything but `a-z0-9-` dropped.
    ///
    /// `1.4.7. Template Placeholders` becomes `147-template-placeholders`.
    static func anchor(for heading: String) -> String {
        let withoutTags = heading.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        var slug = withoutTags.lowercased()
        slug = slug.replacingOccurrences(of: #"[\s_]+"#, with: "-", options: .regularExpression)
        slug = slug.replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
        slug = slug.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// `true` for the characters a backslash may escape in markdown.
    static func isASCIIPunctuation(_ character: Character) -> Bool {
        guard let ascii = character.asciiValue else { return false }
        return (33...47).contains(ascii) || (58...64).contains(ascii)
            || (91...96).contains(ascii) || (123...126).contains(ascii)
    }
}
