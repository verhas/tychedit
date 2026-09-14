import XCTest
@testable import Tychedit

/// The renderer is not trying to be a conformance suite; these pin down the
/// constructs documents rely on and the cases that are easy to get wrong.
final class MarkdownRendererTests: XCTestCase {

    private func html(_ markdown: String) -> String {
        MarkdownRenderer.render(markdown).html
    }

    private func inline(_ markdown: String) -> String {
        InlineRenderer().render(markdown)
    }

    // MARK: Inline

    func testEmphasis() {
        XCTAssertEqual(inline("*a* _b_ **c** __d__"), "<em>a</em> <em>b</em> <strong>c</strong> <strong>d</strong>")
        XCTAssertEqual(inline("***both***"), "<em><strong>both</strong></em>")
        XCTAssertEqual(inline("**bold *and italic* text**"), "<strong>bold <em>and italic</em> text</strong>")
        XCTAssertEqual(inline("~~gone~~"), "<del>gone</del>")
    }

    func testIntrawordUnderscoresStayLiteral() {
        XCTAssertEqual(inline("snake_case_name and 2*3*4"), "snake_case_name and 2<em>3</em>4")
    }

    func testUnmatchedDelimitersAreText() {
        XCTAssertEqual(inline("a * b"), "a * b")
        XCTAssertEqual(inline("**open"), "**open")
    }

    func testCodeSpansAreLiteral() {
        XCTAssertEqual(inline("`a *b* <c>`"), "<code>a *b* &lt;c&gt;</code>")
        XCTAssertEqual(inline("`` a ` b ``"), "<code>a ` b</code>")
        XCTAssertEqual(inline("`unclosed"), "`unclosed")
    }

    func testLinksAndImages() {
        XCTAssertEqual(inline("[a *b*](http://x.y \"T\")"), "<a href=\"http://x.y\" title=\"T\">a <em>b</em></a>")
        XCTAssertEqual(inline("![alt](img/p.png)"), "<img src=\"img/p.png\" alt=\"alt\">")
        XCTAssertEqual(inline("[x](<a b.md>)"), "<a href=\"a%20b.md\">x</a>")
        XCTAssertEqual(inline("[x](f(1).md)"), "<a href=\"f(1).md\">x</a>")
        XCTAssertEqual(inline("[not a link]"), "[not a link]")
    }

    func testReferenceLinks() {
        let result = html("See [the site][s] and [s].\n\n[s]: https://example.com \"Example\"\n")
        XCTAssertTrue(result.contains("<a href=\"https://example.com\" title=\"Example\">the site</a>"))
        XCTAssertTrue(result.contains("<a href=\"https://example.com\" title=\"Example\">s</a>"))
        XCTAssertFalse(result.contains("[s]:"))
    }

    func testAutolinks() {
        XCTAssertEqual(inline("<https://a.b/c>"), "<a href=\"https://a.b/c\">https://a.b/c</a>")
        XCTAssertEqual(inline("visit https://a.b/c."), "visit <a href=\"https://a.b/c\">https://a.b/c</a>.")
        XCTAssertEqual(inline("(see https://a.b/c)"), "(see <a href=\"https://a.b/c\">https://a.b/c</a>)")
    }

    func testEscapingAndEntities() {
        XCTAssertEqual(inline("a < b & c \\*d\\*"), "a &lt; b &amp; c *d*")
        XCTAssertEqual(inline("&copy; &#169;"), "&copy; &#169;")
        XCTAssertEqual(inline("<kbd>K</kbd>"), "<kbd>K</kbd>")
    }

    func testHardBreaks() {
        XCTAssertEqual(inline("a  \nb"), "a<br>\nb")
        XCTAssertEqual(inline("a\\\nb"), "a<br>\nb")
        XCTAssertEqual(inline("a \nb"), "a\nb")
    }

    func testCommentsAreHiddenButVariablesAreLabelled() {
        XCTAssertEqual(inline("a<!-- note -->b"), "ab")
        XCTAssertEqual(inline("v<!--$version-->1.2"),
                       "v<span class=\"mds-var\" title=\"Variable $version: mdship update replaces the value that follows\">$version</span>1.2")
        let marked = inline("<!--$name<M>-->Ann Lee<!--M--> x")
        XCTAssertTrue(marked.contains("$name</span>Ann Lee<span class=\"mds-var-end\"></span> x"))
    }

    // MARK: Blocks

    func testHeadingsGetMdshipAnchors() {
        let result = MarkdownRenderer.render("# 1.4.7. Template Placeholders\n\n## Café crème\n\n## Café crème\n")
        XCTAssertEqual(result.headings.map(\.anchor), ["147-template-placeholders", "caf-crme", "caf-crme-1"])
        XCTAssertEqual(result.headings.map(\.line), [0, 2, 4])
        XCTAssertTrue(result.html.contains("<h1 id=\"147-template-placeholders\" data-line=\"0\">"))
    }

    func testSetextHeadings() {
        let result = MarkdownRenderer.render("Title\n=====\n\nSub\n---\n")
        XCTAssertEqual(result.headings.map(\.level), [1, 2])
    }

    func testParagraphsCarryTheirSourceLine() {
        XCTAssertEqual(html("one\ntwo\n\nthree"), "<p data-line=\"0\">one\ntwo</p>\n<p data-line=\"3\">three</p>\n")
    }

