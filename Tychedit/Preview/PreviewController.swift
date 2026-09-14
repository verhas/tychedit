import AppKit
import UniformTypeIdentifiers
import WebKit

/// Owns the preview's web view and everything said to it.
///
/// One per window, created up front, so the model can push content before
/// SwiftUI has put the view on screen.
@MainActor
final class PreviewController: NSObject {

    /// Relative image paths in the document resolve against a URL in this
    /// scheme, which `LocalFileSchemeHandler` answers from disk. `loadHTMLString`
    /// with a `file:` base URL would be simpler, but WebKit refuses a page
    /// loaded from a string permission to read files, and images stay blank.
    nonisolated static let scheme = "tychedit-doc"

    let webView: WKWebView

    /// Called when a link is clicked that leaves the page.
    var openLink: ((Reference) -> Void)?

    private var baseURL: URL?
    private var pageLoaded = false
    private var pendingHTML: String?
    private var lastHTML: String?
    private var pendingScroll: (line: Double, atEnd: Bool)?
    private var showPlaceholders: Bool
    private var fontSize: Double

    init(showPlaceholders: Bool, fontSize: Double) {
        self.showPlaceholders = showPlaceholders
        self.fontSize = fontSize

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(LocalFileSchemeHandler(), forURLScheme: PreviewController.scheme)
        configuration.userContentController.addUserScript(WKUserScript(
            source: PreviewPage.script,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .defaultClient))
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = .textBackgroundColor
        super.init()
        webView.navigationDelegate = self
    }

    /// Shows `html`, resolving relative links against `directory`.
    func show(html: String, directory: URL?) {
        let base = PreviewController.baseURL(for: directory)
        // A new folder needs a new page, because the base URL is fixed when a
        // page loads. Within one folder the page stays and only its content changes.
        if base != baseURL {
            baseURL = base
            pageLoaded = false
            pendingHTML = html
            lastHTML = nil
            webView.loadHTMLString(PreviewPage.shell(fontSize: fontSize, showPlaceholders: showPlaceholders),
                                   baseURL: base)
            return
        }
        guard pageLoaded else {
            pendingHTML = html
            return
        }
        guard html != lastHTML else { return }
        lastHTML = html
        call("tychedit.update(\(PreviewController.jsonString(html)))")
    }

    func setPlaceholdersVisible(_ visible: Bool) {
        showPlaceholders = visible
        if pageLoaded { call("tychedit.setPlaceholdersVisible(\(visible))") }
    }

    func setFontSize(_ size: Double) {
        fontSize = size
        if pageLoaded { call("tychedit.setFontSize(\(size))") }
    }

    /// Scrolls so that source line `line` -- fractional, zero-based -- is at the top.
    func scroll(toLine line: Double, atEnd: Bool) {
        guard pageLoaded else {
            pendingScroll = (line, atEnd)
            return
        }
        call("tychedit.scrollToLine(\(line), \(atEnd))")
    }

    private func call(_ script: String) {
        webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { _ in }
    }

    /// `tychedit-doc://local/Users/me/docs/` for `/Users/me/docs`. The trailing
    /// slash matters: without it, `image.png` would resolve beside the folder
    /// instead of inside it.
    static func baseURL(for directory: URL?) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "local"
        let path = directory?.standardizedFileURL.path ?? NSHomeDirectory()
        components.path = path.hasSuffix("/") ? path : path + "/"
        return components.url ?? URL(string: "\(scheme)://local/")!
    }

    static func jsonString(_ string: String) -> String {
        // A top-level string is valid JSON, and valid JSON is a valid JS literal
        // once U+2028 and U+2029 are escaped -- which JSONSerialization does not do.
        guard let data = try? JSONSerialization.data(withJSONObject: [string], options: [.fragmentsAllowed]),
              var array = String(data: data, encoding: .utf8) else { return "\"\"" }
        array = array.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return String(array.dropFirst().dropLast())
    }
}

extension PreviewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        if let html = pendingHTML {
            pendingHTML = nil
            lastHTML = html
            call("tychedit.update(\(PreviewController.jsonString(html)))")
        }
        if let scroll = pendingScroll {
            pendingScroll = nil
            call("tychedit.scrollToLine(\(scroll.line), \(scroll.atEnd))")
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        // Jumps within the page, such as a generated table of contents.
        if url.fragment != nil, let base = baseURL,
           url.absoluteString.hasPrefix(base.absoluteString + "#") || url.absoluteString == base.absoluteString {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)

        // The app decides where a link goes: a Tychedit window for text files
        // (reusing an open one), the default app for everything else.
        let reference: Reference = url.scheme == PreviewController.scheme
            ? .file(URL(fileURLWithPath: url.path), url.fragment.map { .anchor($0) })
            : .web(url)
        if let openLink {
            openLink(reference)
        } else if case .web(let web) = reference {
            NSWorkspace.shared.open(web)
        }
    }
}

/// Answers `tychedit-doc://local/<absolute path>` with the file at that path.
///
/// Only reached by the preview page, which only asks for what the document
/// refers to. The app is unsandboxed, so anything the user can read, this can.
final class LocalFileSchemeHandler: NSObject, WKURLSchemeHandler {

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let file = URL(fileURLWithPath: url.path)
        guard let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
