import Foundation

/// Where in a file to land when a reference is followed.
enum NavigationTarget: Sendable, Equatable {
    /// Zero-based line.
    case line(Int)
    /// A heading anchor, as in `file.md#getting-started`.
    case anchor(String)
    /// A heading title, numbering ignored, as INCLUDE's `section:` names it.
    case heading(String)
    /// The first line an INCLUDE `start:` regex selects: the line after the
    /// first match, or the matching line itself with `include: true`.
    case pattern(String, includesMatch: Bool)

    /// The zero-based line a `.pattern` target lands on in `text`, or nil when
    /// nothing matches. mdship searches each line (Python's `re.search`).
    static func line(matching pattern: String, includesMatch: Bool, in text: String) -> Int? {
        guard let regex = PlaceholderValidator.regex(pattern) else { return nil }
        let lines = LineIndex.split(text)
        for (index, line) in lines.enumerated()
        where regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil {
            return includesMatch ? index : min(index + 1, lines.count - 1)
        }
        return nil
    }
}

/// A path written in a placeholder, resolved the way mdship resolves it.
struct FileReference: Sendable, Equatable {
    /// The path as written in the document.
    let range: NSRange
    let url: URL
    let target: NavigationTarget?
}

/// Answers "is there a file here" -- replaceable so tests need no real files.
struct FileSystemProbe: Sendable {
    enum Kind: Sendable { case missing, file, directory }

    var kind: @Sendable (URL) -> Kind
    var lineCount: @Sendable (URL) -> Int?

    static let live = FileSystemProbe(
        kind: { url in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .missing }
            return isDirectory.boolValue ? .directory : .file
        },
        lineCount: { url in
            // Big files are not worth reading on every keystroke to check a range.
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 8_000_000,
                  let data = try? Data(contentsOf: url) else { return nil }
            let newlines = data.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
            return data.last == 10 || data.isEmpty ? newlines : newlines + 1
        })
}

/// Checks each placeholder's configuration against `PlaceholderSchema` and
/// against the file system: unknown or misspelled keys, missing required ones,
/// values of the wrong shape, regexes with the wrong number of groups, and
/// paths that point nowhere.
///
/// Messages follow mdship's wording where mdship has an error for the same
/// thing, so the editor and a later `mdship update` say the same.
enum PlaceholderValidator {

    struct Result: Sendable, Equatable {
        var issues: [PlaceholderIssue] = []
        var references: [FileReference] = []
    }

    static func validate(text: String, scan: PlaceholderScan, documentURL: URL?,
                         fileSystem: FileSystemProbe = .live) -> Result {
        var validator = Validator(text: text as NSString, scan: scan,
                                  directory: documentURL?.deletingLastPathComponent(),
                                  fileSystem: fileSystem)
        validator.run()
        return validator.result
    }

    /// Built-in SUP/SIP pattern names; SET `pattern:` adds more.
    static let builtInPatterns: Set<String> = ["heading", "version"]