    func testFencedCode() {
        XCTAssertEqual(html("```swift\nlet a = 1 < 2\n```\n"),
                       "<pre data-line=\"0\"><code class=\"language-swift\">let a = 1 &lt; 2\n</code></pre>\n")
    }

    func testTightAndLooseLists() {
        let tight = html("- a\n- b\n")
        XCTAssertTrue(tight.contains("<li data-line=\"0\">a\n</li>"))
        let loose = html("- a\n\n- b\n")
        XCTAssertTrue(loose.contains("<li data-line=\"0\"><p data-line=\"0\">a</p>"))
    }

    func testNestedAndOrderedLists() {
        let result = html("3. one\n   - inner\n4. two\n")
        XCTAssertTrue(result.hasPrefix("<ol start=\"3\" data-line=\"0\">"))
        XCTAssertTrue(result.contains("<ul data-line=\"1\">"))
        XCTAssertTrue(result.contains("inner"))
    }

    func testTaskList() {
        let result = html("- [ ] todo\n- [x] done\n")
        XCTAssertTrue(result.contains("<input type=\"checkbox\" disabled> todo"))
        XCTAssertTrue(result.contains("<input type=\"checkbox\" checked disabled> done"))
    }

    func testListNumberInsideParagraphIsNotAList() {
        XCTAssertFalse(html("The year was\n2024. It rained.").contains("<ol"))
    }

    func testTable() {
        let result = html("| a | b |\n|:--|--:|\n| 1 | `x|y` |\n")
        XCTAssertTrue(result.contains("<th style=\"text-align:left\">a</th><th style=\"text-align:right\">b</th>"))
        XCTAssertTrue(result.contains("<td style=\"text-align:right\"><code>x|y</code></td>"))
    }

    func testBlockquote() {
        XCTAssertTrue(html("> quoted\ncontinued\n").contains("<blockquote data-line=\"0\">\n<p data-line=\"0\">quoted\ncontinued</p>"))
    }

    func testRawHTMLBlockPassesThrough() {
        XCTAssertTrue(html("<div align=\"center\">\n<b>x</b>\n</div>\n").contains("<div align=\"center\">\n<b>x</b>\n</div>"))
    }

    // MARK: Placeholders in the preview

    func testPairedPlaceholderRendersAsCardAroundItsContent() throws {
        let url = try XCTUnwrap(Bundle(for: MarkdownRendererTests.self).url(forResource: "mdship-updated", withExtension: "md"))
        let result = MarkdownRenderer.render(try String(contentsOf: url, encoding: .utf8))
        XCTAssertTrue(result.html.contains("<section class=\"mds-ph mds-kind-toc\" data-line=\"2\">"))
        XCTAssertTrue(result.html.contains("<span class=\"mds-badge\">INCLUDE</span> <span class=\"mds-summary\">from: snippet.txt</span>"))
        XCTAssertTrue(result.html.contains("<span class=\"mds-state mds-ok\">generated</span>"))
        // The generated TOC inside the card is rendered as a list with working anchors.
        XCTAssertTrue(result.html.contains("<a href=\"#caf-crme\">Café crème</a>"))
        XCTAssertTrue(result.html.contains("<div class=\"mds-body\"><p data-line=\"20\">line one\nline two — ünïcode</p>"))
        // The configuration is shown, not the raw comment hidden.
        XCTAssertTrue(result.html.contains("<pre class=\"mds-config\">from: &quot;snippet.txt&quot;"))
    }

    func testSelfContainedPlaceholderIsMarkedForHidingInReaderView() {
        let result = html("<!--SET\na: 1\n-->\nText\n")
        XCTAssertTrue(result.hasPrefix("<section class=\"mds-ph mds-kind-set mds-self\" data-line=\"0\">"))
        XCTAssertTrue(result.contains("<p data-line=\"3\">Text</p>"))
    }

    func testUnclosedPlaceholderIsFlaggedAndTheRestStillRenders() {
        let result = html("<!--INCLUDE\nfrom: x\n-->\n# After\n")
        XCTAssertTrue(result.contains("mds-problem"))
        XCTAssertTrue(result.contains("unclosed: expected &lt;!--/INCLUDE--&gt;"))
        XCTAssertTrue(result.contains("<h1 id=\"after\" data-line=\"3\">After</h1>"))
    }

    func testPlaceholderExampleInCodeIsJustCode() {
        let result = html("```\n<!--SET\na: 1\n-->\n```\n")
        XCTAssertFalse(result.contains("mds-ph"))
        XCTAssertTrue(result.contains("&lt;!--SET"))
    }

    func testCardKeysAreStablePerKind() {
        let result = html("<!--SET\na: 1\n-->\n\n<!--SET\nb: 2\n-->\n")
        XCTAssertTrue(result.contains("data-key=\"SET-0\""))
        XCTAssertTrue(result.contains("data-key=\"SET-1\""))
    }

    func testVariableAtStartOfLineIsNotHiddenAsCommentBlock() {
        XCTAssertTrue(html("<!--$appName-->MyApp\n").contains("$appName</span>MyApp"))
    }

    func testFrontMatter() {
        let result = html("---\ntitle: X\n---\n# Doc\n")
        XCTAssertTrue(result.contains("mds-frontmatter"))
        XCTAssertTrue(result.contains("<h1 id=\"doc\" data-line=\"3\">"))
    }
}
