import Foundation

/// The preview's page: loaded once per document folder, then updated in place.
///
/// Replacing the content element rather than reloading the page is what keeps
/// the preview from flashing white and losing its scroll position on every
/// keystroke.
enum PreviewPage {

    static func shell(fontSize: Double, showPlaceholders: Bool) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <!-- No scripts from the document, ever: a markdown file may carry raw
             HTML, and this page is not a place for it to run code. The app's
             own script lives in a separate content world, which this policy
             does not govern. Images may come from the document's folder, from
             data: URLs, or from the web, as they would on GitHub. -->
        <meta http-equiv="Content-Security-Policy"
              content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src \(PreviewController.scheme): data: https: http:; media-src \(PreviewController.scheme): https:; font-src data:">
        <style>\(css)</style>
        <style id="font-size">:root { --font-size: \(fontSize)px; }</style>
        </head>
        <body class="\(showPlaceholders ? "" : "hide-placeholders")">
        <article id="content"></article>
        </body>
        </html>
        """
    }

    /// Injected into the app's own content world; the page cannot see or call it.
    static let script = """
    window.tychedit = (function () {
        const content = () => document.getElementById('content');

        function update(html) {
            const root = content();
            if (!root) { return; }
            // Placeholder cards the user expanded stay expanded.
            const open = new Set();
            root.querySelectorAll('details[open][data-key]').forEach(d => open.add(d.dataset.key));
            root.innerHTML = html;
            root.querySelectorAll('details[data-key]').forEach(d => {
                if (open.has(d.dataset.key)) { d.open = true; }
            });
        }

        function setPlaceholdersVisible(visible) {
            document.body.classList.toggle('hide-placeholders', !visible);
        }

        function setFontSize(size) {
            document.getElementById('font-size').textContent = ':root { --font-size: ' + size + 'px; }';
        }

        // Scrolls so that source line `line` (fractional) is at the top,
        // interpolating between the blocks around it.
        function scrollToLine(line, atEnd) {
            const scroller = document.scrollingElement;
            if (atEnd) {
                scroller.scrollTop = scroller.scrollHeight;
                return;
            }
            if (line <= 0) {
                scroller.scrollTop = 0;
                return;
            }
            const blocks = Array.from(document.querySelectorAll('[data-line]'))
                .filter(e => e.offsetParent !== null || e.getClientRects().length > 0);
            let before = null, after = null;
            for (const element of blocks) {
                const l = Number(element.dataset.line);
                if (l <= line) {
                    if (!before || l >= Number(before.dataset.line)) { before = element; }
                } else if (!after || l < Number(after.dataset.line)) {
                    after = element;
                }
            }
            const top = e => e.getBoundingClientRect().top + scroller.scrollTop;
            const margin = 8;
            if (!before) {
                scroller.scrollTop = 0;
                return;
            }
            const beforeLine = Number(before.dataset.line);
            const beforeTop = top(before);
            let target = beforeTop;
            if (after) {
                const afterLine = Number(after.dataset.line);
                const fraction = (line - beforeLine) / Math.max(1, afterLine - beforeLine);
                target = beforeTop + (top(after) - beforeTop) * fraction;
            } else {
                const fraction = Math.min(1, line - beforeLine);
                target = beforeTop + before.getBoundingClientRect().height * fraction;
            }
            scroller.scrollTop = Math.max(0, target - margin);
        }

        return { update, setPlaceholdersVisible, setFontSize, scrollToLine };
    })();
    """

    static let css = """
    :root {
        color-scheme: light dark;
        --text: #1f2328;
        --muted: #59636e;
        --background: #ffffff;
        --border: #d1d9e0;
        --code-background: #f3f4f6;
        --link: #0969da;
        --placeholder: #7c4dff;
        --placeholder-background: rgba(124, 77, 255, 0.06);
        --managed: rgba(124, 77, 255, 0.35);
        --self: #0a7d55;
        --self-background: rgba(10, 125, 85, 0.06);
        --bad: #cf222e;
        --bad-background: rgba(207, 34, 46, 0.08);
        --ok: #1a7f37;
    }
    @media (prefers-color-scheme: dark) {
        :root {
            --text: #e6edf3;
            --muted: #9198a1;
            --background: #1e1e1e;
            --border: #3d444d;
            --code-background: #2b2b2e;
            --link: #4493f8;
            --placeholder: #b39dff;
            --placeholder-background: rgba(179, 157, 255, 0.08);
            --managed: rgba(179, 157, 255, 0.4);
            --self: #3fb950;
            --self-background: rgba(63, 185, 80, 0.07);
            --bad: #ff7b72;
            --bad-background: rgba(255, 123, 114, 0.1);
            --ok: #3fb950;
        }
    }
    html { background: var(--background); }
    body {
        margin: 0;
        padding: 20px 28px 40vh;
        font: var(--font-size, 14px)/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
        color: var(--text);
        background: var(--background);
        word-wrap: break-word;
    }
    #content { max-width: 920px; margin: 0 auto; }
    h1, h2, h3, h4, h5, h6 { margin: 1.4em 0 0.6em; line-height: 1.25; font-weight: 600; }
    h1 { font-size: 2em; padding-bottom: 0.3em; border-bottom: 1px solid var(--border); }
    h2 { font-size: 1.5em; padding-bottom: 0.3em; border-bottom: 1px solid var(--border); }
    h3 { font-size: 1.25em; }
    h4 { font-size: 1em; }
    h5 { font-size: 0.875em; }
    h6 { font-size: 0.85em; color: var(--muted); }
    #content > :first-child, .mds-body > :first-child { margin-top: 0; }
    p, blockquote, ul, ol, pre, .table-wrap, hr { margin: 0 0 1em; }
    a { color: var(--link); text-decoration: none; }
    a:hover { text-decoration: underline; }
    img { max-width: 100%; }
    hr { border: 0; height: 2px; background: var(--border); }
    blockquote { padding: 0 1em; color: var(--muted); border-left: 0.25em solid var(--border); }
    code, pre {
        font: 0.9em/1.45 ui-monospace, "SF Mono", Menlo, monospace;
        background: var(--code-background);
        border-radius: 6px;
    }
    code { padding: 0.15em 0.35em; }
    pre { padding: 12px 14px; overflow: auto; }
    pre code { padding: 0; background: none; font-size: 1em; }
    ul, ol { padding-left: 2em; }
    li + li { margin-top: 0.2em; }
    li.task { list-style: none; }
    li.task input { margin: 0 0.4em 0 -1.4em; vertical-align: middle; }
    .table-wrap { overflow-x: auto; }
    table { border-collapse: collapse; }
    th, td { border: 1px solid var(--border); padding: 5px 12px; }
    th { font-weight: 600; }
    tr:nth-child(2n) td { background: var(--code-background); }

