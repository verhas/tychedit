import Foundation
import Observation

/// How the gutter numbers lines.
enum LineNumberMode: String, Codable, CaseIterable, Sendable {
    case off
    /// 1, 2, 3 ...
    case absolute
    /// Distance from the caret's line, as vi's `relativenumber`; the caret's
    /// own line shows its absolute number.
    case relative

    /// The next mode, for the toolbar button that steps through them.
    var next: LineNumberMode {
        switch self {
        case .off: .absolute
        case .absolute: .relative
        case .relative: .off
        }
    }

    var title: String {
        switch self {
        case .off: "Line Numbers Off"
        case .absolute: "Line Numbers"
        case .relative: "Relative Line Numbers"
        }
    }

    var icon: String {
        switch self {
        case .off: "text.justify.left"
        case .absolute: "list.number"
        case .relative: "arrow.up.and.down.text.horizontal"
        }
    }
}

/// One mdship command's button: whether it is in the toolbar, and its icon.
struct ToolbarCommand: Codable, Equatable, Sendable, Identifiable {
    /// `MdshipCommand.rawValue`.
    var command: String
    /// An SF Symbol name.
    var icon: String
    var shown: Bool

    var id: String { command }

    static let defaults: [ToolbarCommand] = MdshipCommand.allCases.map {
        ToolbarCommand(command: $0.rawValue, icon: $0.defaultIcon, shown: $0 == .update)
    }
}

/// Everything in `~/.tychedit/settings.json`.
///
/// Decoded leniently: a key missing from the file -- because it was written by
/// an older Tychedit, or removed by hand -- takes its default, and the rest of
/// the file still counts.
struct Settings: Codable, Equatable, Sendable {
    var fontSize = 13.0
    var showPlaceholders = true
    var syncScrolling = true
    var autosaveEnabled = true
    var autosaveInterval = 30.0
    var mdshipPath = ""
    var keepBackups = false
    var numberingStyle = "period"
    var numberingSkipsTitle = false
    var reflowWidth = 80
    var recentFilesLimit = 10
    var lineNumbers = LineNumberMode.off
    var toolbar = ToolbarCommand.defaults

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize
        showPlaceholders = try c.decodeIfPresent(Bool.self, forKey: .showPlaceholders) ?? d.showPlaceholders
        syncScrolling = try c.decodeIfPresent(Bool.self, forKey: .syncScrolling) ?? d.syncScrolling
        autosaveEnabled = try c.decodeIfPresent(Bool.self, forKey: .autosaveEnabled) ?? d.autosaveEnabled
        autosaveInterval = try c.decodeIfPresent(Double.self, forKey: .autosaveInterval) ?? d.autosaveInterval
        mdshipPath = try c.decodeIfPresent(String.self, forKey: .mdshipPath) ?? d.mdshipPath
        keepBackups = try c.decodeIfPresent(Bool.self, forKey: .keepBackups) ?? d.keepBackups
        numberingStyle = try c.decodeIfPresent(String.self, forKey: .numberingStyle) ?? d.numberingStyle
        numberingSkipsTitle = try c.decodeIfPresent(Bool.self, forKey: .numberingSkipsTitle) ?? d.numberingSkipsTitle
        reflowWidth = try c.decodeIfPresent(Int.self, forKey: .reflowWidth) ?? d.reflowWidth
        recentFilesLimit = try c.decodeIfPresent(Int.self, forKey: .recentFilesLimit) ?? d.recentFilesLimit
        lineNumbers = (try? c.decodeIfPresent(LineNumberMode.self, forKey: .lineNumbers)) ?? d.lineNumbers
        // Commands added in a later version appear, with their default icon,
        // after the ones the file already lists.
        let stored = (try? c.decodeIfPresent([ToolbarCommand].self, forKey: .toolbar)) ?? []
        let known = stored.filter { MdshipCommand(rawValue: $0.command) != nil }
        toolbar = known + ToolbarCommand.defaults.filter { item in !known.contains { $0.command == item.command } }
    }
}

/// The folder Tychedit keeps its files in: `~/.tychedit`.
enum TycheditDirectory {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tychedit", isDirectory: true)
    }

    static func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    static func create() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Pretty, sorted JSON, so the files read well and diff well.
    static func writeJSON<T: Encodable>(_ value: T, to name: String) throws {
        try create()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: file(name), options: .atomic)
    }
}

/// Settings shared by every window, kept in `~/.tychedit/settings.json`.
@MainActor
@Observable
final class Preferences {

    static let shared = Preferences()

    static let defaultFontSize = 13.0
    static let fontSizes = 9.0...32.0
    static let autosaveIntervals: [Double] = [10, 30, 60, 300]
    static let fileName = "settings.json"

    /// Posted after any setting changes, so open windows can follow.
    static let didChange = Notification.Name("TycheditPreferencesDidChange")

