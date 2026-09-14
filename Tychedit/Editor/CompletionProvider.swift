import Foundation

/// One suggestion.
struct CompletionItem: Sendable, Equatable, Identifiable {
    enum Kind: Sendable, Equatable { case key, value, file, directory }

    let label: String
    let detail: String
    /// Inserted in place of the typed part; `\u{1}` and `\u{2}` delimit what is
    /// selected afterwards, or mark the caret when they are adjacent.
    let insertion: String
    let kind: Kind
    let required: Bool
    /// Ask again after inserting: a directory to descend into, or a key whose
    /// value has known choices.
    let continues: Bool

    var id: String { "\(kind)-\(label)" }
}

struct CompletionList: Sendable, Equatable {
    let items: [CompletionItem]
    /// The typed text the chosen item replaces.
    let range: NSRange
}

/// Lists a directory -- replaceable for tests.
struct DirectoryLister: Sendable {
    var list: @Sendable (URL) -> [(name: String, isDirectory: Bool)]

    static let live = DirectoryLister { url in
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: []) else { return [] }
        return contents.map { item in
            (item.lastPathComponent, (try? item.resourceValues(forKeys: Set(keys)).isDirectory) ?? false)
        }
    }
}

/// Suggests YAML keys and values while the caret is inside a placeholder's
/// opening comment.
///
/// Works on the text as it is now, not on the last background scan, because
/// suggestions have to follow every keystroke -- including the ones that
/// leave the comment unfinished, which is the normal state while typing it.
enum CompletionProvider {

    static func completions(in text: String, at caret: Int, documentURL: URL?, explicit: Bool,
                            lister: DirectoryLister = .live, probe: FileSystemProbe = .live) -> CompletionList? {
        let ns = text as NSString
        let lines = LineIndex(ns)
        if let opening = openingCompletions(in: ns, lines: lines, caret: caret, explicit: explicit) {
            return opening
        }
        guard let definition = definition(in: ns, lines: lines, caret: caret) else {
            return explicit ? placeholderSnippets(in: ns, lines: lines, caret: caret) : nil
        }
        let caretLine = lines.line(containing: caret)
        let onOpeningLine = caretLine == definition.openLine
        let lineStart = onOpeningLine ? definition.configStart : lines.starts[caretLine]
        var prefix = ns.substring(with: NSRange(location: lineStart, length: caret - lineStart))
        if onOpeningLine {
            prefix = String(prefix.drop { $0 == " " || $0 == "\t" })
        }
        let context = Context(ns: ns, lines: lines, definition: definition, caretLine: caretLine, caret: caret,
                              directory: documentURL?.deletingLastPathComponent(), explicit: explicit,
                              lister: lister, probe: probe)

        if let match = firstMatch(keyPattern, prefix) {
            return context.keys(indent: match.string(1), dash: match.string(2), partial: match.string(3))
        }
        if let match = firstMatch(valuePattern, prefix) {
            return context.values(indent: match.string(1), dash: match.string(2), key: match.string(3),
                                  quote: match.string(4), partial: match.string(5))
        }
        return nil
    }

    // MARK: - Starting a placeholder

    /// `<!--I` offers the placeholders starting with I; a complete `<!--INCLUDE`
    /// offers to close the comment, with the closing tag when the placeholder has one.
    static func openingCompletions(in ns: NSString, lines: LineIndex, caret: Int, explicit: Bool) -> CompletionList? {
        let line = lines.line(containing: caret)
        let start = lines.starts[line]
        let prefix = ns.substring(with: NSRange(location: start, length: caret - start))
        guard let match = firstMatch(openingPattern, prefix) else { return nil }
        let name = match.string(1)
        let range = NSRange(location: caret - name.utf16.count, length: name.utf16.count)

        // Something else follows on the line: this is an edit of an existing comment.
        let lineEnd = NSMaxRange(lines.contentRange(ofLine: line))
        let rest = ns.substring(with: NSRange(location: caret, length: lineEnd - caret))
        guard rest.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        if let kind = PlaceholderKind(rawValue: name) {
            guard !commentIsClosed(after: caret, in: ns) else { return nil }
            return CompletionList(items: closingItems(for: kind), range: NSRange(location: caret, length: 0))
        }
        guard !name.isEmpty || explicit else { return nil }
        // Names by prefix only: `I` means IMPORT or INCLUDE, not every name with an I in it.
        let kinds = PlaceholderKind.allCases.filter { $0.rawValue.lowercased().hasPrefix(name.lowercased()) }
        let items = kinds.map { kind in
            CompletionItem(label: kind.rawValue,
                           detail: kind.role.prefix(1).uppercased() + kind.role.dropFirst()
                               + (PlaceholderKind.pairedNames.contains(kind.rawValue) ? ", with a closing tag" : ""),
                           insertion: kind.rawValue, kind: .value, required: false, continues: true)
        }
        return items.isEmpty ? nil : CompletionList(items: items, range: range)
    }

