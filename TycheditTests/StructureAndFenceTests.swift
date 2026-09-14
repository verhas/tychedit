import XCTest
@testable import Tychedit

/// Moving sections by their headings, and growing code fences.
final class StructureAndFenceTests: XCTestCase {

    private let book = """
        # Book

        Intro.

        ## One

        one text

        ### One A

        a text

        ## Two

        two text

        ## Three

        three text

        """

    private func structure(_ text: String) -> DocumentStructure {
        let result = MarkdownRenderer.render(text)
        return DocumentStructure(text: text, headings: result.headings, scan: result.scan)
    }

    private func titles(_ text: String) -> [String] {
        structure(text).entries.map { String(repeating: "#", count: $0.level) + " " + $0.text }
    }

    func testTree() {
        let s = structure(book)
        XCTAssertEqual(s.entries.map(\.text), ["Book", "One", "One A", "Two", "Three"])
        XCTAssertEqual(s.parents, [nil, 0, 1, 0, 0])
        XCTAssertEqual(s.children(of: 0), [1, 3, 4])
        XCTAssertEqual(s.sectionEnd(1), s.entries[3].line, "One's section includes One A")
    }

    func testMoveSectionDownTakesSubsections() throws {
        let s = structure(book)
        // One (with One A) after Three: child index 3 of Book = the end.
        let moved = try XCTUnwrap(s.move(1...1, toParent: 0, childIndex: 3, in: book))
        XCTAssertEqual(titles(moved), ["# Book", "## Two", "## Three", "## One", "### One A"])
        XCTAssertTrue(moved.contains("## One\n\none text\n\n### One A\n\na text\n"))
        XCTAssertTrue(moved.hasSuffix("\n"))
        XCTAssertEqual(moved.components(separatedBy: "\n").count, book.components(separatedBy: "\n").count)
    }

    func testMoveUp() throws {
        let s = structure(book)
        let moved = try XCTUnwrap(s.move(4...4, toParent: 0, childIndex: 0, in: book))
        XCTAssertEqual(titles(moved), ["# Book", "## Three", "## One", "### One A", "## Two"])
    }

    func testDemoteUnderPreviousSiblingShiftsSubheadings() throws {
        let s = structure(book)
        // Two becomes the last child of One: level 3.
        let moved = try XCTUnwrap(s.move(3...3, toParent: 1, childIndex: 1, in: book))
        XCTAssertEqual(titles(moved), ["# Book", "## One", "### One A", "### Two", "## Three"])

        // One (with One A) dropped at the top level after Book: level 1, One A level 2.
        let promoted = try XCTUnwrap(s.move(1...1, toParent: nil, childIndex: 1, in: book))
        XCTAssertEqual(titles(promoted), ["# Book", "## Two", "## Three", "# One", "## One A"])
    }

    func testConsecutiveSelectionMovesTogether() throws {
        let s = structure(book)
        let moved = try XCTUnwrap(s.move(3...4, toParent: 0, childIndex: 0, in: book))
        XCTAssertEqual(titles(moved), ["# Book", "## Two", "## Three", "## One", "### One A"])
    }

    func testImpossibleMoves() {
        let s = structure(book)
        XCTAssertNil(s.move(1...1, toParent: 2, childIndex: 0, in: book), "not into its own section")
        XCTAssertNil(s.move(1...1, toParent: 0, childIndex: 0, in: book), "same place, same level: nothing to do")
        let deep = "# A\n\n## B\n\n### C\n\n#### D\n\n##### E\n\n###### F\n\n# G\n"
        let d = structure(deep)
        XCTAssertNil(d.move(6...6, toParent: 5, childIndex: 0, in: deep), "G would take a seventh level")
    }

    func testSetextHeadingsBecomeATXWhenTheirLevelChanges() throws {
        let text = "Title\n=====\n\nPart\n----\n\ntext\n"
        let s = structure(text)
        let moved = try XCTUnwrap(s.move(1...1, toParent: nil, childIndex: 1, in: text))
        XCTAssertTrue(moved.contains("# Part"))
        XCTAssertFalse(moved.contains("----"))
    }

    func testHeadingsInGeneratedContentStayPut() {
        let text = "# Doc\n\n<!--INCLUDE\nfrom: x.md\n-->\n# Included\n<!--/INCLUDE-->\n\n## Real\n"
        XCTAssertEqual(structure(text).entries.map(\.text), ["Doc", "Real"])
    }

