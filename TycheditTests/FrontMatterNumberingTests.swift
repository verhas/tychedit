import CryptoKit
import XCTest
@testable import Tychedit

/// The `number:` front-matter key: mdship's numbering, the key's validation,
/// the update-blocking predictions, and completion.
final class FrontMatterNumberingTests: XCTestCase {

    // MARK: Numbering, against mdship's own output

    private func number(_ text: String, style: HeadingNumbering.Style = .period, skipTitle: Bool = false) throws -> String {
        try HeadingNumbering.number(LineIndex.split(text), from: 0, style: style, skipTitle: skipTitle)
            .joined(separator: "\n")
    }

    private func unnumber(_ text: String) -> String {
        HeadingNumbering.unnumber(LineIndex.split(text), from: 0).joined(separator: "\n")
    }

    func testNumbersLikeMdship() throws {
        let text = "# Title\n\n## Intro\n\n### Detail\n\n## Usage\n\n# Second\n\n## Again"
        XCTAssertEqual(try number(text),
                       "# 1. Title\n\n## 1.1. Intro\n\n### 1.1.1. Detail\n\n## 1.2. Usage\n\n# 2. Second\n\n## 2.1. Again")
        XCTAssertEqual(try number(text, style: .space),
                       "# 1 Title\n\n## 1.1 Intro\n\n### 1.1.1 Detail\n\n## 1.2 Usage\n\n# 2 Second\n\n## 2.1 Again")
        XCTAssertEqual(try number("# T\n## A\n### B\n## C", style: .parenthesis, skipTitle: true),
                       "# T\n## 1) A\n### 1.1) B\n## 2) C")
        XCTAssertEqual(unnumber("# 1. Title\n\n## 1.1) Intro\n### 1.1.1 Detail"), "# Title\n\n## Intro\n### Detail")
    }

    /// mdship's quirks are ported on purpose: the editor must predict what it does.
    func testKeepsMdshipQuirks() throws {
        // A level skip numbers from the levels present; a leading number is stripped as numbering.
        XCTAssertEqual(try number("# A\n### skip\n## B\n### C"), "# 1. A\n### 1.1. skip\n## 1.1. B\n### 1.1.1. C")
        XCTAssertEqual(try number("## 1.1. 2023 Report\n## 7 Wonders"), "## 1. Report\n## 2. Wonders")
    }

    func testSkipsFencesAndCommentsLikeMdship() throws {
        let text = "# A\n```\n# not\n```\n<!--SET\n# yaml\n-->\n<!-- x --> \n## B\n#NoSpace\n####### seven"
        XCTAssertEqual(try number(text),
                       "# 1. A\n```\n# not\n```\n<!--SET\n# yaml\n-->\n<!-- x --> \n## 1.1. B\n#NoSpace\n####### seven")
    }

    func testSkipTitleRefusesTwoTitles() {
        XCTAssertThrowsError(try number("# One\n# Two", skipTitle: true)) { error in
            XCTAssertEqual((error as? HeadingNumbering.SkipTitleError)?.message,
                           "--skip-title requires exactly one h1 heading, but found 2")
        }
    }

    // MARK: Reading the key

    private func read(_ text: String) -> FrontMatterNumbering.Reading? {
        FrontMatterNumbering.read(text as NSString, lines: LineIndex(text as NSString))
    }

    func testReadsTheForms() {
        XCTAssertNil(read("# No front matter\n"))
        XCTAssertNil(read("---\nnumber: true\n...\n# Not closed the mdship way\n"))
        XCTAssertNil(read("---\ntitle: x\n---\n# T\n")?.settings)
        XCTAssertEqual(read("---\nnumber: true\n---\n")?.settings, NumberingSettings(number: true))
        XCTAssertEqual(read("---\nnumber: off\n---\n")?.settings, NumberingSettings(number: false))
        XCTAssertEqual(read("---\nnumber:\n  style: parenthesis\n  skip-title: true\n  post-process: yes\n---\n# T\n")?.settings,
                       NumberingSettings(number: true, style: .parenthesis, skipTitle: true, postProcess: true))
        XCTAssertEqual(read("---\nnumber: {style: space, generated: true}\n---\n")?.settings,
                       NumberingSettings(number: true, style: .space, generated: true))
        XCTAssertEqual(read("---\nnumber: {}\n---\n")?.settings, NumberingSettings(number: true))
        XCTAssertEqual(read("---\ntitle: x\nnumber: true\n---\n# T\n")?.bodyStart, 4)
    }

