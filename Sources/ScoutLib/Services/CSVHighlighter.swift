import AppKit

/// Provides syntax highlighting for CSV and TSV files.
///
/// Highlights:
/// - Header row (first line) in bold
/// - Alternating column colors for visual column tracking
/// - Quoted strings
/// - Delimiters dimmed
///
/// Auto-detects the delimiter from the first line when not explicitly provided.
/// Supported delimiters: comma, semicolon, tab, pipe.
enum CSVHighlighter {
    // MARK: - Public API

    /// Returns a syntax-highlighted NSAttributedString for the given CSV/TSV source.
    /// - Parameters:
    ///   - text: The raw CSV/TSV content.
    ///   - delimiter: The field delimiter character. Pass `nil` to auto-detect.
    ///   - fontSize: The font size to use.
    ///   - isDark: Whether to use dark mode colors.
    static func highlight(_ text: String, delimiter: Character? = nil, fontSize: CGFloat,
                          isDark: Bool) -> NSAttributedString
    {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let boldFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        let colors = Colors(isDark: isDark)

        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ])

        let nsText = text as NSString
        let totalLength = nsText.length

        // Find the first line to detect delimiter
        let firstLineEnd = findLineEnd(in: nsText, from: 0)
        let firstLine = nsText.substring(with: NSRange(location: 0, length: firstLineEnd))
        let delim = delimiter ?? detectDelimiter(firstLine)

        var offset = 0

        var lineIndex = 0
        while offset < totalLength {
            // Find end of current line (excluding line terminator)
            let lineEnd = findLineEnd(in: nsText, from: offset)
            let lineRange = NSRange(location: offset, length: lineEnd - offset)
            let line = nsText.substring(with: lineRange)

            let isHeader = lineIndex == 0
            let fields = parseFields(line, delimiter: delim)
            var fieldOffset = offset

            for (colIndex, field) in fields.enumerated() {
                let fieldNSLength = (field as NSString).length

                if colIndex > 0 {
                    // Color the delimiter
                    let delimRange = NSRange(location: fieldOffset, length: 1)
                    if delimRange.location + delimRange.length <= totalLength {
                        result.addAttribute(.foregroundColor, value: colors.delimiter, range: delimRange)
                    }
                    fieldOffset += 1
                }

                let fieldRange = NSRange(location: fieldOffset, length: fieldNSLength)
                guard fieldRange.location + fieldRange.length <= totalLength else { break }

                if isHeader {
                    result.addAttribute(.font, value: boldFont, range: fieldRange)
                    result.addAttribute(.foregroundColor, value: colors.header, range: fieldRange)
                } else if field.hasPrefix("\"") && field.hasSuffix("\"") && field.count >= 2 {
                    result.addAttribute(.foregroundColor, value: colors.quoted, range: fieldRange)
                } else {
                    let color = colors.columns[colIndex % colors.columns.count]
                    result.addAttribute(.foregroundColor, value: color, range: fieldRange)
                }

                fieldOffset += fieldNSLength
            }

            // Advance past line content and line terminator(s)
            offset = lineEnd
            if offset < totalLength {
                let ch = nsText.character(at: offset)
                if ch == 0x0D { // \r
                    offset += 1
                    if offset < totalLength && nsText.character(at: offset) == 0x0A {
                        offset += 1
                    }
                } else if ch == 0x0A { // \n
                    offset += 1
                }
            }

            lineIndex += 1
        }

        return result
    }

    // MARK: - Colors

    private struct Colors {
        let header: NSColor
        let delimiter: NSColor
        let quoted: NSColor
        let columns: [NSColor]

        init(isDark: Bool) {
            if isDark {
                header = NSColor(red: 0.55, green: 0.70, blue: 0.95, alpha: 1)
                delimiter = NSColor(red: 0.45, green: 0.45, blue: 0.50, alpha: 1)
                quoted = NSColor(red: 0.60, green: 0.85, blue: 0.55, alpha: 1)
                columns = [
                    NSColor(red: 0.85, green: 0.75, blue: 0.55, alpha: 1), // warm yellow
                    NSColor(red: 0.65, green: 0.80, blue: 0.90, alpha: 1), // light blue
                    NSColor(red: 0.80, green: 0.65, blue: 0.80, alpha: 1), // lavender
                    NSColor(red: 0.70, green: 0.85, blue: 0.65, alpha: 1), // soft green
                    NSColor(red: 0.90, green: 0.70, blue: 0.60, alpha: 1), // peach
                    NSColor(red: 0.65, green: 0.75, blue: 0.85, alpha: 1), // steel blue
                ]
            } else {
                header = NSColor(red: 0.15, green: 0.35, blue: 0.70, alpha: 1)
                delimiter = NSColor(red: 0.55, green: 0.55, blue: 0.60, alpha: 1)
                quoted = NSColor(red: 0.20, green: 0.55, blue: 0.15, alpha: 1)
                columns = [
                    NSColor(red: 0.60, green: 0.45, blue: 0.10, alpha: 1), // dark gold
                    NSColor(red: 0.15, green: 0.40, blue: 0.65, alpha: 1), // blue
                    NSColor(red: 0.50, green: 0.30, blue: 0.55, alpha: 1), // purple
                    NSColor(red: 0.20, green: 0.50, blue: 0.25, alpha: 1), // green
                    NSColor(red: 0.65, green: 0.35, blue: 0.20, alpha: 1), // rust
                    NSColor(red: 0.30, green: 0.45, blue: 0.60, alpha: 1), // steel
                ]
            }
        }
    }

    // MARK: - Delimiter Detection

    private static let candidateDelimiters: [Character] = [",", ";", "\t", "|"]

    /// Auto-detects the delimiter by counting occurrences of candidate delimiters
    /// in the first line (outside of quoted fields). The most frequent wins.
    private static func detectDelimiter(_ firstLine: String) -> Character {
        var counts: [Character: Int] = [:]
        var inQuotes = false

        for char in firstLine {
            if char == "\"" {
                inQuotes.toggle()
            } else if !inQuotes && candidateDelimiters.contains(char) {
                counts[char, default: 0] += 1
            }
        }

        // Pick the delimiter with the highest count; ties break by candidate order.
        var best: Character = ","
        var bestCount = 0
        for delim in candidateDelimiters {
            let count = counts[delim, default: 0]
            if count > bestCount {
                bestCount = count
                best = delim
            }
        }
        return best
    }

    // MARK: - Parsing

    /// Finds the end offset of the current line (position of the first \r or \n, or end of string).
    private static func findLineEnd(in nsText: NSString, from start: Int) -> Int {
        let length = nsText.length
        var pos = start
        while pos < length {
            let ch = nsText.character(at: pos)
            if ch == 0x0A || ch == 0x0D { return pos }
            pos += 1
        }
        return pos
    }

    /// Parses a single CSV/TSV line into fields, respecting quoted fields.
    private static func parseFields(_ line: String, delimiter: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false

        for char in line {
            if char == "\"" {
                inQuotes.toggle()
                current.append(char)
            } else if char == delimiter, !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        fields.append(current)

        return fields
    }
}
