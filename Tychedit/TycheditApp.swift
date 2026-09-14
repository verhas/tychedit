import SwiftUI

@main
struct TycheditApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Document windows are made by DocumentController, which needs to find,
        // reuse and close them by file -- something SwiftUI's window groups do
        // not offer. SwiftUI supplies Settings and the menu bar.
        SwiftUI.Settings {
            SettingsView()
        }
        .commands {
            FileCommands()
            FindCommands()
            FormatCommands()
            NavigateCommands()
            PlaceholderCommands()
            MdshipCommands()
            ViewCommands()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let controller = DocumentController.shared
            // `Tychedit notes.md` from a shell. Arguments that are not existing
            // files are ignored -- Xcode passes its own flags when it launches the app.
            let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            for argument in CommandLine.arguments.dropFirst() where !argument.hasPrefix("-") {
                let url = URL(fileURLWithPath: argument, relativeTo: workingDirectory).standardizedFileURL
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                    controller.open(url)
                }
            }
            controller.startAutosave()
            // Files opened from Finder arrive around launch; only if none did,
            // start with an empty window.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if controller.documents.isEmpty { controller.newDocument() }
                    // Asked once a window is up, so the question has a context.
                    DefaultEditor.checkAtLaunch()
                }
            }
            // Find mdship in the background, so the first command does not wait.
            Task { await MdshipService.shared.locate() }
        }
    }

    /// Finder's Open With, Diptych, and `open -a Tychedit file.md`.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls { DocumentController.shared.open(url) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            if !flag && DocumentController.shared.documents.isEmpty {
                DocumentController.shared.newDocument()
            }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            DocumentController.shared.prepareToTerminate() ? .terminateNow : .terminateCancel
        }
    }

    /// Settings edited in ~/.tychedit/settings.json by hand take effect on return.
    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated { Preferences.shared.reloadIfChangedOnDisk() }
    }

    /// Switching to another application is a moment to save.
    func applicationWillResignActive(_ notification: Notification) {
        MainActor.assumeIsolated { DocumentController.shared.autosaveAll() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { MdshipService.shared.shutdown() }
    }
}
