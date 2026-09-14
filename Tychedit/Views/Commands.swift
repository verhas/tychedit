import SwiftUI

// The menu bar. Everything acts on the frontmost document window; shortcuts
// follow Xcode where Xcode has one for the same thing.

@MainActor private var controller: DocumentController { DocumentController.shared }
@MainActor private var document: Document? { DocumentController.shared.activeDocument }

struct FileCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New") { controller.newDocument() }
                .keyboardShortcut("n")
            Button("Open…") { controller.openPanel() }
                .keyboardShortcut("o")
            OpenRecentMenu()
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w")
            Button("Save") { document?.save() }
                .keyboardShortcut("s")
            Button("Save As…") { document?.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        }
    }
}

struct FindCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .textEditing) {
            Menu("Find") {
                Button("Find…") { document?.find.show(replace: false) }
                    .keyboardShortcut("f")
                Button("Find and Replace…") { document?.find.show(replace: true) }
                    .keyboardShortcut("r")
                Button("Find Next") { document?.find.next() }
                    .keyboardShortcut("g")
                Button("Find Previous") { document?.find.previous() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Use Selection for Find") { document?.find.useSelectionForFind() }
                    .keyboardShortcut("e")
                Button("Replace All") { document?.find.replaceAll() }
                Button("Jump to Selection") { document?.editor.textView.centerSelectionInVisibleArea(nil) }
                    .keyboardShortcut("j")
            }
            // Control-Space, as asked for. macOS assigns it to "Select the previous
            // input source" by default; where that is on, the system takes the
            // key first, and Escape or Option-Escape still ask.
            Button("Show Completions") {
                if document?.editor.showCompletions(explicit: true) != true { NSSound.beep() }
            }
            .keyboardShortcut(.space, modifiers: .control)
        }
    }
}

struct FormatCommands: Commands {
    var body: some Commands {
        CommandMenu("Format") {
            Button("Bold") { document?.editor.toggleWrap("**", sample: "bold text", actionName: "Bold") }
                .keyboardShortcut("b")
            Button("Italic") { document?.editor.toggleWrap("_", sample: "italic text", actionName: "Italic") }
                .keyboardShortcut("i")
            Button("Code") { document?.editor.toggleWrap("`", sample: "code", actionName: "Code") }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Strikethrough") {
                document?.editor.toggleWrap("~~", sample: "struck text", actionName: "Strikethrough")
            }
            .keyboardShortcut("x", modifiers: [.command, .shift])
            Button("Link") { document?.editor.insertLink() }
                .keyboardShortcut("k")

            Divider()

            Button("Shift Right") { document?.editor.shiftLines(right: true) }
                .keyboardShortcut("]")
            Button("Shift Left") { document?.editor.shiftLines(right: false) }
                .keyboardShortcut("[")
            Button("Move Line Up") { document?.editor.moveLines(up: true) }
                .keyboardShortcut("[", modifiers: [.command, .option])
            Button("Move Line Down") { document?.editor.moveLines(up: false) }
                .keyboardShortcut("]", modifiers: [.command, .option])
            Button("Duplicate Line") { document?.editor.duplicateLines() }
                .keyboardShortcut("d")
            Button("Delete Line") { document?.editor.deleteLines() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
        }
    }
}

struct NavigateCommands: Commands {
    var body: some Commands {
        CommandMenu("Navigate") {
            Button("Open Link or Referenced File") { document?.followAtCaret() }
                .keyboardShortcut("j", modifiers: [.command, .control])
            Button("Go to Line…") { document?.isGoToLinePresented = true }
                .keyboardShortcut("l")
            Button("Document Structure…") { document?.showStructure() }
                .keyboardShortcut("o", modifiers: [.command, .option])

            Divider()

            Button("Next Heading") { document?.nextHeading(forward: true) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .control])
            Button("Previous Heading") { document?.nextHeading(forward: false) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .control])
            Button("Next Placeholder") { document?.nextPlaceholder(forward: true) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .control, .option])
            Button("Previous Placeholder") { document?.nextPlaceholder(forward: false) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .control, .option])
            Button("Next Problem") { document?.nextProblem(forward: true) }
                .keyboardShortcut("'")
            Button("Previous Problem") { document?.nextProblem(forward: false) }
                .keyboardShortcut("'", modifiers: [.command, .shift])
        }
    }
}

struct PlaceholderCommands: Commands {
    var body: some Commands {
        CommandMenu("Placeholder") {
            Section("Insert at the Cursor") {
                Button("Variable Reference <!--$var<>--><!---->") { document?.editor.insertVariableReference() }
                    .keyboardShortcut("v", modifiers: [.command, .option])
                Button("Comment Start <!--") { document?.editor.insertCommentStart() }
                    .keyboardShortcut("/")
                Button("Code Block ```") { document?.editor.insertCodeBlock() }
                    .keyboardShortcut("c", modifiers: [.command, .option, .shift])
            }
            Divider()
            Section("Variable Sources") {
                ForEach(PlaceholderSnippet.variableSources) { snippet in insert(snippet) }
            }
            Divider()
            Section("Generated Content") {
                ForEach(PlaceholderSnippet.contentManagers) { snippet in insert(snippet) }
            }
            Divider()
            Section("Variables") {
                ForEach(PlaceholderSnippet.variableReferences) { snippet in insert(snippet) }
            }
        }
    }

