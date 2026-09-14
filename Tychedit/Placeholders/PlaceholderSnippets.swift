import Foundation

/// Ready-to-edit placeholders for the Insert menu.
///
/// Each one is the smallest placeholder mdship accepts, with the value the
/// user most likely wants to change first between `\u{1}` and `\u{2}`, which
/// the editor selects after inserting. Shapes follow mdship's README and
/// documentation/PYTHON.md.
struct PlaceholderSnippet: Identifiable, Sendable {
    let title: String
    let text: String
    /// A block snippet must start a line; an inline one goes where the caret is.
    let block: Bool

    var id: String { title }

    static let variableSources: [PlaceholderSnippet] = [
        PlaceholderSnippet(title: "SET", text: """
            <!--SET
            \u{1}name\u{2}: "value"
            -->
            """, block: true),
        PlaceholderSnippet(title: "IMPORT", text: """
            <!--IMPORT
            name: "\u{1}config\u{2}"
            from: "settings.json"
            -->
            """, block: true),
        PlaceholderSnippet(title: "SLURP", text: #"""
            <!--SLURP
            name: "\#u{1}config\#u{2}"
            from: "settings.txt"
            strategy: "first"
            rules:
              - '(\w+)=(.+)'
            -->
            """#, block: true),
        PlaceholderSnippet(title: "SIP", text: #"""
            <!--SIP
            name: "\#u{1}app\#u{2}"
            from: "config.txt"
            vars:
              version: 'version:\s+([0-9.]+)'
            -->
            """#, block: true),
        PlaceholderSnippet(title: "SUP", text: #"""
            <!--SUP
            name: "\#u{1}doc.title\#u{2}"
            pattern: '^#+\s+(.*?)\s*$'
            -->
            """#, block: true),
        PlaceholderSnippet(title: "PYTHON define", text: """
            <!--PYTHON
            define: "\u{1}compute_vars.py\u{2}"
            -->
            """, block: true),
    ]

    static let contentManagers: [PlaceholderSnippet] = [
        PlaceholderSnippet(title: "INCLUDE", text: """
            <!--INCLUDE
            from: "\u{1}path/to/file\u{2}"
            -->
            <!--/INCLUDE-->
            """, block: true),
        PlaceholderSnippet(title: "TOC", text: """
            <!--TOC min-level: \u{1}2\u{2}
            max-level: 3
            -->
            <!--/TOC-->
            """, block: true),
        PlaceholderSnippet(title: "TEMPLATE", text: """
            <!--TEMPLATE
            content: |
              \u{1}Text with $variable\u{2}
            -->
            <!--/TEMPLATE-->
            """, block: true),
        PlaceholderSnippet(title: "JINJA2", text: """
            <!--JINJA2
            content: |
              \u{1}{% for item in items %}
              - {{ item }}
              {% endfor %}\u{2}
            -->
            <!--/JINJA2-->
            """, block: true),
        // The line after the comment is left empty: it is the slot mdship
        // fills with the image reference, and it refuses a non-empty one.
        PlaceholderSnippet(title: "MERMAID", text: """
            <!--MERMAID
            file: "\u{1}_diagrams/diagram.svg\u{2}"
            diagram: |
              flowchart LR
                A[Start] --\\> B[End]
            -->

            """, block: true),
        PlaceholderSnippet(title: "PYTHON run", text: """
            <!--PYTHON
            run: "\u{1}generate.py\u{2}"
            -->
            <!--/PYTHON-->
            """, block: true),
        PlaceholderSnippet(title: "AI", text: """
            <!--AI
            name: "\u{1}intro\u{2}"
            prompt: |
                Describe what to write here.
            -->
            <!--/AI-->
            """, block: true),
    ]

    static let variableReferences: [PlaceholderSnippet] = [
        PlaceholderSnippet(title: "Variable Reference", text: "<!--$\u{1}name\u{2}-->value", block: false),
        PlaceholderSnippet(title: "Variable Reference with Spaces", text: "<!--$\u{1}name\u{2}<>-->value with spaces<!---->",
                           block: false),
    ]
}
