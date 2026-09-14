import SwiftUI

/// Tychedit ▸ Settings. Everything here is saved in `~/.tychedit/settings.json`.
struct SettingsView: View {

    @Bindable var preferences = Preferences.shared
    let service = MdshipService.shared

    var body: some View {
        TabView {
            editing
                .tabItem { Label("Editing", systemImage: "square.and.pencil") }
            mdship
                .tabItem { Label("mdship", systemImage: "shippingbox") }
            ToolbarSettings(preferences: preferences)
                .tabItem { Label("Toolbar", systemImage: "wrench.and.screwdriver") }
        }
        .padding(20)
        .frame(width: 640)
        .task { await service.locate() }
    }

    private var editing: some View {
        Form {
            Toggle("Save automatically", isOn: $preferences.autosaveEnabled)
            Picker("Save changes after", selection: $preferences.autosaveInterval) {
                ForEach(Preferences.autosaveIntervals, id: \.self) { seconds in
                    Text(seconds < 60 ? "\(Int(seconds)) seconds" : "\(Int(seconds / 60)) minute\(seconds >= 120 ? "s" : "")")
                        .tag(seconds)
                }
            }
            .disabled(!preferences.autosaveEnabled)
            Text("Files with a location are also saved when their window loses focus and before mdship runs. Untitled documents are never saved automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Line numbers", selection: $preferences.lineNumbers) {
                Text("Off").tag(LineNumberMode.off)
                Text("1, 2, 3 …").tag(LineNumberMode.absolute)
                Text("Relative to the caret").tag(LineNumberMode.relative)
            }
            Stepper("Recent files to remember: \(preferences.recentFilesLimit)",
                    value: $preferences.recentFilesLimit, in: 0...50)
                .onChange(of: preferences.recentFilesLimit) { _, limit in
                    RecentFiles.shared.trim(to: limit)
                }

            LabeledContent("Settings file") {
                Button(TycheditDirectory.file(Preferences.fileName).path.replacingOccurrences(
                    of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")) {
                    NSWorkspace.shared.activateFileViewerSelecting([TycheditDirectory.file(Preferences.fileName)])
                }
                .buttonStyle(.link)
            }
            if let problem = preferences.loadProblem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var mdship: some View {
        Form {
            LabeledContent("Status") {
                switch service.status {
                case .unknown, .locating:
                    HStack { ProgressView().controlSize(.small); Text("Looking for mdship…") }
                case .missing:
                    Text("Not found").foregroundStyle(.red)
                case .ready(let version, let path):
                    VStack(alignment: .leading) {
                        Text("mdship \(version)")
                        Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            TextField("Path to mdship", text: $preferences.mdshipPath, prompt: Text("Found on the login shell's PATH"))
                .onSubmit { Task { await service.locate(force: true) } }
            HStack {
                Button("Look Again") { Task { await service.locate(force: true) } }
                Button(service.activity ?? "Install or Upgrade (pip install mdship)") {
                    DocumentController.shared.showConsole()
                    Task { await service.install() }
                }
                .disabled(service.activity != nil)
            }
            Toggle("Let mdship keep .bak backups", isOn: $preferences.keepBackups)
            Picker("Heading numbers", selection: $preferences.numberingStyle) {
                Text("1.1.").tag("period")
                Text("1 1").tag("space")
                Text("1)").tag("parenthesis")
            }
            Toggle("Leave a single title heading unnumbered", isOn: $preferences.numberingSkipsTitle)
            Stepper("Reflow width: \(preferences.reflowWidth)", value: $preferences.reflowWidth, in: 20...200, step: 4)
            Text("Tychedit's parameter suggestions and checks describe mdship 1.2.5. An installed mdship of another version may accept slightly different parameters; mdship's own run is final.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Which buttons the toolbar has, their order within each group, and their
/// icons -- which mdship commands also show in the mdship menu.
struct ToolbarSettings: View {

    @Bindable var preferences: Preferences

    /// Symbols offered in each icon's menu. Any other SF Symbol name can be typed.
    static let suggestions = [
        "arrow.triangle.2.circlepath", "arrow.clockwise", "bolt", "hammer", "wand.and.stars", "sparkles",
        "list.bullet.indent", "list.number", "list.bullet", "list.bullet.rectangle", "doc.on.doc", "doc.text",
        "tablecells", "text.alignleft", "text.justify", "link", "checkmark.seal", "number.square", "flowchart",
        "increase.indent", "decrease.indent", "exclamationmark.arrow.triangle.2.circlepath", "shippingbox",
        "dollarsign", "dollarsign.square", "dollarsign.circle", "chevron.left.forwardslash.chevron.right",
        "lessthan.square", "curlybraces", "ellipsis.curlybraces", "curlybraces.square", "text.bubble",
        "apple.terminal", "terminal", "sidebar.right", "rectangle", "eye", "arrow.turn.down.left", "arrow.right.to.line",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose the toolbar buttons and the icon each one shows; mdship commands show the same icon in the mdship menu. Buttons that show a state have an icon for each state. Icons are SF Symbol names.")
                .font(.caption)
                .foregroundStyle(.secondary)
            List {
                ForEach(ToolbarGroup.allCases, id: \.self) { group in
                    Section(group.title) {
                        ForEach(preferences.toolbar.filter { $0.group == group }) { item in
                            row(item.id)
                        }
                        .onMove { from, to in preferences.moveToolbarItems(in: group, from: from, to: to) }
                    }
                }
            }
            .frame(height: 400)
            HStack {
                Text("Drag rows to reorder the buttons within a group.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Restore Defaults") { preferences.toolbar = ToolbarCommand.defaults }
            }
        }
    }

    private func binding(_ id: String) -> Binding<ToolbarCommand>? {
        guard let index = preferences.toolbar.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(get: { preferences.toolbar[min(index, preferences.toolbar.count - 1)] },
                       set: { if index < preferences.toolbar.count { preferences.toolbar[index] = $0 } })
    }

    @ViewBuilder
    private func row(_ id: String) -> some View {
        if let item = binding(id) {
            let states = item.wrappedValue.action?.states ?? [""]
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Toggle("", isOn: item.shown)
                        .labelsHidden()
                        .help("Show in the toolbar")
                    Text(item.wrappedValue.title)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if states.count == 1 {
                        iconEditor(item, state: 0)
                    }
                }
                if states.count > 1 {
                    ForEach(Array(states.enumerated()), id: \.offset) { state, name in
                        HStack(spacing: 10) {
                            Text(name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            iconEditor(item, state: state)
                        }
                    }
                }
            }
        }
    }

    private func iconEditor(_ item: Binding<ToolbarCommand>, state: Int) -> some View {
        let icon = Binding<String>(
            get: { item.wrappedValue.icon(state: state) },
            set: { value in
                var icons = item.wrappedValue.icons
                while icons.count <= state { icons.append(item.wrappedValue.icon(state: icons.count)) }
                icons[state] = value
                item.wrappedValue.icons = icons
            })
        return HStack(spacing: 6) {
            Image(systemName: NSImage(systemSymbolName: icon.wrappedValue, accessibilityDescription: nil) == nil
                  ? "questionmark.square.dashed" : icon.wrappedValue)
                .frame(width: 22)
            TextField("", text: icon)
                .frame(width: 190)
                .font(.system(size: 11, design: .monospaced))
            Menu {
                ForEach(ToolbarSettings.suggestions, id: \.self) { symbol in
                    Button {
                        icon.wrappedValue = symbol
                    } label: {
                        Label(symbol, systemImage: symbol)
                    }
                }
                Divider()
                Button("Default") {
                    let defaults = item.wrappedValue.defaultIcons
                    icon.wrappedValue = defaults[min(state, defaults.count - 1)]
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

/// Everything mdship said, newest last.
struct ConsoleView: View {

    let service: MdshipService

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if service.entries.isEmpty {
                            Text("Output from mdship commands appears here.")
                                .foregroundStyle(.secondary)
                                .padding()
                        }
                        ForEach(service.entries) { entry in
                            ConsoleEntryView(entry: entry).id(entry.id)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Follow the output as it grows, not only when entries are added.
                .onChange(of: service.entries.last?.output.count) {
                    proxy.scrollTo("end", anchor: .bottom)
                }
                .onChange(of: service.entries.count) {
                    proxy.scrollTo("end", anchor: .bottom)
                }
            }
            Divider()
            HStack {
                if let activity = service.activity {
                    ProgressView().controlSize(.small)
                    Text(activity).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear") { service.clearConsole() }
            }
            .padding(8)
        }
    }
}

private struct ConsoleEntryView: View {

    let entry: ConsoleEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                switch entry.state {
                case .running:
                    ProgressView().controlSize(.mini)
                case .succeeded:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed:
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                }
                Text(entry.title).fontWeight(.semibold)
                if let document = entry.document {
                    Button(document.lastPathComponent) { DocumentController.shared.open(document) }
                        .buttonStyle(.link)
                }
                Spacer()
                Text(entry.date.formatted(date: .omitted, time: .standard))
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            Text(entry.output.isEmpty && entry.state == .running ? "running…" : entry.output)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(entry.output.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
