import XCTest
@testable import Tychedit

/// The placeholder scanner has to agree with mdship, or the editor warns about
/// problems that do not exist and misses the ones that do. The fixture file was
/// written by a real `mdship update`, so the integrity tests check the actual
/// checksum format rather than a reading of mdship's source.
final class PlaceholderScannerTests: XCTestCase {

    private func fixture() throws -> String {
        let url = try XCTUnwrap(Bundle(for: PlaceholderScannerTests.self)
            .url(forResource: "mdship-updated", withExtension: "md"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func line(_ scan: PlaceholderScan, _ text: String, issue index: Int = 0) -> Int {
        scan.issues[index].line
    }

    // MARK: Shapes

    func testSelfContainedPlaceholdersOwnOnlyTheirComment() {
        let text = """
            <!--SET
            appName: "MyApp"
            -->
            Text after.
            """
        let scan = PlaceholderScanner.scan(text)
        XCTAssertEqual(scan.placeholders.count, 1)
        let set = scan.placeholders[0]
        XCTAssertEqual(set.kind, .set)
        XCTAssertEqual(set.shape, .selfContained)
        XCTAssertEqual(set.openLines, 0...2)
        XCTAssertNil(set.bodyRange)
        XCTAssertEqual(set.integrity, .none)
        XCTAssertTrue(scan.issues.isEmpty)
    }

    func testPairedPlaceholderFindsItsClosingTagAndBody() {
        let text = """
            Intro
            <!--INCLUDE
            from: "a.txt"
            -->
            included
            <!--/INCLUDE-->
            Outro
            """
        let scan = PlaceholderScanner.scan(text)
        XCTAssertEqual(scan.placeholders.count, 1)
        let include = scan.placeholders[0]
        XCTAssertEqual(include.shape, .paired)
        XCTAssertEqual(include.closeLine, 5)
        XCTAssertEqual((text as NSString).substring(with: include.bodyRange!), "\nincluded\n")
        XCTAssertEqual(include.value(forKey: "from"), "a.txt")
        XCTAssertEqual(include.integrity, .unrecorded)
        XCTAssertTrue(scan.issues.isEmpty)
    }

    func testSingleLineOpeningWithConfiguration() {
        let text = "<!--TOC min-level: 2\nmax-level: 3\n-->\n<!--/TOC-->\n"
        let scan = PlaceholderScanner.scan(text)
        XCTAssertEqual(scan.placeholders.first?.value(forKey: "min-level"), "2")
        XCTAssertEqual(scan.placeholders.first?.value(forKey: "max-level"), "3")
        XCTAssertTrue(scan.issues.isEmpty)
    }

    func testTerminateRenamesTheClosingTag() {
        let text = """
            <!--TOC
            _terminate_: "CONTENTS"
            -->
            <!--/CONTENTS-->
            """
        let scan = PlaceholderScanner.scan(text)
        XCTAssertEqual(scan.placeholders.first?.terminator, "CONTENTS")
        XCTAssertEqual(scan.placeholders.first?.closeLine, 3)
        XCTAssertTrue(scan.issues.isEmpty)
    }

    func testPythonDefineIsSelfContainedAndRunIsPaired() {
        let define = PlaceholderScanner.scan("<!--PYTHON\ndefine: \"v.py\"\n-->\ntext\n")
        XCTAssertEqual(define.placeholders.first?.shape, .selfContained)
        XCTAssertTrue(define.issues.isEmpty)

        let run = PlaceholderScanner.scan("<!--PYTHON\nrun: \"g.py\"\n-->\n<!--/PYTHON-->\n")
        XCTAssertEqual(run.placeholders.first?.shape, .paired)
        XCTAssertTrue(run.issues.isEmpty)
    }

    func testMermaidOwnsTheLineAfterItsComment() {
        let text = """
            <!--MERMAID
            file: "d.svg"
            diagram: |
              flowchart LR
                A --\\> B
            -->

            After
            """
        let scan = PlaceholderScanner.scan(text)
        let mermaid = scan.placeholders[0]
        XCTAssertEqual(mermaid.shape, .managedLine)
        XCTAssertEqual(mermaid.openLines, 0...5)
        XCTAssertEqual(mermaid.managedLine, 6)
        XCTAssertTrue(scan.issues.isEmpty)
    }

    func testMermaidWithoutChecksumNeedsAnEmptySlot() {
        let scan = PlaceholderScanner.scan("<!--MERMAID\nfile: \"d.svg\"\n-->\nnot empty\n")
        XCTAssertEqual(scan.issues.count, 1)
        XCTAssertEqual(scan.issues[0].line, 3)
    }

    func testNameMustEndAtAWordBoundary() {
        let scan = PlaceholderScanner.scan("<!--SETUP notes -->\n<!--TOCS-->\n")
        XCTAssertTrue(scan.placeholders.isEmpty)
    }

    func testOpeningMustStartTheLine() {
        let scan = PlaceholderScanner.scan("See <!--SET a: 1 --> here\n")
        XCTAssertTrue(scan.placeholders.isEmpty)
    }

    // MARK: Examples are not placeholders

    func testPlaceholdersInCodeFencesAreIgnored() {
        let text = """
            ```markdown
            <!--INCLUDE
            from: "x"
            -->
            ```
            ~~~
            <!--/TOC-->
            ~~~
            """
        let scan = PlaceholderScanner.scan(text)
        XCTAssertTrue(scan.placeholders.isEmpty)
        XCTAssertTrue(scan.issues.isEmpty)
    }

    func testFrontMatterIsSkipped() {
        let scan = PlaceholderScanner.scan("---\ntitle: <!--SET a: 1 -->\n---\n# Doc\n")
        XCTAssertEqual(scan.frontMatter, 0...2)
        XCTAssertTrue(scan.placeholders.isEmpty)
    }

    func testStrayUnknownClosingTagOutsidePlaceholdersIsText() {
        // A leftover <!--/MERMAID--> from before MERMAID lost its closing tag.
        let scan = PlaceholderScanner.scan("<!--/MERMAID-->\n")
        XCTAssertTrue(scan.issues.isEmpty)
    }

    // MARK: Structural errors, in mdship's words

    func testUnclosedPlaceholder() {
        let scan = PlaceholderScanner.scan("<!--TEMPLATE\ncontent: |\n  Test\n-->\ncontent\n")
        XCTAssertEqual(scan.issues.count, 1)
        XCTAssertEqual(scan.issues[0].line, 0)
        XCTAssertTrue(scan.issues[0].message.contains("Unclosed <!--TEMPLATE--> placeholder"))
        XCTAssertTrue(scan.placeholders[0].isUnclosed)
    }

    func testTypoInClosingTag() {
        let scan = PlaceholderScanner.scan("<!--TEMPLATE\ncontent: |\n  Test\n-->\ncontent\n<!--/TEMPLATEE-->\n")
        XCTAssertTrue(scan.issues.contains { $0.line == 5 && $0.message.contains("does not match opening <!--TEMPLATE--> at line 1") })
    }

    func testMismatchedNestingRecoversAtTheOuterTag() {
        let text = """
            <!--TEMPLATE
            content: x
            -->
            <!--INCLUDE
            from: "a"
            -->
            <!--/TEMPLATE-->
            after
            """
        let scan = PlaceholderScanner.scan(text)
        let template = scan.placeholders.first { $0.kind == .template }!
        XCTAssertEqual(template.closeLine, 6)
        XCTAssertTrue(scan.issues.contains { $0.message.contains("Closing <!--/TEMPLATE--> does not match opening <!--INCLUDE-->") })
        XCTAssertTrue(scan.issues.contains { $0.message.contains("Unclosed <!--INCLUDE-->") })
    }

    func testClosingWithoutOpening() {
        let scan = PlaceholderScanner.scan("text\n<!--/INCLUDE-->\n")
        XCTAssertEqual(scan.issues.first?.line, 1)
    }

    func testCommentNeverClosed() {
        let scan = PlaceholderScanner.scan("<!--SET\na: 1\n\nmore text\n")
        XCTAssertEqual(scan.issues.count, 1)
        XCTAssertTrue(scan.issues[0].message.contains("never closed with -->"))
    }

    // MARK: Integrity, against real mdship output

    func testFixtureWrittenByMdshipIsIntact() throws {
        let scan = PlaceholderScanner.scan(try fixture())
        XCTAssertEqual(scan.placeholders.map(\.kind), [.toc, .include])
        XCTAssertEqual(scan.placeholders.map(\.integrity), [.intact, .intact])
        XCTAssertTrue(scan.issues.isEmpty, "\(scan.issues)")
    }

    func testHandEditInsideManagedContentIsReported() throws {
        // Same length, different text: the closing tag stays put, the hash differs.
        let edited = try fixture().replacingOccurrences(of: "line one", with: "line ONE")
        let scan = PlaceholderScanner.scan(edited)
        XCTAssertEqual(scan.placeholders.map(\.integrity), [.intact, .edited])
        XCTAssertEqual(scan.issues.count, 1)
        XCTAssertEqual(scan.issues[0].severity, .warning)
    }

    func testLengthChangeInsideManagedContentIsReported() throws {
        let edited = try fixture().replacingOccurrences(of: "line one", with: "line one, longer")
        let scan = PlaceholderScanner.scan(edited)
        let include = scan.placeholders.first { $0.kind == .include }!
        XCTAssertEqual(include.integrity, .moved)
        // Still paired up structurally, so the rest of the document is unaffected.
        XCTAssertNotNil(include.closeRange)
        XCTAssertEqual(scan.issues.count, 1)
    }

    func testYoloAcceptsEditsOnlyForPython() throws {
        // mdship's INCLUDE ignores _yolo_ and still checks the hash.
        let include = try fixture()
            .replacingOccurrences(of: "from: \"snippet.txt\"", with: "from: \"snippet.txt\"\n_yolo_: true")
            .replacingOccurrences(of: "line one", with: "line ONE")
        XCTAssertEqual(PlaceholderScanner.scan(include).placeholders.first { $0.kind == .include }?.integrity, .edited)

        let python = """
            <!--PYTHON
            run: "gen.py"
            _yolo_: true
            _content_generated_: 5:md5:00000000000000000000000000000000
            -->
            edited by hand
            <!--/PYTHON-->
            """
        let scan = PlaceholderScanner.scan(python)
        XCTAssertEqual(scan.placeholders.first?.integrity, .overridden)
        XCTAssertTrue(scan.issues.isEmpty)
    }

    // MARK: Variable references

    func testShortVariableReferenceValueRunsToEndOfLine() {
        let text = "Version: <!--$app.version-->1.0.0 and more\nNext"
        let scan = PlaceholderScanner.scan(text)
        XCTAssertEqual(scan.variables.count, 1)
        let variable = scan.variables[0]
        XCTAssertEqual(variable.name, "app.version")
        XCTAssertNil(variable.marker)
        XCTAssertEqual((text as NSString).substring(with: variable.valueRange), "1.0.0 and more")
    }

    func testMarkerVariableReference() {
        let text = "Author: <!--${config.authors[0]}<>-->Alice Smith<!---->, editor"
        let scan = PlaceholderScanner.scan(text)
        XCTAssertEqual(scan.variables.count, 1)
        XCTAssertEqual(scan.variables[0].name, "config.authors[0]")
        XCTAssertEqual(scan.variables[0].marker, "")
        XCTAssertEqual((text as NSString).substring(with: scan.variables[0].valueRange), "Alice Smith")
    }

    func testVariableReferencesInCodeAreNotReferences() {
        let scan = PlaceholderScanner.scan("```\n<!--$a-->b\n```\n")
        XCTAssertTrue(scan.variables.isEmpty)
    }

    // MARK: Caret context

    func testCaretContext() throws {
        let text = try fixture()
        let ns = text as NSString
        let scan = PlaceholderScanner.scan(text)

        let inIncluded = ns.range(of: "line one").location + 2
        guard case .managedContent(let placeholder) = scan.context(at: inIncluded) else {
            return XCTFail("expected managed content")
        }
        XCTAssertEqual(placeholder.kind, .include)

        let inDefinition = ns.range(of: "snippet.txt").location
        guard case .definition(let definition) = scan.context(at: inDefinition) else {
            return XCTFail("expected definition")
        }
        XCTAssertEqual(definition.kind, .include)

        XCTAssertNil(scan.context(at: ns.range(of: "## Second").location + 4))
    }
}