    // MARK: Fences

    private func apply(_ edits: [CodeFenceGuard.Edit], to text: String) -> String {
        edits.reduce(text) { ($0 as NSString).replacingCharacters(in: $1.range, with: $1.replacement) }
    }

    func testTypingABacktickRunGrowsTheFence() {
        let text = "Text\n\n```text\nuse ``x``\n```\n"
        let at = (text as NSString).range(of: "``x").location
        let after = (text as NSString).replacingCharacters(in: NSRange(location: at, length: 0), with: "`")
        let edits = CodeFenceGuard.edits(afterReplacing: NSRange(location: at, length: 0), in: text, with: "`")
        XCTAssertEqual(apply(edits, to: after), "Text\n\n````text\nuse ```x``\n````\n")
    }

    func testPastingAFenceLineInsideGrowsTheFence() {
        let text = "```\ncode\n```\n"
        let at = (text as NSString).range(of: "code").location + 4
        let paste = "\n```\nmore"
        let after = (text as NSString).replacingCharacters(in: NSRange(location: at, length: 0), with: paste)
        let edits = CodeFenceGuard.edits(afterReplacing: NSRange(location: at, length: 0), in: text, with: paste)
        XCTAssertEqual(apply(edits, to: after), "````\ncode\n```\nmore\n````\n")
    }

    func testNothingOutsideBlocksOrBelowTheFenceLength() {
        let text = "a ``b``\n\n```\nx\n```\n"
        XCTAssertTrue(CodeFenceGuard.edits(afterReplacing: NSRange(location: 2, length: 0), in: text, with: "`").isEmpty)
        let inside = (text as NSString).range(of: "x").location
        XCTAssertTrue(CodeFenceGuard.edits(afterReplacing: NSRange(location: inside, length: 0), in: text, with: "``").isEmpty)
        let tilde = "~~~\nx\n~~~\n"
        XCTAssertTrue(CodeFenceGuard.edits(afterReplacing: NSRange(location: 4, length: 0), in: tilde, with: "```").isEmpty)
    }
}

/// Turning short variable references into the marker form when mdship refuses a value with spaces.
final class VariableMarkerFixTests: XCTestCase {

    private let message = "Variable 'name' value 'value kakks' contains spaces. Use the marker form: <!--$name<MARKER>-->value with spaces<!--MARKER-->"

    func testReadsTheFailure() {
        XCTAssertEqual(VariableMarkerFix.failure(in: "Error: " + message),
                       VariableMarkerFix.Failure(name: "name", value: "value kakks"))
        XCTAssertEqual(VariableMarkerFix.failure(in: "Variable 'config.title' value 'it's here' contains spaces. Use the marker form: x")?.value,
                       "it's here")
        XCTAssertNil(VariableMarkerFix.failure(in: "Line 3: Variable 'name' not found or is None"))
    }

    func testShortestMarker() {
        XCTAssertEqual(VariableMarkerFix.marker(for: "two words"), "")
        XCTAssertEqual(VariableMarkerFix.marker(for: "a <!----> b"), "1")
        XCTAssertEqual(VariableMarkerFix.marker(for: "a <!----> <!--1--> b"), "2")
    }

    func testRewritesEveryShortReferenceToTheVariable() {
        let text = """
            <!--SET
            name: "value kakks"
            -->
            Hello <!--$name-->old
            Keep <!--${name}-->`old` trailing
            ```
            <!--$name-->incode
            ```
            Already <!--$name<>-->value kakks<!---->
            """
        let scan = PlaceholderScanner.scan(text)
        let failure = VariableMarkerFix.failure(in: message)!
        let fixed = VariableMarkerFix.fix(failure, in: text, variables: scan.variables)
        XCTAssertEqual(fixed.count, 2)
        XCTAssertTrue(fixed.text.contains("Hello <!--$name<>--><!---->\n"))
        XCTAssertTrue(fixed.text.contains("Keep <!--${name}<>-->`old`<!----> trailing"))
        XCTAssertTrue(fixed.text.contains("<!--$name-->incode"), "code blocks are left alone")
        XCTAssertTrue(fixed.text.contains("Already <!--$name<>-->value kakks<!---->"))
    }
}