    private(set) var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            save()
            NotificationCenter.default.post(name: Preferences.didChange, object: nil)
        }
    }

    @ObservationIgnored private var fileDate: Date?
    /// Why the settings file could not be read, if it could not.
    private(set) var loadProblem: String?

    private init() {
        settings = Settings()
        let url = TycheditDirectory.file(Preferences.fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            loadFromFile()
        } else {
            settings = Preferences.migratedFromUserDefaults()
            save()
        }
    }

    // MARK: - Access

    var fontSize: Double {
        get { settings.fontSize }
        set { settings.fontSize = newValue }
    }
    var showPlaceholders: Bool {
        get { settings.showPlaceholders }
        set { settings.showPlaceholders = newValue }
    }
    var syncScrolling: Bool {
        get { settings.syncScrolling }
        set { settings.syncScrolling = newValue }
    }
    /// Save files that have a location on disk while you work: every
    /// `autosaveInterval` seconds, when a window loses focus, and before mdship runs.
    var autosaveEnabled: Bool {
        get { settings.autosaveEnabled }
        set { settings.autosaveEnabled = newValue }
    }
    var autosaveInterval: Double {
        get { settings.autosaveInterval }
        set { settings.autosaveInterval = newValue }
    }
    /// Explicit path to the mdship executable. Empty: look it up on the login shell's PATH.
    var mdshipPath: String {
        get { settings.mdshipPath }
        set { settings.mdshipPath = newValue }
    }
    /// Let mdship write `file.md.bak` before it changes a file.
    var keepBackups: Bool {
        get { settings.keepBackups }
        set { settings.keepBackups = newValue }
    }
    var numberingStyle: String {
        get { settings.numberingStyle }
        set { settings.numberingStyle = newValue }
    }
    var numberingSkipsTitle: Bool {
        get { settings.numberingSkipsTitle }
        set { settings.numberingSkipsTitle = newValue }
    }
    var reflowWidth: Int {
        get { settings.reflowWidth }
        set { settings.reflowWidth = newValue }
    }
    var recentFilesLimit: Int {
        get { settings.recentFilesLimit }
        set { settings.recentFilesLimit = max(0, min(100, newValue)) }
    }
    var lineNumbers: LineNumberMode {
        get { settings.lineNumbers }
        set { settings.lineNumbers = newValue }
    }
    var toolbar: [ToolbarCommand] {
        get { settings.toolbar }
        set { settings.toolbar = newValue }
    }

    func toolbarItem(for command: MdshipCommand) -> ToolbarCommand {
        toolbar.first { $0.command == command.rawValue }
            ?? ToolbarCommand(command: command.rawValue, icon: command.defaultIcon, shown: false)
    }

    // MARK: - The file

    private func save() {
        do {
            try TycheditDirectory.writeJSON(settings, to: Preferences.fileName)
            fileDate = modificationDate()
        } catch {
            NSLog("Tychedit: could not write settings: \(error.localizedDescription)")
        }
    }

    private func modificationDate() -> Date? {
        try? TycheditDirectory.file(Preferences.fileName).resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
    }

    private func loadFromFile() {
        let url = TycheditDirectory.file(Preferences.fileName)
        do {
            let loaded = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: url))
            loadProblem = nil
            fileDate = modificationDate()
            if loaded != settings { settings = loaded }
        } catch {
            // Keep the broken file for the user to repair; the next change
            // writes a fresh one, so set the broken one aside first.
            loadProblem = "\(url.path) could not be read: \(error.localizedDescription)"
            let aside = url.deletingPathExtension().appendingPathExtension("broken.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.copyItem(at: url, to: aside)
            fileDate = modificationDate()
        }
    }

    /// Reads the file again if it was edited outside Tychedit.
    func reloadIfChangedOnDisk() {
        guard let current = modificationDate(), current != fileDate else { return }
        loadFromFile()
    }

    /// Settings kept in user defaults by earlier versions.
    private static func migratedFromUserDefaults() -> Settings {
        let defaults = UserDefaults.standard
        var settings = Settings()
        func has(_ key: String) -> Bool { defaults.object(forKey: key) != nil }
        if has("fontSize") { settings.fontSize = defaults.double(forKey: "fontSize") }
        if has("showPlaceholders") { settings.showPlaceholders = defaults.bool(forKey: "showPlaceholders") }
        if has("syncScrolling") { settings.syncScrolling = defaults.bool(forKey: "syncScrolling") }
        if has("autosaveEnabled") { settings.autosaveEnabled = defaults.bool(forKey: "autosaveEnabled") }
        if has("autosaveInterval") { settings.autosaveInterval = defaults.double(forKey: "autosaveInterval") }
        if has("mdshipPath") { settings.mdshipPath = defaults.string(forKey: "mdshipPath") ?? "" }
        if has("keepBackups") { settings.keepBackups = defaults.bool(forKey: "keepBackups") }
        if has("numberingStyle") { settings.numberingStyle = defaults.string(forKey: "numberingStyle") ?? "period" }
        if has("numberingSkipsTitle") { settings.numberingSkipsTitle = defaults.bool(forKey: "numberingSkipsTitle") }
        if has("reflowWidth") { settings.reflowWidth = defaults.integer(forKey: "reflowWidth") }
        return settings
    }
}

/// The File ▸ Open Recent list, kept in `~/.tychedit/recent.json`.
@MainActor
@Observable
final class RecentFiles {

    static let shared = RecentFiles(directory: TycheditDirectory.url)
    static let fileName = "recent.json"

    private struct Stored: Codable {
        var files: [String]
    }

    private(set) var paths: [String] = []
    @ObservationIgnored private let directory: URL

    init(directory: URL) {
        self.directory = directory
        if let data = try? Data(contentsOf: directory.appendingPathComponent(RecentFiles.fileName)),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            paths = stored.files
        }
    }

    /// The remembered files that still exist, most recent first.
    var existing: [URL] {
        paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ url: URL, limit: Int) {
        let path = url.standardizedFileURL.path
        var updated = paths.filter { $0 != path }
        updated.insert(path, at: 0)
        paths = Array(updated.prefix(max(0, limit)))
        save()
    }

    func trim(to limit: Int) {
        guard paths.count > limit else { return }
        paths = Array(paths.prefix(max(0, limit)))
        save()
    }

    func clear() {
        paths = []
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try encoder.encode(Stored(files: paths)).write(to: directory.appendingPathComponent(RecentFiles.fileName),
                                                          options: .atomic)
        } catch {
            NSLog("Tychedit: could not write the recent files list: \(error.localizedDescription)")
        }
    }
}
