import AppKit

/// Provides syntax highlighting for Mermaid diagram files.
///
/// Token categories based on the VS Code mermaid-syntax-highlight TextMate grammar
/// (bpruitt-goddard/vscode-mermaid-syntax-highlight):
/// - Diagram type declarations (bold keyword)
/// - Structural/control keywords
/// - Arrows and edge connectors (all variants)
/// - Node labels and quoted strings
/// - Pipe-delimited edge labels
/// - Comments (%%)
/// - Direction values and constants
/// - Style/classDef properties
/// - Numeric literals
/// - Node shape delimiters
/// - ER relationship operators
/// - Class diagram visibility markers
enum MermaidHighlighter {

    // MARK: - Public API

    /// Returns a syntax-highlighted NSAttributedString for the given mermaid source.
    static func highlight(_ text: String, fontSize: CGFloat, isDark: Bool) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let boldFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        let colors = Colors(isDark: isDark)

        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ])

        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        // Order matters — later rules override earlier ones for overlapping ranges.
        // Apply broad/low-priority rules first, specific/high-priority rules last.

        // 1. Node shape delimiters: ([, ]), ((, )), [[, ]], [( etc.
        apply(Patterns.shapeDelimiters, color: colors.bracket, font: font, to: result, in: fullRange)

        // 2. Arrows and edge connectors (all variants)
        apply(Patterns.arrows, color: colors.arrow, font: font, to: result, in: fullRange)

        // 3. ER relationship operators: ||--o{, }|..|{, etc.
        apply(Patterns.erRelationships, color: colors.arrow, font: font, to: result, in: fullRange)

        // 4. Structural/control keywords
        apply(Patterns.controlKeywords, color: colors.keyword, font: font, to: result, in: fullRange)

        // 5. Direction values: TB, TD, BT, RL, LR
        apply(Patterns.directions, color: colors.constant, font: font, to: result, in: fullRange)

        // 6. Gantt/git constants: crit, done, active, after, NORMAL, REVERSE, HIGHLIGHT
        apply(Patterns.constants, color: colors.constant, font: font, to: result, in: fullRange)

        // 7. Class diagram visibility markers: +, -, #, ~
        apply(Patterns.visibilityMarkers, color: colors.keyword, font: font, to: result, in: fullRange)

        // 8. Numeric literals
        apply(Patterns.numbers, color: colors.number, font: font, to: result, in: fullRange)

        // 9. Style/classDef property values: fill:#f9f,stroke:#333,stroke-width:2px
        apply(Patterns.styleProperties, color: colors.property, font: font, to: result, in: fullRange, captureGroup: 1)

        // 10. Quoted strings: "text"
        apply(Patterns.quotedStrings, color: colors.string, font: font, to: result, in: fullRange)

        // 11. Pipe-delimited edge labels: |text|
        apply(Patterns.pipeLabels, color: colors.string, font: font, to: result, in: fullRange)

        // 12. Node labels inside shape delimiters: A[label text here]
        apply(Patterns.nodeLabels, color: colors.string, font: font, to: result, in: fullRange)

        // 13. Diagram type declarations (highest keyword priority, bold)
        apply(Patterns.diagramTypes, color: colors.keyword, font: boldFont, to: result, in: fullRange)

        // 14. Comments: %% to end of line (highest priority — overrides everything)
        apply(Patterns.comments, color: colors.comment, font: font, to: result, in: fullRange)

        return result
    }

    // MARK: - Colors

    private struct Colors {
        let keyword: NSColor
        let arrow: NSColor
        let string: NSColor
        let comment: NSColor
        let constant: NSColor
        let bracket: NSColor
        let number: NSColor
        let property: NSColor

        init(isDark: Bool) {
            if isDark {
                keyword  = NSColor(red: 0.55, green: 0.50, blue: 0.95, alpha: 1)
                arrow    = NSColor(red: 0.60, green: 0.75, blue: 0.95, alpha: 1)
                string   = NSColor(red: 0.60, green: 0.85, blue: 0.55, alpha: 1)
                comment  = NSColor(red: 0.55, green: 0.55, blue: 0.60, alpha: 1)
                constant = NSColor(red: 0.85, green: 0.55, blue: 0.40, alpha: 1)
                bracket  = NSColor(red: 0.80, green: 0.70, blue: 0.35, alpha: 1)
                number   = NSColor(red: 0.85, green: 0.65, blue: 0.45, alpha: 1)
                property = NSColor(red: 0.75, green: 0.60, blue: 0.85, alpha: 1)
            } else {
                keyword  = NSColor(red: 0.40, green: 0.20, blue: 0.80, alpha: 1)
                arrow    = NSColor(red: 0.15, green: 0.40, blue: 0.75, alpha: 1)
                string   = NSColor(red: 0.20, green: 0.55, blue: 0.15, alpha: 1)
                comment  = NSColor(red: 0.45, green: 0.45, blue: 0.50, alpha: 1)
                constant = NSColor(red: 0.70, green: 0.30, blue: 0.10, alpha: 1)
                bracket  = NSColor(red: 0.60, green: 0.45, blue: 0.10, alpha: 1)
                number   = NSColor(red: 0.70, green: 0.40, blue: 0.10, alpha: 1)
                property = NSColor(red: 0.55, green: 0.35, blue: 0.65, alpha: 1)
            }
        }
    }

    // MARK: - Patterns

    /// Pre-compiled regex patterns based on the VS Code mermaid TextMate grammar.
    private enum Patterns {
        // Comments: %% to end of line
        static let comments = regex("%%.*$")

        // Diagram type declarations (at start of line)
        static let diagramTypes: NSRegularExpression = {
            let types = [
                "graph", "flowchart", "sequenceDiagram", "classDiagram",
                "stateDiagram(?:-v2)?", "erDiagram", "gantt", "pie",
                "gitGraph", "gitgraph", "journey", "mindmap", "timeline",
                "quadrantChart", "sankey", "xychart(?:-beta)?", "block",
                "packet", "architecture(?:-beta)?", "kanban",
                "requirementDiagram",
                "C4Context", "C4Container", "C4Component", "C4Deployment",
            ]
            return regex("^\\s*(" + types.joined(separator: "|") + ")\\b")
        }()

        // Structural/control keywords
        static let controlKeywords: NSRegularExpression = {
            let words = [
                "subgraph", "end", "direction", "participant", "actor",
                "activate", "deactivate", "loop", "alt", "else", "opt",
                "par", "and", "rect", "autonumber", "critical", "break",
                "Note", "note", "over", "left of", "right of",
                "class", "click", "callback", "link", "style", "classDef",
                "section", "title", "dateFormat", "axisFormat", "excludes",
                "todayMarker", "state", "as", "commit", "branch",
                "checkout", "merge", "cherry-pick", "group",
                "service", "junction", "accTitle", "accDescr",
            ]
            return regex("\\b(" + words.joined(separator: "|") + ")\\b")
        }()

        // Direction values
        static let directions = regex("\\b(TB|TD|BT|RL|LR)\\b")

        // Gantt/git/state constants
        static let constants = regex("\\b(crit|done|active|after|NORMAL|REVERSE|HIGHLIGHT)\\b")

        // Arrows and edge connectors — ordered longest-first to avoid partial matches.
        // Covers: solid (--), thick (==), dotted (-.-), with endpoints (x, o, >, <)
        // and multi-dash variants (---, -----, ===, etc.)
        static let arrows = regex(
            [
                "[xo<]?-{1,5}\\.{1,4}-{1,5}[xo>]?",  // dotted: -.-, -..-, -..->, <-.->
                "[xo<]?={2,5}[xo>]?",                   // thick: ==, ===, ==>, <==>
                "[xo<]?-{2,5}[xo>]?",                   // solid: --, ---, -->, <-->
                "-->",                                    // common arrow (ensure match)
            ].joined(separator: "|")
        )

        // ER relationship operators: ||--o{, }|..|{, |o--||, etc.
        static let erRelationships = regex(
            "(?:[|}][|o])(?:\\.{2}|-{2})(?:[o|][{|])"
        )

        // Quoted strings: "..."
        static let quotedStrings = regex("\"[^\"]*\"")

        // Pipe-delimited edge labels: |text|
        static let pipeLabels = regex("\\|[^|\\n]+\\|")

        // Node labels inside shape delimiters.
        // Matches text inside: [text], (text), {text}, ((text)), [[text]], [(text)]
        // Uses lookbehind for opening delimiter and lookahead for closing.
        static let nodeLabels = regex(
            "(?<=\\[\\[|\\[\\(|\\(\\[|\\(\\(|[\\[\\(\\{>])" +     // opening delimiter
            "([^\\]\\)\\}\\n]+?)" +                                  // label content
            "(?=\\]\\]|\\)\\]|\\]\\)|\\)\\)|[\\]\\)\\}])"           // closing delimiter
        )

        // Node shape delimiters: ([, ]), ((, )), [[, ]], [(, )]
        // Also single: [, ], (, ), {, }, >
        static let shapeDelimiters = regex(
            "\\(\\[|\\]\\)|\\(\\(|\\)\\)|\\[\\[|\\]\\]|\\[\\(|\\)\\]|[\\[\\]\\(\\)\\{\\}>]"
        )

        // Numeric literals (integers and decimals)
        static let numbers = regex("(?<![\\w#])[-+]?\\d+\\.?\\d*(?![\\w])")

        // Style/classDef property values after style/classDef keyword
        // Matches: fill:#f9f,stroke:#333,stroke-width:2px,color:#000
        // Uses a non-lookbehind approach: captures the property value group.
        static let styleProperties = regex(
            "\\b(?:style|classDef)\\s+\\S+\\s+([-,:;#\\w%.]+)"
        )

        // Class diagram visibility markers at start of member lines
        // Uses fixed-width lookbehind (exactly 4 spaces) since ICU
        // doesn't support variable-length lookbehinds.
        static let visibilityMarkers = regex("^\\s+[+\\-#~](?=\\w)")

        // MARK: - Helpers

        private static func regex(_ pattern: String) -> NSRegularExpression {
            do {
                return try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
            } catch {
                assertionFailure("Invalid mermaid regex pattern: \(pattern) — \(error)")
                // Return a pattern that never matches, so highlighting degrades gracefully.
                return try! NSRegularExpression(pattern: "(?!)", options: [])
            }
        }
    }

    // MARK: - Application

    private static func apply(
        _ regex: NSRegularExpression,
        color: NSColor,
        font: NSFont,
        to attrString: NSMutableAttributedString,
        in range: NSRange,
        captureGroup: Int = 0
    ) {
        let matches = regex.matches(in: attrString.string, options: [], range: range)
        for match in matches {
            let target = captureGroup > 0 && captureGroup < match.numberOfRanges
                ? match.range(at: captureGroup)
                : match.range
            guard target.location != NSNotFound else { continue }
            attrString.addAttribute(.foregroundColor, value: color, range: target)
            attrString.addAttribute(.font, value: font, range: target)
        }
    }
}
