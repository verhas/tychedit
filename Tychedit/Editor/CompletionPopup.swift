import AppKit

/// The suggestion list under the caret.
///
/// A borderless child panel that never takes keyboard focus: typing stays in
/// the editor, which forwards the arrow keys, Return, Tab and Escape here while
/// the list is showing. That keeps the editor's own undo, input methods and
/// find bar working normally around it.
@MainActor
final class CompletionPopup: NSObject {

    private let panel: NSPanel
    private let table: NSTableView
    private var items: [CompletionItem] = []
    private var onAccept: ((CompletionItem) -> Void)?

    private static let width: CGFloat = 520
    private static let rowHeight: CGFloat = 36
    private static let visibleRows = 8

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: CompletionPopup.width, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        table = NSTableView()
        super.init()

        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear

        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.width = CompletionPopup.width - 16
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = CompletionPopup.rowHeight
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.refusesFirstResponder = true

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = background
        background.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: background.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -4),
        ])
    }

    var isVisible: Bool { panel.isVisible }

    var selectedItem: CompletionItem? {
        let row = table.selectedRow
        return row >= 0 && row < items.count ? items[row] : nil
    }

    /// Shows `items` below the screen rectangle `anchor`, or above it when
    /// there is no room below.
    func show(_ items: [CompletionItem], below anchor: NSRect, in parent: NSWindow?, onAccept: @escaping (CompletionItem) -> Void) {
        let previous = selectedItem
        self.items = items
        self.onAccept = onAccept
        table.reloadData()
        let row = previous.flatMap { item in items.firstIndex { $0.id == item.id } } ?? 0
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)

        let height = CGFloat(min(items.count, CompletionPopup.visibleRows)) * CompletionPopup.rowHeight + 8
        var frame = NSRect(x: anchor.minX - 10, y: anchor.minY - height - 2, width: CompletionPopup.width, height: height)
        if let screen = parent?.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            if frame.minY < visible.minY { frame.origin.y = anchor.maxY + 2 }
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        }
        panel.setFrame(frame, display: true)
        if panel.parent == nil, let parent {
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func hide() {
        guard panel.isVisible || panel.parent != nil else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let row = min(max(0, table.selectedRow + delta), items.count - 1)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    func acceptSelection() {
        if let item = selectedItem { onAccept?(item) }
    }

    @objc private func doubleClicked() {
        let row = table.clickedRow
        guard row >= 0 && row < items.count else { return }
        onAccept?(items[row])
    }
}

extension CompletionPopup: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("CompletionRow")
        let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? CompletionRowView ?? CompletionRowView()
        view.identifier = identifier
        view.show(items[row])
        return view
    }
}

private final class CompletionRowView: NSTableCellView {

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        label.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        badge.font = .systemFont(ofSize: 10, weight: .medium)
        badge.textColor = .systemOrange
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        icon.contentTintColor = .secondaryLabelColor

        for view in [icon, label, badge, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        label.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            badge.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            badge.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
            badge.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            detail.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            detail.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 0),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ item: CompletionItem) {
        label.stringValue = item.label
        detail.stringValue = item.detail
        badge.stringValue = item.required ? "required" : ""
        let symbol = switch item.kind {
        case .key: "key"
        case .value: "list.bullet"
        case .file: "doc"
        case .directory: "folder"
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }
}
