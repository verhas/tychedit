import AppKit

/// Owns the editing text view and every command that changes or moves in it.
///
/// AppKit's NSTextView rather than SwiftUI's TextEditor: it brings the find
/// and replace bar, the full set of macOS text navigation keys, undo, and --
/// for the later version -- attribute-based colouring, none of which
/// TextEditor exposes.
///
/// One per window, created with the model, so a file opened before the window
/// appears still has somewhere to go.
@MainActor
final class EditorController: NSObject {

    let scrollView: NSScrollView
    let textView: EditorTextView

    /// The user changed the text. Not called for `setText`.
    var onTextChange: ((String) -> Void)?
    var onSelectionChange: (() -> Void)?
    /// The editor scrolled: the fractional source line at the top, and whether
    /// the view is scrolled to the very end.
    var onScroll: ((Double, Bool) -> Void)?
    /// Command-click at a character index; true when it led somewhere.
    var onCommandClick: ((Int) -> Bool)?
    /// Suggestions for the caret at an offset; the flag says whether they were asked for.
    var completionSource: ((Int, Bool) -> CompletionList?)?

    private let popup = CompletionPopup()
    private var activeCompletions: CompletionList?
    private var typedCharacter = false

    // Gutter and folding; see EditorFolding.swift.
    private(set) var gutter: EditorGutter!
    var lineChanges = LineChanges.none
    var foldRegions: [FoldRegion] = []
    var regionsByFirstLine: [Int: [FoldRegion]] = [:]
    /// Folded regions by key, with where each currently is.
    var foldedKeys: [FoldRegion.Key: FoldedRange] = [:]
    /// Badge text by the location where each merged fold starts.
    var badgeLabels: [Int: String] = [:]
    /// The union of the folded ranges, sorted and non-overlapping, for fast lookup.
    var hiddenRanges: [NSRange] = []
    /// While the whole text is replaced, edits do not unfold anything.
    var replacingEverything = false

    private var cachedLineIndex: LineIndex?
    private var styleAttributes: [TextStyle: [NSAttributedString.Key: Any]] = [:]
    private var styleIDs: [TextStyle: Int] = [:]
    var lastStyleRuns: [StyleRun] = []
    private var font: NSFont

    init(fontSize: Double) {
        font = EditorController.font(size: fontSize)

        // TextKit 1, built by hand. NSTextView's convenience initialisers give
        // TextKit 2 now, whose layout queries -- which line is at the top of the
        // view, where is line 400 -- are asynchronous and approximate, and both
        // scroll sync and Go to Line depend on exact answers.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        // Contiguous layout: every position is exact. With non-contiguous layout
        // the lines above the visible area are estimated, and the gutter, fold
        // badges and scroll sync drew at the estimates while the text was drawn
        // at the corrected positions -- several lines apart around long wrapped paragraphs.
        layoutManager.allowsNonContiguousLayout = false
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        textView = EditorTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        scrollView = NSScrollView()
        super.init()
        textView.controller = self
        // Folding hides glyphs as they are generated, and follows edits.
        layoutManager.delegate = self
        storage.delegate = self

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 10, height: 12)

        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        // Every one of these would quietly corrupt a placeholder: smart quotes
        // break its YAML, a smart dash turns `-->` into `–>` and leaves the
        // comment open, and autocorrect "fixes" variable names.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isContinuousSpellCheckingEnabled = false

        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .textColor
        textView.font = font
        textView.typingAttributes = attributes
        textView.delegate = self

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.findBarPosition = .aboveContent

        gutter = EditorGutter(scrollView: scrollView, controller: self)
        scrollView.verticalRulerView = gutter
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    private static func font(size: Double) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Plain text: what typing and inserted text start as, until the next
    /// styling pass gives it its markdown style.
    var attributes: [NSAttributedString.Key: Any] {
        attributes(for: .plain)
    }

    // MARK: - Text

    var text: String { textView.string }

    var nsText: NSString { textView.string as NSString }

    var lineIndex: LineIndex {
        if let cachedLineIndex { return cachedLineIndex }
        let index = LineIndex(nsText)
        cachedLineIndex = index
        return index
    }

