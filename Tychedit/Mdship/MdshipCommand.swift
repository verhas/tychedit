import Foundation

/// The mdship operations the editor offers.
enum MdshipCommand: String, CaseIterable, Identifiable, Sendable {
    case update
    case forceUpdate
    case toc
    case includes
    case diagrams
    case number
    case unnumber
    case fixHeadings
    case shiftHeadingsDown
    case shiftHeadingsUp
    case formatTables
    case semanticLineBreaks
    case reflow
    case validateLinks
    case aiCheck
    case addChecksum
    case verifyChecksum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .update: "Update Placeholders"
        case .forceUpdate: "Update Placeholders, Overwriting Edits"
        case .toc: "Update Table of Contents"
        case .includes: "Update Includes"
        case .diagrams: "Render Diagrams"
        case .number: "Number Headings"
        case .unnumber: "Remove Heading Numbers"
        case .fixHeadings: "Fix Heading Levels"
        case .shiftHeadingsDown: "Demote Headings"
        case .shiftHeadingsUp: "Promote Headings"
        case .formatTables: "Format Tables"
        case .semanticLineBreaks: "Semantic Line Breaks"
        case .reflow: "Reflow Paragraphs"
        case .validateLinks: "Validate Links"
        case .aiCheck: "Check AI Placeholders"
        case .addChecksum: "Add Checksum"
        case .verifyChecksum: "Verify Checksum"
        }
    }

    /// The toolbar and menu icon unless Settings choose another: an SF Symbol name.
    var defaultIcon: String {
        switch self {
        case .update: "arrow.triangle.2.circlepath"
        case .forceUpdate: "exclamationmark.arrow.triangle.2.circlepath"
        case .toc: "list.bullet.indent"
        case .includes: "doc.on.doc"
        case .diagrams: "flowchart"
        case .number: "list.number"
        case .unnumber: "list.bullet"
        case .fixHeadings: "text.line.first.and.arrowtriangle.forward"
        case .shiftHeadingsDown: "decrease.indent"
        case .shiftHeadingsUp: "increase.indent"
        case .formatTables: "tablecells"
        case .semanticLineBreaks: "text.alignleft"
        case .reflow: "text.justify"
        case .validateLinks: "link"
        case .aiCheck: "sparkles"
        case .addChecksum: "number.square"
        case .verifyChecksum: "checkmark.seal"
        }
    }

    /// The command writes the file, which the editor then reloads.
    var changesFile: Bool {
        switch self {
        case .validateLinks, .aiCheck, .verifyChecksum: false
        default: true
        }
    }

    /// Limited to the selected lines when there is a selection.
    var usesSelection: Bool {
        switch self {
        case .number, .unnumber, .shiftHeadingsDown, .shiftHeadingsUp, .semanticLineBreaks, .reflow: true
        default: false
        }
    }

    enum Request {
        case tool(String, [String: Any])
        /// Arguments after `mdship`; the file path is included.
        case cli([String])
    }

    struct Options {
        var backup: Bool
        var numberingStyle: String
        var skipTitle: Bool
        var reflowWidth: Int
    }

    /// How to ask for it. `lines` are 1-based and inclusive.
    func request(path: String, lines: ClosedRange<Int>?, options: Options) -> Request {
        var arguments: [String: Any] = ["path": path]
        if changesFile { arguments["backup"] = options.backup }
        if usesSelection, let lines {
            arguments["start_line"] = lines.lowerBound
            arguments["end_line"] = lines.upperBound
        }
        switch self {
        case .update: return .tool("update", arguments)
        case .forceUpdate:
            arguments["force"] = true
            return .tool("update", arguments)
        case .toc: return .tool("toc", arguments)
        case .includes: return .tool("include", arguments)
        case .diagrams: return .tool("mermaid", arguments)
        case .number:
            arguments["style"] = options.numberingStyle
            if options.skipTitle { arguments["skip_title"] = true }
            return .tool("number", arguments)
        case .unnumber: return .tool("unnumber", arguments)
        case .fixHeadings: return .tool("fix_headings", arguments)
        case .shiftHeadingsDown:
            arguments["levels"] = 1
            return .tool("shift_headings", arguments)
        case .shiftHeadingsUp:
            arguments["levels"] = -1
            return .tool("shift_headings", arguments)
        case .formatTables: return .tool("format_tables", arguments)
        case .semanticLineBreaks: return .tool("semantic_line_breaks", arguments)
        case .reflow:
            arguments["width"] = options.reflowWidth
            return .tool("reflow", arguments)
        // The MCP server has no link validation; the command line does.
        case .validateLinks: return .cli(["validate", path])
        case .aiCheck: return .tool("ai_check", arguments)
        case .addChecksum: return .tool("add_checksum", arguments)
        case .verifyChecksum: return .tool("check_checksum", arguments)
        }
    }

    /// Output that reports problems rather than success, although the command ran.
    func reportsProblems(_ output: String, status: Int32) -> Bool {
        switch self {
        case .validateLinks: status != 0
        case .verifyChecksum: output.hasPrefix("Error")
        case .aiCheck: output.localizedCaseInsensitiveContains("error") || output.localizedCaseInsensitiveContains("mismatch")
        default: false
        }
    }
}

/// Reading `Line N:` out of whatever mdship printed.
enum MdshipOutput {

    private static let linePattern = try! NSRegularExpression(pattern: #"Line (\d+):\s*(.*)"#)

    static func issues(in output: String, text: String) -> [PlaceholderIssue] {
        let lines = LineIndex(text)
        var issues: [PlaceholderIssue] = []
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            let ns = line as NSString
            guard let match = linePattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  let number = Int(ns.substring(with: match.range(at: 1))), number >= 1 else { continue }
            let target = min(number - 1, lines.count - 1)
            let message = line.trimmingCharacters(in: .whitespaces)
            issues.append(PlaceholderIssue(line: target, range: lines.contentRange(ofLine: target),
                                           message: message.hasPrefix("Line") ? message : "Line \(number): " + ns.substring(with: match.range(at: 2)),
                                           severity: .error, source: .mdship))
        }
        return issues
    }

    /// mdship's MCP errors start with "Error executing tool update: ".
    static func cleaned(_ message: String) -> String {
        message.replacingOccurrences(of: #"^Error executing tool \w+: "#, with: "", options: .regularExpression)
    }
}
