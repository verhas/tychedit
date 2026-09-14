import SwiftUI
import WebKit

/// A document window: editor on the left, preview on the right, status bar below.
struct ContentView: View {

    @Bindable var document: Document
    @State private var goToLineText = ""

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack(spacing: 0) {
                    if document.find.isVisible {
                        FindBar(find: document.find)
                        Divider()
                    }
                    HostedView(view: document.editor.scrollView)
                }
                .frame(minWidth: 240, idealWidth: 560, maxWidth: .infinity)
                HostedView(view: document.preview.webView)
                    .frame(minWidth: 240, idealWidth: 560, maxWidth: .infinity)
            }
            Divider()
            StatusBar(document: document)
        }
        .toolbar {
            // Editor display, on its own at the leading side, apart from the mdship commands.
            ToolbarItem(placement: .navigation) {
                let mode = Preferences.shared.lineNumbers
                Button {
                    Preferences.shared.lineNumbers = mode.next
                } label: {
                    Label(mode.title, systemImage: mode.icon)
                }
                .help("\(mode.title) — click for \(mode.next.title.lowercased())")
            }
            ToolbarItemGroup {
                OutlineMenu(document: document)
                // The mdship commands chosen in Settings ▸ Toolbar, with their icons.
                ForEach(Preferences.shared.toolbar.filter(\.shown)) { item in
                    if let command = MdshipCommand(rawValue: item.command) {
                        Button {
                            document.run(command)
                        } label: {
                            Label(command.title, systemImage: item.icon)
                        }
                        .help("mdship: \(command.title)")
                        .disabled(document.mdshipActivity != nil || !document.isMarkdown)
                    }
                }
                if document.mdshipActivity != nil {
                    ProgressView().controlSize(.small)
                }
                Toggle(isOn: Binding(get: { Preferences.shared.showPlaceholders },
                                     set: { Preferences.shared.showPlaceholders = $0 })) {
                    Label("Placeholders", systemImage: "curlybraces.square")
                }
                .help("Show mdship placeholders in the preview")
            }
        }
        .alert("Go to Line", isPresented: $document.isGoToLinePresented) {
            TextField("Line number", text: $goToLineText)
            Button("Go") {
                if let line = Int(goToLineText.trimmingCharacters(in: .whitespaces)) {
                    document.goToLine(line)
                }
                goToLineText = ""
            }
            Button("Cancel", role: .cancel) { goToLineText = "" }
        } message: {
            Text("Line 1 to \(document.editor.lineIndex.count)")
        }
    }
}

/// Headings and placeholders, to jump to.
struct OutlineMenu: View {

    let document: Document

    var body: some View {
        Menu {
            let headings = document.rendered.headings
            if headings.isEmpty {
                Text("No Headings")
            } else {
                Section("Headings") {
                    ForEach(headings) { heading in
                        Button(String(repeating: "    ", count: heading.level - 1) + heading.text) {
                            document.jump(toLine: heading.line)
                        }
                    }
                }
            }
            let placeholders = document.rendered.scan.placeholders
            if !placeholders.isEmpty {
                Section("Placeholders") {
                    ForEach(placeholders) { placeholder in
                        Button("\(placeholder.summary)  (line \(placeholder.openLines.lowerBound + 1))") {
                            document.jump(to: placeholder.openRange.location)
                        }
                    }
                }
            }
        } label: {
            Label("Outline", systemImage: "list.bullet.indent")
        }
        .help("Jump to a heading or placeholder")
    }
}

/// Puts an AppKit view owned by the document into the SwiftUI hierarchy, so the
/// view -- and its undo history and scroll position -- outlives SwiftUI updates.
struct HostedView: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
