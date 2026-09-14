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
    @MainActor private lazy var peek = ChangePeek()
    private var peekTask: Task<Void, Never>?
    /// What the peek currently shows, so moving within one line does not redraw it.
    private var peekKey: String?

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
        // Views no longer clip their drawing by default; the gutter must, or a
        // redraw rectangle larger than it paints over the view next to it.
        clipsToBounds = true
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
            controller?.fitTextWidth()
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

            let area = rect.intersection(bounds)
            NSColor.separatorColor.withAlphaComponent(0.4).setFill()
            NSRect(x: bounds.maxX - 1, y: area.minY, width: 1, height: area.height).fill()
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

    // MARK: Hovering over changes

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    /// What is under the pointer: a deletion wedge, or a changed line.
    @MainActor
    private func change(at point: NSPoint) -> (hunk: LineChanges.Hunk, line: Int, deletion: Bool, top: CGFloat)? {
        guard let controller else { return nil }
        let changes = controller.lineChanges
        guard !changes.hunks.isEmpty else { return nil }
        let lines = visibleLines()
        // The wedge sits on the boundary above a line; it wins within a few points of it.
        for line in lines where abs(point.y - line.top) <= 4 {
            if let hunk = changes.hunk(deletedBefore: line.number) { return (hunk, line.number, true, line.top) }
        }
        if let last = lines.last, abs(point.y - last.bottom) <= 4,
           let hunk = changes.hunk(deletedBefore: last.number + 1) {
            return (hunk, last.number + 1, true, last.bottom)
        }
        guard let line = lines.first(where: { point.y >= $0.top && point.y < $0.bottom }),
              let hunk = changes.hunk(containing: line.number) else { return nil }
        return (hunk, line.number, false, line.top)
    }

    override func mouseMoved(with event: NSEvent) {
        MainActor.assumeIsolated {
            let point = convert(event.locationInWindow, from: nil)
            // The change bar and the numbers beside it; the chevrons are for folding.
            guard point.x < chevronsX, let found = change(at: point) else {
                hidePeek()
                return
            }
            let key = "\(found.hunk.newStart)-\(found.line)-\(found.deletion)"
            guard key != peekKey else { return }
            peekKey = key
            peekTask?.cancel()
            let delay: Duration = peek.isVisible ? .zero : .milliseconds(350)
            peekTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, let window = self.window else { return }
                let rowRect = NSRect(x: 0, y: found.top, width: self.bounds.width, height: 1)
                let anchor = window.convertToScreen(self.convert(rowRect, to: nil))
                self.peek.show(found.hunk, hoveredLine: found.deletion ? nil : found.line,
                               deletionOnly: found.deletion, beside: anchor, in: window)
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        MainActor.assumeIsolated { hidePeek() }
    }

    @MainActor
    func hidePeek() {
        peekTask?.cancel()
        peekKey = nil
        peek.hide()
    }

    // MARK: Reverting

    /// Right-click on a changed line: put it back as it was committed.
    override func menu(for event: NSEvent) -> NSMenu? {
        hidePeek()
        let point = convert(event.locationInWindow, from: nil)
        guard let found = change(at: point) else { return nil }
        let menu = NSMenu()
        if found.deletion {
            let count = found.hunk.oldLines.count - found.hunk.newLines.count
            menu.addItem(item(count == 1 ? "Restore Deleted Line" : "Restore \(count) Deleted Lines",
                              #selector(restoreDeleted(_:)), found))
        } else {
            let isAdded = found.line - found.hunk.newStart >= found.hunk.oldLines.count
            menu.addItem(item(isAdded ? "Remove This Added Line" : "Revert This Line", #selector(revertLine(_:)), found))
            if found.hunk.newLines.count > 1 || found.hunk.oldLines.count != found.hunk.newLines.count {
                let first = found.hunk.newStart + 1
                let last = found.hunk.newStart + max(found.hunk.newLines.count, 1)
                menu.addItem(item(first == last ? "Revert Whole Change (line \(first))" : "Revert Whole Change (lines \(first)–\(last))",
                                  #selector(revertHunk(_:)), found))
            }
        }
        return menu
    }

    private final class ChangeTarget: NSObject {
        let hunk: LineChanges.Hunk
        let line: Int
        init(hunk: LineChanges.Hunk, line: Int) {
            self.hunk = hunk
            self.line = line
        }
    }

    private func item(_ title: String, _ action: Selector, _ found: (hunk: LineChanges.Hunk, line: Int, deletion: Bool, top: CGFloat)) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = ChangeTarget(hunk: found.hunk, line: found.line)
        return item
    }

    @objc private func revertLine(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? ChangeTarget else { return }
        MainActor.assumeIsolated { controller?.revertLine(target.line, of: target.hunk) }
    }

    @objc private func revertHunk(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? ChangeTarget else { return }
        MainActor.assumeIsolated { controller?.revertHunk(target.hunk) }
    }

    @objc private func restoreDeleted(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? ChangeTarget else { return }
        MainActor.assumeIsolated { controller?.restoreDeletedLines(of: target.hunk) }
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