    private func insert(_ snippet: PlaceholderSnippet) -> some View {
        Button(snippet.title) {
            document?.editor.insertSnippet(snippet.text, block: snippet.block, actionName: "Insert \(snippet.title)")
        }
    }
}

struct MdshipCommands: Commands {
    var body: some Commands {
        CommandMenu("mdship") {
            command(.update).keyboardShortcut("u", modifiers: [.command, .shift])
            command(.forceUpdate)
            command(.toc)
            command(.includes)
            command(.diagrams)

            Divider()

            command(.number)
            command(.unnumber)
            command(.fixHeadings)
            command(.shiftHeadingsUp)
            command(.shiftHeadingsDown)

            Divider()

            command(.formatTables)
            command(.semanticLineBreaks)
            command(.reflow)

            Divider()

            command(.validateLinks)
            command(.aiCheck)
            command(.addChecksum)
            command(.verifyChecksum)

            Divider()

            Button("Show Console") { controller.showConsole() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Install or Upgrade mdship…") {
                controller.showConsole()
                Task { await MdshipService.shared.install() }
            }
            Button("Restart mdship MCP Server") { MdshipService.shared.restartServer() }
        }
    }

    private func command(_ command: MdshipCommand) -> some View {
        Button {
            document?.run(command)
        } label: {
            Label(command.usesSelection ? "\(command.title) (Selection or All)" : command.title,
                  systemImage: Preferences.shared.toolbarItem(for: command).icon)
        }
    }
}

struct ViewCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Toggle("Show Placeholders in Preview", isOn: Binding(
                get: { Preferences.shared.showPlaceholders },
                set: { Preferences.shared.showPlaceholders = $0 }))
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Fold") { document?.editor.foldAtCaret() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Unfold") { document?.editor.unfoldAtCaret() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Fold All") { document?.editor.foldAll() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option, .shift])
            Button("Unfold All") { document?.editor.unfoldAll() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option, .shift])

            Divider()

            Picker("Line Numbers", selection: Binding(
                get: { Preferences.shared.lineNumbers },
                set: { Preferences.shared.lineNumbers = $0 })) {
                Text("Off").tag(LineNumberMode.off)
                Text("Absolute").tag(LineNumberMode.absolute)
                Text("Relative to the Caret").tag(LineNumberMode.relative)
            }
            .pickerStyle(.menu)

            Toggle("Wrap Lines", isOn: Binding(
                get: { Preferences.shared.wrapLines },
                set: { Preferences.shared.wrapLines = $0 }))
            Toggle("Show Preview", isOn: Binding(
                get: { Preferences.shared.showPreview },
                set: { Preferences.shared.showPreview = $0 }))
                .keyboardShortcut("p", modifiers: [.command, .option])

            Toggle("Sync Preview Scrolling", isOn: Binding(
                get: { Preferences.shared.syncScrolling },
                set: { Preferences.shared.syncScrolling = $0 }))

            Divider()

            Button("Bigger Text") { zoom(by: 1) }
                .keyboardShortcut("+")
            Button("Smaller Text") { zoom(by: -1) }
                .keyboardShortcut("-")
            Button("Actual Size") { Preferences.shared.fontSize = Preferences.defaultFontSize }
                .keyboardShortcut("0")

            Divider()
        }
    }

    private func zoom(by step: Double) {
        let preferences = Preferences.shared
        preferences.fontSize = min(Preferences.fontSizes.upperBound,
                                   max(Preferences.fontSizes.lowerBound, preferences.fontSize + step))
    }
}

/// File ▸ Open Recent, from `~/.tychedit/recent.json`.
struct OpenRecentMenu: View {

    let recent = RecentFiles.shared

    var body: some View {
        Menu("Open Recent") {
            let files = recent.existing
            ForEach(files, id: \.self) { url in
                Button(RecentFiles.menuTitle(for: url, among: files)) {
                    DocumentController.shared.open(url)
                }
            }
            if !files.isEmpty {
                Divider()
            }
            Button("Clear Menu") { recent.clear() }
                .disabled(recent.paths.isEmpty)
        }
    }
}

extension RecentFiles {
    /// The file name, and its folder when another remembered file has the same name.
    static func menuTitle(for url: URL, among files: [URL]) -> String {
        let name = url.lastPathComponent
        guard files.filter({ $0.lastPathComponent == name }).count > 1 else { return name }
        let folder = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        return "\(name) — \(folder)"
    }
}