    func testRejectsWhatMdshipRejects() {
        func problems(_ yaml: String) -> [String] { read("---\n\(yaml)\n---\n# T\n")?.problems.map(\.message) ?? [] }
        let allowed = "style, skip-title, generated, post-process"
        XCTAssertEqual(problems("number: \"true\""), ["Front-matter 'number:' must be true, false, or a mapping of \(allowed), not 'true'"])
        XCTAssertEqual(problems("number:"), ["Front-matter 'number:' must be true, false, or a mapping of \(allowed), not None"])
        XCTAssertEqual(problems("number: 1"), ["Front-matter 'number:' must be true, false, or a mapping of \(allowed), not 1"])
        XCTAssertEqual(problems("number:\n  styel: space"),
                       ["Unknown front-matter 'number:' key(s): styel. Allowed keys are \(allowed)"])
        XCTAssertEqual(problems("number:\n  style: Period"),
                       ["Front-matter 'number.style' must be 'period', 'space', or 'parenthesis', not 'Period'"])
        XCTAssertEqual(problems("number:\n  generated: 'yes'"),
                       ["Front-matter 'number.generated' must be true or false, not 'yes'"])
        XCTAssertEqual(problems("number: {skip-title: maybe}"),
                       ["Front-matter 'number.skip-title' must be true or false, not 'maybe'"])
        XCTAssertNil(read("---\nnumber:\n  styel: space\n---\n")?.settings)
    }

    // MARK: What mdship update will think

    private func messages(_ text: String) -> [String] {
        PlaceholderValidator.validate(text: text, scan: PlaceholderScanner.scan(text), documentURL: nil)
            .issues.map(\.message)
    }

    /// An INCLUDE whose content mdship recorded, as `mdship update` writes it.
    private func include(_ body: String, recordedAs recorded: String? = nil) -> String {
        let signed = recorded ?? body
        let hash = Insecure.MD5.hash(data: Data(signed.utf8)).map { String(format: "%02x", $0) }.joined()
        return "<!--INCLUDE\nfrom: inc.md\n_content_generated_: \(body.unicodeScalars.count):md5:\(hash)\n-->"
            + body + "<!--/INCLUDE-->\n"
    }

    func testBadValueIsAnError() {
        XCTAssertEqual(messages("---\nnumber:\n  style: roman\n---\n# T\n"),
                       ["Line 3: Front-matter 'number.style' must be 'period', 'space', or 'parenthesis', not 'roman'"])
    }

    func testSkipTitleWithTwoTitlesIsAnError() {
        XCTAssertEqual(messages("---\nnumber:\n  skip-title: true\n---\n# One\n# Two\n"),
                       ["Line 3: --skip-title requires exactly one h1 heading, but found 2"])
    }

    func testNumberingGeneratedContentNeedsGenerated() {
        let body = "# Title\n\n" + include("\n## Inc\n") + "\n## After\n"
        XCTAssertEqual(messages("---\nnumber: true\n---\n" + body),
                       ["Line 6: heading numbering would change the generated content of the INCLUDE placeholder. Set 'generated: true' under the front-matter 'number:' key to let numbering update generated content and its checksum."])
        XCTAssertEqual(messages("---\nnumber:\n  generated: true\n---\n" + body), [])
        // Without number:, nothing is renumbered, so nothing can be refused.
        XCTAssertEqual(messages("---\ntitle: x\n---\n" + body), [])
    }

