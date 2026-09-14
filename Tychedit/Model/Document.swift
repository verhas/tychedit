import AppKit
import Observation

/// Where the caret is, for the status bar.
struct CaretInfo: Equatable {
    var line = 0
    var column = 0
    var selectionLength = 0
    var context: CaretContext?
    /// The problem under the caret, if any.
    var problem: PlaceholderIssue?
}

/// A short message in the status bar.
struct StatusMessage: Equatable {
    let text: String
    let isError: Bool
    let date = Date()
}

/// One open file in one window: its text, where it lives, and everything
/// done to it.
@MainActor
@Observable
final class Document: Identifiable {

    let id = UUID()

    private(set) var fileURL: URL?
    private(set) var isDirty = false
    private(set) var rendered = RenderResult.empty
    /// The text `rendered` was made from.
    @ObservationIgnored private(set) var renderedText = ""
    /// The headings window, once opened.
    @ObservationIgnored private var structurePanel: StructurePanel?
    /// The scanner's, the validator's and mdship's problems, in document order.
    private(set) var problems: [PlaceholderIssue] = []
    private(set) var wordCount = 0
    private(set) var caret = CaretInfo()
    private(set) var lastSaved: Date?
    private(set) var lastSaveWasAutomatic = false
    /// The mdship command running on this file, if any.
    private(set) var mdshipActivity: String?
    private(set) var statusMessage: StatusMessage?

    var isGoToLinePresented = false

    @ObservationIgnored let editor: EditorController
    @ObservationIgnored let preview: PreviewController
    let find = FindController()
    @ObservationIgnored weak var window: NSWindow?

    @ObservationIgnored private var savedText = ""
    @ObservationIgnored private var encoding: String.Encoding = .utf8
    @ObservationIgnored private var byteOrderMark = false
    @ObservationIgnored private var diskModificationDate: Date?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var references: [FileReference] = []
    @ObservationIgnored private var mdshipProblems: [PlaceholderIssue] = []
    @ObservationIgnored private var lastEdit = Date.distantPast
    @ObservationIgnored private var firstUnsavedEdit: Date?
    @ObservationIgnored private var pendingTarget: NavigationTarget?
    @ObservationIgnored private var askingAboutDiskChange = false
    @ObservationIgnored private var preferencesObserver: NSObjectProtocol?
    @ObservationIgnored private var gitBaseline: GitBaseline.State = .unavailable

