import XCTest
@testable import Tychedit

/// The YAML outline, the schema checks, and file resolution.
final class PlaceholderValidatorTests: XCTestCase {

    private var root: URL!
    private var document: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TycheditValidator-\(UUID().uuidString)").resolvingSymlinksInPath()
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("docs/sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(".mdship/scripts"), withIntermediateDirectories: true)
        try "one\ntwo\nthree\n".write(to: root.appendingPathComponent("docs/code.py"), atomically: true, encoding: .utf8)
        try "{}".write(to: root.appendingPathComponent("docs/settings.json"), atomically: true, encoding: .utf8)
        try "def run(c, ctx): return c".write(to: root.appendingPathComponent(".mdship/scripts/gen.py"), atomically: true, encoding: .utf8)
        document = root.appendingPathComponent("docs/doc.md")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func validate(_ text: String) -> PlaceholderValidator.Result {
        PlaceholderValidator.validate(text: text, scan: PlaceholderScanner.scan(text), documentURL: document)
    }

    private func messages(_ text: String) -> [String] {
        validate(text).issues.map(\.message)
    }

    // MARK: YAML outline

    func testOutlineReadsKeysValuesAndPositions() {
        let config = " min-level: 2\nname: \"x y\" # note\ncontent: |\n  a\n  b\nstart:\n  pattern: 'x'\n  include: true\nrules:\n  - '(a)=(b)'\n"
        let outline = YAMLOutline(config, offset: 100, line: 5)
        XCTAssertEqual(outline.entries.map(\.key), ["min-level", "name", "content", "start", "rules"])
        XCTAssertEqual(outline.entry("min-level")?.value.scalarText, "2")
        XCTAssertEqual(outline.entry("min-level")?.keyRange.location, 101)
        XCTAssertEqual(outline.entry("name")?.value.scalarText, "x y")
        XCTAssertEqual(outline.entry("name")?.line, 6)
        guard case .block = outline.entry("content")?.value else { return XCTFail("block") }
        guard case .mapping(let start)? = outline.entry("start")?.value else { return XCTFail("mapping") }
        XCTAssertEqual(start.map(\.key), ["pattern", "include"])
        guard case .sequence(let rules)? = outline.entry("rules")?.value else { return XCTFail("sequence") }
        XCTAssertEqual(rules.first?.value.scalarText, "(a)=(b)")
        XCTAssertTrue(outline.problems.isEmpty, "\(outline.problems)")
    }

    func testOutlineSequenceOfMappings() {
        let outline = YAMLOutline("\ndeps:\n  - path: a.py\n    range: \"1..2\"\n  - path: b.py\n", offset: 0, line: 0)
        guard case .sequence(let items)? = outline.entry("deps")?.value else { return XCTFail("sequence") }
        XCTAssertEqual(items.count, 2)
        guard case .mapping(let first) = items[0].value else { return XCTFail("mapping") }
        XCTAssertEqual(first.map(\.key), ["path", "range"])
    }

    func testOutlineReportsDuplicatesAndGarbage() {
        let outline = YAMLOutline("\nfrom: a\nfrom: b\nnot yaml\n", offset: 0, line: 0)
        XCTAssertEqual(outline.problems.count, 2)
    }

    // MARK: Schema

    func testMisspelledKeyGetsSuggestion() {
        let result = messages("<!--INCLUDE\nfrom: \"code.py\"\nprefx: \"```\"\n-->\n<!--/INCLUDE-->\n")
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].contains("Unknown INCLUDE parameter 'prefx'"))
        XCTAssertTrue(result[0].contains("Did you mean 'prefix'?"))
    }

    func testSwappedLettersGetSuggestion() {
        let result = messages("<!--IMPORT\nname: cfg\nform: settings.json\n-->\n")
        XCTAssertTrue(result.contains { $0.contains("Unknown IMPORT parameter 'form': mdship ignores it. Did you mean 'from'?") }, "\(result)")
    }

    func testMissingRequiredParameter() {
        let result = validate("<!--INCLUDE\nprefix: x\n-->\n<!--/INCLUDE-->\n")
        XCTAssertTrue(result.issues.contains { $0.message.contains("INCLUDE placeholder requires 'from' parameter") })
        // Underlines the placeholder name.
        XCTAssertEqual(result.issues.first?.range, NSRange(location: 0, length: 11))
    }

    func testMissingFileAndDirectory() {
        let result = messages("""
            <!--INCLUDE
            from: "nope.py"
            -->
            <!--/INCLUDE-->
            <!--IMPORT
            name: cfg
            from: "sub"
            -->
            """)
        XCTAssertTrue(result.contains { $0.contains("File not found: nope.py") }, "\(result)")
        XCTAssertTrue(result.contains { $0.contains("Path is not a file: sub") }, "\(result)")
    }

    func testExistingFileBecomesReferenceWithTarget() {
        let text = "<!--INCLUDE\nfrom: \"code.py\"\nrange: \"2..3\"\n-->\n<!--/INCLUDE-->\n"
        let result = validate(text)
        XCTAssertTrue(result.issues.isEmpty, "\(result.issues)")
        XCTAssertEqual(result.references.count, 1)
        XCTAssertEqual(result.references[0].url.path, root.appendingPathComponent("docs/code.py").path)
        XCTAssertEqual(result.references[0].target, .line(1))
        XCTAssertEqual((text as NSString).substring(with: result.references[0].range), "code.py")
    }

    func testStartBecomesPatternTarget() {
        let plain = validate("<!--INCLUDE\nfrom: code.py\nstart: \"two\"\n-->\n<!--/INCLUDE-->\n")
        XCTAssertEqual(plain.references.first?.target, .pattern("two", includesMatch: false))
        let structured = validate("<!--INCLUDE\nfrom: code.py\nstart:\n  pattern: 'tw.'\n  include: true\n-->\n<!--/INCLUDE-->\n")
        XCTAssertEqual(structured.references.first?.target, .pattern("tw.", includesMatch: true))
    }

    func testRangeBeyondFileEnd() {
        let result = messages("<!--INCLUDE\nfrom: code.py\nrange: \"2..9\"\n-->\n<!--/INCLUDE-->\n")
        XCTAssertTrue(result.contains { $0.contains("end beyond file end (the file has 3 lines)") }, "\(result)")
    }

    func testTypesAndChoices() {
        let result = messages("""
            <!--TOC min-level: two
            max-level: 9
            -->
            <!--/TOC-->
            <!--SLURP
            from: code.py
            rules: '(a)'
            strategy: random
            recurse: "yes"
            -->
            """)
        XCTAssertTrue(result.contains { $0.contains("'min-level' must be a whole number") }, "\(result)")
        XCTAssertTrue(result.contains { $0.contains("'max-level' must be between 1 and 6") }, "\(result)")
        XCTAssertTrue(result.contains { $0.contains("SLURP 'rules' must be a list") }, "\(result)")
        XCTAssertTrue(result.contains { $0.contains("'strategy' must be one of fail, first, last, concatenate") }, "\(result)")
        XCTAssertTrue(result.contains { $0.contains("'recurse' must be true or false") }, "\(result)")
    }

    func testRegexGroupCounts() {
        let result = messages("""
            <!--SUP
            name: title
            pattern: '^#+\\s+.*$'
            -->
            <!--SIP
            from: code.py
            vars:
              version: 'v(\\d+)\\.(\\d+)'
            -->
            <!--SLURP
            from: code.py
            rules:
              - '(?P<var>\\w+)=(?P<val>.+)'
              - '(\\w+)=(.+'
            -->
            """)
        XCTAssertTrue(result.contains { $0.contains("'pattern' needs exactly 1 capturing group, this one has 0") }, "\(result)")
        XCTAssertTrue(result.contains { $0.contains("'version' needs exactly 1 capturing group, this one has 2") }, "\(result)")
        XCTAssertTrue(result.contains { $0.contains("'rule' is not a valid regular expression") }, "\(result)")
        XCTAssertEqual(result.filter { $0.contains("rule") }.count, 1, "named var/val groups are fine")
    }

    func testPatternReferences() {
        let result = messages("""
            <!--SET
            pattern:
              build: 'build-(\\d+)'
            -->
            <!--SUP
            name: a
            pattern: "@build"
            -->
            <!--SUP
            name: b
            pattern: "@nosuch"
            -->
            """)
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].contains("Pattern 'nosuch' not found"))
    }

    func testExclusiveIncludeSelections() {
        let result = messages("<!--INCLUDE\nfrom: code.py\nrange: \"1..2\"\nsection: Intro\n-->\n<!--/INCLUDE-->\n")
        XCTAssertTrue(result.contains { $0.contains("'section' cannot be combined with 'range'") }, "\(result)")
    }

    func testPythonRules() {
        XCTAssertTrue(messages("<!--PYTHON\nsource: x\n-->\n<!--/PYTHON-->\n").contains { $0.contains("requires 'run' or 'define'") })
        let both = messages("<!--PYTHON\nrun: gen.py\ndefine: gen.py\ntransform: gen.py\n-->\n<!--/PYTHON-->\n")
        XCTAssertTrue(both.contains { $0.contains("has both 'run' and 'define'") })
        XCTAssertTrue(both.contains { $0.contains("does not support 'transform'") })
        // Extra keys are the script's own arguments.
        XCTAssertTrue(messages("<!--PYTHON\nrun: gen.py\nsource: data.csv\n-->\n<!--/PYTHON-->\n").isEmpty)
    }

    func testScriptsResolveUnderMdshipScripts() {
        XCTAssertTrue(messages("<!--TOC\ntransform: gen.py\n-->\n<!--/TOC-->\n").isEmpty)
        XCTAssertTrue(messages("<!--TOC\ntransform:\n  - gen.py\n  - missing.py\n-->\n<!--/TOC-->\n")
            .contains { $0.contains("Script not found: .mdship/scripts/missing.py") })
        XCTAssertTrue(messages("<!--TOC\ntransform: ../../etc/passwd\n-->\n<!--/TOC-->\n")
            .contains { $0.contains("resolves outside") })
    }

    func testSetVariablesDefinedTwice() {
        let result = messages("<!--SET\na: 1\n-->\n<!--SET\na: 2\n-->\n")
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].contains("Variable 'a' is already defined"))
    }

    func testAIPlaceholderRules() {
        let result = messages("""
            <!--AI
            name: "12"
            prompt: x
            deps:
              - path: code.py
                binary: true
                range: "1..2"
              - range: "1..2"
            -->
            <!--/AI-->
            <!--AI
            name: "12"
            -->
            <!--/AI-->
            """)
        XCTAssertTrue(result.contains { $0.contains("must not be a pure decimal integer") }, "\(result)")
        XCTAssertTrue(result.contains { $0.contains("'binary: true' is incompatible with 'range'") }, "\(result)")
        XCTAssertTrue(result.contains { $0.contains("dep must have a 'path' key") }, "\(result)")
        XCTAssertTrue(result.contains { $0.contains("duplicates the one at line 1") }, "\(result)")
        XCTAssertTrue(result.contains { $0.contains("has no 'prompt'") }, "\(result)")
    }

    func testMermaidOutputFileNeedNotExistButMustBeAnImage() {
        XCTAssertTrue(messages("<!--MERMAID\nfile: \"out/d.svg\"\ndiagram: |\n  flowchart LR\n-->\n\n").isEmpty)
        XCTAssertTrue(messages("<!--MERMAID\nfile: \"d.gif\"\ndiagram: x\n-->\n\n").contains { $0.contains("Must be .svg or .png") })
    }

    func testUntitledDocumentSkipsRelativeFileChecks() {
        let text = "<!--INCLUDE\nfrom: nope.py\n-->\n<!--/INCLUDE-->\n"
        let result = PlaceholderValidator.validate(text: text, scan: PlaceholderScanner.scan(text), documentURL: nil)
        XCTAssertTrue(result.issues.isEmpty)
    }

    // MARK: Completion

    private func complete(_ textWithCaret: String, explicit: Bool = false) -> CompletionList? {
        let caret = (textWithCaret as NSString).range(of: "|").location
        let text = textWithCaret.replacingOccurrences(of: "|", with: "")
        return CompletionProvider.completions(in: text, at: caret, documentURL: document, explicit: explicit)
    }

    func testCompletesTopLevelKeysNotYetPresent() throws {
        let list = try XCTUnwrap(complete("<!--INCLUDE\nfrom: code.py\npr|\n-->\n<!--/INCLUDE-->"))
        XCTAssertEqual(list.items.map(\.label), ["prefix"])
        XCTAssertEqual(list.range.length, 2)
        let all = try XCTUnwrap(complete("<!--INCLUDE\nfrom: code.py\n|\n-->", explicit: true))
        XCTAssertFalse(all.items.contains { $0.label == "from" })
        XCTAssertFalse(all.items.contains { $0.label == "_content_generated_" })
        XCTAssertNil(complete("<!--INCLUDE\nfrom: code.py\n|\n-->"), "no popup on an empty line unless asked")
    }

    func testCompletesWhileCommentIsStillOpen() throws {
        let list = try XCTUnwrap(complete("text\n<!--AI\nna|"))
        XCTAssertEqual(list.items.first?.label, "name")
    }

    func testCompletesOnTheOpeningLine() throws {
        let list = try XCTUnwrap(complete("<!--TOC mi|"))
        // Prefix matches come before names that merely contain the text (_terminate_).
        XCTAssertEqual(list.items.first?.label, "min-level")
    }

    func testNothingOutsidePlaceholders() {
        XCTAssertNil(complete("<!--INCLUDE\nfrom: x\n-->\npr|"))
        XCTAssertNil(complete("<!-- comment\npr|"))
    }

    func testCompletesNestedKeys() throws {
        let dep = try XCTUnwrap(complete("<!--AI\ndeps:\n  - path: code.py\n    ra|\n-->"))
        XCTAssertEqual(dep.items.map(\.label), ["range"])
        let item = try XCTUnwrap(complete("<!--AI\ndeps:\n  - pa|\n-->"))
        XCTAssertEqual(item.items.map(\.label), ["path"])
        let boundary = try XCTUnwrap(complete("<!--INCLUDE\nfrom: x\nstart:\n  inc|\n-->"))
        XCTAssertEqual(boundary.items.map(\.label), ["include"])
    }

    func testCompletesChoices() throws {
        let list = try XCTUnwrap(complete("<!--SLURP\nstrategy: f|\n-->"))
        XCTAssertEqual(list.items.map(\.label), ["fail", "first"])
        let theme = try XCTUnwrap(complete("<!--MERMAID\ntheme: |\n-->"))
        XCTAssertEqual(theme.items.count, 4)
    }

    func testCompletesFilesAndFolders() throws {
        let list = try XCTUnwrap(complete("<!--INCLUDE\nfrom: \"|\n-->"))
        XCTAssertEqual(list.items.map(\.label), ["sub/", "code.py", "doc.md", "settings.json"].filter { $0 != "doc.md" })
        XCTAssertEqual(list.items[1].insertion, "code.py\"")
        XCTAssertEqual(list.items[0].insertion, "sub/\u{1}\u{2}")
        XCTAssertTrue(list.items[0].continues)

        let unquoted = try XCTUnwrap(complete("<!--INCLUDE\nfrom: se|\n-->"))
        XCTAssertEqual(unquoted.items.map(\.insertion), ["\"settings.json\""])
    }

    func testCompletesScripts() throws {
        let list = try XCTUnwrap(complete("<!--PYTHON\nrun: |\n-->"))
        XCTAssertEqual(list.items.map(\.label), ["gen.py"])
    }

    // MARK: References

    private func reference(_ textWithCaret: String) -> Reference? {
        let caret = (textWithCaret as NSString).range(of: "|").location
        let text = textWithCaret.replacingOccurrences(of: "|", with: "")
        let scan = PlaceholderScanner.scan(text)
        let validation = PlaceholderValidator.validate(text: text, scan: scan, documentURL: document)
        return ReferenceFinder.reference(in: text, at: caret, documentURL: document, scan: scan,
                                         fileReferences: validation.references,
                                         definitions: MarkdownRenderer.linkDefinitions(in: text))
    }

    func testFollowsLinks() {
        let docs = root.appendingPathComponent("docs")
        XCTAssertEqual(reference("See [the |code](code.py) here"), .file(docs.appendingPathComponent("code.py"), nil))
        XCTAssertEqual(reference("[x](other.md#setup|)"), .file(docs.appendingPathComponent("other.md"), .anchor("setup")))
        XCTAssertEqual(reference("[x](#intro|)"), .anchor("intro"))
        XCTAssertEqual(reference("go to https://example.com/a|b now"), .web(URL(string: "https://example.com/ab")!))
        XCTAssertEqual(reference("[docs][d|]\n\n[d]: sub/readme.md"), .file(docs.appendingPathComponent("sub/readme.md"), nil))
        XCTAssertEqual(reference("<img src=\"pic|.png\">"), .file(docs.appendingPathComponent("pic.png"), nil))
        XCTAssertNil(reference("plain | text"))
    }

    func testFollowsPlaceholderPaths() {
        let result = reference("<!--INCLUDE\nfrom: \"co|de.py\"\nsection: Usage\n-->\n<!--/INCLUDE-->")
        XCTAssertEqual(result, .file(root.appendingPathComponent("docs/code.py"), .heading("Usage")))
    }

    func testVariableReferenceLeadsToDefinition() {
        // "appName" starts right after "<!--SET\n".
        XCTAssertEqual(reference("<!--SET\nappName: x\n-->\nA <!--$app|Name-->x"), .location(8))

        let imported = "<!--IMPORT\nname: cfg\nfrom: settings.json\n-->\nB <!--$cfg.db.h|ost-->y"
        let expected = (imported as NSString).range(of: "cfg\nfrom").location
        XCTAssertEqual(reference(imported), .location(expected))

        // The value is text, not a way to the definition.
        XCTAssertNil(reference("<!--SET\nappName: x\n-->\nA <!--$appName-->x|y"))
    }
}

