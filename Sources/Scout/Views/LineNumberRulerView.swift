import AppKit

/// A vertical ruler view that draws non-selectable line numbers alongside an NSTextView.
final class LineNumberRulerView: NSRulerView {
    // MARK: - Properties

    private let lineNumberFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private let textColor: NSColor = .secondaryLabelColor
    private let gutterPadding: CGFloat = 8

    // MARK: - Init

    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView!, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40

        // Redraw when the text view scrolls.
        NotificationCenter.default.addObserver(
            self, selector: #selector(viewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: textView.enclosingScrollView?.contentView
        )

        // Redraw when text content changes.
        if let textStorage = textView.textStorage {
            NotificationCenter.default.addObserver(
                self, selector: #selector(textDidChange(_:)),
                name: NSTextStorage.didProcessEditingNotification,
                object: textStorage
            )
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Drawing

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let scrollView = scrollView else { return }

        // Draw gutter background.
        NSColor.controlBackgroundColor.setFill()
        rect.fill()

        // Draw 1px separator line at the right edge.
        let separatorRect = NSRect(x: ruleThickness - 1, y: rect.minY, width: 1, height: rect.height)
        NSColor.separatorColor.setFill()
        separatorRect.fill()

        let visibleRect = scrollView.contentView.bounds
        let textContainerInset = textView.textContainerInset
        let text = textView.string as NSString
        let textLength = text.length

        guard textLength > 0 else {
            // Empty file — draw line number 1.
            drawLineNumber(1, at: textContainerInset.height - visibleRect.origin.y)
            return
        }

        // Get the range of glyphs visible in the scroll view.
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let visibleCharRange = layoutManager.characterRange(
            forGlyphRange: visibleGlyphRange, actualGlyphRange: nil
        )

        // Count newlines before the visible range to determine the starting line number.
        var lineNumber = 1
        if visibleCharRange.location > 0 {
            let beforeVisible = NSRange(location: 0, length: visibleCharRange.location)
            text.enumerateSubstrings(
                in: beforeVisible, options: [.byLines, .substringNotRequired]
            ) { _, _, _, _ in
                lineNumber += 1
            }
        }

        // Enumerate visible lines and draw their numbers.
        var charIndex = visibleCharRange.location
        while charIndex < NSMaxRange(visibleCharRange) {
            let lineRange = text.lineRange(for: NSRange(location: charIndex, length: 0))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)

            var effectiveRange = NSRange()
            let lineFragmentRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex, effectiveRange: &effectiveRange
            )

            let y = lineFragmentRect.origin.y + textContainerInset.height - visibleRect.origin.y

            drawLineNumber(lineNumber, at: y, lineHeight: lineFragmentRect.height)

            lineNumber += 1
            charIndex = NSMaxRange(lineRange)
        }

        // If the text ends with a newline, draw one more line number for the trailing empty line.
        if text.hasSuffix("\n"), charIndex == textLength {
            let lastGlyphIndex = layoutManager.glyphIndexForCharacter(at: max(0, textLength - 1))
            var effectiveRange = NSRange()
            let lastRect = layoutManager.lineFragmentRect(
                forGlyphAt: lastGlyphIndex, effectiveRange: &effectiveRange
            )
            let y = lastRect.maxY + textContainerInset.height - visibleRect.origin.y
            drawLineNumber(lineNumber, at: y, lineHeight: lastRect.height)
        }
    }

    // MARK: - Private Helpers

    private func drawLineNumber(_ number: Int, at y: CGFloat, lineHeight: CGFloat = 14) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: lineNumberFont,
            .foregroundColor: textColor,
        ]

        let string = "\(number)" as NSString
        let size = string.size(withAttributes: attributes)
        let x = ruleThickness - size.width - gutterPadding - 1 // -1 for separator
        let drawY = y + (lineHeight - size.height) / 2

        string.draw(at: NSPoint(x: x, y: drawY), withAttributes: attributes)
    }

    @objc private func viewDidScroll(_ notification: Notification) {
        needsDisplay = true
    }

    @objc private func textDidChange(_ notification: Notification) {
        updateThickness()
        needsDisplay = true
    }

    /// Adjusts the ruler width based on the number of digits in the highest line number.
    private func updateThickness() {
        guard let textView = clientView as? NSTextView else { return }
        let lineCount = max(1, textView.string.components(separatedBy: "\n").count)
        let digits = max(2, String(lineCount).count)
        let sampleString = String(repeating: "8", count: digits) as NSString
        let size = sampleString.size(withAttributes: [.font: lineNumberFont])
        let newThickness = ceil(size.width + gutterPadding * 2 + 1) // +1 for separator
        if abs(ruleThickness - newThickness) > 1 {
            ruleThickness = newThickness
        }
    }
}
