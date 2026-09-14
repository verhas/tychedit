import Foundation

/// What each placeholder accepts, as Tychedit understands mdship.
///
/// Taken from mdship's source (`markdown.py`, `scripting.py`) at version 1.2.5:
/// the keys each processor reads with `config.get`/`config[...]`, the ones it
/// requires, and the combinations it rejects. An installed mdship that is newer
/// or older may accept a little more or less; the editor's word is advice, and
/// only mdship's own run is final.
struct PlaceholderSchema: Sendable {

    enum ValueType: Sendable, Equatable {
        case string
        case integer(ClosedRange<Int>?)
        case boolean
        case choice([String])
        /// A regular expression, and how many capture groups mdship insists on.
        case regex(groups: Int?)
        /// `"x..y"`, 1-based and inclusive.
        case lineRange
        /// A file mdship reads, relative to the markdown file unless absolute.
        case inputFile
        /// A file or a directory mdship reads.
        case inputFileOrDirectory
        /// A file mdship writes; it need not exist.
        case outputFile
        /// Script names under `.mdship/scripts/`: one, or a list.
        case scripts
        /// Multi-line text, usually a `|` block.
        case text
        /// A regex string, or `{pattern, include}`.
        case boundary
        case mapping
        case list
        /// AI `deps:` -- a list of `{path, range | start/end | section, binary}`.
        case dependencies
        case any

        var isFile: Bool {
            switch self {
            case .inputFile, .inputFileOrDirectory, .outputFile, .scripts: true
            default: false
            }
        }
    }

    struct Parameter: Sendable, Identifiable {
        let name: String
        let type: ValueType
        let required: Bool
        let summary: String
        /// What completion inserts; `\u{1}` and `\u{2}` delimit the part selected afterwards.
        let insertion: String
        /// Written by mdship, not by people: never suggested, always accepted.
        let managed: Bool

        var id: String { name }

        init(_ name: String, _ type: ValueType, required: Bool = false, _ summary: String,
             insertion: String? = nil, managed: Bool = false) {
            self.name = name
            self.type = type
            self.required = required
            self.summary = summary
            self.managed = managed
            self.insertion = insertion ?? Parameter.defaultInsertion(name, type)
        }

        static func defaultInsertion(_ name: String, _ type: ValueType) -> String {
            switch type {
            case .text: "\(name): |\n  \u{1}\u{2}"
            case .mapping: "\(name):\n  \u{1}\u{2}"
            case .list: "\(name):\n  - \u{1}\u{2}"
            case .dependencies: "\(name):\n  - path: \"\u{1}\u{2}\""
            case .integer, .boolean, .choice: "\(name): \u{1}\u{2}"
            default: "\(name): \"\u{1}\u{2}\""
            }
        }
    }

    let kind: PlaceholderKind
    let parameters: [Parameter]
    /// Keys beyond the listed ones are fine: SET's variables, PYTHON's script arguments.
    let acceptsOtherKeys: Bool
    /// Groups of keys that cannot be combined; mdship uses the first group present.
    let exclusiveGroups: [[String]]

    func parameter(_ name: String) -> Parameter? {
        parameters.first { $0.name == name }
    }

    // MARK: - Shared parameters

    private static let terminate = Parameter(
        "_terminate_", .string,
        "Closing tag name to use instead of the placeholder's own: <!--/NAME-->",
        insertion: "_terminate_: \"\u{1}END\u{2}\"")
    private static let contentGenerated = Parameter(
        "_content_generated_", .string, "Length and checksum of the generated content, written by mdship", managed: true)
    private static let transform = Parameter(
        "transform", .scripts, "Script(s) in .mdship/scripts that post-process the generated content")
    private static let audit = Parameter(
        "audit", .scripts, "Script(s) in .mdship/scripts that check the collected variables")
    private static let name = Parameter(
        "name", .string, "Variable name to store the values under; dots make a hierarchy")
    private static let include = Parameter(
        "include", .string, "Glob of files to read when `from` is a directory (default *)")
    private static let exclude = Parameter(
        "exclude", .string, "Glob of files to skip when `from` is a directory")
    private static let recurse = Parameter(
        "recurse", .boolean, "Descend into subdirectories of `from`")
    private static let strategy = Parameter(
        "strategy", .choice(["fail", "first", "last", "concatenate"]),
        "What to do when a pattern matches more than once (default fail)")
    private static let separator = Parameter(
        "separator", .string, "Joins the matches for strategy: concatenate")

    // MARK: - The schemas

