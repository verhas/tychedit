import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The open documents and their windows.
///
/// One window per file: opening a file that is already open brings its window
/// forward instead of opening it twice, so following an INCLUDE to a file you
/// are already editing lands in the window you already have.
@MainActor
@Observable
final class DocumentController {

    static let shared = DocumentController()

    private(set) var documents: [Document] = []
    /// The document of the frontmost document window -- what the menus act on.
    private(set) var activeDocument: Document?

    @ObservationIgnored private var windowControllers: [UUID: DocumentWindowController] = [:]
    @ObservationIgnored private var autosaveTimer: Timer?
    @ObservationIgnored private var cascadePoint = NSPoint.zero
    @ObservationIgnored private var consoleWindow: NSWindow?

    static var contentTypes: [UTType] {
        [UTType("net.daringfireball.markdown"), UTType(filenameExtension: "md"), .plainText].compactMap { $0 }
    }

    // MARK: - Opening

    @discardableResult
    func newDocument() -> Document {
        let document = Document()
        show(document)
        return document
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = DocumentController.contentTypes
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = activeDocument?.fileURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            open(url)
        }
    }

    func document(for url: URL) -> Document? {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return documents.first { $0.fileURL?.resolvingSymlinksInPath().standardizedFileURL.path == path }
    }

    /// Opens `url` in its own window, or brings forward the window that already
    /// has it; then goes to `target`. Folders open in Finder, and files that are
    /// not text in their own application.
    func open(_ url: URL, target: NavigationTarget? = nil, from source: Document? = nil) {
        let url = url.standardizedFileURL
        if let existing = document(for: url) {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            if let target { existing.reveal(target) }
            return
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            offerToCreate(url, target: target)
            return
        }
        if isDirectory.boolValue || !DocumentController.isText(url) {
            NSWorkspace.shared.open(url)
            return
        }

        // A fresh, empty window opened at launch is taken over rather than left behind.
        let reuse = source == nil ? documents.first(where: \.isPristine) : nil
        let document = reuse ?? Document()
        guard document.load(url) else {
            if reuse == nil { document.close() }
            return
        }
        if reuse == nil {
            show(document)
        } else {
            document.window?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
        if let target { document.reveal(target) }
    }

    /// Acts on a followed reference.
    func follow(_ reference: Reference, from document: Document) {
        switch reference {
        case .web(let url):
            NSWorkspace.shared.open(url)
        case .anchor(let anchor):
            document.reveal(.anchor(anchor))
        case .location(let offset):
            document.jump(to: offset)
        case .file(let url, let target):
            open(url, target: target, from: document)
        }
    }

    private func offerToCreate(_ url: URL, target: NavigationTarget?) {
        let alert = NSAlert()
        alert.messageText = "“\(url.lastPathComponent)” does not exist."
        alert.informativeText = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        let canCreate = DocumentController.isText(url)
        if canCreate {
            alert.addButton(withTitle: "Create and Open")
        }
        alert.addButton(withTitle: canCreate ? "Cancel" : "OK")
        guard canCreate, alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url, options: .withoutOverwriting)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        open(url, target: target)
    }

    /// Text by its type, or -- for unknown extensions -- by having no NUL bytes
    /// and decoding as UTF-8 at the start.
    static func isText(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["md", "markdown", "mdown", "mkd", "txt", "py", "json", "yaml", "yml", "toml", "xml", "csv"].contains(ext) {
            return true
        }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .text) || type.conforms(to: .sourceCode) { return true }
            if type.conforms(to: .image) || type.conforms(to: .audiovisualContent) || type.conforms(to: .pdf)
                || type.conforms(to: .archive) || type.conforms(to: .executable) { return false }
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4096)) ?? Data()
        return !head.contains(0) && String(data: head, encoding: .utf8) != nil
    }

    // MARK: - Windows

    private func show(_ document: Document) {
        documents.append(document)
        let controller = DocumentWindowController(document: document)
        windowControllers[document.id] = controller
        if let window = controller.window {
            // Each new window steps down and right from the one before it.
            if documents.count == 1 || cascadePoint == .zero {
                window.center()
                cascadePoint = window.cascadeTopLeft(from: .zero)
            } else {
                cascadePoint = window.cascadeTopLeft(from: cascadePoint)
            }
        }
        controller.showWindow(nil)
        activeDocument = document
        document.editor.focus()
    }

    func windowBecameKey(for document: Document) {
        activeDocument = document
        document.checkForExternalChanges()
        document.refreshGitBaseline()
    }

    func windowClosed(for document: Document) {
        document.close()
        documents.removeAll { $0 === document }
        windowControllers[document.id] = nil
        if activeDocument === document {
            activeDocument = documents.last
        }
    }

    // MARK: - Saving

    func startAutosave() {
        autosaveTimer?.invalidate()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                for document in DocumentController.shared.documents {
                    document.autosaveIfDue()
                }
            }
        }
    }

    func autosaveAll() {
        for document in documents {
            document.autosave()
        }
    }

    /// Before quitting: every document saved, or confirmed to be discarded.
    func prepareToTerminate() -> Bool {
        for document in documents where !document.prepareToClose() {
            return false
        }
        return true
    }

    // MARK: - mdship

    func offerInstall(message: String) {
        let alert = NSAlert()
        alert.messageText = "mdship was not found."
        alert.informativeText = "\(message)\n\nInstall it now with pip install mdship?"
        alert.addButton(withTitle: "Install mdship")
        alert.addButton(withTitle: "Open Settings…")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            showConsole()
            Task { await MdshipService.shared.install() }
        case .alertSecondButtonReturn:
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        default:
            break
        }
    }

    func showConsole() {
        if let consoleWindow {
            consoleWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "mdship Console"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        let hosting = NSHostingController(rootView: ConsoleView(service: MdshipService.shared))
        // Left to itself, the hosting controller sizes the window to the
        // content's ideal size, which for a scroll view is next to nothing.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.minSize = NSSize(width: 420, height: 260)
        window.setContentSize(NSSize(width: 720, height: 460))
        window.center()
        window.setFrameAutosaveName("mdshipConsole")
        // A frame saved while the window was still tiny is not worth restoring.
        if window.frame.width < window.minSize.width || window.frame.height < window.minSize.height {
            window.setContentSize(NSSize(width: 720, height: 460))
            window.center()
        }
        consoleWindow = window
        window.makeKeyAndOrderFront(nil)
    }
}

/// One document's window.
@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate {

    let editorDocument: Document

    init(document: Document) {
        self.editorDocument = document
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isRestorable = false
        window.tabbingIdentifier = "TycheditDocument"
        window.minSize = NSSize(width: 560, height: 360)
        let hosting = NSHostingController(rootView: ContentView(document: document))
        // The window keeps its size; SwiftUI's toolbar shows in the window's toolbar.
        hosting.sizingOptions = []
        hosting.sceneBridgingOptions = [.toolbars]
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1200, height: 760))
        super.init(window: window)
        window.delegate = self
        document.window = window
        document.updateWindow()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        editorDocument.prepareToClose()
    }

    func windowWillClose(_ notification: Notification) {
        editorDocument.closeStructure()
        DocumentController.shared.windowClosed(for: editorDocument)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        DocumentController.shared.windowBecameKey(for: editorDocument)
    }

    /// Losing focus is a moment to save.
    func windowDidResignKey(_ notification: Notification) {
        editorDocument.editor.hideCompletions()
        editorDocument.autosave()
    }
}