    /// A `-->` comes before the next `<!--`: the comment being typed is already
    /// finished, so there is nothing to close.
    static func commentIsClosed(after caret: Int, in ns: NSString) -> Bool {
        let rest = NSRange(location: caret, length: ns.length - caret)
        let close = ns.range(of: "-->", options: [], range: rest)
        guard close.location != NSNotFound else { return false }
        let nextOpen = ns.range(of: "<!--", options: [], range: rest)
        return nextOpen.location == NSNotFound || close.location < nextOpen.location
    }

    /// What finishes `<!--KIND`. The caret lands on the empty line inside the
    /// comment, where the parameters go.
    static func closingItems(for kind: PlaceholderKind) -> [CompletionItem] {
        let name = kind.rawValue
        func item(_ label: String, _ detail: String, _ insertion: String) -> CompletionItem {
            CompletionItem(label: label, detail: detail, insertion: insertion, kind: .value, required: false, continues: true)
        }
        switch kind {
        case .template, .jinja2, .include, .toc, .ai:
            return [item("⏎ --> ⏎ <!--/\(name)-->", "Close the comment and add the closing tag",
                         "\n\u{1}\u{2}\n-->\n<!--/\(name)-->")]
        case .mermaid:
            return [item("⏎ --> ⏎", "Close the comment; the empty line after it is where mdship puts the image",
                         "\n\u{1}\u{2}\n-->\n")]
        case .python:
            return [
                item("run: ⏎ --> ⏎ <!--/PYTHON-->", "Generate content with a script; needs the closing tag",
                     "\nrun: \"\u{1}\u{2}\"\n-->\n<!--/PYTHON-->"),
                item("define: ⏎ -->", "Define variables with a script; no closing tag",
                     "\ndefine: \"\u{1}\u{2}\"\n-->"),
            ]
        case .set, .importFile, .slurp, .sip, .sup:
            return [item("⏎ -->", "Close the comment; \(name) has no closing tag", "\n\u{1}\u{2}\n-->")]
        }
    }

    /// Asked for on an empty line outside any placeholder: every placeholder,
    /// ready to fill in.
    static func placeholderSnippets(in ns: NSString, lines: LineIndex, caret: Int) -> CompletionList? {
        let line = lines.line(containing: caret)
        let content = lines.contentRange(ofLine: line)
        guard ns.substring(with: content).trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let items = (PlaceholderSnippet.variableSources + PlaceholderSnippet.contentManagers).map { snippet in
            let kind = PlaceholderKind(rawValue: String(snippet.title.prefix { $0 != " " }))
            return CompletionItem(label: snippet.title, detail: "Insert a \(kind?.role ?? "placeholder") placeholder",
                                  insertion: snippet.text, kind: .value, required: false, continues: false)
        }
        return CompletionList(items: items, range: content)
    }

    // MARK: - Where the caret is

    struct Definition: Sendable, Equatable {
        let kind: PlaceholderKind
        let openLine: Int
        /// Just after the placeholder's name.
        let configStart: Int
    }

    /// The placeholder opening comment the caret is inside, if any: the nearest
    /// `<!--KIND` above the caret with no `-->` in between.
    static func definition(in ns: NSString, lines: LineIndex, caret: Int) -> Definition? {
        let caretLine = lines.line(containing: caret)
        var line = caretLine
        while line >= max(0, caretLine - 400) {
            let range = lines.contentRange(ofLine: line)
            let full = ns.substring(with: range)
            let considered = line == caretLine
                ? ns.substring(with: NSRange(location: range.location, length: caret - range.location))
                : full
            let indent = full.utf16.prefix { $0 == 32 || $0 == 9 }.count
            let trimmed = String(full.utf16.dropFirst(indent)) ?? full
            if trimmed.hasPrefix("<!--") {
                guard let kind = kindOpened(by: trimmed) else { return nil }
                let nameEnd = range.location + indent + 4 + kind.rawValue.utf16.count
                guard caret >= nameEnd else { return nil }
                let between = ns.substring(with: NSRange(location: nameEnd, length: caret - nameEnd))
                let closed = between.split(separator: "\n", omittingEmptySubsequences: false)
                    .contains { CommentText.hasClosingArrow($0) }
                return closed ? nil : Definition(kind: kind, openLine: line, configStart: nameEnd)
            }
            // A `-->` inside a quoted value does not end the definition for
            // suggestions; the scanner reports it as the error it is for mdship.
            if CommentText.hasClosingArrow(considered) { return nil }
            line -= 1
        }
        return nil
    }

