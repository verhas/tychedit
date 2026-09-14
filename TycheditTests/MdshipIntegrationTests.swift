import XCTest
@testable import Tychedit

/// Talks to the real mdship. Skipped where mdship is not installed.
///
/// Worth the dependency: the MCP handshake, argument names and error wording
/// are exactly the parts a mock would get right by construction and a new
/// mdship version could quietly change.
@MainActor
final class MdshipIntegrationTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        let service = MdshipService.shared
        let found = await service.locate()
        try XCTSkipUnless(found, "mdship is not installed")
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TycheditMdship-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func file(_ name: String, _ text: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testToolChangesFileThroughTheServer() async throws {
        let url = try file("n.md", "# 1. Title\n\n## 1.1. Part\n")
        let result = try await MdshipService.shared.run(.unnumber, on: url, lines: nil)
        XCTAssertFalse(result.problems)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Title\n\n## Part\n")
    }

    /// The backup flag follows the setting, and is sent explicitly both ways --
    /// mdship's own default is to write a backup.
    func testBackupFollowsTheSetting() {
        for backup in [false, true] {
            let options = MdshipCommand.Options(backup: backup, numberingStyle: "period", skipTitle: false, reflowWidth: 80)
            guard case .tool(_, let arguments) = MdshipCommand.unnumber.request(path: "/x.md", lines: nil, options: options) else {
                return XCTFail("expected a tool call")
            }
            XCTAssertEqual(arguments["backup"] as? Bool, backup)
        }
    }

    func testUpdateGeneratesContent() async throws {
        let url = try file("u.md", "# Doc\n\n<!--TOC-->\n<!--/TOC-->\n\n## Section\n")
        _ = try await MdshipService.shared.run(.update, on: url, lines: nil)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("- [Section](#section)"), text)
        // What mdship wrote, the editor must consider intact.
        XCTAssertEqual(PlaceholderScanner.scan(text).placeholders.first?.integrity, .intact)
    }

    func testFailureCarriesTheLine() async throws {
        let url = try file("e.md", "text\n<!--TEMPLATE\ncontent: x\n-->\nno closing\n")
        do {
            _ = try await MdshipService.shared.run(.update, on: url, lines: nil)
            XCTFail("expected an error")
        } catch {
            let issues = MdshipOutput.issues(in: error.localizedDescription, text: "text\n<!--TEMPLATE\ncontent: x\n-->\nno closing\n")
            XCTAssertEqual(issues.first?.line, 1, error.localizedDescription)
        }
    }

    /// The editor must end up showing what mdship wrote. It once kept the old
    /// text -- the text view was still read-only when the reload ran -- and the
    /// next autosave then wrote that old text over mdship's work.
    func testDocumentTakesWhatMdshipWroteAndCanUndoIt() async throws {
        let original = "# Doc\n\n<!--TOC-->\n<!--/TOC-->\n\n## Section\n"
        let url = try file("d.md", original)
        let document = Document()
        defer { document.close() }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.contentView = document.editor.scrollView
        XCTAssertTrue(document.load(url))

        document.run(.toc)
        let deadline = Date().addingTimeInterval(60)
        repeat {
            try await Task.sleep(for: .milliseconds(100))
        } while document.mdshipActivity != nil && Date() < deadline
        // run() sets the activity before its task starts; wait for the task too.
        try await Task.sleep(for: .milliseconds(300))
        while document.mdshipActivity != nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }

        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("- [Section](#section)"), onDisk)
        XCTAssertEqual(document.editor.text, onDisk)
        XCTAssertFalse(document.isDirty)
        XCTAssertTrue(document.editor.textView.isEditable)

        document.editor.textView.undoManager?.undo()
        XCTAssertEqual(document.editor.text, original)
    }

    func testValidateRunsOnTheCommandLine() async throws {
        let url = try file("v.md", "# A\n\n[x](missing.md)\n")
        let result = try await MdshipService.shared.run(.validateLinks, on: url, lines: nil)
        XCTAssertTrue(result.problems)
        XCTAssertEqual(MdshipOutput.issues(in: result.output, text: "# A\n\n[x](missing.md)\n").first?.line, 2, result.output)
    }
}
