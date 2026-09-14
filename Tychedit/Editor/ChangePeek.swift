import AppKit

/// The small panel that shows, on hover over the gutter, what a changed line
/// was in the last commit.
@MainActor
final class ChangePeek {

    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true

        let background = NSVisualEffectView()
        background.material = .toolTip
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.masksToBounds = true
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = background
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: background.topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -7),
        ])
    }

    var isVisible: Bool { panel.isVisible }

    /// Shows the hunk next to `anchor`, a rectangle in screen coordinates whose
    /// top is the hovered line's top.
    func show(_ hunk: LineChanges.Hunk, hoveredLine: Int?, deletionOnly: Bool, beside anchor: NSRect, in window: NSWindow?) {
        label.attributedStringValue = ChangePeek.describe(hunk, hoveredLine: hoveredLine, deletionOnly: deletionOnly)
        label.preferredMaxLayoutWidth = 620
        let size = label.fittingSize
        let width = min(640, size.width + 20)
        let height = size.height + 14
        var frame = NSRect(x: anchor.maxX + 6, y: anchor.maxY - height, width: width, height: height)
        if let screen = window?.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - height))
            frame.origin.x = min(frame.minX, visible.maxX - width)
        }
        panel.setFrame(frame, display: true)
        if panel.parent == nil, let window { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        guard panel.isVisible || panel.parent != nil else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private static let limit = 15

    static func describe(_ hunk: LineChanges.Hunk, hoveredLine: Int?, deletionOnly: Bool) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let body = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)

        func append(_ string: String, _ attributes: [NSAttributedString.Key: Any]) {
            text.append(NSAttributedString(string: string, attributes: attributes))
        }
        let title: String
        if deletionOnly {
            let count = hunk.oldLines.count - hunk.newLines.count
            title = count == 1 ? "Deleted since the last commit" : "\(count) lines deleted since the last commit"
        } else if hunk.oldLines.isEmpty {
            title = hunk.newLines.count == 1 ? "Added since the last commit" : "\(hunk.newLines.count) lines added since the last commit"
        } else {
            title = "Changed since the last commit"
        }
        append(title + "\n", [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.labelColor])

        let old = deletionOnly ? Array(hunk.oldLines[hunk.newLines.count...]) : hunk.oldLines
        for line in old.prefix(limit) {
            append("− " + line + "\n", [.font: body, .foregroundColor: NSColor.labelColor,
                                        .backgroundColor: NSColor.systemRed.withAlphaComponent(0.18)])
        }
        if old.count > limit {
            append("  … \(old.count - limit) more\n", [.font: body, .foregroundColor: NSColor.secondaryLabelColor])
        }
        if !deletionOnly {
            for (offset, line) in hunk.newLines.prefix(limit).enumerated() {
                let hovered = hoveredLine == hunk.newStart + offset
                append("+ " + line + "\n", [.font: hovered ? bold : body, .foregroundColor: NSColor.labelColor,
                                            .backgroundColor: NSColor.systemGreen.withAlphaComponent(hovered ? 0.3 : 0.18)])
            }
            if hunk.newLines.count > limit {
                append("  … \(hunk.newLines.count - limit) more\n", [.font: body, .foregroundColor: NSColor.secondaryLabelColor])
            }
        }
        append("Right-click to revert", [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor])
        return text
    }
}
