import AppKit

/// The strip left of the text: what changed since the last git commit, line
/// numbers, and the chevrons that fold.
///
/// From left to right: the change bar (green added, blue changed, a red wedge
/// where committed lines were deleted), the line number, the chevron that folds
/// a section or a whole placeholder, and -- for placeholders whose opening
/// comment spans several lines -- a second chevron that folds only that comment.
final class EditorGutter: NSRulerView {

    private weak var controller: EditorController?

    private static let barX: CGFloat = 2
    private static let barWidth: CGFloat = 3
    private static let chevronSlot: CGFloat = 14
    private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

    @MainActor
    init(scrollView: NSScrollView, controller: EditorController) {
        self.controller = controller
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = controller.textView
        ruleThickness = currentThickness
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    // MARK: Geometry

    @MainActor
    private var numbersWidth: CGFloat {
        guard let controller, Preferences.shared.lineNumbers != .off else { return 0 }
        // Room for three digits at least, so a document under 1,000 lines
        // never changes the gutter's width while it is being typed.
        let digits = max(3, String(controller.lineIndex.count).count)
        let sample = NSAttributedString(string: String(repeating: "8", count: digits),
                                        attributes: [.font: EditorGutter.numberFont])
        return ceil(sample.size().width) + 6
    }

    @MainActor
    private var chevronsX: CGFloat { 8 + numbersWidth }

    @MainActor
    private var currentThickness: CGFloat { chevronsX + 2 * EditorGutter.chevronSlot + 2 }

    /// Widens or narrows the gutter when line numbers are switched or the text
    /// grows another digit.
    @MainActor
    func updateThickness() {
        let wanted = currentThickness
        if abs(ruleThickness - wanted) > 0.5, let scrollView {
            ruleThickness = wanted
            scrollView.tile()
            // The text moves sideways: draw everything in the scroll view again,
            // or what was on screen before the move stays behind at the edge.
            scrollView.needsDisplay = true
            for view in [scrollView.contentView, scrollView.documentView].compactMap({ $0 }) {
                view.needsDisplay = true
            }
        }
        needsDisplay = true
    }

    /// One visible logical line: its number and the vertical span it occupies
    /// in gutter coordinates.
    private struct VisibleLine {
        let number: Int
        let top: CGFloat
        let bottom: CGFloat
        let firstFragmentBottom: CGFloat
    }

    @MainActor
    private func visibleLines() -> [VisibleLine] {
        guard let controller, let layoutManager = controller.textView.layoutManager,
              let container = controller.textView.textContainer else { return [] }
        let textView = controller.textView
        let index = controller.lineIndex
        let length = index.length
        let origin = textView.textContainerOrigin
        var visible = textView.visibleRect
        visible.origin.y -= origin.y
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)

        var lines: [VisibleLine] = []
        var line = index.line(containing: characters.location)
        let lastCharacter = NSMaxRange(characters)
        while line < index.count && index.starts[line] <= lastCharacter {
            let start = index.starts[line]
            defer { line += 1 }
            // Lines inside a fold are not on screen.
            if start > 0 && start < length && controller.isHidden(start) { continue }

            var rect: NSRect
            var first: NSRect
            if start >= length {
                rect = layoutManager.extraLineFragmentRect
                if rect.height == 0 { continue }
                first = rect
            } else {
                let content = index.contentRange(ofLine: line)
                let lineGlyphs = layoutManager.glyphRange(
                    forCharacterRange: content.length > 0 ? content : NSRange(location: start, length: 1),
                    actualCharacterRange: nil)
                first = layoutManager.lineFragmentRect(forGlyphAt: lineGlyphs.location, effectiveRange: nil)
                rect = first
                if content.length > 0 {
                    // A wrapped line spans several fragments.
                    let lastGlyph = max(lineGlyphs.location, NSMaxRange(lineGlyphs) - 1)
                    rect = rect.union(layoutManager.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil))
                }
            }
            let top = convert(NSPoint(x: 0, y: rect.minY + origin.y), from: textView).y
            let bottom = convert(NSPoint(x: 0, y: rect.maxY + origin.y), from: textView).y
            let firstBottom = convert(NSPoint(x: 0, y: first.maxY + origin.y), from: textView).y
            lines.append(VisibleLine(number: line, top: top, bottom: bottom, firstFragmentBottom: firstBottom))
        }
        return lines
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        MainActor.assumeIsolated {
            guard let controller else { return }
            let changes = controller.lineChanges
            let mode = Preferences.shared.lineNumbers
            let caretLine = controller.lineIndex.line(containing: controller.selectedRange.location)
            let numbersRight = chevronsX - 4
            let lines = visibleLines()

            for line in lines where line.bottom >= rect.minY && line.top <= rect.maxY {
                let height = line.bottom - line.top
                let firstHeight = line.firstFragmentBottom - line.top
                if let change = changes.lines[line.number] {
                    (change == .added ? NSColor.systemGreen : NSColor.systemBlue).setFill()
                    NSRect(x: EditorGutter.barX, y: line.top + 1, width: EditorGutter.barWidth, height: height - 2).fill()
                }
                if changes.deletions.contains(line.number) {
                    drawDeletion(at: line.top)
                }

                if mode != .off {
                    let isCaretLine = line.number == caretLine
                    let value = mode == .relative && !isCaretLine ? abs(line.number - caretLine) : line.number + 1
                    let text = NSAttributedString(string: String(value), attributes: [
                        .font: EditorGutter.numberFont,
                        .foregroundColor: isCaretLine ? NSColor.labelColor : NSColor.tertiaryLabelColor,
                    ])
                    let size = text.size()
                    text.draw(at: NSPoint(x: numbersRight - size.width, y: line.top + (firstHeight - size.height) / 2))
                }

                for (slot, region) in slots(for: line.number).enumerated() {
                    guard let region else { continue }
                    let centerX = chevronsX + CGFloat(slot) * EditorGutter.chevronSlot + EditorGutter.chevronSlot / 2
                    drawChevron(folded: controller.isFolded(region), header: region.isHeader,
                                center: NSPoint(x: centerX, y: line.top + firstHeight / 2))
                }
            }
            // Deleted at the very end of the text.
            if let last = lines.last, last.number == controller.lineIndex.count - 1,
               changes.deletions.contains(controller.lineIndex.count) {
                drawDeletion(at: last.bottom)
            }

            NSColor.separatorColor.withAlphaComponent(0.4).setFill()
            NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
        }
    }

    /// The regions whose chevrons sit on `line`: slot 0 folds a section or the
    /// whole placeholder, slot 1 only a placeholder's opening comment.
    @MainActor
    private func slots(for line: Int) -> [FoldRegion?] {
        guard let regions = controller?.regionsByFirstLine[line] else { return [] }
        let header = regions.first { $0.isHeader }
        let whole = regions.first { !$0.isHeader }
        // A self-contained placeholder has only its comment to fold: one chevron, on the left.
        return whole == nil ? [header] : [whole, header]
    }

    private func drawDeletion(at y: CGFloat) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: y - 4))
        path.line(to: NSPoint(x: 7, y: y))
        path.line(to: NSPoint(x: 0, y: y + 4))
        path.close()
        NSColor.systemRed.setFill()
        path.fill()
    }

    private func drawChevron(folded: Bool, header: Bool, center: NSPoint) {
        let path = NSBezierPath()
        let size: CGFloat = header ? 3 : 4
        if folded {
            path.move(to: NSPoint(x: center.x - size / 2, y: center.y - size))
            path.line(to: NSPoint(x: center.x + size * 0.75, y: center.y))
            path.line(to: NSPoint(x: center.x - size / 2, y: center.y + size))
        } else {
            path.move(to: NSPoint(x: center.x - size, y: center.y - size / 2))
            path.line(to: NSPoint(x: center.x, y: center.y + size * 0.75))
            path.line(to: NSPoint(x: center.x + size, y: center.y - size / 2))
        }
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        (folded ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor).setStroke()
        path.stroke()
    }

    // MARK: Clicking

    /// A click on a chevron folds or unfolds its region.
    override func mouseDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard let controller else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard let line = visibleLines().first(where: { point.y >= $0.top && point.y < max($0.bottom, $0.top + 14) })
            else { return }
            let slot = Int(floor((point.x - chevronsX) / EditorGutter.chevronSlot))
            let slots = slots(for: line.number)
            guard slot >= 0, slot < slots.count, let region = slots[slot] else { return }
            controller.toggleFold(region)
        }
    }
}
