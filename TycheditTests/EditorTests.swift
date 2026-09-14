import XCTest
@testable import Tychedit

/// Line bookkeeping, the editing commands, and saving.
@MainActor
final class EditorTests: XCTestCase {

    // MARK: LineIndex

    func testLineIndex() {
        let index = LineIndex("ab\ncd\n\nef")
        XCTAssertEqual(index.starts, [0, 3, 6, 7])
        XCTAssertEqual(index.line(containing: 0), 0)
        XCTAssertEqual(index.line(containing: 2), 0)
        XCTAssertEqual(index.line(containing: 3), 1)
        XCTAssertEqual(index.line(containing: 99), 3)
        XCTAssertEqual(index.contentRange(ofLine: 1), NSRange(location: 3, length: 2))
        XCTAssertEqual(index.fullRange(ofLine: 1), NSRange(location: 3, length: 3))
        XCTAssertEqual(index.contentRange(ofLine: 3), NSRange(location: 7, length: 2))
    }

    func testLineIndexCountsUTF16() {
        // An emoji is two UTF-16 units, as NSTextView counts.
        let index = LineIndex("😀\nx")
        XCTAssertEqual(index.starts, [0, 3])
    }

    // MARK: Commands

    private func editor(_ text: String, selection: NSRange) -> EditorController {
        let editor = EditorController(fontSize: 13)
        editor.setText(text)
        editor.textView.setSelectedRange(selection)
        return editor
    }

    func testToggleWrapWrapsAndUnwraps() {
        let e = editor("say hello now", selection: NSRange(location: 4, length: 5))
        e.toggleWrap("**", sample: "bold", actionName: "Bold")
        XCTAssertEqual(e.text, "say **hello** now")
        XCTAssertEqual(e.selectedRange, NSRange(location: 6, length: 5))
        e.toggleWrap("**", sample: "bold", actionName: "Bold")
        XCTAssertEqual(e.text, "say hello now")
    }

    func testToggleWrapWithoutSelectionInsertsSelectedSample() {
        let e = editor("ab", selection: NSRange(location: 1, length: 0))
        e.toggleWrap("_", sample: "it", actionName: "Italic")
        XCTAssertEqual(e.text, "a_it_b")
        XCTAssertEqual(e.selectedRange, NSRange(location: 2, length: 2))
    }

    func testMoveLines() {
        let e = editor("one\ntwo\nthree", selection: NSRange(location: 5, length: 0))
        e.moveLines(up: true)
        XCTAssertEqual(e.text, "two\none\nthree")
        XCTAssertEqual(e.selectedRange.location, 1)
        e.moveLines(up: false)
        e.moveLines(up: false)
        XCTAssertEqual(e.text, "one\nthree\ntwo")
        // Already last: nothing happens.
        e.moveLines(up: false)
        XCTAssertEqual(e.text, "one\nthree\ntwo")
    }

    func testShiftLinesSkipsEmptyLinesAndIgnoresLineAfterSelection() {
        // Selection from "a" to the start of "c": lines a, (empty), b.
        let e = editor("a\n\nb\nc", selection: NSRange(location: 0, length: 5))
        e.shiftLines(right: true)
        XCTAssertEqual(e.text, "    a\n\n    b\nc")
        e.shiftLines(right: false)
        XCTAssertEqual(e.text, "a\n\nb\nc")
    }

    func testDuplicateAndDeleteLines() {
        let e = editor("one\ntwo", selection: NSRange(location: 1, length: 0))
        e.duplicateLines()
        XCTAssertEqual(e.text, "one\none\ntwo")
        XCTAssertEqual(e.selectedRange.location, 5)
        e.deleteLines()
        XCTAssertEqual(e.text, "one\ntwo")
        e.textView.setSelectedRange(NSRange(location: 5, length: 0))
        e.deleteLines()
        XCTAssertEqual(e.text, "one")
    }

    func testCommandsAreUndoable() throws {
        let e = editor("one\ntwo", selection: NSRange(location: 0, length: 0))
        // Undo needs an undo manager, which a text view outside a window only
        // has when given one.
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.contentView = e.scrollView
        let undo = try XCTUnwrap(e.textView.undoManager)
        e.moveLines(up: false)
        XCTAssertEqual(e.text, "two\none")
        undo.undo()
        XCTAssertEqual(e.text, "one\ntwo")
    }

    func testBlockSnippetGoesOnItsOwnLine() {
        let e = editor("text here", selection: NSRange(location: 4, length: 0))
        e.insertSnippet("<!--SET\n\u{1}name\u{2}: 1\n-->", block: true, actionName: "Insert SET")
        XCTAssertEqual(e.text, "text here\n<!--SET\nname: 1\n-->")
        XCTAssertEqual((e.text as NSString).substring(with: e.selectedRange), "name")
    }

    func testBlockSnippetReplacesABlankLine() {
        let e = editor("a\n   \nb", selection: NSRange(location: 3, length: 0))
        e.insertSnippet("<!--TOC-->\n<!--/TOC-->", block: true, actionName: "Insert TOC")
        XCTAssertEqual(e.text, "a\n<!--TOC-->\n<!--/TOC-->\nb")
    }

    func testEverySnippetIsAValidPlaceholder() {
        for snippet in PlaceholderSnippet.variableSources + PlaceholderSnippet.contentManagers {
            let text = snippet.text.replacingOccurrences(of: "\u{1}", with: "").replacingOccurrences(of: "\u{2}", with: "")
            let scan = PlaceholderScanner.scan(text)
            XCTAssertEqual(scan.placeholders.count, 1, snippet.title)
            XCTAssertTrue(scan.issues.isEmpty, "\(snippet.title): \(scan.issues)")
        }
        for snippet in PlaceholderSnippet.variableReferences {
            let text = snippet.text.replacingOccurrences(of: "\u{1}", with: "").replacingOccurrences(of: "\u{2}", with: "")
            XCTAssertEqual(PlaceholderScanner.scan(text).variables.count, 1, snippet.title)
        }
    }

    // MARK: Files

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Tychedit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTripKeepsBytes() throws {
        let url = directory.appendingPathComponent("crlf.md")
        let original = Data("\u{FEFF}# Title\r\nline — two\r\n".utf8)
        try original.write(to: url)
        let contents = try TextFile.read(url)
        XCTAssertTrue(contents.utf8ByteOrderMark)
        try TextFile.write(contents.text, to: url, encoding: contents.encoding,
                           utf8ByteOrderMark: contents.utf8ByteOrderMark)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testLatin1RoundTrip() throws {
        let url = directory.appendingPathComponent("latin1.md")
        let original = Data([0x63, 0x61, 0x66, 0xE9, 0x0A])  // "café\n" in Latin-1
        try original.write(to: url)
        let contents = try TextFile.read(url)
        XCTAssertEqual(contents.text, "café\n")
        try TextFile.write(contents.text, to: url, encoding: contents.encoding)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testSaveKeepsPermissions() throws {
        let url = directory.appendingPathComponent("script.md")
        try Data("old".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try TextFile.write("new", to: url, encoding: .utf8)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }
}