    init() {
        let preferences = Preferences.shared
        editor = EditorController(fontSize: preferences.fontSize)
        preview = PreviewController(showPlaceholders: preferences.showPlaceholders, fontSize: preferences.fontSize + 1)

        find.editor = editor
        editor.onTextChange = { [weak self] text in
            self?.textDidChange(text)
            self?.find.textDidChange()
        }
        editor.onSelectionChange = { [weak self] in self?.updateCaret() }
        editor.onScroll = { [weak self] line, atEnd in
            guard Preferences.shared.syncScrolling else { return }
            self?.preview.scroll(toLine: line, atEnd: atEnd)
        }
        editor.onCommandClick = { [weak self] offset in self?.follow(at: offset) ?? false }
        editor.completionSource = { [weak self] offset, explicit in
            guard let self, self.isMarkdown else { return nil }
            return CompletionProvider.completions(in: self.editor.text, at: offset, documentURL: self.fileURL, explicit: explicit)
        }
        editor.setWrapsLines(preferences.wrapLines)
        preview.openLink = { [weak self] reference in
            guard let self else { return }
            DocumentController.shared.follow(reference, from: self)
        }
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: Preferences.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPreferences() }
        }
        scheduleRender(immediately: true)
    }

    func close() {
        renderTask?.cancel()
        editor.hideCompletions()
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
    }

    var displayName: String {
        fileURL?.lastPathComponent ?? "Untitled"
    }

    /// Markdown gets placeholders, completion and a rendered preview; any other
    /// text file is edited as plain text.
    var isMarkdown: Bool {
        guard let ext = fileURL?.pathExtension.lowercased(), !ext.isEmpty else { return true }
        return ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "txt"].contains(ext)
    }

    /// A new, empty, untouched window -- which opening a file may take over.
    var isPristine: Bool {
        fileURL == nil && !isDirty && editor.text.isEmpty
    }

    private func applyPreferences() {
        let preferences = Preferences.shared
        editor.setFontSize(preferences.fontSize)
        preview.setFontSize(preferences.fontSize + 1)
        preview.setPlaceholdersVisible(preferences.showPlaceholders)
        editor.setWrapsLines(preferences.wrapLines)
        editor.gutter.updateThickness()
    }

    // MARK: - Window

    func updateWindow() {
        guard let window else { return }
        window.representedURL = fileURL
        window.title = displayName
        window.subtitle = fileURL.map { ($0.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath } ?? ""
        window.isDocumentEdited = isDirty
    }

    // MARK: - Text and rendering

    private func textDidChange(_ text: String) {
        lastEdit = Date()
        let dirty = text != savedText
        if dirty && firstUnsavedEdit == nil { firstUnsavedEdit = lastEdit }
        if !dirty { firstUnsavedEdit = nil }
        if dirty != isDirty {
            isDirty = dirty
            updateWindow()
        }
        scheduleRender()
    }

    /// Renders and validates shortly after typing pauses, off the main thread.
    private func scheduleRender(immediately: Bool = false) {
        renderTask?.cancel()
        let text = editor.text
        let url = fileURL
        let markdown = isMarkdown
        let baseline = gitBaseline
        renderTask = Task { [weak self] in
            if !immediately {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            let analysis = await Task.detached(priority: .userInitiated) {
                Document.analyze(text, url: url, markdown: markdown, baseline: baseline)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.rendered = analysis.render
            self.renderedText = text
            self.references = analysis.validation.references
            self.wordCount = analysis.words
            // Any edit since the snapshot cancels this task, so the ranges are current.
            self.editor.applyStyles(analysis.styles)
            self.editor.setFoldRegions(analysis.folds)
            self.editor.setLineChanges(analysis.changes)
            self.publishProblems(scan: analysis.render.scan.issues + analysis.validation.issues)
            self.preview.show(html: analysis.render.html, directory: url?.deletingLastPathComponent())
            self.updateCaret()
            if let target = self.pendingTarget {
                self.pendingTarget = nil
                self.apply(target)
            }
            self.syncPreviewScroll()
            self.structurePanel?.refresh()
        }
    }

    /// Opens the window showing only the headings, to rearrange the document by.
    func showStructure() {
        let panel = structurePanel ?? StructurePanel(document: self)
        structurePanel = panel
        panel.show()
    }

    func closeStructure() {
        structurePanel?.close()
        structurePanel = nil
    }

    private struct Analysis: Sendable {
        let render: RenderResult
        let validation: PlaceholderValidator.Result
        let words: Int
        let folds: [FoldRegion]
        let changes: LineChanges
        let styles: [StyleRun]
    }

    nonisolated private static func analyze(_ text: String, url: URL?, markdown: Bool,
                                            baseline: GitBaseline.State) -> Analysis {
        let words = text.split(whereSeparator: \.isWhitespace).count
        let changes: LineChanges = switch baseline {
        case .unavailable: .none
        case .committed(let committed): LineChanges.compute(base: committed, current: text)
        case .uncommitted: LineChanges.allAdded(text)
        }
        guard markdown else {
            // Code and other text: shown as it is, nothing to validate or fold.
            let language = url?.pathExtension ?? ""
            let html = "<pre data-line=\"0\"><code class=\"language-\(HTML.escape(language))\">\(HTML.escape(text))</code></pre>"
            let plain = [StyleRun(range: NSRange(location: 0, length: (text as NSString).length), style: .plain)]
            return Analysis(render: RenderResult(html: html, headings: [], scan: PlaceholderScan()),
                            validation: PlaceholderValidator.Result(), words: words, folds: [], changes: changes,
                            styles: plain)
        }
        let render = MarkdownRenderer.render(text)
        let validation = PlaceholderValidator.validate(text: text, scan: render.scan, documentURL: url)
        let folds = FoldRegion.regions(in: text, headings: render.headings, scan: render.scan)
        let styles = SyntaxHighlighter.runs(in: text, headings: render.headings, scan: render.scan)
        return Analysis(render: render, validation: validation, words: words, folds: folds, changes: changes,
                        styles: styles)
    }

    // MARK: - Git

    /// Fetches the committed version of the file, then compares again. Called
    /// when a file is opened or saved under a new name, and when its window
    /// becomes active -- a commit may have happened in a terminal or in Diptych.
    func refreshGitBaseline() {
        guard let url = fileURL else {
            gitBaseline = .unavailable
            return
        }
        Task { [weak self] in
            let state = await Task.detached(priority: .utility) { GitBaseline.state(for: url) }.value
            guard let self, self.fileURL == url, state != self.gitBaseline else { return }
            self.gitBaseline = state
            self.scheduleRender(immediately: true)
        }
    }

    @ObservationIgnored private var scanProblems: [PlaceholderIssue] = []

    private func publishProblems(scan: [PlaceholderIssue]? = nil) {
        if let scan { scanProblems = scan }
        // mdship often reports what the editor already found, in the same words.
        let known = Set(scanProblems.map(\.message))
        let fromMdship = mdshipProblems.filter { !known.contains($0.message) }
        problems = (scanProblems + fromMdship).sorted { $0.location < $1.location }
        editor.showDiagnostics(problems)
    }

    private func updateCaret() {
        let selection = editor.selectedRange
        let index = editor.lineIndex
        let line = index.line(containing: selection.location)
        let offset = selection.location
        caret = CaretInfo(
            line: line,
            column: offset - index.starts[line],
            selectionLength: selection.length,
            context: rendered.scan.context(at: offset),
            problem: problems.first { offset >= $0.range.location && offset <= NSMaxRange($0.range) })
    }

    private func syncPreviewScroll() {
        guard Preferences.shared.syncScrolling else { return }
        let position = editor.visiblePosition()
        preview.scroll(toLine: position.line, atEnd: position.atEnd)
    }

    // MARK: - Loading and saving

    func newDocument() {
        fileURL = nil
        savedText = ""
        encoding = .utf8
        byteOrderMark = false
        diskModificationDate = nil
        editor.setText("")
        isDirty = false
        firstUnsavedEdit = nil
        gitBaseline = .unavailable
        updateWindow()
        scheduleRender(immediately: true)
    }

    @discardableResult
    func load(_ url: URL) -> Bool {
        let contents: TextFile.Contents
        do {
            contents = try TextFile.read(url)
        } catch {
            report(error, doing: "open “\(url.lastPathComponent)”")
            return false
        }
        fileURL = url
        savedText = contents.text
        encoding = contents.encoding
        byteOrderMark = contents.utf8ByteOrderMark
        diskModificationDate = TextFile.modificationDate(of: url)
        mdshipProblems = []
        editor.setText(contents.text)
        isDirty = false
        firstUnsavedEdit = nil
        lastSaved = nil
        updateWindow()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        RecentFiles.shared.add(url, limit: Preferences.shared.recentFilesLimit)
        gitBaseline = .unavailable
        scheduleRender(immediately: true)
        refreshGitBaseline()
        return true
    }

    /// Saves to the file. Interactive saves may ask questions and show errors;
    /// automatic ones never interrupt, and quietly skip when the file changed
    /// on disk -- that question is asked when the window is next used.
    @discardableResult
    func save(interactive: Bool = true) -> Bool {
        guard let url = fileURL else { return interactive ? saveAs() : false }
        if changedOnDisk(url) {
            guard interactive else { return false }
            let alert = NSAlert()
            alert.messageText = "“\(displayName)” has been changed by another application."
            alert.informativeText = "Saving replaces those changes with the text in the editor."
            alert.addButton(withTitle: "Save Anyway")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        return write(to: url, interactive: interactive)
    }

    @discardableResult
    func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = DocumentController.contentTypes
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "Untitled.md"
        panel.directoryURL = fileURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        if let other = DocumentController.shared.document(for: url), other !== self {
            other.window?.performClose(nil)
        }
        return write(to: url, interactive: true)
    }

    private func write(to url: URL, interactive: Bool) -> Bool {
        let text = editor.text
        do {
            try TextFile.write(text, to: url, encoding: encoding, utf8ByteOrderMark: byteOrderMark)
        } catch {
            if interactive {
                report(error, doing: "save “\(url.lastPathComponent)”")
            } else {
                statusMessage = StatusMessage(text: "Autosave failed: \(error.localizedDescription)", isError: true)
            }
            return false
        }
        let movedFolder = url.deletingLastPathComponent() != fileURL?.deletingLastPathComponent()
        let renamed = url != fileURL
        fileURL = url
        savedText = text
        diskModificationDate = TextFile.modificationDate(of: url)
        isDirty = false
        firstUnsavedEdit = nil
        lastSaved = Date()
        lastSaveWasAutomatic = !interactive
        updateWindow()
        if interactive {
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            RecentFiles.shared.add(url, limit: Preferences.shared.recentFilesLimit)
        }
        // Relative paths resolve somewhere else now, and a new extension may
        // turn plain text into markdown.
        if movedFolder || interactive { scheduleRender(immediately: true) }
        if renamed { refreshGitBaseline() }
        return true
    }

    private func changedOnDisk(_ url: URL) -> Bool {
        guard let known = diskModificationDate, let current = TextFile.modificationDate(of: url) else { return false }
        return current != known
    }

    // MARK: - Autosave

    /// Saves now if autosave is on and there is something to save.
    func autosave() {
        guard Preferences.shared.autosaveEnabled, isDirty, fileURL != nil, mdshipActivity == nil,
              !editor.textView.hasMarkedText() else { return }
        save(interactive: false)
    }

    /// The periodic check: saves once changes have waited `autosaveInterval`
    /// and typing has paused for a moment, so a save never lands mid-word.
    func autosaveIfDue(now: Date = Date()) {
        guard let firstUnsavedEdit,
              now.timeIntervalSince(firstUnsavedEdit) >= Preferences.shared.autosaveInterval,
              now.timeIntervalSince(lastEdit) >= 1.5 else { return }
        autosave()
    }

    /// Before the window closes: save when autosave may, ask when it may not.
    func prepareToClose() -> Bool {
        guard isDirty else { return true }
        if Preferences.shared.autosaveEnabled, fileURL != nil, save(interactive: false) {
            return true
        }
        return confirmDiscardingChanges()
    }

    /// Asks about unsaved changes. True when it is fine to go on.
    func confirmDiscardingChanges() -> Bool {
        guard isDirty else { return true }
        window?.makeKeyAndOrderFront(nil)
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes you made to “\(displayName)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let dontSave = alert.addButton(withTitle: "Don’t Save")
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = [.command]
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    /// Picks up changes made on disk by `mdship` in a terminal, git, or Diptych.
    func checkForExternalChanges() {
        guard !askingAboutDiskChange, mdshipActivity == nil, let url = fileURL, let known = diskModificationDate,
              let current = TextFile.modificationDate(of: url), current != known,
              let contents = try? TextFile.read(url) else { return }
        guard contents.text != savedText else {
            diskModificationDate = current
            return
        }
        if isDirty {
            askingAboutDiskChange = true
            defer { askingAboutDiskChange = false }
            window?.makeKeyAndOrderFront(nil)
            let alert = NSAlert()
            alert.messageText = "“\(displayName)” changed on disk."
            alert.informativeText = "It also has unsaved changes in Tychedit. Reloading replaces them with the version on disk; Undo brings them back."
            alert.addButton(withTitle: "Keep Tychedit Version")
            alert.addButton(withTitle: "Reload from Disk")
            guard alert.runModal() == .alertSecondButtonReturn else {
                diskModificationDate = current
                return
            }
        }
        takeDiskVersion(contents, modified: current, actionName: "Reload from Disk")
    }

    /// Replaces the text with what is on disk, as one undoable change.
    private func takeDiskVersion(_ contents: TextFile.Contents, modified: Date?, actionName: String) {
        savedText = contents.text
        encoding = contents.encoding
        byteOrderMark = contents.utf8ByteOrderMark
        diskModificationDate = modified
        if contents.text != editor.text {
            editor.replaceAll(with: contents.text, actionName: actionName)
            // Never keep stale text: autosave would write it over the file.
            if editor.text != contents.text {
                editor.setText(contents.text)
            }
        }
        isDirty = editor.text != savedText
        firstUnsavedEdit = nil
        updateWindow()
    }

    private func report(_ error: Error, doing action: String) {
        let alert = NSAlert(error: error)
        alert.messageText = "Could not \(action)."
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    // MARK: - mdship

    func run(_ command: MdshipCommand) {
        guard mdshipActivity == nil else {
            NSSound.beep()
            return
        }
        if fileURL == nil {
            let alert = NSAlert()
            alert.messageText = "Save the document first."
            alert.informativeText = "mdship works on files, so “\(command.title)” needs this document saved somewhere."
            alert.addButton(withTitle: "Save…")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn, saveAs() else { return }
        }
        guard let url = fileURL else { return }
        if command == .forceUpdate {
            let alert = NSAlert()
            alert.messageText = "Overwrite hand edits in generated content?"
            alert.informativeText = "mdship regenerates every placeholder, including content that was edited by hand. Undo in Tychedit brings the text back."
            alert.addButton(withTitle: "Update")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        // mdship works on the file, so the file has to be what the editor shows.
        if isDirty || changedOnDisk(url) {
            guard save(interactive: true) else { return }
        }

        var lines: ClosedRange<Int>?
        let selection = editor.selectedRange
        if command.usesSelection, selection.length > 0 {
            let index = editor.lineIndex
            let first = index.line(containing: selection.location)
            var last = index.line(containing: NSMaxRange(selection))
            if last > first, index.starts[last] == NSMaxRange(selection) { last -= 1 }
            lines = (first + 1)...(last + 1)
        }

        mdshipActivity = command.title
        editor.hideCompletions()
        // No typing while mdship rewrites the file underneath.
        editor.textView.isEditable = false
        Task {
            defer { mdshipActivity = nil }
            do {
                let result = try await MdshipService.shared.run(command, on: url, lines: lines)
                mdshipProblems = result.problems ? MdshipOutput.issues(in: result.output, text: editor.text) : []
                let summary = result.output.split(separator: "\n").first.map(String.init) ?? "done"
                statusMessage = StatusMessage(text: "\(command.title): \(summary)", isError: result.problems)
            } catch {
                let message = error.localizedDescription
                mdshipProblems = MdshipOutput.issues(in: message, text: editor.text)
                statusMessage = StatusMessage(text: "\(command.title) failed: \(message.split(separator: "\n").first ?? "")",
                                              isError: true)
                if case MdshipService.ServiceError.notInstalled = error {
                    DocumentController.shared.offerInstall(message: message)
                }
            }
            // Editable again before the reload: a read-only text view refuses
            // programmatic changes as well as typing.
            editor.textView.isEditable = true
            if command.changesFile, let contents = try? TextFile.read(url), contents.text != editor.text {
                takeDiskVersion(contents, modified: TextFile.modificationDate(of: url), actionName: command.title)
            } else {
                diskModificationDate = TextFile.modificationDate(of: url)
            }
            publishProblems()
            updateCaret()
        }
    }

    // MARK: - Navigation

    func goToLine(_ oneBased: Int) {
        editor.goToLine(oneBased - 1)
    }

    func jump(toLine line: Int) {
        editor.goToLine(line)
    }

    func jump(to location: Int) {
        editor.select(NSRange(location: location, length: 0))
    }

    /// Goes to `target` once the document has been rendered, since headings
    /// are only known then.
    func reveal(_ target: NavigationTarget) {
        pendingTarget = target
        scheduleRender(immediately: true)
    }

    private func apply(_ target: NavigationTarget) {
        switch target {
        case .line(let line):
            editor.goToLine(line)
        case .anchor(let anchor):
            let wanted = anchor.lowercased()
            if let heading = rendered.headings.first(where: { $0.anchor == wanted }) {
                editor.goToLine(heading.line)
            } else {
                statusMessage = StatusMessage(text: "No heading #\(anchor) in \(displayName)", isError: true)
            }
        case .pattern(let pattern, let includesMatch):
            if let line = NavigationTarget.line(matching: pattern, includesMatch: includesMatch, in: editor.text) {
                editor.goToLine(line)
            } else {
                statusMessage = StatusMessage(text: "Nothing in \(displayName) matches start: \(pattern)", isError: true)
            }
        case .heading(let title):
            let wanted = Document.bareTitle(title)
            if let heading = rendered.headings.first(where: { Document.bareTitle($0.text) == wanted }) {
                editor.goToLine(heading.line)
            } else {
                statusMessage = StatusMessage(text: "No section “\(title)” in \(displayName)", isError: true)
            }
        }
    }

    /// A heading title without its numbering, as mdship compares sections.
    static func bareTitle(_ title: String) -> String {
        title.replacingOccurrences(of: #"^\s*[\d.]+[.)]?\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Follows the link or reference at `offset`. False when there is none.
    @discardableResult
    func follow(at offset: Int) -> Bool {
        guard let reference = ReferenceFinder.reference(
            in: editor.text, at: offset, documentURL: fileURL, scan: rendered.scan,
            fileReferences: references, definitions: MarkdownRenderer.linkDefinitions(in: editor.text)) else { return false }
        DocumentController.shared.follow(reference, from: self)
        return true
    }

    func followAtCaret() {
        if !follow(at: editor.selectedRange.location) {
            NSSound.beep()
        }
    }

    func nextHeading(forward: Bool) {
        let line = caret.line
        let lines = rendered.headings.map(\.line)
        if let target = forward ? lines.first(where: { $0 > line }) : lines.last(where: { $0 < line }) {
            editor.goToLine(target)
        } else {
            NSSound.beep()
        }
    }

    func nextPlaceholder(forward: Bool) {
        step(through: (rendered.scan.placeholders.map(\.openRange.location) + rendered.scan.variables.map(\.range.location)).sorted(),
             forward: forward)
    }

    func nextProblem(forward: Bool) {
        step(through: problems.map(\.location), forward: forward)
    }

    private func step(through locations: [Int], forward: Bool) {
        let here = editor.selectedRange.location
        if let target = forward ? locations.first(where: { $0 > here }) : locations.last(where: { $0 < here }) {
            jump(to: target)
        } else if let wrapped = forward ? locations.first : locations.last, wrapped != here {
            jump(to: wrapped)
        } else {
            NSSound.beep()
        }
    }
}
