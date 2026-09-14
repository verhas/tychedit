import SwiftUI

/// The find and replace bar above the editor.
struct FindBar: View {

    @Bindable var find: FindController
    @FocusState private var focus: FindController.Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                TextField("Find", text: $find.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .find)
                    .onSubmit { find.next() }
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.shift) else { return .ignored }
                        find.previous()
                        return .handled
                    }
                    .overlay(alignment: .trailing) {
                        Text(find.countText)
                            .font(.caption)
                            .foregroundStyle(find.matches.isEmpty ? .red : .secondary)
                            .padding(.trailing, 8)
                            .allowsHitTesting(false)
                    }

                Toggle(isOn: $find.options.caseSensitive) { Text("Aa").frame(minWidth: 18) }
                    .toggleStyle(.button)
                    .help("Match case")
                Toggle(isOn: $find.options.wholeWords) { Text("W").frame(minWidth: 18) }
                    .toggleStyle(.button)
                    .help("Whole words only")
                Toggle(isOn: $find.options.regex) { Text(".*").frame(minWidth: 18) }
                    .toggleStyle(.button)
                    .help("Regular expression; the replacement can use $1, $2 … for groups")

                ControlGroup {
                    Button { find.previous() } label: { Image(systemName: "chevron.left") }
                        .help("Previous match (⇧⌘G)")
                    Button { find.next() } label: { Image(systemName: "chevron.right") }
                        .help("Next match (⌘G)")
                }
                .frame(width: 60)

                Button(find.showsReplace ? "Hide Replace" : "Replace") { find.showsReplace.toggle() }
                    .buttonStyle(.link)
                Button("Done") { find.close() }
            }

            if find.showsReplace {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.2.squarepath")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    TextField(find.options.regex ? "Replace — $1, $2 … for groups" : "Replace", text: $find.replacement)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .replace)
                        .onSubmit { find.replaceCurrent() }
                    Button("Replace") { find.replaceCurrent() }
                        .help("Replace the selected match and find the next (Return in this field)")
                    Button("All") { find.replaceAll() }
                        .help("Replace every match; one Undo takes it back")
                }
            }

            if let text = find.problem ?? find.message {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(find.problem == nil ? Color.secondary : Color.red)
                    .padding(.leading, 22)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.bar)
        .onExitCommand { find.close() }
        .onChange(of: find.focusRequest, initial: true) {
            focus = find.focusField
        }
    }
}