final class ImportAndSetTests: XCTestCase {

    private func messages(_ text: String) -> [String] {
        PlaceholderValidator.validate(text: text, scan: PlaceholderScanner.scan(text), documentURL: nil).issues.map(\.message)
    }

    func testImportNeedsAFormatForUnknownExtensions() {
        XCTAssertTrue(messages("<!--IMPORT\nname: cfg\nfrom: \"notes.md\"\n-->\n")
            .contains { $0.contains("Cannot determine file format from extension '.md'") })
        XCTAssertFalse(messages("<!--IMPORT\nname: cfg\nfrom: \"notes.md\"\nformat: yaml\n-->\n")
            .contains { $0.contains("Cannot determine file format") })
        XCTAssertFalse(messages("<!--IMPORT\nname: cfg\nfrom: \"settings.YML\"\n-->\n")
            .contains { $0.contains("Cannot determine file format") })
    }

    private func labels(_ textWithCaret: String, explicit: Bool = true) -> [String] {
        let caret = (textWithCaret as NSString).range(of: "|").location
        let text = textWithCaret.replacingOccurrences(of: "|", with: "")
        return CompletionProvider.completions(in: text, at: caret, documentURL: nil, explicit: explicit)?.items.map(\.label) ?? []
    }

    func testSetOffersItsReservedKeysAndSaysAnyNameWorks() {
        XCTAssertEqual(labels("<!--SET\n|\n-->"), ["pattern", "audit", "any-name: value"])
        XCTAssertEqual(labels("<!--SET\npattern:\n|\n-->"), ["audit", "any-name: value"])
    }

    /// The reported sequence: pattern written, its line deleted, Control-Space.
    func testDeletedKeyIsOfferedAgain() {
        XCTAssertEqual(labels("<!--SET\n|\n\n-->"), ["pattern", "audit", "any-name: value"])
        XCTAssertEqual(labels("<!--SET\n\n|\n-->"), ["pattern", "audit", "any-name: value"])
    }

    /// While the comment is not closed yet, keys of a placeholder further down
    /// must not count as present.
    func testLaterPlaceholdersDoNotCount() {
        XCTAssertEqual(labels("<!--SET\n|\n\nText.\n\n<!--SET\npattern:\n  x: 'a(b)'\n-->\n"),
                       ["pattern", "audit", "any-name: value"])
    }
}
