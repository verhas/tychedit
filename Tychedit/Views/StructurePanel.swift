import AppKit

/// A document's headings in a small window of their own, to rearrange it by.
///
/// Dragging a heading up or down moves its section -- subheadings and all; the
/// indentation it is dropped at decides its level, and its subheadings follow.
/// Several headings can go together when they are next to each other.
final class StructurePanel: NSWindowController, NSWindowDelegate {

    private let editorDocument: Document
    private let outlineView = NSOutlineView()
    private let emptyLabel = NSTextField(labelWithString: "No headings")

    /// The structure on show, and the text it was taken from: a drop only
    /// applies to the text it describes.
    private var structure: DocumentStructure?
    private var structureText = ""
    private var roots: [Node] = []
    private var nodes: [Node] = []

    /// Headings are remembered by level, title and how many alike came before,
    /// so a refresh keeps what was collapsed and selected.
    private var collapsed: Set<String> = []
    private var reloading = false
    private var dragged: ClosedRange<Int>?

    private static let dragType = NSPasteboard.PasteboardType("com.verhas.tychedit.heading")

    final class Node: NSObject {
        let index: Int
        let key: String
        var children: [Node] = []
        init(index: Int, key: String) {
            self.index = index
            self.key = key
        }
    }

    init(document: Document) {
        self.editorDocument = document
        let panel = EscapePanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 480),
                                styleMask: [.titled, .closable, .resizable, .utilityWindow],
                                backing: .buffered, defer: false)
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 220, height: 200)
        super.init(window: panel)
        panel.delegate = self
        buildViews(in: panel)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildViews(in panel: NSPanel) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("heading"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.allowsMultipleSelection = true
        outlineView.autoresizesOutlineColumn = true
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(openHeading(_:))
        outlineView.registerForDraggedTypes([Self.dragType])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.draggingDestinationFeedbackStyle = .sourceList

        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let hint = NSTextField(wrappingLabelWithString:
            "Drag to move a section with its subheadings; drop further left or right to change its level.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center

        let content = NSView()
        for view in [scroll, hint, emptyLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            hint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            hint.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        panel.contentView = content
    }

    /// Opens the panel beside the document window's editor.
    func show() {
        refresh()
        if let panel = window, !panel.isVisible, let parent = editorDocument.window {
            let frame = parent.frame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: frame.minX + 24, y: frame.maxY - size.height - 80))
        }
        window?.makeKeyAndOrderFront(nil)
    }

    /// Rebuilds the tree from the latest rendering, when that rendering is of
    /// the text in the editor.
    func refresh() {
        window?.title = "Structure — \(editorDocument.displayName)"
        let text = editorDocument.editor.text
        guard editorDocument.renderedText == text else { return }
        let structure = DocumentStructure(text: text, headings: editorDocument.rendered.headings, scan: editorDocument.rendered.scan)
        guard structure != self.structure || text != structureText else { return }

        let selectedKeys = Set(outlineView.selectedRowIndexes.compactMap { (outlineView.item(atRow: $0) as? Node)?.key })
        self.structure = structure
        structureText = text

        var seen: [String: Int] = [:]
        nodes = structure.entries.enumerated().map { index, entry in
            let base = "\(entry.level)|\(entry.text)"
            let occurrence = seen[base, default: 0]
            seen[base] = occurrence + 1
            return Node(index: index, key: "\(base)|\(occurrence)")
        }
        roots = []
        for node in nodes {
            if let parent = structure.parents[node.index] {
                nodes[parent].children.append(node)
            } else {
                roots.append(node)
            }
        }

        reloading = true
        outlineView.reloadData()
        for node in nodes where !collapsed.contains(node.key) && !node.children.isEmpty {
            outlineView.expandItem(node)
        }
        // Expanding a parent can open children that were collapsed before; close those again.
        for node in nodes.reversed() where collapsed.contains(node.key) {
            outlineView.collapseItem(node)
        }
        let rows = IndexSet(nodes.filter { selectedKeys.contains($0.key) }.map { outlineView.row(forItem: $0) }.filter { $0 >= 0 })
        outlineView.selectRowIndexes(rows, byExtendingSelection: false)
        reloading = false
        emptyLabel.isHidden = !nodes.isEmpty
    }

    @objc private func openHeading(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? Node, let structure else { return }
        editorDocument.jump(toLine: structure.entries[node.index].line)
        editorDocument.window?.makeKeyAndOrderFront(nil)
        editorDocument.editor.focus()
    }

    func windowWillClose(_ notification: Notification) {
        dragged = nil
    }
}