    /// The directory holding `.mdship`, searched upwards from `directory`.
    static func projectRoot(from directory: URL, fileSystem: FileSystemProbe) -> URL? {
        var current = directory.standardizedFileURL
        while true {
            if fileSystem.kind(current.appendingPathComponent(".mdship")) == .directory { return current }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
    }

    /// A path as mdship resolves it: absolute if it starts with `/`, otherwise
    /// relative to the markdown file. No `~` expansion -- mdship does none.
    static func resolve(_ path: String, against directory: URL?) -> URL? {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        guard let directory else { return nil }
        return directory.appendingPathComponent(path).standardizedFileURL
    }

    // MARK: -

    private struct Validator {
        let text: NSString
        let scan: PlaceholderScan
        let directory: URL?
        let fileSystem: FileSystemProbe
        var result = Result()
        let lines: LineIndex

        /// SET variable names seen so far, for mdship's "already defined" error.
        var definedVariables: [String: Int] = [:]
        var customPatterns: Set<String> = []
        var aiNames: [String: Int] = [:]

        init(text: NSString, scan: PlaceholderScan, directory: URL?, fileSystem: FileSystemProbe) {
            self.text = text
            self.scan = scan
            self.directory = directory
            self.fileSystem = fileSystem
            self.lines = LineIndex(text)
        }

        mutating func report(_ range: NSRange, _ message: String, _ severity: PlaceholderIssue.Severity = .error) {
            let line = lines.line(containing: range.location)
            result.issues.append(PlaceholderIssue(line: line, range: range, message: "Line \(line + 1): \(message)",
                                                  severity: severity))
        }

        mutating func run() {
            let outlines = scan.placeholders.map { placeholder in
                YAMLOutline(placeholder.config,
                            offset: placeholder.openRange.location + 4 + placeholder.kind.rawValue.utf16.count,
                            line: placeholder.openLines.lowerBound)
            }
            // Custom patterns count wherever they are defined: mdship collects all
            // variable sources before it uses any.
            for (placeholder, outline) in zip(scan.placeholders, outlines) where placeholder.kind == .set {
                if case .mapping(let entries)? = outline.entry("pattern")?.value {
                    customPatterns.formUnion(entries.map(\.key))
                }
            }
            for (placeholder, outline) in zip(scan.placeholders, outlines) {
                check(placeholder, outline)
            }
            result.issues.sort { $0.location < $1.location }
        }

        // MARK: Placeholders

        mutating func check(_ placeholder: Placeholder, _ outline: YAMLOutline) {
            let kind = placeholder.kind
            guard let schema = PlaceholderSchema.all[kind] else { return }
            let nameRange = NSRange(location: placeholder.openRange.location, length: 4 + kind.rawValue.utf16.count)

            for problem in outline.problems {
                report(problem.range, "\(kind.rawValue) configuration: \(problem.message)")
            }

            // Unknown keys and value shapes.
            for entry in outline.entries {
                guard let parameter = schema.parameter(entry.key) else {
                    if !schema.acceptsOtherKeys {
                        report(entry.keyRange, unknownKeyMessage(entry.key, kind: kind.rawValue, known: schema.parameters),
                               .warning)
                    } else if kind == .set {
                        defineVariable(entry)
                    }
                    continue
                }
                check(entry, against: parameter, in: placeholder, outline: outline)
            }

            // Required keys.
            for parameter in schema.parameters where parameter.required && outline.entry(parameter.name) == nil {
                report(nameRange, "\(kind.rawValue) placeholder requires '\(parameter.name)' parameter")
            }

            // Keys that cannot be combined.
            let present = schema.exclusiveGroups.filter { group in group.contains { outline.entry($0) != nil } }
            if kind != .python, present.count > 1, let used = present.first {
                for group in present.dropFirst() {
                    for key in group {
                        if let entry = outline.entry(key) {
                            report(entry.keyRange, "'\(key)' cannot be combined with '\(used.joined(separator: "/"))'; mdship uses '\(used[0])' and ignores this", .warning)
                        }
                    }
                }
            }

            switch kind {
            case .set:
                if outline.entries.isEmpty && outline.problems.isEmpty {
                    report(nameRange, "SET placeholder has no variables defined")
                }
            case .python:
                checkPython(outline, nameRange: nameRange)
            case .toc:
                if let min = outline.entry("min-level")?.value.scalarText.flatMap({ Int($0) }),
                   let max = outline.entry("max-level")?.value.scalarText.flatMap({ Int($0) }), min > max,
                   let entry = outline.entry("min-level") {
                    report(entry.keyRange, "min-level \(min) is deeper than max-level \(max); the table of contents will be empty", .warning)
                }
            case .mermaid:
                if let entry = outline.entry("file"), let path = entry.value.scalarText, let range = entry.value.range {
                    let ext = (path as NSString).pathExtension.lowercased()
                    if ext != "svg" && ext != "png" {
                        report(range, "Unsupported file extension '.\(ext)'. Must be .svg or .png")
                    }
                }
            case .ai:
                checkAI(outline, nameRange: nameRange)
            case .importFile:
                // Without `format`, mdship reads the format from the extension, and
                // gives up on any it does not know.
                if outline.entry("format") == nil, let entry = outline.entry("from"), let path = entry.value.scalarText {
                    let ext = (path as NSString).pathExtension.lowercased()
                    if !["json", "yaml", "yml", "toml", "xml"].contains(ext) {
                        let shown = ext.isEmpty ? "" : "." + ext
                        report(entry.value.textRange ?? entry.keyRange,
                               "Cannot determine file format from extension '\(shown)'. Supported formats: .json, .yaml, .yml, .toml, .xml. Use 'format' parameter to specify explicitly.")
                    }
                }
            default:
                break
            }
        }

        mutating func checkPython(_ outline: YAMLOutline, nameRange: NSRange) {
            let run = outline.entry("run")
            let define = outline.entry("define")
            if let run, define != nil {
                report(run.keyRange, "PYTHON placeholder has both 'run' and 'define' — a placeholder is either content-generating or a variable source, not both")
            } else if run == nil && define == nil {
                report(nameRange, "PYTHON placeholder requires 'run' or 'define'")
            }
            if let transform = outline.entry("transform") {
                report(transform.keyRange, "PYTHON placeholder does not support 'transform' — do the post-processing inside the run() function instead")
            }
            if run != nil, let audit = outline.entry("audit") {
                report(audit.keyRange, "PYTHON placeholder in run: mode does not support 'audit' — 'audit' belongs to variable-source placeholders")
            }
        }

        mutating func checkAI(_ outline: YAMLOutline, nameRange: NSRange) {
            if let entry = outline.entry("name"), let name = entry.value.scalarText, let range = entry.value.range {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && trimmed.allSatisfy(\.isNumber) {
                    report(range, "AI placeholder 'name' must not be a pure decimal integer (got '\(trimmed)') — integers are reserved for line-number addressing")
                }
                // Like mdship, name the line of the other placeholder's opening comment.
                if let previous = aiNames[trimmed] {
                    report(range, "AI placeholder name '\(trimmed)' duplicates the one at line \(previous + 1)")
                } else {
                    aiNames[trimmed] = lines.line(containing: nameRange.location)
                }
            }
            if outline.entry("prompt") == nil {
                report(nameRange, "AI placeholder has no 'prompt': there is nothing to generate from", .warning)
            }
        }

        mutating func defineVariable(_ entry: YAMLOutline.Entry) {
            if let previous = definedVariables[entry.key] {
                report(entry.keyRange, "Variable '\(entry.key)' is already defined (line \(previous + 1))")
            } else {
                definedVariables[entry.key] = entry.line
            }
        }

        // MARK: Values

        mutating func check(_ entry: YAMLOutline.Entry, against parameter: PlaceholderSchema.Parameter,
                            in placeholder: Placeholder, outline: YAMLOutline?) {
            let value = entry.value
            let valueRange = value.range ?? entry.keyRange
            let key = entry.key

            func needsSingleValue() -> Bool {
                switch value {
                case .scalar: return true
                case .null:
                    report(entry.keyRange, "'\(key)' has no value")
                    return false
                default:
                    report(entry.keyRange, "'\(key)' should be a single value, not \(value.shapeName)")
                    return false
                }
            }

            switch parameter.type {
            case .any:
                break

            case .string:
                if case .mapping = value { report(entry.keyRange, "'\(key)' should be a single value, not a mapping") }
                if case .sequence = value { report(entry.keyRange, "'\(key)' should be a single value, not a list") }
                if key == "_terminate_", let name = value.scalarText,
                   name.range(of: #"^\w+$"#, options: .regularExpression) == nil {
                    report(valueRange, "_terminate_ must be a single word, as in <!--/\(name)-->")
                }

            case .integer(let bounds):
                guard needsSingleValue(), let text = value.scalarText else { return }
                guard let number = Int(text.trimmingCharacters(in: .whitespaces)) else {
                    report(valueRange, "'\(key)' must be a whole number, not '\(text)'")
                    return
                }
                if let bounds, !bounds.contains(number) {
                    report(valueRange, "'\(key)' must be between \(bounds.lowerBound) and \(bounds.upperBound)")
                }

            case .boolean:
                guard needsSingleValue(), case .scalar(let text, _, let quoted) = value else { return }
                let literals: Set<String> = ["true", "false", "yes", "no", "on", "off"]
                if quoted || !literals.contains(text.lowercased()) {
                    report(valueRange, "'\(key)' must be true or false")
                }

            case .choice(let choices):
                guard needsSingleValue(), let text = value.scalarText else { return }
                if !choices.contains(text.lowercased()) {
                    report(valueRange, "'\(key)' must be one of \(choices.joined(separator: ", ")), not '\(text)'")
                }

            case .regex(let groups):
                guard needsSingleValue(), let pattern = value.scalarText else { return }
                checkRegex(pattern, groups: groups, range: valueRange, key: key)

            case .lineRange:
                guard needsSingleValue(), let text = value.scalarText else { return }
                guard let (first, last) = PlaceholderValidator.lineRange(text) else {
                    report(valueRange, "Invalid range format: \(text), expected 'x..y'")
                    return
                }
                if first < 1 || last < first {
                    report(valueRange, "Invalid range: \(text)")
                } else if let from = outline?.entry("from")?.value.scalarText ?? outline?.entry("path")?.value.scalarText,
                          let url = PlaceholderValidator.resolve(from, against: directory),
                          fileSystem.kind(url) == .file, let count = fileSystem.lineCount(url), last > count {
                    report(valueRange, "Invalid range: \(text) end beyond file end (the file has \(count) lines)")
                }

            case .inputFile, .inputFileOrDirectory, .outputFile:
                guard needsSingleValue(), let path = value.scalarText else { return }
                checkPath(path, range: value.textRange ?? valueRange, type: parameter.type, outline: outline)

            case .scripts:
                switch value {
                case .scalar(let name, _, _):
                    checkScript(name, range: value.textRange ?? valueRange)
                case .sequence(let items):
                    for item in items {
                        if case .scalar(let name, _, _) = item.value, let range = item.value.textRange {
                            checkScript(name, range: range)
                        } else {
                            report(item.dashRange, "'\(key)' contains an invalid script name")
                        }
                    }
                default:
                    report(entry.keyRange, "'\(key)' must be a script name or a list of script names")
                }

            case .text:
                if case .mapping = value { report(entry.keyRange, "'\(key)' should be text, not a mapping") }
                if case .sequence = value { report(entry.keyRange, "'\(key)' should be text, not a list") }

            case .boundary:
                switch value {
                case .scalar(let pattern, let range, _):
                    checkRegex(pattern, groups: nil, range: range, key: key)
                case .mapping(let entries):
                    checkNested(entries, parameters: PlaceholderSchema.boundary, context: "'\(key)'", keyRange: entry.keyRange,
                                placeholder: placeholder)
                default:
                    report(entry.keyRange, "'\(key)' must be a string or a structure with 'pattern' and optional 'include'")
                }

            case .mapping:
                switch value {
                case .mapping(let entries):
                    // SIP vars and SET patterns: every value is a one-group regex.
                    if (placeholder.kind == .sip && key == "vars") || (placeholder.kind == .set && key == "pattern") {
                        for child in entries {
                            if let pattern = child.value.scalarText, let range = child.value.range {
                                checkRegex(pattern, groups: 1, range: range, key: child.key)
                            }
                        }
                    }
                case .flow:
                    break
                default:
                    report(entry.keyRange, placeholder.kind == .sip
                           ? "SIP 'vars' must be a dict with variable names as keys"
                           : "'\(key)' must be a mapping of names to values")
                }

            case .list:
                switch value {
                case .sequence(let items):
                    if placeholder.kind == .slurp && key == "rules" {
                        for item in items {
                            if let pattern = item.value.scalarText, let range = item.value.range {
                                checkRegex(pattern, groups: 2, range: range, key: "rule")
                            }
                        }
                    }
                case .flow:
                    break
                default:
                    report(entry.keyRange, placeholder.kind == .slurp
                           ? "SLURP 'rules' must be a list of regex patterns"
                           : "'\(key)' must be a list")
                }

            case .dependencies:
                switch value {
                case .sequence(let items):
                    for item in items {
                        guard case .mapping(let entries) = item.value else {
                            report(item.dashRange, "Each 'deps' entry must be a mapping with a 'path'")
                            continue
                        }
                        checkNested(entries, parameters: PlaceholderSchema.dependency, context: "dep", keyRange: item.dashRange,
                                    placeholder: placeholder)
                        let keys = Set(entries.map(\.key))
                        let binary = entries.first { $0.key == "binary" }?.value.scalarText?.lowercased() == "true"
                        if binary, let bad = ["range", "start", "end"].first(where: keys.contains),
                           let badEntry = entries.first(where: { $0.key == bad }) {
                            report(badEntry.keyRange, "'binary: true' is incompatible with '\(bad)'")
                        }
                        if keys.contains("range") && (keys.contains("start") || keys.contains("end")),
                           let rangeEntry = entries.first(where: { $0.key == "range" }) {
                            report(rangeEntry.keyRange, "'range' and 'start'/'end' are mutually exclusive")
                        }
                    }
                case .null:
                    break
                default:
                    report(entry.keyRange, "AI placeholder 'deps' must be a list")
                }
            }
        }

        mutating func checkNested(_ entries: [YAMLOutline.Entry], parameters: [PlaceholderSchema.Parameter],
                                  context: String, keyRange: NSRange, placeholder: Placeholder) {
            let local = YAMLOutline.fromEntries(entries)
            for child in entries {
                guard let parameter = parameters.first(where: { $0.name == child.key }) else {
                    report(child.keyRange, unknownKeyMessage(child.key, kind: context, known: parameters), .warning)
                    continue
                }
                check(child, against: parameter, in: placeholder, outline: local)
            }
            for parameter in parameters where parameter.required && !entries.contains(where: { $0.key == parameter.name }) {
                report(keyRange, "\(context) must have a '\(parameter.name)' key")
            }
        }

        mutating func checkPath(_ path: String, range: NSRange, type: PlaceholderSchema.ValueType, outline: YAMLOutline?) {
            guard !path.trimmingCharacters(in: .whitespaces).isEmpty else {
                report(range, "The path is empty")
                return
            }
            guard let url = PlaceholderValidator.resolve(path, against: directory) else { return }
            let kind = fileSystem.kind(url)

            // Where the included part begins, in mdship's order of precedence:
            // range, then start, then section.
            var target: NavigationTarget?
            if let rangeText = outline?.entry("range")?.value.scalarText, let (first, _) = PlaceholderValidator.lineRange(rangeText) {
                target = .line(max(0, first - 1))
            } else if let start = outline?.entry("start") {
                switch start.value {
                case .scalar(let pattern, _, _):
                    target = .pattern(pattern, includesMatch: false)
                case .mapping(let entries):
                    if let pattern = entries.first(where: { $0.key == "pattern" })?.value.scalarText {
                        let include = entries.first(where: { $0.key == "include" })?.value.scalarText?.lowercased()
                        target = .pattern(pattern, includesMatch: ["true", "yes", "on"].contains(include ?? ""))
                    }
                default:
                    break
                }
            } else if let section = outline?.entry("section")?.value.scalarText {
                target = .heading(section)
            }

            switch (type, kind) {
            case (.outputFile, _):
                if kind != .missing { result.references.append(FileReference(range: range, url: url, target: nil)) }
            case (_, .missing):
                report(range, "File not found: \(path)")
            case (.inputFile, .directory):
                report(range, "Path is not a file: \(path)")
                result.references.append(FileReference(range: range, url: url, target: nil))
            default:
                result.references.append(FileReference(range: range, url: url, target: target))
            }
        }

        mutating func checkScript(_ name: String, range: NSRange) {
            guard let directory else { return }
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                report(range, "Empty script name")
                return
            }
            guard let root = PlaceholderValidator.projectRoot(from: directory, fileSystem: fileSystem) else {
                report(range, "Script '\(name)' needs a .mdship directory above \(directory.path). Run 'mdship scripts init' in the project root.")
                return
            }
            let scripts = root.appendingPathComponent(".mdship/scripts", isDirectory: true)
            let url = scripts.appendingPathComponent(name).standardizedFileURL
            guard url.path.hasPrefix(scripts.standardizedFileURL.path + "/") else {
                report(range, "Script '\(name)' resolves outside \(scripts.path)")
                return
            }
            if fileSystem.kind(url) == .file {
                result.references.append(FileReference(range: range, url: url, target: nil))
            } else {
                report(range, "Script not found: .mdship/scripts/\(name)")
            }
        }

        mutating func checkRegex(_ pattern: String, groups: Int?, range: NSRange, key: String) {
            if pattern.hasPrefix("@") {
                let name = String(pattern.dropFirst())
                if !PlaceholderValidator.builtInPatterns.contains(name) && !customPatterns.contains(name) {
                    let available = (PlaceholderValidator.builtInPatterns.union(customPatterns)).sorted().map { "@\($0)" }
                    report(range, "Pattern '\(name)' not found. Available patterns: \(available.joined(separator: ", "))")
                }
                return
            }
            guard let regex = PlaceholderValidator.regex(pattern) else {
                report(range, "'\(key)' is not a valid regular expression")
                return
            }
            guard let groups else { return }
            let found = regex.numberOfCaptureGroups
            // SLURP also takes named groups `var` and `val`, in either order.
            if groups == 2 && pattern.contains("(?P<var>") && pattern.contains("(?P<val>") { return }
            if found != groups {
                let noun = groups == 1 ? "capturing group" : "capturing groups"
                report(range, "'\(key)' needs exactly \(groups) \(noun), this one has \(found)")
            }
        }

        func unknownKeyMessage(_ key: String, kind: String, known: [PlaceholderSchema.Parameter]) -> String {
            let names = known.filter { !$0.managed }.map(\.name)
            if let suggestion = PlaceholderValidator.closest(to: key, in: names) {
                return "Unknown \(kind) parameter '\(key)': mdship ignores it. Did you mean '\(suggestion)'?"
            }
            return "Unknown \(kind) parameter '\(key)': mdship ignores it. Known: \(names.joined(separator: ", "))"
        }
    }

