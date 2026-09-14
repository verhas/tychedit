import XCTest
@testable import Tychedit

/// Change marks, fold regions, `start:` navigation, and completing the start of a placeholder.
final class GutterTests: XCTestCase {

    // MARK: Line changes

    func testUnchangedHasNoMarks() {
        XCTAssertTrue(LineChanges.compute(base: "a\nb\n", current: "a\nb\n").isEmpty)
        XCTAssertTrue(LineChanges.compute(base: "a\r\nb\r\n", current: "a\nb\n").isEmpty, "line endings are not changes")
    }

    func testAddedModifiedDeleted() {
        let changes = LineChanges.compute(base: "one\ntwo\nthree\nfour\n", current: "one\nTWO\nthree\nnew\nfour\n")
        XCTAssertEqual(changes.lines, [1: .modified, 3: .added])
        XCTAssertTrue(changes.deletions.isEmpty)

        let deleted = LineChanges.compute(base: "one\ntwo\nthree\n", current: "one\nthree\n")
        XCTAssertTrue(deleted.lines.isEmpty)
        XCTAssertEqual(deleted.deletions, [1])

        let replacedMore = LineChanges.compute(base: "a\nb\nc\nd\n", current: "a\nX\nd\n")
        XCTAssertEqual(replacedMore.lines, [1: .modified])
        XCTAssertEqual(replacedMore.deletions, [2])
    }

    func testDeletionAtEnd() {
        let changes = LineChanges.compute(base: "a\nb", current: "a")
        XCTAssertEqual(changes.deletions, [1])
    }

    // MARK: Folding

    func testSectionsFoldToTheNextHeadingOfTheSameLevel() {
        let text = "# A\ntext\n\n## B\nb text\n\n## C\nc\n\n# D\nd\n"
        let result = MarkdownRenderer.render(text)
        let regions = FoldRegion.regions(in: text, headings: result.headings, scan: result.scan)
        let sections = regions.filter { if case .section = $0.kind { return true } else { return false } }
        XCTAssertEqual(sections.map { [$0.firstLine, $0.lastLine] }, [[0, 7], [3, 4], [6, 7], [9, 10]].sorted { $0[0] < $1[0] })
        // Folding A hides from the end of "# A" to the end of "c".
        let a = sections[0]
        XCTAssertEqual((text as NSString).substring(with: a.hiddenRange), "\ntext\n\n## B\nb text\n\n## C\nc")
    }

    func testPlaceholdersFoldWholeAndHeader() {
        let text = "<!--INCLUDE\nfrom: x.md\nstart: a\n-->\nincluded\n<!--/INCLUDE-->\n<!--SET a: 1 -->\n<!--SET\nb: 2\n-->\n"
        let result = MarkdownRenderer.render(text)
        let regions = FoldRegion.regions(in: text, headings: [], scan: result.scan)
        XCTAssertEqual(regions.map { [$0.firstLine, $0.lastLine] }, [[0, 5], [0, 3], [7, 9]], "one-line SET does not fold")
        XCTAssertEqual(regions.map(\.isHeader), [false, true, true])
        let ns = text as NSString
        // The whole placeholder hides through its closing tag.
        XCTAssertEqual(ns.substring(with: regions[0].hiddenRange), "\nfrom: x.md\nstart: a\n-->\nincluded\n<!--/INCLUDE-->")
        // The header hides only up to its -->, which stays in view.
        XCTAssertEqual(ns.substring(with: regions[1].hiddenRange), "\nfrom: x.md\nstart: a\n")
        // Badges show the first parameter written.
        XCTAssertEqual(regions[1].label, "from: x.md")
        XCTAssertEqual(regions[0].label, "from: x.md … /INCLUDE")
        XCTAssertEqual(regions[2].label, "b: 2")
    }

    func testFirstParameterSkipsWhatMdshipWrote() {
        let text = "<!--TOC\n_content_generated_: 1:md5:0\nmax-level: 2\n-->\n- x\n<!--/TOC-->\n"
        let region = FoldRegion.regions(in: text, headings: [], scan: PlaceholderScanner.scan(text)).first { $0.isHeader }
        XCTAssertEqual(region?.label, "max-level: 2")
    }

    func testFoldKeysSurviveEditsAboveAndCountRepeats() {
        let before = "## Notes\nx\n\n## Notes\ny\n"
        let after = "intro\n\n" + before
        let keys1 = FoldRegion.regions(in: before, headings: MarkdownRenderer.render(before).headings, scan: PlaceholderScan()).map(\.key)
        let keys2 = FoldRegion.regions(in: after, headings: MarkdownRenderer.render(after).headings, scan: PlaceholderScan()).map(\.key)
        XCTAssertEqual(keys1, keys2)
        XCTAssertEqual(keys1.map(\.occurrence), [0, 1])
    }

    // MARK: start: navigation