    /* mdship placeholders */
    .mds-ph, .mds-frontmatter { margin: 0 0 1em; }
    .mds-def > summary, .mds-frontmatter > summary {
        cursor: pointer;
        font: 12px/1.6 -apple-system, BlinkMacSystemFont, sans-serif;
        color: var(--muted);
        list-style: none;
        display: flex;
        flex-wrap: wrap;
        align-items: baseline;
        gap: 0 8px;
    }
    .mds-def > summary::-webkit-details-marker, .mds-frontmatter > summary::-webkit-details-marker { display: none; }
    .mds-def > summary::before, .mds-frontmatter > summary::before { content: "\\25B8"; width: 0.8em; }
    .mds-def[open] > summary::before, .mds-frontmatter[open] > summary::before { content: "\\25BE"; }
    .mds-badge {
        font: 600 11px/1.5 ui-monospace, "SF Mono", Menlo, monospace;
        color: var(--placeholder);
        border: 1px solid var(--placeholder);
        border-radius: 4px;
        padding: 0 5px;
    }
    .mds-self .mds-badge { color: var(--self); border-color: var(--self); }
    .mds-summary { font-family: ui-monospace, "SF Mono", Menlo, monospace; color: var(--text); }
    .mds-role { font-style: italic; }
    .mds-state { border-radius: 4px; padding: 0 5px; background: var(--code-background); }
    .mds-state.mds-ok { color: var(--ok); }
    .mds-state.mds-bad { color: var(--bad); background: var(--bad-background); font-weight: 600; }
    .mds-config { margin: 6px 0 8px; font-size: 12px; background: var(--placeholder-background); }
    .mds-self .mds-config, .mds-frontmatter .mds-config { background: var(--self-background); }
    .mds-body {
        margin-top: 4px;
        padding: 8px 12px 1px;
        border-left: 3px solid var(--managed);
        background: var(--placeholder-background);
        border-radius: 0 6px 6px 0;
    }
    .mds-problem > .mds-body { border-left-color: var(--bad); background: var(--bad-background); }
    .mds-var {
        font: 600 0.72em/1 ui-monospace, "SF Mono", Menlo, monospace;
        color: var(--placeholder);
        background: var(--placeholder-background);
        border: 1px solid var(--managed);
        border-radius: 4px;
        padding: 1px 4px;
        margin-right: 3px;
        vertical-align: 0.1em;
    }
    .mds-var-end::after {
        content: "\\2039";
        color: var(--placeholder);
        font-weight: 700;
        margin-left: 1px;
    }

    /* Reader view: the document as its readers will see it. */
    .hide-placeholders .mds-self,
    .hide-placeholders .mds-def,
    .hide-placeholders .mds-var,
    .hide-placeholders .mds-var-end { display: none; }
    .hide-placeholders .mds-ph { margin: 0; }
    .hide-placeholders .mds-body {
        margin: 0;
        padding: 0;
        border: 0;
        background: none;
        border-radius: 0;
    }
    """
}
