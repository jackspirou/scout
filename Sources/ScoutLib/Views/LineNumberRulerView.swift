import AppKit

/// A simple NSView that draws non-selectable line numbers alongside an NSTextView.
/// Unlike NSRulerView, this view sits next to the scroll view in the layout hierarchy,
/// avoiding clip view bounds offset issues that prevent text rendering.
final class LineNumberRulerView: NSView {
    // MARK: - Properties

    private let lineNumberFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private let textColor: NSColor = .secondaryLabelColor
    private let gutterPadding: CGFloat = 8

    private lazy var lineNumberAttributes: [NSAttributedString.Key: Any] = [
        .font: lineNumberFont,
        .foregroundColor: textColor,
    ]

    private weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?

    /// Cached character offsets for the start of each line. Built on text change, used for
    /// O(log n) line number lookup during draw instead of O(n) enumeration.
    private var lineStartOffsets: [Int] = [0]

    /// Width constraint for dynamic gutter sizing based on digit count.
    private var widthConstraint: NSLayoutConstraint?

    // MARK: - Init

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        self.scrollView = scrollView
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // Redraw when the text view scrolls.
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        // Redraw when the scroll view resizes (text rewraps at new width).
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: scrollView.contentView
        )

        // Redraw when text content changes (deferred to avoid mid-layout issues).
        if let textStorage = textView.textStorage {
            NotificationCenter.default.addObserver(
                self, selector: #selector(textDidChange(_:)),
                name: NSTextStorage.didProcessEditingNotification,
                object: textStorage
            )
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// The initial width of the gutter for constraint setup (2-digit minimum).
    var gutterWidth: CGFloat {
        widthForDigitCount(2)
    }

    /// Stores the width constraint so it can be updated dynamically.
    func setWidthConstraint(_ constraint: NSLayoutConstraint) {
        widthConstraint = constraint
    }

    // MARK: - Drawing

    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let scrollView = scrollView else { return }

        // Draw gutter background.
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()

        // Draw 1px separator line at the right edge.
        let separatorRect = NSRect(x: bounds.width - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height)
        NSColor.separatorColor.setFill()
        separatorRect.fill()

        let visibleRect = scrollView.contentView.bounds
        let textContainerInset = textView.textContainerInset
        let text = textView.string as NSString
        let textLength = text.length

        guard textLength > 0 else {
            drawLineNumber(1, at: textContainerInset.height)
            return
        }

        // Get the range of glyphs visible in the scroll view.
        let adjustedRect = visibleRect.offsetBy(dx: -textContainerInset.width, dy: -textContainerInset.height)
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: adjustedRect, in: textContainer)
        let visibleCharRange = layoutManager.characterRange(
            forGlyphRange: visibleGlyphRange, actualGlyphRange: nil
        )

        // Binary search for the line number at visibleCharRange.location.
        let lineNumber = lineNumberForCharacterOffset(visibleCharRange.location)

        // Enumerate visible lines and draw their numbers.
        // Y coordinates must account for the scroll offset since we're not inside the scroll view.
        var currentLine = lineNumber
        var charIndex = visibleCharRange.location
        while charIndex < NSMaxRange(visibleCharRange) {
            let lineRange = text.lineRange(for: NSRange(location: charIndex, length: 0))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)

            var effectiveRange = NSRange()
            let lineFragmentRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex, effectiveRange: &effectiveRange
            )

            // Convert from text container coordinates to our view coordinates.
            let y = lineFragmentRect.origin.y + textContainerInset.height - visibleRect.origin.y

            drawLineNumber(currentLine, at: y, lineHeight: lineFragmentRect.height)

            currentLine += 1
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
            drawLineNumber(currentLine, at: y, lineHeight: lastRect.height)
        }
    }

    // MARK: - Private Helpers

    private func drawLineNumber(_ number: Int, at y: CGFloat, lineHeight: CGFloat = 14) {
        let string = "\(number)" as NSString
        let size = string.size(withAttributes: lineNumberAttributes)
        let x = bounds.width - size.width - gutterPadding - 1 // -1 for separator
        let drawY = y + (lineHeight - size.height) / 2

        string.draw(at: NSPoint(x: x, y: drawY), withAttributes: lineNumberAttributes)
    }

    /// Returns the 1-based line number for the given character offset using binary search.
    private func lineNumberForCharacterOffset(_ offset: Int) -> Int {
        var low = 0
        var high = lineStartOffsets.count
        while low < high {
            let mid = (low + high) / 2
            if lineStartOffsets[mid] <= offset {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low // 1-based because lineStartOffsets[0] == 0 corresponds to line 1
    }

    /// Rebuilds the cached line start offsets from the current text content.
    private func rebuildLineOffsets() {
        guard let text = textView?.string as NSString? else {
            lineStartOffsets = [0]
            return
        }

        var offsets = [0]
        let length = text.length
        var index = 0
        while index < length {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let nextIndex = NSMaxRange(lineRange)
            if nextIndex > index {
                if nextIndex < length {
                    offsets.append(nextIndex)
                }
                index = nextIndex
            } else {
                break
            }
        }
        lineStartOffsets = offsets
    }

    /// Computes the gutter width needed for a given number of digits.
    private func widthForDigitCount(_ digits: Int) -> CGFloat {
        let sampleString = String(repeating: "8", count: digits) as NSString
        let size = sampleString.size(withAttributes: [.font: lineNumberFont])
        return ceil(size.width + gutterPadding * 2 + 1)
    }

    /// Updates the gutter width constraint based on the current line count.
    private func updateWidth() {
        let lineCount = max(1, lineStartOffsets.count)
        let digits = max(2, String(lineCount).count)
        let newWidth = widthForDigitCount(digits)
        if let constraint = widthConstraint, abs(constraint.constant - newWidth) > 1 {
            constraint.constant = newWidth
        }
    }

    @objc private func contentDidChange(_ notification: Notification) {
        needsDisplay = true
    }

    @objc private func textDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.rebuildLineOffsets()
            self?.updateWidth()
            self?.needsDisplay = true
        }
    }
}