    /// Replaces everything, as when a file is opened: no undo, caret at the top.
    func setText(_ text: String) {
        // A different text: nothing folded carries over.
        foldedKeys.removeAll()
        replacingEverything = true
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        replacingEverything = false
        cachedLineIndex = nil
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        onSelectionChange?()
    }

    /// Replaces everything as one undoable edit, keeping the caret and the
    /// scroll position as close as the new text allows. For a file that changed
    /// on disk: the reload can be undone like any other change.
    func replaceAll(with text: String, actionName: String) {
        let selection = textView.selectedRange()
        let visible = scrollView.contentView.bounds.origin
        // The same document, rewritten: folds are kept by key and come back
        // when the new text has been analysed.
        replacingEverything = true
        replace(NSRange(location: 0, length: nsText.length), with: text, selecting: nil, actionName: actionName)
        replacingEverything = false
        let length = nsText.length
        let location = min(selection.location, length)
        textView.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        scrollView.contentView.scroll(to: visible)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func setFontSize(_ size: Double) {
        font = EditorController.font(size: size)
        textView.font = font
        // Every style's font is derived from this one: build them again.
        styleAttributes.removeAll()
        styleIDs.removeAll()
        if let storage = textView.textStorage {
            storage.removeAttribute(EditorController.styleKey, range: NSRange(location: 0, length: storage.length))
        }
        let runs = lastStyleRuns
        applyStyles(runs.isEmpty ? [StyleRun(range: NSRange(location: 0, length: nsText.length), style: .plain)] : runs)
        textView.typingAttributes = attributes
    }

    // MARK: - Styling

    /// Marks each run with the id of the style it was given, so a later pass
    /// can tell which runs already look right.
    static let styleKey = NSAttributedString.Key("TycheditStyle")

    /// Gives the text its markdown styling. Only runs whose style differs from
    /// what they already have are touched, so typing in plain text lays out
    /// nothing again; a style that no longer applies is replaced by the plain
    /// run covering those characters.
    func applyStyles(_ runs: [StyleRun]) {
        guard let storage = textView.textStorage else { return }
        lastStyleRuns = runs
        let length = storage.length
        var editing = false
        for run in runs where run.range.length > 0 && NSMaxRange(run.range) <= length {
            let id = styleID(for: run.style)
            var effective = NSRange()
            if let current = storage.attribute(EditorController.styleKey, at: run.range.location,
                                               longestEffectiveRange: &effective, in: run.range) as? Int,
               current == id, NSEqualRanges(effective, run.range) {
                continue
            }
            if !editing {
                storage.beginEditing()
                editing = true
            }
            storage.setAttributes(attributes(for: run.style), range: run.range)
        }
        if editing { storage.endEditing() }
    }

    private func styleID(for style: TextStyle) -> Int {
        if let id = styleIDs[style] { return id }
        let id = styleIDs.count + 1
        styleIDs[style] = id
        return id
    }

    func attributes(for style: TextStyle) -> [NSAttributedString.Key: Any] {
        if let cached = styleAttributes[style] { return cached }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.15
        if style.heading > 0 {
            // Headings stand out with some room above them too.
            paragraph.paragraphSpacingBefore = font.pointSize * 0.3
        }
        var result: [NSAttributedString.Key: Any] = [
            .font: styledFont(style),
            .foregroundColor: EditorController.color(style.color),
            .paragraphStyle: paragraph,
            EditorController.styleKey: styleID(for: style),
        ]
        if style.strike {
            result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        styleAttributes[style] = result
        return result
    }

    private func styledFont(_ style: TextStyle) -> NSFont {
        let scales: [CGFloat] = [1.0, 1.6, 1.4, 1.22, 1.1, 1.04, 1.0]
        let size = font.pointSize * scales[min(max(style.heading, 0), 6)]
        var styled = NSFont.monospacedSystemFont(ofSize: size, weight: style.bold ? .bold : .regular)
        if style.italic {
            let italic = NSFontManager.shared.convert(styled, toHaveTrait: .italicFontMask)
            if NSFontManager.shared.traits(of: italic).contains(.italicFontMask) {
                styled = italic
            } else {
                // No italic face: slant the regular one.
                let matrix = AffineTransform(m11: 1, m12: 0, m21: 0.2, m22: 1, tX: 0, tY: 0)
                let descriptor = styled.fontDescriptor.withMatrix(matrix)
                styled = NSFont(descriptor: descriptor, size: size) ?? styled
            }
        }
        return styled
    }

    private static func color(_ color: TextStyle.Color) -> NSColor {
        switch color {
        case .text: .textColor
        case .code: .systemGray
        case .comment: .tertiaryLabelColor
        case .placeholder: .systemPurple
        case .placeholderKey: .systemIndigo
        case .variable: .systemTeal
        }
    }

    func focus() {
        textView.window?.makeFirstResponder(textView)
    }

    // MARK: - Positions

    var selectedRange: NSRange { textView.selectedRange() }

    /// Selects `range`, scrolls it into the middle of the view, and focuses the editor.
    func select(_ range: NSRange) {
        let length = nsText.length
        let location = min(max(0, range.location), length)
        let clamped = NSRange(location: location, length: min(range.length, length - location))
        textView.setSelectedRange(clamped)
        scrollToCenter(clamped)
        focus()
    }

    /// Moves the caret to the start of zero-based `line`.
    func goToLine(_ line: Int) {
        let index = lineIndex
        let target = min(max(0, line), index.count - 1)
        select(NSRange(location: index.starts[target], length: 0))
    }

    private func scrollToCenter(_ range: NSRange) {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else {
            textView.scrollRangeToVisible(range)
            return
        }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.y += textView.textContainerOrigin.y
        let visible = scrollView.contentView.bounds
        // Already comfortably in view: leave the view where it is, so stepping
        // through nearby matches does not make the text jump.
        let comfort = visible.insetBy(dx: 0, dy: visible.height * 0.15)
        if comfort.contains(NSPoint(x: comfort.midX, y: rect.midY)) { return }
        let y = max(0, min(rect.midY - visible.height / 2, textView.frame.height - visible.height))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// The fractional line at the top of the view, and whether it is scrolled to the end.
    func visiblePosition() -> (line: Double, atEnd: Bool) {
        let visible = scrollView.contentView.bounds
        let atEnd = visible.minY > 0 && visible.maxY >= textView.frame.height - 2
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else {
            return (0, atEnd)
        }
        let y = visible.minY - textView.textContainerOrigin.y
        guard y > 0, nsText.length > 0 else { return (0, atEnd) }

        let glyph = layoutManager.glyphIndex(for: NSPoint(x: 0, y: y), in: container)
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        let index = lineIndex
        let line = index.line(containing: character)
        // How far into the line the top of the view is, since a long paragraph
        // wraps into many visual lines.
        let glyphs = layoutManager.glyphRange(forCharacterRange: index.fullRange(ofLine: line), actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        let fraction = rect.height > 0 ? min(1, max(0, (y - rect.minY) / rect.height)) : 0
        return (Double(line) + fraction, atEnd)
    }

    @objc private func boundsDidChange(_ notification: Notification) {
        let position = visiblePosition()
        onScroll?(position.line, position.atEnd)
        gutter.needsDisplay = true
    }

    // MARK: - Find

    /// Sends a find bar action to the editor. The action is read from the
    /// sender's tag, which is how AppKit's own Find menu items talk to a text view.
    func performFind(_ action: NSTextFinder.Action) {
        focus()
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        textView.performTextFinderAction(sender)
    }

    // MARK: - Editing commands

    /// Every command edit goes through here, so it is undoable, named in the
    /// Edit menu, and reported like typing.
    @discardableResult
    private func replace(_ range: NSRange, with string: String, selecting selection: NSRange?, actionName: String) -> Bool {
        guard textView.shouldChangeText(in: range, replacementString: string) else { return false }
        textView.breakUndoCoalescing()
        textView.textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: string, attributes: attributes))
        textView.didChangeText()
        textView.undoManager?.setActionName(actionName)
        if let selection {
            textView.setSelectedRange(selection)
            textView.scrollRangeToVisible(selection)
        }
        return true
    }

    /// Wraps the selection in `marker` -- or unwraps it, if it is already wrapped.
    /// With no selection, inserts a sample and selects it for typing over.
    func toggleWrap(_ marker: String, sample: String, actionName: String) {
        let selection = selectedRange
        let text = nsText
        let m = (marker as NSString).length

        if selection.length == 0 {
            let inserted = marker + sample + marker
            replace(selection, with: inserted,
                    selecting: NSRange(location: selection.location + m, length: (sample as NSString).length),
                    actionName: actionName)
            return
        }

        let selected = text.substring(with: selection)
        // The selection includes the markers.
        if selection.length >= 2 * m, selected.hasPrefix(marker), selected.hasSuffix(marker) {
            let inner = (selected as NSString).substring(with: NSRange(location: m, length: selection.length - 2 * m))
            replace(selection, with: inner,
                    selecting: NSRange(location: selection.location, length: (inner as NSString).length),
                    actionName: actionName)
            return
        }
        // The markers sit just outside the selection.
        if selection.location >= m, NSMaxRange(selection) + m <= text.length,
           text.substring(with: NSRange(location: selection.location - m, length: m)) == marker,
           text.substring(with: NSRange(location: NSMaxRange(selection), length: m)) == marker {
            let outer = NSRange(location: selection.location - m, length: selection.length + 2 * m)
            replace(outer, with: selected,
                    selecting: NSRange(location: outer.location, length: selection.length),
                    actionName: actionName)
            return
        }
        replace(selection, with: marker + selected + marker,
                selecting: NSRange(location: selection.location + m, length: selection.length),
                actionName: actionName)
    }

    /// `[selection](url)` with `url` selected, or `[text](url)` with `text` selected.
    func insertLink() {
        let selection = selectedRange
        if selection.length > 0 {
            let selected = nsText.substring(with: selection)
            let inserted = "[\(selected)](url)"
            let urlStart = selection.location + (selected as NSString).length + 3
            replace(selection, with: inserted, selecting: NSRange(location: urlStart, length: 3), actionName: "Insert Link")
        } else {
            replace(selection, with: "[text](url)", selecting: NSRange(location: selection.location + 1, length: 4),
                    actionName: "Insert Link")
        }
    }

    /// The lines the selection touches. A selection ending at the very start of
    /// a line does not include that line -- which is what selecting whole
    /// lines by dragging produces.
    private var selectedLines: ClosedRange<Int> {
        let index = lineIndex
        let selection = selectedRange
        let first = index.line(containing: selection.location)
        var last = index.line(containing: NSMaxRange(selection))
        if selection.length > 0, last > first, index.starts[last] == NSMaxRange(selection) {
            last -= 1
        }
        return first...last
    }

    /// The text of lines `lines`, from the first line's start to the last
    /// line's end, newline excluded.
    private func contentRange(of lines: ClosedRange<Int>) -> NSRange {
        let index = lineIndex
        let start = index.starts[lines.lowerBound]
        let end = NSMaxRange(index.contentRange(ofLine: lines.upperBound))
        return NSRange(location: start, length: end - start)
    }

    static let indentUnit = "    "

    func shiftLines(right: Bool) {
        let lines = selectedLines
        let range = contentRange(of: lines)
        let original = nsText.substring(with: range).components(separatedBy: "\n")
        let shifted = original.map { line -> String in
            if right {
                return line.isEmpty ? line : EditorController.indentUnit + line
            }
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            let spaces = min(EditorController.indentUnit.count, line.prefix { $0 == " " }.count)
            return String(line.dropFirst(spaces))
        }
        let replacement = shifted.joined(separator: "\n")
        guard replacement != nsText.substring(with: range) else { return }
        replace(range, with: replacement,
                selecting: NSRange(location: range.location, length: (replacement as NSString).length),
                actionName: right ? "Shift Right" : "Shift Left")
    }

    func moveLines(up: Bool) {
        let lines = selectedLines
        let index = lineIndex
        let selection = selectedRange
        if up {
            guard lines.lowerBound > 0 else { return }
            let range = contentRange(of: (lines.lowerBound - 1)...lines.upperBound)
            var parts = nsText.substring(with: range).components(separatedBy: "\n")
            let above = parts.removeFirst()
            parts.append(above)
            let shift = (above as NSString).length + 1
            replace(range, with: parts.joined(separator: "\n"),
                    selecting: NSRange(location: selection.location - shift, length: selection.length),
                    actionName: "Move Line Up")
        } else {
            guard lines.upperBound + 1 < index.count else { return }
            let range = contentRange(of: lines.lowerBound...(lines.upperBound + 1))
            var parts = nsText.substring(with: range).components(separatedBy: "\n")
            let below = parts.removeLast()
            parts.insert(below, at: 0)
            let shift = (below as NSString).length + 1
            replace(range, with: parts.joined(separator: "\n"),
                    selecting: NSRange(location: selection.location + shift, length: selection.length),
                    actionName: "Move Line Down")
        }
    }

    func duplicateLines() {
        let range = contentRange(of: selectedLines)
        let block = nsText.substring(with: range)
        let selection = selectedRange
        let shift = (block as NSString).length + 1
        replace(NSRange(location: NSMaxRange(range), length: 0), with: "\n" + block,
                selecting: NSRange(location: selection.location + shift, length: selection.length),
                actionName: "Duplicate Line")
    }

    func deleteLines() {
        let lines = selectedLines
        let index = lineIndex
        var range = index.fullRange(ofLines: lines)
        // The last line has no newline of its own; take the one before it instead.
        if lines.upperBound == index.count - 1, lines.lowerBound > 0 {
            range = NSRange(location: range.location - 1, length: range.length + 1)
        }
        guard range.length > 0 else { return }
        replace(range, with: "", selecting: NSRange(location: range.location, length: 0), actionName: "Delete Line")
    }

    /// Inserts a snippet. `\u{1}` and `\u{2}` mark the part to select afterwards.
    ///
    /// A block snippet -- a placeholder comment -- must start a line, so it
    /// replaces the current line when that line is blank and goes on a new
    /// line below it otherwise.
    func insertSnippet(_ snippet: String, block: Bool, actionName: String) {
        var target = selectedRange
        var prefix = ""
        if block {
            let index = lineIndex
            let line = index.line(containing: target.location)
            let content = index.contentRange(ofLine: line)
            if nsText.substring(with: content).trimmingCharacters(in: .whitespaces).isEmpty {
                target = content
            } else {
                target = NSRange(location: NSMaxRange(content), length: 0)
                prefix = "\n"
            }
        }
        insert(prefix + snippet, replacing: target, actionName: actionName)
        focus()
    }

    /// Replaces `range` with `snippet`, selecting what `\u{1}`...`\u{2}` mark,
    /// or putting the caret after the text when nothing is marked.
    func insert(_ snippet: String, replacing range: NSRange, actionName: String) {
        let clean = snippet.replacingOccurrences(of: "\u{1}", with: "").replacingOccurrences(of: "\u{2}", with: "")
        let selection: NSRange
        if snippet.contains("\u{1}") {
            let start = (snippet.components(separatedBy: "\u{1}")[0] as NSString).length
            let end = ((snippet.components(separatedBy: "\u{2}").first ?? snippet)
                .replacingOccurrences(of: "\u{1}", with: "") as NSString).length
            selection = NSRange(location: range.location + start, length: max(0, end - start))
        } else {
            selection = NSRange(location: range.location + (clean as NSString).length, length: 0)
        }
        replace(range, with: clean, selecting: selection, actionName: actionName)
    }

    // MARK: - Problems

    /// Marks the text each problem is about: a thick underline and a light tint
    /// behind it -- a thin dotted line alone was too easy to miss. Temporary
    /// attributes change how the text is drawn, not the text, so they never
    /// reach the file or the undo history.
    func showDiagnostics(_ issues: [PlaceholderIssue]) {
        guard let layoutManager = textView.layoutManager else { return }
        let length = nsText.length
        let whole = NSRange(location: 0, length: length)
        for key in [NSAttributedString.Key.underlineStyle, .underlineColor, .backgroundColor] {
            layoutManager.removeTemporaryAttribute(key, forCharacterRange: whole)
        }
        let style = NSUnderlineStyle.thick.rawValue
        for issue in issues {
            var range = issue.range
            guard range.location < length else { continue }
            if range.length == 0 { range.length = 1 }
            range.length = min(range.length, length - range.location)
            let color: NSColor = issue.severity == .error ? .systemRed : .systemOrange
            layoutManager.addTemporaryAttributes([
                .underlineStyle: style,
                .underlineColor: color,
                .backgroundColor: color.withAlphaComponent(0.16),
            ], forCharacterRange: range)
        }
    }

    // MARK: - Completion

    /// Shows the suggestions for the caret, if there are any. `explicit` when
    /// asked for (Escape, Option-Escape) rather than prompted by typing.
    @discardableResult
    func showCompletions(explicit: Bool) -> Bool {
        let selection = selectedRange
        guard selection.length == 0, !textView.hasMarkedText(),
              let list = completionSource?(selection.location, explicit), !list.items.isEmpty else {
            hideCompletions()
            return false
        }
        activeCompletions = list
        let anchor = textView.firstRect(forCharacterRange: NSRange(location: list.range.location, length: 0), actualRange: nil)
        popup.show(list.items, below: anchor, in: textView.window) { [weak self] item in
            self?.accept(item)
        }
        return true
    }

    func hideCompletions() {
        activeCompletions = nil
        popup.hide()
    }

    private func accept(_ item: CompletionItem) {
        guard let list = activeCompletions else { return }
        let caret = selectedRange.location
        let range = NSRange(location: list.range.location, length: max(0, caret - list.range.location))
        hideCompletions()
        insert(item.insertion, replacing: range, actionName: "Complete")
        textView.window?.makeKey()
        focus()
        if item.continues {
            showCompletions(explicit: true)
        }
    }
}

/// The editing view: NSTextView plus Command-click to follow references and
/// the completion request routed to placeholder suggestions.
final class EditorTextView: NSTextView {

    weak var controller: EditorController?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let controller, controller.unfoldBadge(at: point) {
            return
        }
        if event.modifierFlags.contains(.command), event.clickCount == 1, let controller {
            let index = characterIndexForInsertion(at: point)
            if controller.onCommandClick?(index) == true { return }
        }
        super.mouseDown(with: event)
    }

    /// Escape and Option-Escape ask for completions. Inside a placeholder they
    /// get parameter suggestions; elsewhere, AppKit's word completion.
    override func complete(_ sender: Any?) {
        if controller?.showCompletions(explicit: true) != true {
            super.complete(sender)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        controller?.drawFoldBadges(in: dirtyRect)
    }

    override func resignFirstResponder() -> Bool {
        controller?.hideCompletions()
        return super.resignFirstResponder()
    }
}

extension EditorController: NSTextViewDelegate {

    /// Typed text starts plain rather than taking on the style of the character
    /// before it -- a heading's size, a code span's grey -- until it is styled.
    func textView(_ textView: NSTextView, shouldChangeTypingAttributes oldTypingAttributes: [String: Any],
                  toAttributes newTypingAttributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        attributes
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        // A single typed character -- or a deletion while the list is up --
        // refreshes the suggestions once the change has happened.
        if let replacement = replacementString {
            typedCharacter = (replacement.count == 1 && replacement != "\n") || (replacement.isEmpty && popup.isVisible)
        }
        return true
    }

    func textDidChange(_ notification: Notification) {
        cachedLineIndex = nil
        gutter.updateThickness()
        onTextChange?(textView.string)
        if typedCharacter {
            typedCharacter = false
            showCompletions(explicit: false)
        } else {
            hideCompletions()
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        revealSelection()
        // The caret's line number is highlighted, and relative numbers count from it.
        if Preferences.shared.lineNumbers != .off { gutter.needsDisplay = true }
        onSelectionChange?()
        if let list = activeCompletions {
            let selection = selectedRange
            if selection.length > 0 || selection.location < list.range.location
                || lineIndex.line(containing: selection.location) != lineIndex.line(containing: list.range.location) {
                hideCompletions()
            }
        }
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard popup.isVisible else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            popup.moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)):
            popup.moveSelection(by: 1)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)):
            popup.moveSelection(by: -7)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)):
            popup.moveSelection(by: 7)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            popup.acceptSelection()
        case #selector(NSResponder.cancelOperation(_:)):
            hideCompletions()
        default:
            hideCompletions()
            return false
        }
        return true
    }
}