    func testStartPatternTarget() {
        let code = "import os\n# START\ndef f():\n    pass\n# END\n"
        XCTAssertEqual(NavigationTarget.line(matching: "START", includesMatch: false, in: code), 2)
        XCTAssertEqual(NavigationTarget.line(matching: #"def\s+f"#, includesMatch: true, in: code), 2)
        XCTAssertNil(NavigationTarget.line(matching: "nothing", includesMatch: false, in: code))
    }

    // MARK: Completing <!--

    private func complete(_ textWithCaret: String, explicit: Bool = false) -> CompletionList? {
        let caret = (textWithCaret as NSString).range(of: "|").location
        let text = textWithCaret.replacingOccurrences(of: "|", with: "")
        return CompletionProvider.completions(in: text, at: caret, documentURL: nil, explicit: explicit)
    }

    func testPlaceholderNamesAfterCommentStart() throws {
        let list = try XCTUnwrap(complete("text\n<!--I|"))
        XCTAssertEqual(list.items.map(\.label), ["IMPORT", "INCLUDE", "PYTHON"].filter { $0.hasPrefix("I") })
        XCTAssertEqual(list.range.length, 1)
        let lower = try XCTUnwrap(complete("<!--inc|"))
        XCTAssertEqual(lower.items.map(\.insertion), ["INCLUDE"])
        XCTAssertNil(complete("<!--|"), "a bare comment start is not a request")
        XCTAssertEqual(complete("<!--|", explicit: true)?.items.count, PlaceholderKind.allCases.count)
        XCTAssertNil(complete("see <!--I|"), "placeholders start a line")
    }

    func testFinishedNameOffersTheClosing() throws {
        let paired = try XCTUnwrap(complete("<!--INCLUDE|"))
        XCTAssertEqual(paired.items.map(\.insertion), ["\n\u{1}\u{2}\n-->\n<!--/INCLUDE-->"])
        XCTAssertEqual(paired.range, NSRange(location: 11, length: 0))

        let single = try XCTUnwrap(complete("<!--SET|"))
        XCTAssertEqual(single.items.map(\.insertion), ["\n\u{1}\u{2}\n-->"])

        XCTAssertEqual(complete("<!--PYTHON|")?.items.count, 2)
        XCTAssertNil(complete("<!--INCLUDE|\nfrom: x\n-->\n<!--/INCLUDE-->"), "already closed")
    }

    func testClosingThenParameters() throws {
        // What the editor does on accepting: insert, then ask again with the caret inside.
        let closed = "<!--INCLUDE\n\n-->\n<!--/INCLUDE-->"
        let caret = 12
        let list = try XCTUnwrap(CompletionProvider.completions(in: closed, at: caret, documentURL: nil, explicit: true))
        XCTAssertEqual(list.items.first?.label, "from")
    }

    // MARK: --> inside a quoted value

    /// The text that confused the editor: the `-->` inside the `start:` string.
    private let quotedArrow = """
        <!--INCLUDE
        from: "arrays-and-wanting-one.md"
        start: "<!-- abstract -->"

        -->
        <!--/INCLUDE-->
        """

    func testQuotedArrowIsReportedWhereMdshipWouldFail() throws {
        let scan = PlaceholderScanner.scan(quotedArrow)
        let issue = try XCTUnwrap(scan.issues.first { $0.message.contains("inside a quoted value") })
        XCTAssertEqual(issue.line, 2)
        XCTAssertEqual((quotedArrow as NSString).substring(with: issue.range), "-->")
        XCTAssertTrue(issue.message.contains("--[>]"))

        // The spelling that works with mdship is not reported.
        let fixed = quotedArrow.replacingOccurrences(of: "abstract -->", with: "abstract --[>]")
        XCTAssertFalse(PlaceholderScanner.scan(fixed).issues.contains { $0.message.contains("quoted value") })
    }

    func testQuotedArrowDoesNotEndTheDefinitionForSuggestions() throws {
        let caret = (quotedArrow as NSString).range(of: "\"\n\n").location + 2
        for explicit in [true, false] {
            let list = CompletionProvider.completions(in: quotedArrow, at: caret, documentURL: nil, explicit: explicit)
            if explicit {
                let labels = try XCTUnwrap(list).items.map(\.label)
                XCTAssertTrue(labels.contains("end"), "\(labels)")
                XCTAssertFalse(labels.contains("from") || labels.contains("start"), "already present: \(labels)")
                XCTAssertFalse(labels.contains("INCLUDE"), "not the placeholder list")
            } else {
                XCTAssertNil(list, "an empty line is not a request")
            }
        }
    }

    func testCommentText() {
        XCTAssertTrue(CommentText.hasClosingArrow("-->"))
        XCTAssertTrue(CommentText.hasClosingArrow("name: x -->"))
        XCTAssertFalse(CommentText.hasClosingArrow("start: \"<!-- abstract -->\""))
        XCTAssertFalse(CommentText.hasClosingArrow("start: '-->'"))
        XCTAssertTrue(CommentText.hasClosingArrow("prefix: don't -->"), "an apostrophe inside a word is not a quote")
        XCTAssertTrue(CommentText.endsInsideQuotes("start: \"<!-- abstract "))
        XCTAssertFalse(CommentText.endsInsideQuotes("start: \"done\" "))
    }

    func testExplicitOnBlankLineOffersWholePlaceholders() throws {
        let list = try XCTUnwrap(complete("# Doc\n\n|\n", explicit: true))
        XCTAssertTrue(list.items.contains { $0.label == "INCLUDE" })
        XCTAssertNil(complete("# Doc\n\n|\n"))
    }
}
