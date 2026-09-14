import AppKit
import UniformTypeIdentifiers

/// At launch, offers to make Tychedit the default application for Markdown
/// files -- unless `~/.tychedit/NOT_DEFAULT_EDITOR` says the user declined for good.
@MainActor
enum DefaultEditor {

    static let markerName = "NOT_DEFAULT_EDITOR"

    static let markerText = """
        This file was created by Tychedit.

        When Tychedit starts, it checks whether it is the default application for
        opening Markdown (.md) files for your user account, and if it is not, it asks
        whether it should become one. You answered "No, Don't Ask Again", and this
        file is how Tychedit remembers that answer.

        Delete this file to make Tychedit ask about being the default Markdown editor
        again the next time it starts.

        Changing the default by hand works too: select a Markdown file in Finder,
        choose File > Get Info, pick an application under "Open with", and click
        "Change All...".

        """

    static var markdown: UTType? { UTType("net.daringfireball.markdown") }

    static var isDefault: Bool {
        guard let markdown, let current = NSWorkspace.shared.urlForApplication(toOpen: markdown),
              let identifier = Bundle.main.bundleIdentifier else { return false }
        return Bundle(url: current)?.bundleIdentifier == identifier
    }

    static func checkAtLaunch() {
        // Never while unit tests run inside the app: a modal alert would stop them.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let marker = TycheditDirectory.file(markerName)
        guard !FileManager.default.fileExists(atPath: marker.path), let markdown, !isDefault else { return }

        let current = NSWorkspace.shared.urlForApplication(toOpen: markdown)
        let currentName = current.map { FileManager.default.displayName(atPath: $0.path) }

        let alert = NSAlert()
        alert.messageText = "Make Tychedit the default editor for Markdown files?"
        alert.informativeText = (currentName.map { "Markdown files now open in \($0). " } ?? "")
            + "Tychedit would open them when you double-click one in Finder."
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "No, Don’t Ask Again")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: markdown) { error in
                guard let error else { return }
                DispatchQueue.main.async {
                    let failure = NSAlert(error: error)
                    failure.messageText = "Tychedit could not become the default Markdown editor."
                    failure.runModal()
                }
            }
        case .alertThirdButtonReturn:
            do {
                try TycheditDirectory.create()
                try markerText.write(to: marker, atomically: true, encoding: .utf8)
            } catch {
                NSAlert(error: error).runModal()
            }
        default:
            break
        }
    }
}