    func testAlreadyNumberedGeneratedContentIsFine() {
        let body = "# 1. Title\n\n" + include("\n## 1.1. Inc\n") + "\n## 1.2. After\n"
        XCTAssertEqual(messages("---\nnumber: true\n---\n" + body), [])
        XCTAssertEqual(messages("---\nnumber: false\n---\n" + body).count, 1)
    }

    func testHandEditedGeneratedContentIsNotResigned() {
        let text = "---\nnumber:\n  generated: true\n---\n# Title\n\n" + include("\n## Edited\n", recordedAs: "\n## Inc!!\n")
        XCTAssertTrue(messages(text).contains(
            "Line 7: INCLUDE placeholder content was manually edited. Hash mismatch detected, so numbering will not recalculate its checksum. Delete _content_generated_ line to override and accept data loss."))
    }

    // MARK: Completion

    private func labels(_ textWithCaret: String, explicit: Bool = true) -> [String] {
        let caret = (textWithCaret as NSString).range(of: "|").location
        let text = textWithCaret.replacingOccurrences(of: "|", with: "")
        return CompletionProvider.completions(in: text, at: caret, documentURL: nil, explicit: explicit)?.items.map(\.label) ?? []
    }

    func testCompletesTheKeyItsOptionsAndValues() {
        XCTAssertEqual(labels("---\nnum|\n---\n", explicit: false), ["number"])
        XCTAssertEqual(labels("---\ntitle: x\n|\n---\n"), ["number"])
        XCTAssertEqual(labels("---\nnumber: true\n|\n---\n"), [])
        XCTAssertEqual(labels("---\nti|\n---\n", explicit: false), [])
        XCTAssertEqual(labels("---\nnumber: |\n---\n"), ["true", "false", "options…"])
        XCTAssertEqual(labels("---\nnumber: t|\n---\n"), ["true"])
        XCTAssertEqual(labels("---\nnumber:\n  |\n---\n"), ["style", "skip-title", "generated", "post-process"])
        XCTAssertEqual(labels("---\nnumber:\n  style: space\n  |\n---\n"), ["skip-title", "generated", "post-process"])
        XCTAssertEqual(labels("---\nnumber:\n  style: |\n---\n"), ["period", "space", "parenthesis"])
        XCTAssertEqual(labels("---\nnumber:\n  post-process: t|\n---\n"), ["true"])
        XCTAssertEqual(labels("---\nauthor:\n  |\n---\n"), [])
    }

    /// Choosing `number`, then "options…", must land on a line whose suggestions
    /// are the options -- the mapping form is reachable without knowing it exists.
    func testOptionsAreReachableFromTheKey() throws {
        func accept(_ label: String, in textWithCaret: String) throws -> String {
            let caret = (textWithCaret as NSString).range(of: "|").location
            let text = textWithCaret.replacingOccurrences(of: "|", with: "")
            let list = try XCTUnwrap(CompletionProvider.completions(in: text, at: caret, documentURL: nil, explicit: true))
            let item = try XCTUnwrap(list.items.first { $0.label == label })
            XCTAssertTrue(item.continues, label)
            // The caret goes where the insertion's markers are.
            let insertion = item.insertion.replacingOccurrences(of: "\u{1}", with: "|").replacingOccurrences(of: "\u{2}", with: "")
            return (text as NSString).replacingCharacters(in: list.range, with: insertion)
        }
        let afterKey = try accept("number", in: "---\nnum|\n---\n")
        XCTAssertEqual(afterKey, "---\nnumber: |\n---\n")
        let afterOptions = try accept("options…", in: afterKey)
        XCTAssertEqual(afterOptions, "---\nnumber: \n  |\n---\n")
        XCTAssertEqual(labels(afterOptions), ["style", "skip-title", "generated", "post-process"])
    }

    func testFrontMatterCompletionStaysInTheFrontMatter() {
        XCTAssertEqual(labels("---\nnumber: true\n---\nnum|\n", explicit: false), [])
    }
}
