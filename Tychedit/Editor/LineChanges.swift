import Foundation

/// Which lines differ from the committed version, for the gutter.
struct LineChanges: Sendable, Equatable {

    enum Kind: Sendable, Equatable {
        /// A line that was not there before.
        case added
        /// A line that replaced one or more committed lines.
        case modified
    }

    /// Zero-based line of the current text → how it changed.
    var lines: [Int: Kind] = [:]
    /// Committed lines were removed just before these current lines. A value
    /// equal to the line count means at the end of the text.
    var deletions: Set<Int> = []

    static let none = LineChanges()

    var isEmpty: Bool { lines.isEmpty && deletions.isEmpty }

    /// Compares `current` with `base`, line by line.
    ///
    /// The diff is the standard library's `difference(from:)` -- Myers, as git's
    /// own default is. Runs of removed and inserted lines at the same place
    /// pair up as modifications; what is left over is added or deleted.
    static func compute(base: String, current: String) -> LineChanges {
        let old = split(base)
        let new = split(current)
        guard old != new else { return .none }
        let difference = new.difference(from: old)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var changes = LineChanges()
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if removed.contains(i) || inserted.contains(j) {
                var removedRun = 0
                while removed.contains(i + removedRun) { removedRun += 1 }
                var insertedRun = 0
                while inserted.contains(j + insertedRun) { insertedRun += 1 }
                for k in 0..<insertedRun {
                    changes.lines[j + k] = k < removedRun ? .modified : .added
                }
                if removedRun > insertedRun {
                    changes.deletions.insert(j + insertedRun)
                }
                i += removedRun
                j += insertedRun
            } else {
                i += 1
                j += 1
            }
        }
        return changes
    }

    /// Lines without their terminators, so a CRLF checkout and an LF edit agree.
    static func split(_ text: String) -> [Substring] {
        // "\r\n" is one Character in Swift: split on it as well as on "\n".
        text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
    }
}

/// The committed version of a file, from git.
enum GitBaseline {

    enum State: Sendable, Equatable {
        /// Not in a git repository, or git is not available: nothing to compare.
        case unavailable
        /// In a repository, but not in the last commit: every line is new.
        case uncommitted
        case committed(String)
    }

    /// `git show HEAD:file`. Blocking: call it off the main thread.
    static func state(for url: URL) -> State {
        let environment = ShellEnvironment.login
        guard let git = ShellEnvironment.executable("git", in: environment) else { return .unavailable }
        let directory = url.deletingLastPathComponent()
        let inside = ProcessRunner.run(git, ["-C", directory.path, "rev-parse", "--is-inside-work-tree"],
                                       environment: environment, timeout: 10)
        guard inside.status == 0, inside.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            return .unavailable
        }
        // `./name` is relative to -C, so symlinked folders and odd repository
        // roots need no path arithmetic here.
        let shown = ProcessRunner.run(git, ["-C", directory.path, "show", "HEAD:./\(url.lastPathComponent)"],
                                      environment: environment, timeout: 20)
        guard shown.status == 0 else { return .uncommitted }
        return .committed(shown.stdout)
    }
}