    // MARK: - Helpers

    static func lineRange(_ text: String) -> (Int, Int)? {
        let parts = text.components(separatedBy: "..")
        guard parts.count == 2,
              let first = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let last = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        return (first, last)
    }

    /// Compiles a Python regex with ICU, translating the Python-only spellings
    /// of named groups first.
    static func regex(_ pattern: String) -> NSRegularExpression? {
        let translated = pattern
            .replacingOccurrences(of: "(?P<", with: "(?<")
            .replacingOccurrences(of: #"\(\?P=(\w+)\)"#, with: #"\\k<$1>"#, options: .regularExpression)
        return try? NSRegularExpression(pattern: translated)
    }

    /// The candidate within two edits of `word`, if one is.
    static func closest(to word: String, in candidates: [String]) -> String? {
        let scored = candidates.map { ($0, distance(word.lowercased(), $0.lowercased())) }
            .filter { $0.1 <= max(1, min(2, word.count / 3)) }
            .sorted { $0.1 < $1.1 }
        return scored.first?.0
    }

    /// Edit distance where swapping two neighbouring letters is one edit, the
    /// most common typo: `form` for `from`.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[a.count][b.count]
    }
}

extension YAMLOutline {
    /// An outline holding just `entries`, to look keys up among siblings.
    static func fromEntries(_ entries: [Entry]) -> YAMLOutline {
        var outline = YAMLOutline("", offset: 0, line: 0)
        outline.entries = entries
        return outline
    }
}