    static func kindOpened(by trimmed: String) -> PlaceholderKind? {
        let afterOpen = trimmed.dropFirst(4)
        let name = afterOpen.prefix { $0.isUppercase || $0.isNumber }
        guard let kind = PlaceholderKind(rawValue: String(name)) else { return nil }
        let rest = afterOpen.dropFirst(name.count)
        if rest.isEmpty || rest.hasPrefix("-->") || rest.first?.isWhitespace == true { return kind }
        return nil
    }

    // MARK: - Suggestions

    private struct Context {
        let ns: NSString
        let lines: LineIndex
        let definition: Definition
        let caretLine: Int
        let caret: Int
        let directory: URL?
        let explicit: Bool
        let lister: DirectoryLister
        let probe: FileSystemProbe

        /// The configuration as typed so far: up to its closing `-->`, or -- while
        /// that is not written yet -- up to the next comment, so the keys of a
        /// placeholder further down do not count as this one's.
        var outline: YAMLOutline {
            let start = definition.configStart
            let rest = NSRange(location: caret, length: ns.length - caret)
            let close = ns.range(of: "-->", options: [], range: rest)
            let nextOpen = ns.range(of: "<!--", options: [], range: rest)
            let end = min(close.location == NSNotFound ? ns.length : close.location,
                          nextOpen.location == NSNotFound ? ns.length : nextOpen.location)
            return YAMLOutline(ns.substring(with: NSRange(location: start, length: end - start)),
                               offset: start, line: definition.openLine)
        }

        func keys(indent: String, dash: String, partial: String) -> CompletionList? {
            if partial.isEmpty && !explicit { return nil }
            let path = parentPath(indent: indent.count, hasDash: !dash.isEmpty)
            var parameters = PlaceholderSchema.parameters(for: definition.kind, at: path).filter { !$0.managed }
            if path.isEmpty {
                let present = Set(outline.entries.map(\.key))
                parameters.removeAll { present.contains($0.name) }
                if definition.kind == .python {
                    if present.contains("run") { parameters.removeAll { $0.name == "define" || $0.name == "audit" } }
                    if present.contains("define") { parameters.removeAll { $0.name == "run" || $0.name == "_yolo_" } }
                }
            }
            let matching = CompletionProvider.filter(parameters, by: partial, name: \.name)
            var items = matching.map { parameter in
                CompletionItem(label: parameter.name,
                               detail: parameter.summary,
                               insertion: parameter.insertion,
                               kind: .key,
                               required: parameter.required,
                               continues: parameter.type.isFile || CompletionProvider.choices(for: parameter) != nil)
            }
            .sorted { $0.required && !$1.required }
            // SET's keys are the variables themselves: say so, rather than
            // suggesting that pattern and audit are all there is.
            if definition.kind == .set, path.isEmpty, explicit || matching.isEmpty {
                items.append(CompletionItem(label: "any-name: value",
                                            detail: "SET takes any variable name; pattern and audit are the only reserved keys",
                                            insertion: "\u{1}name\u{2}: \"value\"", kind: .key, required: false, continues: false))
            }
            guard !items.isEmpty else { return nil }
            return CompletionList(items: items, range: NSRange(location: caret - partial.utf16.count, length: partial.utf16.count))
        }

        func values(indent: String, dash: String, key: String, quote: String, partial: String) -> CompletionList? {
            let path = parentPath(indent: indent.count, hasDash: !dash.isEmpty)
            guard let parameter = PlaceholderSchema.parameters(for: definition.kind, at: path)
                .first(where: { $0.name == key }) else { return nil }
            let range = NSRange(location: caret - partial.utf16.count, length: partial.utf16.count)

            if let choices = CompletionProvider.choices(for: parameter) {
                let items = CompletionProvider.filter(choices, by: partial, name: \.self).map {
                    CompletionItem(label: $0, detail: parameter.summary, insertion: $0, kind: .value,
                                   required: false, continues: false)
                }
                return items.isEmpty ? nil : CompletionList(items: items, range: range)
            }
            guard parameter.type.isFile else { return nil }
            return files(for: parameter, quote: quote, partial: partial, range: range)
        }

