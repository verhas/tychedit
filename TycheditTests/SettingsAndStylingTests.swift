import XCTest
@testable import Tychedit

/// Settings files, recent files, editor styling, and streamed process output.
final class SettingsAndStylingTests: XCTestCase {

    // MARK: Settings

    func testSettingsDecodeLenientlyAndKeepUnknownCommandsOut() throws {
        let json = #"{"fontSize": 15, "lineNumbers": "relative", "toolbar": [{"command": "toc", "icon": "star", "shown": true}, {"command": "gone", "icon": "x", "shown": true}]}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.fontSize, 15)
        XCTAssertEqual(settings.lineNumbers, .relative)
        XCTAssertEqual(settings.autosaveInterval, 30, "missing keys take their defaults")
        XCTAssertEqual(settings.toolbar.first { $0.command == "toc" }, ToolbarCommand(command: "toc", icon: "star", shown: true))
        let order = settings.toolbar.map(\.command)
        XCTAssertLessThan(order.firstIndex(of: "structure")!, order.firstIndex(of: "toc")!,
                          "buttons missing from the file go where they are by default")
        XCTAssertFalse(settings.toolbar.contains { $0.command == "gone" })
        XCTAssertEqual(settings.toolbar.count, MdshipCommand.allCases.count + ToolbarAction.allCases.count,
                       "every button has an entry")
    }

    func testEveryToolbarStateHasAnIcon() throws {
        let json = #"{"toolbar": [{"command": "lineNumbers", "icon": "a", "shown": false, "alternateIcons": ["b"]}, {"command": "console", "icon": "t", "shown": true, "alternateIcons": ["x", "y"]}]}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        let lines = try XCTUnwrap(settings.toolbar.first { $0.action == .lineNumbers })
        XCTAssertEqual(lines.icons, ["a", "b", LineNumberMode.relative.icon])
        XCTAssertFalse(lines.shown)
        XCTAssertEqual(settings.toolbar.first { $0.action == .console }?.icons, ["t"])
        XCTAssertEqual(settings.toolbar.first { $0.action == .insertComment }?.icon, "chevron.left.forwardslash.chevron.right")
    }

    func testSettingsRoundTrip() throws {
        var settings = Settings()
        settings.recentFilesLimit = 3
        settings.toolbar[0].icon = "bolt"
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
    }

    @MainActor
    func testRecentFilesRememberNewestFirstUpToTheLimit() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("TycheditRecent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recent = RecentFiles(directory: directory)
        for name in ["a", "b", "c", "a"] {
            recent.add(URL(fileURLWithPath: "/tmp/\(name).md"), limit: 2)
        }
        XCTAssertEqual(recent.paths, ["/tmp/a.md", "/tmp/c.md"])
        // Written to recent.json and read back.
        XCTAssertEqual(RecentFiles(directory: directory).paths, ["/tmp/a.md", "/tmp/c.md"])
        recent.trim(to: 1)
        XCTAssertEqual(RecentFiles(directory: directory).paths, ["/tmp/a.md"])
    }

    // MARK: Styling

    private func style(_ text: String, at fragment: String, offset: Int = 0) -> TextStyle {
        let result = MarkdownRenderer.render(text)
        let runs = SyntaxHighlighter.runs(in: text, headings: result.headings, scan: result.scan)
        let location = (text as NSString).range(of: fragment).location + offset
        return runs.first { NSLocationInRange(location, $0.range) }?.style ?? .plain
    }

    func testRunsCoverTheWholeText() {
        let text = "# Title\n\nSome **bold** and `code`.\n"
        let result = MarkdownRenderer.render(text)
        let runs = SyntaxHighlighter.runs(in: text, headings: result.headings, scan: result.scan)
        XCTAssertEqual(runs.first?.range.location, 0)
        XCTAssertEqual(runs.map(\.range.length).reduce(0, +), (text as NSString).length)
    }

    func testMarkdownStyles() {
        let text = "## Heading\n\nA **bold** word, *italic*, ~~gone~~, `code`, snake_case_name.\n\n```\nlet x = 1\n```\n"
        XCTAssertEqual(style(text, at: "## Heading").heading, 2)
        XCTAssertTrue(style(text, at: "**bold**").bold, "the ** markers are bold too")
        XCTAssertTrue(style(text, at: "bold**").bold)
        XCTAssertFalse(style(text, at: " word").bold)
        XCTAssertTrue(style(text, at: "*italic*").italic)
        XCTAssertTrue(style(text, at: "~~gone~~").strike)
        XCTAssertEqual(style(text, at: "`code`").color, .code)
        XCTAssertFalse(style(text, at: "case_name").italic, "intraword underscores are not emphasis")
        XCTAssertEqual(style(text, at: "let x").color, .code)
        XCTAssertEqual(style(text, at: "```").color, .code)
    }

    func testPlaceholderStyles() {
        let text = "<!--INCLUDE\nfrom: \"x.md\"\n-->\n**included**\n<!--/INCLUDE-->\nValue <!--$name-->v\n<!-- note -->\n"
        XCTAssertEqual(style(text, at: "<!--INCLUDE").color, .placeholder)
        XCTAssertEqual(style(text, at: "from:").color, .placeholderKey)
        XCTAssertEqual(style(text, at: "\"x.md\"").color, .placeholder)
        XCTAssertTrue(style(text, at: "**included**").bold, "generated content is markdown too")
        XCTAssertEqual(style(text, at: "<!--/INCLUDE-->").color, .placeholder)
        XCTAssertEqual(style(text, at: "<!--$name-->").color, .variable)
        XCTAssertEqual(style(text, at: "<!-- note").color, .comment)
    }

    func testCodeInsideCommentOrPlaceholderIsNotEmphasis() {
        let text = "<!--SET\npattern: '*x*'\n-->\n"
        XCTAssertFalse(style(text, at: "*x*").italic)
    }

    // MARK: Streaming output

    func testProcessOutputArrivesWhileItRuns() throws {
        let chunks = ChunkLog()
        let started = Date()
        let result = ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo first; sleep 1; echo second"],
                                       timeout: 10) { chunk in chunks.add(chunk, at: Date()) }
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "first\nsecond\n")
        let firstArrival = try XCTUnwrap(chunks.entries.first { $0.0.contains("first") }?.1)
        XCTAssertLessThan(firstArrival.timeIntervalSince(started), 0.8, "the first line came before the process ended")
    }

    private final class ChunkLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [(String, Date)] = []
        func add(_ chunk: String, at date: Date) { lock.withLock { stored.append((chunk, date)) } }
        var entries: [(String, Date)] { lock.withLock { stored } }
    }
}
