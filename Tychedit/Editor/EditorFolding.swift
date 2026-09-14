import AppKit

/// A folded region's current place and its badge text.
struct FoldedRange: Equatable {
    var range: NSRange
    let label: String
}

/// Folding: hiding a section or placeholder behind its first line.
///
/// Nothing is removed from the text. The layout manager is asked to generate no
/// glyphs for the folded characters, except the first -- the line break after
/// the visible line -- which becomes a blank space as wide as the badge drawn
/// over it. So saving, undo, find and mdship all see the whole document, the
/// badge never overlaps text, and what follows the fold (a `-->`, the next
/// line) continues after the badge. When the caret or a selection moves into
/// folded text -- Go to Line, Find, a jump to a problem -- the fold opens.
extension EditorController {

    // MARK: - Regions

    /// The foldable regions of the text as last analysed. Folded regions that
    /// still exist stay folded at their new position; others are forgotten.
    func setFoldRegions(_ regions: [FoldRegion]) {
        foldRegions = regions
        regionsByFirstLine = Dictionary(grouping: regions, by: \.firstLine)
        let byKey = Dictionary(regions.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var updated: [FoldRegion.Key: FoldedRange] = [:]
        for key in foldedKeys.keys {
            if let region = byKey[key] { updated[key] = FoldedRange(range: region.hiddenRange, label: region.label) }
        }
        applyFolds(updated)
    }

    func setLineChanges(_ changes: LineChanges) {
        guard changes != lineChanges else { return }
        lineChanges = changes
        gutter.needsDisplay = true
    }

    func isFolded(_ region: FoldRegion) -> Bool {
        foldedKeys[region.key] != nil
    }

    func toggleFold(_ region: FoldRegion) {
        isFolded(region) ? unfold(region) : fold(region)
    }

    func fold(_ region: FoldRegion) {
        var folded = foldedKeys
        folded[region.key] = FoldedRange(range: region.hiddenRange, label: region.label)
        moveCaretOutOf([region.hiddenRange])
        applyFolds(folded)
    }

    func unfold(_ region: FoldRegion) {
        var folded = foldedKeys
        folded[region.key] = nil
        applyFolds(folded)
    }

    /// The caret must not stay inside what is hidden, or the fold would open again at once.
    private func moveCaretOutOf(_ ranges: [NSRange]) {
        let caret = selectedRange.location
        if let range = ranges.first(where: { caret > $0.location && caret <= NSMaxRange($0) }) {
            textView.setSelectedRange(NSRange(location: range.location, length: 0))
        }
    }

    /// Folds the innermost open region around the caret.
    func foldAtCaret() {
        let line = lineIndex.line(containing: selectedRange.location)
        let candidates = foldRegions
            .filter { $0.firstLine <= line && line <= $0.lastLine && !isFolded($0) }
            .sorted { $0.hiddenRange.length < $1.hiddenRange.length }
        guard let region = candidates.first else { return NSSound.beep() }
        fold(region)
    }

    /// Opens the folds on the caret's line, or the innermost fold around it.
    func unfoldAtCaret() {
        let line = lineIndex.line(containing: selectedRange.location)
        let onLine = foldRegions.filter { $0.firstLine == line && isFolded($0) }
        let around = onLine.isEmpty
            ? foldRegions.filter { $0.firstLine <= line && line <= $0.lastLine && isFolded($0) }
                .sorted { $0.hiddenRange.length < $1.hiddenRange.length }.prefix(1)
            : ArraySlice(onLine)
        guard !around.isEmpty else { return NSSound.beep() }
        var keys = foldedKeys
        for region in around { keys[region.key] = nil }
        applyFolds(keys)
    }

    func foldAll() {
        var keys = foldedKeys
        for region in foldRegions { keys[region.key] = FoldedRange(range: region.hiddenRange, label: region.label) }
        moveCaretOutOf(keys.values.map(\.range))
        applyFolds(keys)
    }

    func unfoldAll() {
        applyFolds([:])
    }

    // MARK: - Applying

    func applyFolds(_ folded: [FoldRegion.Key: FoldedRange]) {
        let length = nsText.length
        let valid = folded.filter { NSMaxRange($0.value.range) <= length && $0.value.range.length > 0 }
        let merged = EditorController.merge(valid.values.map(\.range))
        // Each badge speaks for the outermost fold starting where it is.
        var labels: [Int: String] = [:]
        for range in merged {
            labels[range.location] = valid.values
                .filter { $0.range.location == range.location }
                .max { $0.range.length < $1.range.length }?.label ?? "…"
        }
        let changed = merged != hiddenRanges || labels != badgeLabels
        let previous = hiddenRanges
        foldedKeys = valid
        hiddenRanges = merged
        badgeLabels = labels
        guard changed, let layoutManager = textView.layoutManager else {
            gutter.needsDisplay = true
            return
        }
        for range in EditorController.merge(previous + merged) {
            let start = max(0, range.location - 1)
            let end = min(length, NSMaxRange(range) + 1)
            let affected = NSRange(location: start, length: end - start)
            layoutManager.invalidateGlyphs(forCharacterRange: affected, changeInLength: 0, actualCharacterRange: nil)
            layoutManager.invalidateLayout(forCharacterRange: affected, actualCharacterRange: nil)
        }
        textView.needsDisplay = true
        gutter.needsDisplay = true
    }

    static func merge(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = result.last, range.location < NSMaxRange(last) {
                result[result.count - 1] = NSUnionRange(last, range)
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// Whether the character at `index` is folded away.
    func isHidden(_ index: Int) -> Bool {
        EditorController.range(containing: index, in: hiddenRanges) != nil
    }

    /// Binary search in sorted, non-overlapping ranges.
    static func range(containing index: Int, in sorted: [NSRange]) -> NSRange? {
        var low = 0
        var high = sorted.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = sorted[mid]
            if index < range.location {
                high = mid - 1
            } else if index >= NSMaxRange(range) {
                low = mid + 1
            } else {
                return range
            }
        }
        return nil
    }

    /// Opens folds the selection has moved into.
    func revealSelection() {
        guard !foldedKeys.isEmpty else { return }
        let selection = selectedRange
        var keys = foldedKeys
        for (key, folded) in foldedKeys {
            let range = folded.range
            let caretInside = selection.length == 0
                && selection.location > range.location && selection.location <= NSMaxRange(range)
            let endInside = selection.length > 0
                && [selection.location, NSMaxRange(selection)].contains { $0 > range.location && $0 < NSMaxRange(range) }
            if caretInside || endInside { keys[key] = nil }
        }
        if keys.count != foldedKeys.count {
            applyFolds(keys)
        }
    }

    // MARK: - Badges

    static let badgeFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    /// The width a badge takes in the text, margins included.
    func badgeAdvance(for label: String) -> CGFloat {
        let text = NSAttributedString(string: label, attributes: [.font: EditorController.badgeFont])
        return ceil(text.size().width) + 16 + 10
    }

    /// Where each badge is drawn, in text view coordinates, with the fold it opens.
    private func badgeRects() -> [(rect: NSRect, location: Int, label: String)] {
        guard let layoutManager = textView.layoutManager else { return [] }
        let origin = textView.textContainerOrigin
        return hiddenRanges.compactMap { range in
            guard let label = badgeLabels[range.location] else { return nil }
            let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
            guard glyph < layoutManager.numberOfGlyphs else { return nil }
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let position = layoutManager.location(forGlyphAt: glyph)
            let height = min(17, max(12, line.height - 4))
            let width = badgeAdvance(for: label) - 10
            let rect = NSRect(x: line.minX + position.x + origin.x + 5,
                              y: line.minY + origin.y + (line.height - height) / 2,
                              width: width, height: height)
            return (rect, range.location, label)
        }
    }

    func drawFoldBadges(in dirtyRect: NSRect) {
        for badge in badgeRects() where badge.rect.intersects(dirtyRect) {
            let path = NSBezierPath(roundedRect: badge.rect, xRadius: badge.rect.height / 2, yRadius: badge.rect.height / 2)
            NSColor.quaternaryLabelColor.setFill()
            path.fill()
            let text = NSAttributedString(string: badge.label, attributes: [
                .font: EditorController.badgeFont,
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            let size = text.size()
            text.draw(at: NSPoint(x: badge.rect.minX + 8, y: badge.rect.midY - size.height / 2))
        }
    }

    /// A click on a badge opens the folds it stands for.
    func unfoldBadge(at point: NSPoint) -> Bool {
        guard let badge = badgeRects().first(where: { $0.rect.insetBy(dx: -3, dy: -3).contains(point) }) else { return false }
        let merged = EditorController.range(containing: badge.location, in: hiddenRanges)
        applyFolds(foldedKeys.filter { folded in
            guard let merged else { return true }
            // Open everything that makes up this badge; folds elsewhere stay.
            return !(folded.value.range.location >= merged.location && NSMaxRange(folded.value.range) <= NSMaxRange(merged))
        })
        return true
    }
}

// MARK: - Layout manager: hiding folded glyphs

extension EditorController: @preconcurrency NSLayoutManagerDelegate {

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes: UnsafePointer<Int>,
                       font: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        guard !hiddenRanges.isEmpty else { return 0 }
        var adjusted: [NSLayoutManager.GlyphProperty]?
        for i in 0..<glyphRange.length {
            let index = characterIndexes[i]
            guard let range = EditorController.range(containing: index, in: hiddenRanges) else { continue }
            if adjusted == nil { adjusted = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length)) }
            // The first folded character is the space the badge sits in.
            adjusted![i] = index == range.location ? .controlCharacter : .null
        }
        guard let adjusted else { return 0 }
        adjusted.withUnsafeBufferPointer { buffer in
            layoutManager.setGlyphs(glyphs, properties: buffer.baseAddress!, characterIndexes: characterIndexes,
                                    font: font, forGlyphRange: glyphRange)
        }
        return glyphRange.length
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        guard let range = EditorController.range(containing: charIndex, in: hiddenRanges) else { return action }
        // No line break inside a fold; the first character becomes the badge's space.
        return charIndex == range.location ? .whitespace : .zeroAdvancement
    }

    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int,
                       for textContainer: NSTextContainer, proposedLineFragment proposedRect: NSRect,
                       glyphPosition: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let width = badgeLabels[charIndex].map { badgeAdvance(for: $0) } ?? 0
        return NSRect(x: glyphPosition.x, y: glyphPosition.y, width: width, height: proposedRect.height)
    }

