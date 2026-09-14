import Foundation

/// Which lines differ from the committed version, for the gutter.
struct LineChanges: Sendable, Equatable {

    enum Kind: Sendable, Equatable {
        /// A line that was not there before.
        case added
        /// A line that replaced one or more committed lines.
        case modified
    }

    /// One place where the text differs from the commit: the committed lines
    /// that were there and the current lines that are there now. Either side
    /// may be empty.
    struct Hunk: Sendable, Equatable {
        /// Zero-based first line of `oldLines` in the committed text.
        let oldStart: Int
        let oldLines: [String]
        /// Zero-based first line of `newLines` in the current text.
        let newStart: Int
        let newLines: [String]

        var newRange: Range<Int> { newStart..<(newStart + newLines.count) }

        /// Committed lines with no current line opposite them, shown as a
        /// deletion before this current line.
        var deletionLine: Int? { oldLines.count > newLines.count ? newStart + newLines.count : nil }
    }

    /// Zero-based line of the current text → how it changed.
    var lines: [Int: Kind] = [:]
    /// Committed lines were removed just before these current lines. A value
    /// equal to the line count means at the end of the text.
    var deletions: Set<Int> = []
    var hunks: [Hunk] = []

    /// The change the current `line` is part of.
    func hunk(containing line: Int) -> Hunk? {
        hunks.first { $0.newRange.contains(line) }
    }

    /// The change whose deleted lines are shown before `line`.
    func hunk(deletedBefore line: Int) -> Hunk? {
        hunks.first { $0.deletionLine == line }
    }

    /// Every line added: a file that is not in the last commit.
    static func allAdded(_ text: String) -> LineChanges {
        let new = split(text).map(String.init)
        var changes = LineChanges()
        for index in new.indices { changes.lines[index] = .added }
        changes.hunks = [Hunk(oldStart: 0, oldLines: [], newStart: 0, newLines: new)]
        return changes
    }

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
                changes.hunks.append(Hunk(oldStart: i, oldLines: old[i..<(i + removedRun)].map(String.init),
                                          newStart: j, newLines: new[j..<(j + insertedRun)].map(String.init)))
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

/// Edits that put committed lines back.
///
/// Each returns the range to replace and its replacement, or nil when the text
/// no longer holds the lines the change was computed for -- it was edited since,
/// and reverting would put lines in the wrong place.
enum ChangeRevert {

    typealias Edit = (range: NSRange, replacement: String)

    /// Only `line` goes back: a changed line to its committed text, an added line away.
    static func revertLine(_ line: Int, of hunk: LineChanges.Hunk, in text: String) -> Edit? {
        let ns = text as NSString
        let index = LineIndex(ns)
        guard stillMatches(hunk, index: index, ns: ns), hunk.newRange.contains(line) else { return nil }
        let offset = line - hunk.newStart
        if offset < hunk.oldLines.count {
            return (textRange(ofLine: line, index: index, ns: ns), hunk.oldLines[offset])
        }
        return (removal(ofLines: line...line, index: index), "")
    }

    /// The whole change goes back: its current lines replaced by its committed ones.
    static func revertHunk(_ hunk: LineChanges.Hunk, in text: String) -> Edit? {
        let ns = text as NSString
        let index = LineIndex(ns)
        guard stillMatches(hunk, index: index, ns: ns) else { return nil }
        let newline = newlineOf(text)
        if hunk.newLines.isEmpty {
            return insertion(hunk.oldLines, before: hunk.newStart, index: index, newline: newline)
        }
        if hunk.oldLines.isEmpty {
            return (removal(ofLines: hunk.newStart...(hunk.newRange.upperBound - 1), index: index), "")
        }
        let start = index.starts[hunk.newStart]
        let end = NSMaxRange(textRange(ofLine: hunk.newRange.upperBound - 1, index: index, ns: ns))
        return (NSRange(location: start, length: end - start), hunk.oldLines.joined(separator: newline))
    }

    /// The committed lines deleted before `hunk.deletionLine` come back.
    static func restoreDeletedLines(of hunk: LineChanges.Hunk, in text: String) -> Edit? {
        let ns = text as NSString
        let index = LineIndex(ns)
        guard stillMatches(hunk, index: index, ns: ns), let line = hunk.deletionLine else { return nil }
        let deleted = Array(hunk.oldLines[hunk.newLines.count...])
        return insertion(deleted, before: line, index: index, newline: newlineOf(text))
    }

    private static func stillMatches(_ hunk: LineChanges.Hunk, index: LineIndex, ns: NSString) -> Bool {
        guard hunk.newRange.upperBound <= index.count, hunk.newStart <= index.count else { return false }
        for (offset, expected) in hunk.newLines.enumerated() {
            var current = ns.substring(with: index.contentRange(ofLine: hunk.newStart + offset))
            if current.hasSuffix("\r") { current.removeLast() }
            if current != expected { return false }
        }
        return true
    }

    /// A line's text without the `\r` of a CRLF break, which stays where it is.
    private static func textRange(ofLine line: Int, index: LineIndex, ns: NSString) -> NSRange {
        var range = index.contentRange(ofLine: line)
        if range.length > 0, ns.character(at: NSMaxRange(range) - 1) == 13 { range.length -= 1 }
        return range
    }

    /// Lines removed with their line breaks; the last line takes the break before it.
    private static func removal(ofLines lines: ClosedRange<Int>, index: LineIndex) -> NSRange {
        var range = index.fullRange(ofLines: lines)
        if lines.upperBound == index.count - 1, lines.lowerBound > 0 {
            let start = NSMaxRange(index.contentRange(ofLine: lines.lowerBound - 1))
            range = NSRange(location: start, length: NSMaxRange(range) - start)
        }
        return range
    }

    private static func insertion(_ lines: [String], before line: Int, index: LineIndex, newline: String) -> Edit {
        if line < index.count {
            return (NSRange(location: index.starts[line], length: 0), lines.map { $0 + newline }.joined())
        }
        return (NSRange(location: index.length, length: 0), lines.map { newline + $0 }.joined())
    }

    private static func newlineOf(_ text: String) -> String {
        text.contains("\r\n") ? "\r\n" : "\n"
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