        func files(for parameter: PlaceholderSchema.Parameter, quote: String, partial: String, range: NSRange) -> CompletionList? {
            let slash = partial.lastIndex(of: "/")
            let folder = slash.map { String(partial[...$0]) } ?? ""
            let name = slash.map { String(partial[partial.index(after: $0)...]) } ?? partial

            let base: URL
            if parameter.type == .scripts {
                guard let directory, let root = PlaceholderValidator.projectRoot(from: directory, fileSystem: probe) else { return nil }
                base = root.appendingPathComponent(".mdship/scripts", isDirectory: true).appendingPathComponent(folder)
            } else if folder.hasPrefix("/") {
                base = URL(fileURLWithPath: folder, isDirectory: true)
            } else {
                guard let directory else { return nil }
                base = directory.appendingPathComponent(folder, isDirectory: true)
            }

            let next = caret < ns.length ? ns.substring(with: NSRange(location: caret, length: 1)) : ""
            let open = quote.isEmpty ? "\"" : ""
            let close = quote.isEmpty ? "\"" : (next == quote ? "" : quote)

            let entries = lister.list(base)
                .filter { name.hasPrefix(".") || !$0.name.hasPrefix(".") }
                .filter { name.isEmpty || $0.name.lowercased().hasPrefix(name.lowercased()) }
                .sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
                .prefix(300)

            let items = entries.map { entry in
                entry.isDirectory
                    ? CompletionItem(label: entry.name + "/", detail: "folder", insertion: open + folder + entry.name + "/\u{1}\u{2}",
                                     kind: .directory, required: false, continues: true)
                    : CompletionItem(label: entry.name, detail: parameter.summary, insertion: open + folder + entry.name + close,
                                     kind: .file, required: false, continues: false)
            }
            return items.isEmpty ? nil : CompletionList(items: Array(items), range: range)
        }

        /// The chain of keys enclosing the caret's line: `[]` at the top level,
        /// `["deps"]` inside an AI dependency, `["deps", "start"]` below that.
        func parentPath(indent: Int, hasDash: Bool) -> [String] {
            var path: [String] = []
            var current = indent
            var inItem = hasDash
            var line = caretLine - 1
            while line >= definition.openLine {
                var text = ns.substring(with: lines.contentRange(ofLine: line))
                if line == definition.openLine {
                    let offset = definition.configStart - lines.starts[line]
                    text = String((text as NSString).substring(from: offset).drop { $0 == " " || $0 == "\t" })
                }
                line -= 1
                let lineIndent = text.prefix { $0 == " " }.count
                let content = text.dropFirst(lineIndent)
                if content.trimmingCharacters(in: .whitespaces).isEmpty || content.hasPrefix("#") { continue }

                if content.hasPrefix("- ") || content == "-" {
                    guard lineIndent < current || (inItem && lineIndent == current) else { continue }
                    // A sequence item: its mapping's keys continue at the item's column.
                    let rest = content.dropFirst(1).drop { $0 == " " }
                    if let key = CompletionProvider.bareKey(String(rest)), lineIndent + 2 < indent {
                        path.insert(key, at: 0)
                    }
                    current = lineIndent
                    inItem = true
                    continue
                }
                let isBareKey = CompletionProvider.bareKey(String(content))
                if lineIndent < current || (inItem && lineIndent == current) {
                    guard let key = isBareKey else { break }
                    path.insert(key, at: 0)
                    current = lineIndent
                    inItem = false
                    if lineIndent == 0 { break }
                }
            }
            return path
        }
    }

    // MARK: - Helpers

    /// `key:` with no value on the line -- a key that opens a nested block.
    static func bareKey(_ content: String) -> String? {
        guard let match = firstMatch(bareKeyPattern, content) else { return nil }
        return match.string(1)
    }

    static func choices(for parameter: PlaceholderSchema.Parameter) -> [String]? {
        switch parameter.type {
        case .choice(let values): values
        case .boolean: ["true", "false"]
        case .regex where parameter.name == "pattern": ["@heading", "@version"]
        default: nil
        }
    }

    /// Prefix matches first, then other matches, keeping the given order within each.
    static func filter<T>(_ items: [T], by partial: String, name: (T) -> String) -> [T] {
        guard !partial.isEmpty else { return items }
        let lower = partial.lowercased()
        let prefixed = items.filter { name($0).lowercased().hasPrefix(lower) }
        let contained = items.filter { !name($0).lowercased().hasPrefix(lower) && name($0).lowercased().contains(lower) }
        return prefixed + contained
    }

    private static let openingPattern = try! NSRegularExpression(pattern: #"^[ \t]*<!--([A-Za-z0-9]*)$"#)
    private static let keyPattern = try! NSRegularExpression(pattern: #"^( *)(- +)?([A-Za-z0-9_\-]*)$"#)
    private static let valuePattern = try! NSRegularExpression(pattern: #"^( *)(- +)?([A-Za-z0-9_\-]+):[ \t]*(["']?)([^"'#]*)$"#)
    private static let bareKeyPattern = try! NSRegularExpression(pattern: #"^([A-Za-z0-9_\-]+):[ \t]*(#.*)?$"#)

    struct Match {
        let result: NSTextCheckingResult
        let text: NSString
        func string(_ group: Int) -> String {
            let range = result.range(at: group)
            return range.location == NSNotFound ? "" : text.substring(with: range)
        }
    }

    static func firstMatch(_ regex: NSRegularExpression, _ text: String) -> Match? {
        let ns = text as NSString
        guard let result = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Match(result: result, text: ns)
    }
}