    static let all: [PlaceholderKind: PlaceholderSchema] = [
        .set: PlaceholderSchema(kind: .set, parameters: [
            Parameter("pattern", .mapping, "Named regular expressions, usable as @name in SUP and SIP"),
            audit,
        ], acceptsOtherKeys: true, exclusiveGroups: []),

        .importFile: PlaceholderSchema(kind: .importFile, parameters: [
            Parameter("name", .string, required: true, "Variable to store the imported data under"),
            Parameter("from", .inputFile, required: true, "JSON, YAML, TOML or XML file to import"),
            Parameter("format", .choice(["json", "yaml", "toml", "xml"]), "File format, when the extension does not say"),
            audit,
        ], acceptsOtherKeys: false, exclusiveGroups: []),

        .slurp: PlaceholderSchema(kind: .slurp, parameters: [
            Parameter("from", .inputFileOrDirectory, required: true, "File or directory to extract names and values from"),
            Parameter("rules", .list, required: true, "Regexes with two groups: the name, then the value"),
            name, include, exclude, recurse, strategy, separator, audit,
        ], acceptsOtherKeys: false, exclusiveGroups: []),

        .sip: PlaceholderSchema(kind: .sip, parameters: [
            Parameter("from", .inputFileOrDirectory, required: true, "File or directory to extract values from"),
            Parameter("vars", .mapping, required: true, "Variable name → regex with one group capturing the value"),
            name, include, exclude, recurse, strategy, separator, audit,
        ], acceptsOtherKeys: false, exclusiveGroups: []),

        .sup: PlaceholderSchema(kind: .sup, parameters: [
            Parameter("name", .string, required: true, "Variable to store the value under"),
            Parameter("pattern", .regex(groups: 1), required: true,
                      "Regex with one group, matched against the next non-empty line; or @heading, @version"),
            audit,
        ], acceptsOtherKeys: false, exclusiveGroups: []),

        .template: PlaceholderSchema(kind: .template, parameters: [
            Parameter("content", .text, required: true, "Template text; $variables are substituted"),
            transform, terminate, contentGenerated,
        ], acceptsOtherKeys: false, exclusiveGroups: []),

        .jinja2: PlaceholderSchema(kind: .jinja2, parameters: [
            Parameter("content", .text, required: true, "Jinja2 template; every mdship variable is available"),
            transform, terminate, contentGenerated,
        ], acceptsOtherKeys: false, exclusiveGroups: []),

        .include: PlaceholderSchema(kind: .include, parameters: [
            Parameter("from", .inputFile, required: true, "File to include, relative to this document"),
            Parameter("prefix", .string, "Line added before the included text, such as ```python"),
            Parameter("postfix", .string, "Line added after the included text, such as ```"),
            Parameter("range", .lineRange, "Lines x..y of the file, 1-based and inclusive", insertion: "range: \"\u{1}1..10\u{2}\""),
            Parameter("start", .boundary, "Regex: start after the first matching line; or {pattern, include}"),
            Parameter("end", .boundary, "Regex: stop before the next matching line; or {pattern, include}"),
            Parameter("section", .string, "Heading title of the section to include, numbering ignored"),
            Parameter("margin", .integer(0...200), "Indent so the leftmost line has this many spaces"),
            transform, terminate, contentGenerated,
        ], acceptsOtherKeys: false, exclusiveGroups: [["range"], ["start", "end"], ["section"]]),

        .toc: PlaceholderSchema(kind: .toc, parameters: [
            Parameter("min-level", .integer(1...6), "Shallowest heading level listed (default 1)"),
            Parameter("max-level", .integer(1...6), "Deepest heading level listed (default 6)"),
            transform, terminate, contentGenerated,
        ], acceptsOtherKeys: false, exclusiveGroups: []),

        .mermaid: PlaceholderSchema(kind: .mermaid, parameters: [
            Parameter("file", .outputFile, required: true, "Image to render into: .svg or .png"),
            Parameter("diagram", .text, required: true, "Mermaid source; write --\\> for -->"),
            Parameter("theme", .choice(["default", "forest", "dark", "neutral"]), "Mermaid theme"),
            transform, contentGenerated,
        ], acceptsOtherKeys: false, exclusiveGroups: []),

        .python: PlaceholderSchema(kind: .python, parameters: [
            Parameter("run", .scripts, "Script whose run(content, ctx) generates the content"),
            Parameter("define", .scripts, "Script whose define(ctx) defines variables"),
            Parameter("audit", .scripts, "Script(s) that check the variables (define: mode only)"),
            Parameter("_yolo_", .boolean, "Overwrite the content even if it was edited by hand"),
            terminate, contentGenerated,
        ], acceptsOtherKeys: true, exclusiveGroups: [["run"], ["define"]]),

        .ai: PlaceholderSchema(kind: .ai, parameters: [
            Parameter("name", .string, "Unique name to address this placeholder by; not a plain number"),
            Parameter("prompt", .text, "What to write"),
            Parameter("brief", .inputFile, "File of standing style and audience instructions"),
            Parameter("deps", .dependencies, "Files the content depends on"),
            terminate, contentGenerated,
            Parameter("_prompt_checksum_", .string, "Checksum of the prompt, written by mdship ai-fix", managed: true),
            Parameter("_brief_checksum_", .string, "Checksum of the brief, written by mdship ai-fix", managed: true),
        ], acceptsOtherKeys: false, exclusiveGroups: []),
    ]

    /// The keys of one `deps:` entry of an AI placeholder.
    static let dependency: [Parameter] = [
        Parameter("path", .inputFile, required: true, "File the content depends on"),
        Parameter("range", .lineRange, "Only lines x..y", insertion: "range: \"\u{1}1..10\u{2}\""),
        Parameter("start", .boundary, "Regex: start after the first matching line"),
        Parameter("end", .boundary, "Regex: stop before the next matching line"),
        Parameter("section", .string, "Only the section under this heading"),
        Parameter("binary", .boolean, "Checksum the raw bytes; cannot be combined with range, start or end"),
        Parameter("checksum", .string, "Checksum of the file, written by mdship ai-fix", managed: true),
    ]

    /// The keys of a `start:` or `end:` written as a mapping.
    static let boundary: [Parameter] = [
        Parameter("pattern", .regex(groups: nil), required: true, "Regex matching the boundary line"),
        Parameter("include", .boolean, "Include the matching line itself (default false)"),
    ]

    /// Parameters available at `path` inside a `kind` placeholder: `[]` is the
    /// top level, `["deps"]` an AI dependency, `["start"]` a boundary mapping.
    static func parameters(for kind: PlaceholderKind, at path: [String]) -> [Parameter] {
        guard let schema = all[kind] else { return [] }
        guard let last = path.last else { return schema.parameters }
        if path == ["deps"] && kind == .ai { return dependency }
        if last == "start" || last == "end" { return boundary }
        return []
    }
}
