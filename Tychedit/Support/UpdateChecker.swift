import AppKit
import Foundation

/// The latest release GitHub reports, as much of it as matters here.
struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }
}

/// Looks on GitHub for a newer release, and downloads it when told to.
///
/// Opt in: no connection is made unless the person turned on
/// Settings ▸ Editing ▸ "Check for updates at startup", or chose
/// Tychedit ▸ Check for Updates… -- which is a request, so it always goes out.
/// The startup check runs at most once a day. Nothing is downloaded, and the
/// app is never replaced, without a yes to the question that names the version.
@MainActor
final class UpdateChecker {

    static let shared = UpdateChecker()
    private init() {}

    private static let repository = "verhas/tychedit"
    private static let checkInterval: TimeInterval = 86400
    private static let releaseURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    private var hasCheckedThisLaunch = false
    private var isBusy = false

    /// The version this app reports about itself.
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// At startup: only when opted in, at most once a day, and silent unless there is something new.
    func checkAtLaunchIfEnabled() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        guard !hasCheckedThisLaunch, Preferences.shared.checkForUpdates else { return }
        hasCheckedThisLaunch = true
        if let last = Preferences.shared.lastUpdateCheck, Date().timeIntervalSince(last) < Self.checkInterval {
            return
        }
        Task { await check(interactive: false) }
    }

    /// The menu item: says so when there is nothing new, or the check failed.
    func checkNow() {
        Task { await check(interactive: true) }
    }

    private func check(interactive: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        Preferences.shared.lastUpdateCheck = Date()
        do {
            let release = try await Self.fetchLatestRelease()
            let remote = Self.version(fromTag: release.tagName)
            guard Self.isNewer(remote, than: Self.currentVersion) else {
                if interactive {
                    inform("Tychedit is up to date.", "You have version \(Self.currentVersion), the newest there is.")
                }
                return
            }
            guard let asset = release.assets.first(where: { $0.name.hasSuffix(".dmg") }) else {
                if interactive { inform("Tychedit \(remote) is out.", "It has no disk image to download yet.") }
                return
            }
            offer(version: remote, asset: asset)
        } catch {
            if interactive { inform("Could not check for updates.", error.localizedDescription) }
        }
    }

    private static func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: releaseURL, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    static func version(fromTag tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// Plain numeric comparison: "1.3.10" is newer than "1.3.9", which
    /// comparing the strings themselves would get backwards.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
        let r = parts(remote), l = parts(local)
        for i in 0..<max(r.count, l.count) {
            let a = i < r.count ? r[i] : 0
            let b = i < l.count ? l[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    private func inform(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }

    private func offer(version: String, asset: GitHubRelease.Asset) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Tychedit \(version) Is Available"
        alert.informativeText = "You have \(Self.currentVersion). Download it to your Downloads folder and open the disk image, ready to drag into Applications? Tychedit quits once that is done, after asking about any unsaved changes."
        alert.addButton(withTitle: "Download and Install")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await install(asset) }
    }

    private func install(_ asset: GitHubRelease.Asset) async {
        do {
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            let destination = downloads.appendingPathComponent(asset.name)
            let (downloaded, _) = try await URLSession.shared.download(from: asset.browserDownloadURL)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: downloaded, to: destination)
            NSWorkspace.shared.open(destination)
            // Quitting the ordinary way: unsaved documents are still asked about.
            NSApp.terminate(nil)
        } catch {
            inform("“\(asset.name)” could not be downloaded.", error.localizedDescription)
        }
    }
}
