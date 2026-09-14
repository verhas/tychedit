import AppKit
import Observation

/// The find and replace bar's state, one per window.
///
/// Tychedit's own bar rather than AppKit's, because AppKit's has no regular
/// expressions, and so no replacement with `$1`.
@MainActor
@Observable
final class FindController {

    enum Field: Hashable { case find, replace }

    private(set) var isVisible = false
    var showsReplace = false

    var query = "" {
        didSet { if query != oldValue { search(fromOrigin: true) } }
    }
    var replacement = ""

    var options: FindOptions {
        didSet {
            guard options != oldValue else { return }
            Preferences.shared.findOptions = options
            search(fromOrigin: true)
        }
    }

    private(set) var matches: [NSRange] = []
    private(set) var currentIndex: Int?
    private(set) var problem: String?
    private(set) var message: String?

    /// Changed to move keyboard focus into the bar.
    private(set) var focusRequest = 0
    private(set) var focusField = Field.find

    @ObservationIgnored weak var editor: EditorController?
    /// Where typing a query searches from: the caret when the bar opened, or
    /// after the last explicit Next.
    @ObservationIgnored private var origin = 0
    @ObservationIgnored private var expression: NSRegularExpression?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init() {
        options = Preferences.shared.findOptions
    }

    // MARK: - Opening and closing

    /// Opens the bar -- with the replace row for Find and Replace -- and puts
    /// the caret in the search field, filled with the selection when there is one.
    func show(replace: Bool) {
        guard let editor else { return }
        let selection = editor.selectedRange
        if selection.length > 0, selection.length < 500 {
            let selected = editor.nsText.substring(with: selection)
            if !selected.contains("\n") {
                query = options.regex ? NSRegularExpression.escapedPattern(for: selected) : selected
            }
        }
        origin = selection.location
        showsReplace = replace || (isVisible && showsReplace)
        isVisible = true
        focusField = .find
        focusRequest += 1
        search(fromOrigin: false)
    }

    func close() {
        isVisible = false
        message = nil
        editor?.setFindHighlights([], current: nil)
        editor?.focus()
    }

    func useSelectionForFind() {
        guard let editor else { return }
        let selection = editor.selectedRange
        guard selection.length > 0 else { return NSSound.beep() }
        let selected = editor.nsText.substring(with: selection)
        query = options.regex ? NSRegularExpression.escapedPattern(for: selected) : selected
        origin = selection.location
        if !isVisible { show(replace: false) }
    }

    // MARK: - Searching

    /// Finds every match. Typing a query selects the first match at or after
    /// where the search started, so the selection refines in place.
    func search(fromOrigin moveSelection: Bool) {
        guard let editor else { return }
        message = nil
        guard !query.isEmpty else {
            expression = nil
            matches = []
            currentIndex = nil
            problem = nil
            editor.setFindHighlights([], current: nil)
            return
        }
        do {
            expression = try TextSearch.expression(for: query, options: options)
            problem = nil
        } catch {
            expression = nil
            matches = []
            currentIndex = nil
            problem = "Not a valid regular expression"
            editor.setFindHighlights([], current: nil)
            return
        }
        matches = TextSearch.matches(of: expression!, in: editor.text)
        if moveSelection, isVisible {
            select(matches.firstIndex { $0.location >= origin } ?? (matches.isEmpty ? nil : 0))
        } else {
            currentIndex = matches.firstIndex { $0 == editor.selectedRange }
            editor.setFindHighlights(matches, current: currentIndex.map { matches[$0] })
        }
    }

    /// The text changed: matches are found again, a moment later, without
    /// moving the selection.
    func textDidChange() {
        guard isVisible, !query.isEmpty else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.search(fromOrigin: false)
        }
    }

    func next() { step(forward: true) }

    func previous() { step(forward: false) }

    private func step(forward: Bool) {
        guard let editor else { return }
        if query.isEmpty {
            show(replace: showsReplace)
            return
        }
        if expression == nil { search(fromOrigin: false) }
        guard !matches.isEmpty else { return NSSound.beep() }
        let selection = editor.selectedRange
        let target: Int
        if forward {
            let after = NSMaxRange(selection)
            if let index = matches.firstIndex(where: { $0.location >= after && $0 != selection }) {
                target = index
            } else {
                target = 0
                message = "Continued from the top"
            }
        } else {
            if let index = matches.lastIndex(where: { NSMaxRange($0) <= selection.location && $0 != selection }) {
                target = index
            } else {
                target = matches.count - 1
                message = "Continued from the bottom"
            }
        }
        select(target)
        origin = matches[target].location
    }

    private func select(_ index: Int?) {
        currentIndex = index
        guard let editor else { return }
        if let index {
            editor.reveal(matches[index])
        }
        editor.setFindHighlights(matches, current: index.map { matches[$0] })
    }

    // MARK: - Replacing

    /// Replaces the selected match and moves on to the next one. When the
    /// selection is not a match, the first step only finds one.
    func replaceCurrent() {
        guard let editor, let expression else { return NSSound.beep() }
        let selection = editor.selectedRange
        guard matches.contains(selection),
              let replaced = TextSearch.replacement(for: selection, in: editor.text, expression: expression,
                                                    template: replacement, options: options) else {
            next()
            return
        }
        editor.replaceText(in: selection, with: replaced, actionName: "Replace")
        let after = selection.location + (replaced as NSString).length
        matches = TextSearch.matches(of: expression, in: editor.text)
        editor.textView.setSelectedRange(NSRange(location: after, length: 0))
        if let index = matches.firstIndex(where: { $0.location >= after }) ?? (matches.isEmpty ? nil : 0) {
            select(index)
        } else {
            select(nil)
        }
    }

    /// Replaces every match, as one change that one Undo takes back.
    func replaceAll() {
        guard let editor else { return }
        if expression == nil { search(fromOrigin: false) }
        guard let expression, !matches.isEmpty else { return NSSound.beep() }
        let result = TextSearch.replacingAll(in: editor.text, expression: expression, template: replacement, options: options)
        editor.applyMinimalEdit(result.text, actionName: "Replace All")
        matches = TextSearch.matches(of: expression, in: editor.text)
        currentIndex = nil
        editor.setFindHighlights(matches, current: nil)
        message = result.count == 1 ? "Replaced 1 match" : "Replaced \(result.count) matches"
    }

    /// "3 of 12", "12 matches", "No matches".
    var countText: String {
        guard !query.isEmpty, problem == nil else { return "" }
        if matches.isEmpty { return "No matches" }
        if let currentIndex { return "\(currentIndex + 1) of \(matches.count)" }
        return matches.count == 1 ? "1 match" : "\(matches.count) matches"
    }
}
