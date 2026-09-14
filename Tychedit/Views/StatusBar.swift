import SwiftUI

/// Position, saving, mdship, and what the caret is on.
struct StatusBar: View {

    let document: Document

    var body: some View {
        let caret = document.caret
        HStack(spacing: 12) {
            Text("Ln \(caret.line + 1), Col \(caret.column + 1)")
                .monospacedDigit()
            if caret.selectionLength > 0 {
                Text("\(caret.selectionLength) selected")
                    .monospacedDigit()
            }
            Text("\(document.wordCount) words")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            SaveState(document: document)

            // What is under the caret matters more than a message from a while ago.
            if let problem = caret.problem {
                Label(problem.message, systemImage: problem.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(problem.severity == .error ? .red : .orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(problem.message)
            } else if let context = caret.context {
                ContextLabel(context: context)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if let message = document.statusMessage {
                Text(message.text)
                    .foregroundStyle(message.isError ? .red : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(message.text)
            }

            Spacer(minLength: 8)

            if let activity = document.mdshipActivity {
                ProgressView().controlSize(.mini)
                Text("mdship: \(activity)…")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ProblemsMenu(document: document)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(.bar)
    }
}

/// "Edited", "Saved 12:04", "Autosaved 12:04".
struct SaveState: View {

    let document: Document

    var body: some View {
        if document.fileURL == nil {
            EmptyView()
        } else if document.isDirty {
            Text("Edited").foregroundStyle(.secondary)
        } else if let saved = document.lastSaved {
            Text("\(document.lastSaveWasAutomatic ? "Autosaved" : "Saved") \(saved.formatted(date: .omitted, time: .shortened))")
                .foregroundStyle(.secondary)
        }
    }
}

/// What editing at the caret means in mdship terms.
struct ContextLabel: View {

    let context: CaretContext

    var body: some View {
        switch context {
        case .definition(let placeholder):
            Label("\(placeholder.kind.rawValue) definition: Esc suggests parameters", systemImage: "curlybraces")
                .foregroundStyle(.purple)
        case .managedContent(let placeholder):
            switch placeholder.integrity {
            case .edited, .moved:
                Label("Inside \(placeholder.kind.rawValue) content: already edited, mdship update will refuse",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            default:
                Label("Inside \(placeholder.kind.rawValue) content: mdship update overwrites edits here",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        case .variableReference(let variable):
            Label("Variable $\(variable.name): ⌘-click for its definition", systemImage: "dollarsign")
                .foregroundStyle(.purple)
        case .variableValue(let variable):
            Label("Value of $\(variable.name): mdship update replaces it", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }
}

/// The problems in the document, each one a jump to its place.
struct ProblemsMenu: View {

    let document: Document

    var body: some View {
        let problems = document.problems
        if problems.isEmpty {
            Label("No problems", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
        } else {
            let errors = problems.filter { $0.severity == .error }.count
            Menu {
                let fromMdship = problems.filter { $0.source == .mdship }
                let fromEditor = problems.filter { $0.source == .editor }
                if !fromEditor.isEmpty {
                    Section("Found While Editing") {
                        ForEach(Array(fromEditor.enumerated()), id: \.offset) { _, problem in
                            Button(problem.message) { document.jump(to: problem.location) }
                        }
                    }
                }
                if !fromMdship.isEmpty {
                    Section("Reported by mdship") {
                        ForEach(Array(fromMdship.enumerated()), id: \.offset) { _, problem in
                            Button(problem.message) { document.jump(to: problem.location) }
                        }
                    }
                }
            } label: {
                Label(problems.count == 1 ? "1 problem" : "\(problems.count) problems",
                      systemImage: errors > 0 ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(errors > 0 ? .red : .orange)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Placeholder problems found while editing, and what mdship reported last")
        }
    }
}
