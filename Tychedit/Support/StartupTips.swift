import AppKit

/// The "Did You Know?" window: one tip, with Next for the following ones.
///
/// Shown at startup unless the person has turned that off, and on request from
/// the Help menu. Next steps through the pool from a random start, so pressing
/// it works through everything there is to know instead of risking the same
/// tip twice in a row.
@MainActor
enum StartupTips {

    private static var shownAtLaunch = false

    /// Once per launch, if the setting allows.
    static func presentAtLaunchIfWanted() {
        // Never under the test runner: the tests run inside the app, and a modal
        // window would hold the main thread and hang the whole run.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        guard !shownAtLaunch, Preferences.shared.showTipsAtStartup else { return }
        shownAtLaunch = true
        present()
    }

    /// Runs until the person presses OK. Blocks, like the app's other alerts.
    static func present() {
        let tips = TycheditTips.all
        guard !tips.isEmpty else { return }
        var index = Int.random(in: 0..<tips.count)
        while true {
            let alert = NSAlert()
            alert.messageText = "Did You Know?"
            alert.informativeText = tips[index]
            alert.icon = NSImage(systemSymbolName: "lightbulb", accessibilityDescription: nil)
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Next")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Do not show tips at startup"
            alert.suppressionButton?.state = Preferences.shared.showTipsAtStartup ? .off : .on
            let response = alert.runModal()
            Preferences.shared.showTipsAtStartup = alert.suppressionButton?.state != .on
            guard response == .alertSecondButtonReturn else { return }
            index = (index + 1) % tips.count
        }
    }
}