    /// The gutter follows the text: whenever layout finishes, it draws again.
    func layoutManager(_ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?,
                       atEnd layoutFinishedFlag: Bool) {
        gutter.needsDisplay = true
    }
}

// MARK: - Text storage: keeping folds in place while typing

extension EditorController: @preconcurrency NSTextStorageDelegate {

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), !foldedKeys.isEmpty else { return }
        if replacingEverything {
            // Shown unfolded until the new text is analysed; the keys bring the
            // folds back then.
            hiddenRanges = []
            return
        }
        // Before the edit, the changed characters were here.
        let old = NSRange(location: editedRange.location, length: editedRange.length - delta)
        var updated: [FoldRegion.Key: FoldedRange] = [:]
        for (key, folded) in foldedKeys {
            let range = folded.range
            if NSMaxRange(old) <= range.location {
                updated[key] = FoldedRange(range: NSRange(location: range.location + delta, length: range.length),
                                           label: folded.label)
            } else if old.location >= NSMaxRange(range) {
                updated[key] = folded
            }
            // An edit inside a fold opens it.
        }
        foldedKeys = updated
        hiddenRanges = EditorController.merge(updated.values.map(\.range))
        badgeLabels = Dictionary(updated.values.map { ($0.range.location, $0.label) }, uniquingKeysWith: { first, _ in first })
    }
}