private final class EscapePanel: NSPanel {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

extension StructurePanel: NSOutlineViewDataSource, NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Node)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node, let entry = structure?.entries[node.index] else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("HeadingCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        let title = NSMutableAttributedString(string: "H\(entry.level)  ", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        title.append(NSAttributedString(string: entry.text.isEmpty ? "(untitled)" : entry.text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: entry.level == structure?.rootLevel ? .semibold : .regular),
            .foregroundColor: NSColor.labelColor,
        ]))
        cell.textField?.attributedStringValue = title
        cell.toolTip = "Line \(entry.line + 1)"
        return cell
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !reloading, let node = notification.userInfo?["NSObject"] as? Node else { return }
        collapsed.insert(node.key)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !reloading, let node = notification.userInfo?["NSObject"] as? Node else { return }
        collapsed.remove(node.key)
    }

    /// Only headings next to each other can be selected together.
    func outlineView(_ outlineView: NSOutlineView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        guard let first = proposed.first, let last = proposed.last else { return proposed }
        if last - first + 1 == proposed.count { return proposed }
        // Keep the run that holds the row just clicked.
        let clicked = outlineView.clickedRow
        guard clicked >= 0, proposed.contains(clicked) else { return outlineView.selectedRowIndexes }
        var low = clicked
        var high = clicked
        while proposed.contains(low - 1) { low -= 1 }
        while proposed.contains(high + 1) { high += 1 }
        return IndexSet(integersIn: low...high)
    }

    /// A single heading picked shows in the editor, without leaving the panel.
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !reloading, outlineView.selectedRowIndexes.count == 1, let structure,
              let node = outlineView.item(atRow: outlineView.selectedRow) as? Node else { return }
        editorDocument.jump(toLine: structure.entries[node.index].line)
    }

    // MARK: Dragging

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? Node else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(String(node.index), forType: Self.dragType)
        return pasteboardItem
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        let dragNodes = draggedItems.compactMap { $0 as? Node }
        let rows = dragNodes.map { outlineView.row(forItem: $0) }.sorted()
        guard let first = rows.first, let last = rows.last, last - first + 1 == rows.count,
              editorDocument.editor.text == structureText else {
            dragged = nil
            return
        }
        let indices = dragNodes.map(\.index)
        dragged = indices.min()!...indices.max()!
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragged = nil
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        movedText(item: item, childIndex: index, info: info) == nil ? [] : .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let text = movedText(item: item, childIndex: index, info: info) else { return false }
        let selected = outlineView.selectedRowIndexes
        dragged = nil
        editorDocument.editor.applyMinimalEdit(text, actionName: "Move Section")
        // Until the new text is rendered, the tree on show no longer matches it.
        structure = nil
        outlineView.selectRowIndexes(selected, byExtendingSelection: false)
        return true
    }

    /// The text after dropping the dragged headings at `item`, `childIndex` --
    /// on a heading means as its last child. Nil when that drop cannot be made.
    private func movedText(item: Any?, childIndex: Int, info: NSDraggingInfo) -> String? {
        guard let dragged, let structure, info.draggingSource as? NSOutlineView === outlineView,
              editorDocument.editor.text == structureText else { return nil }
        let parent = (item as? Node)?.index
        let index = childIndex == NSOutlineViewDropOnItemIndex ? structure.children(of: parent).count : childIndex
        return structure.move(dragged, toParent: parent, childIndex: index, in: structureText)
    }
}
