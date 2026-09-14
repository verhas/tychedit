import XCTest
@testable import Tychedit

/// The find bar's matching and replacing, and reverting git changes line by line.
final class FindAndRevertTests: XCTestCase {

    // MARK: Search

    private func find(_ query: String, in text: String, _ configure: (inout FindOptions) -> Void = { _ in }) throws -> [String] {
        var options = FindOptions()
        configure(&options)
        let expression = try TextSearch.expression(for: query, options: options)
        return TextSearch.matches(of: expression, in: text).map { (text as NSString).substring(with: $0) }
    }

    func testPlainQueriesAreLiteralAndCaseInsensitiveByDefault() throws {
        XCTAssertEqual(try find("a.b", in: "a.b axb A.B"), ["a.b", "A.B"])
        XCTAssertEqual(try find("a.b", in: "a.b A.B") { $0.caseSensitive = true }, ["a.b"])
    }

    func testWholeWords() throws {
        XCTAssertEqual(try find("cat", in: "cat catalog concat cat_ cat.") { $0.wholeWords = true }, ["cat", "cat"])
        XCTAssertEqual(try find("#x", in: "#x a#x #x2") { $0.wholeWords = true }, ["#x"], "boundaries also work for queries starting with punctuation")
    }

    func testRegexAndGroupsInReplacement() throws {
        var options = FindOptions()
        options.regex = true
        let expression = try TextSearch.expression(for: #"(\w+)@(\w+)"#, options: options)
        let result = TextSearch.replacingAll(in: "ann@home bob@work", expression: expression, template: "$2:$1", options: options)
        XCTAssertEqual(result.text, "home:ann work:bob")
        XCTAssertEqual(result.count, 2)

        let one = TextSearch.replacement(for: NSRange(location: 9, length: 8), in: "ann@home bob@work",
                                         expression: expression, template: "<$1>", options: options)
        XCTAssertEqual(one, "<bob>")
    }

    func testPlainReplacementKeepsDollarSigns() throws {
        let options = FindOptions()
        let expression = try TextSearch.expression(for: "price", options: options)
        XCTAssertEqual(TextSearch.replacingAll(in: "price", expression: expression, template: "$1 \\n", options: options).text, "$1 \\n")
    }

    func testInvalidRegexIsReported() {
        var options = FindOptions()
        options.regex = true
        XCTAssertThrowsError(try TextSearch.expression(for: "(unclosed", options: options))
    }

    func testRegexAnchorsWorkPerLine() throws {
        XCTAssertEqual(try find("^# .*$", in: "# One\ntext\n# Two") { $0.regex = true }, ["# One", "# Two"])
    }

    // MARK: Hunks and reverting

    private let committed = "one\ntwo\nthree\nfour\nfive\n"

    private func apply(_ edit: ChangeRevert.Edit?, to text: String) throws -> String {
        let edit = try XCTUnwrap(edit)
        return (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    func testHunksKeepTheCommittedLines() {
        let changes = LineChanges.compute(base: committed, current: "one\nTWO\nNEW\nthree\nfive\n")
        XCTAssertEqual(changes.hunks, [
            LineChanges.Hunk(oldStart: 1, oldLines: ["two"], newStart: 1, newLines: ["TWO", "NEW"]),
            LineChanges.Hunk(oldStart: 3, oldLines: ["four"], newStart: 4, newLines: []),
        ])
        XCTAssertEqual(changes.hunk(containing: 2)?.oldLines, ["two"])
        XCTAssertEqual(changes.hunk(deletedBefore: 4)?.oldLines, ["four"])
    }

    func testRevertOneLine() throws {
        let current = "one\nTWO\nNEW\nthree\nfive\n"
        let changes = LineChanges.compute(base: committed, current: current)
        let hunk = try XCTUnwrap(changes.hunk(containing: 1))
        // The changed line goes back to its committed text.
        XCTAssertEqual(try apply(ChangeRevert.revertLine(1, of: hunk, in: current), to: current), "one\ntwo\nNEW\nthree\nfive\n")
        // The added line goes away.
        XCTAssertEqual(try apply(ChangeRevert.revertLine(2, of: hunk, in: current), to: current), "one\nTWO\nthree\nfive\n")
    }

    func testRevertWholeChangeAndRestoreDeletion() throws {
        let current = "one\nTWO\nNEW\nthree\nfive\n"
        let changes = LineChanges.compute(base: committed, current: current)
        let first = try XCTUnwrap(changes.hunk(containing: 1))
        XCTAssertEqual(try apply(ChangeRevert.revertHunk(first, in: current), to: current), "one\ntwo\nthree\nfive\n")
        let deletion = try XCTUnwrap(changes.hunk(deletedBefore: 4))
        XCTAssertEqual(try apply(ChangeRevert.restoreDeletedLines(of: deletion, in: current), to: current), "one\nTWO\nNEW\nthree\nfour\nfive\n")
    }

    func testEditedSinceMeansNoRevert() throws {
        let current = "one\nTWO\nthree\nfour\nfive\n"
        let hunk = try XCTUnwrap(LineChanges.compute(base: committed, current: current).hunk(containing: 1))
        XCTAssertNil(ChangeRevert.revertLine(1, of: hunk, in: "one\nTWO again\nthree\nfour\nfive\n"))
    }

    func testRestoreAtEndOfFileWithoutNewline() throws {
        let current = "one\ntwo"
        let hunk = try XCTUnwrap(LineChanges.compute(base: "one\ntwo\nthree", current: current).hunk(deletedBefore: 2))
        XCTAssertEqual(try apply(ChangeRevert.restoreDeletedLines(of: hunk, in: current), to: current), "one\ntwo\nthree")
    }

    func testCRLFLinesKeepTheirBreaks() throws {
        let current = "one\r\nTWO\r\nthree\r\n"
        let hunk = try XCTUnwrap(LineChanges.compute(base: "one\r\ntwo\r\nthree\r\n", current: current).hunk(containing: 1))
        XCTAssertEqual(try apply(ChangeRevert.revertLine(1, of: hunk, in: current), to: current), "one\r\ntwo\r\nthree\r\n")
    }
}
