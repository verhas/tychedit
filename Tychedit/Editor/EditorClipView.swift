import AppKit

/// The editor's clip view: keeps the text in place horizontally while lines wrap.
///
/// The gutter sits in the scroll view's left content inset, so the visible
/// area's normal horizontal origin is minus the gutter's width, not zero.
/// Anything that scrolled to an x of zero -- or scrolled a match's rectangle
/// into view -- slid the text under the gutter. While lines wrap there is
/// nothing to scroll sideways to, so the origin is pinned.
final class EditorClipView: NSClipView {

    var wrapsLines = true

    /// Told when the width available to the text changes.
    var onWidthChange: (() -> Void)?

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        if wrapsLines {
            rect.origin.x = -contentInsets.left
        }
        return rect
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        pinHorizontalOrigin()
        if changed { onWidthChange?() }
    }

    /// The gutter's width arrives as a content inset, sometimes after the frame.
    override var contentInsets: NSEdgeInsets {
        didSet { pinHorizontalOrigin() }
    }

    /// Resizing or moving the scroll view into another container (hiding the
    /// preview, opening a window) resets the origin without scrolling, so the
    /// constraint above never sees it. Put it back.
    func pinHorizontalOrigin() {
        guard wrapsLines, bounds.origin.x != -contentInsets.left else { return }
        setBoundsOrigin(NSPoint(x: -contentInsets.left, y: bounds.origin.y))
        (superview as? NSScrollView)?.reflectScrolledClipView(self)
    }
}
