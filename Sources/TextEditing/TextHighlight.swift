import AppKit

/// A range of an `EditingTextView`'s text drawn on a rounded background, under the text, as a
/// mention's pill is: how a view marks text that means something to its owner (slash commands mark
/// the `/name` typed on a line, and what it's given). Set on the view as `highlights`; the view
/// draws them, so a host forwards nothing. UTF-16, as `NSRange` is.
public struct TextHighlight: Equatable {
    public var range: NSRange
    /// Drawn as it is: an owner that marks text on a surface it doesn't know takes the text's own
    /// color at a low alpha, as a pill does.
    public var fill: NSColor

    public init(range: NSRange, fill: NSColor) {
        self.range = range
        self.fill = fill
    }
}

extension EditingTextView {
    /// Where a highlight is drawn, in the view's coordinates: a rounded rect for each line its range
    /// reaches (a range that wraps is a rect a line), reaching a little past its text at both ends
    /// and as tall as a mention's pill in the text's font, centered in the line. Nothing for a range
    /// that is empty or isn't in the text, and, as for the caret's frame, nothing on TextKit 1.
    public func frames(of highlight: TextHighlight) -> [CGRect] {
        guard let layout = textLayoutManager, let content = layout.textContentManager, let storage = textStorage,
              highlight.range.length > 0, highlight.range.location >= 0, highlight.range.location <= storage.length,
              highlight.range.length <= storage.length - highlight.range.location,
              let start = content.location(content.documentRange.location, offsetBy: highlight.range.location),
              let end = content.location(start, offsetBy: highlight.range.length),
              let range = NSTextRange(location: start, end: end) else { return [] }
        layout.ensureLayout(for: range)
        let origin = textContainerOrigin
        let padding = TextEditingStyle.highlightPadding
        let highlightHeight = (highlightFontSize * TextEditingStyle.highlightHeight).rounded()
        var frames: [CGRect] = []
        layout.enumerateTextSegments(in: range, type: .standard, options: []) { _, segment, _, _ in
            let height = min(segment.height, highlightHeight)
            let frame = CGRect(x: segment.minX - padding + origin.x, y: segment.midY - height / 2 + origin.y,
                               width: segment.width + 2 * padding, height: height)
            // A line can come in more than one segment (a wrapped line's trailing space, a run of other
            // attributes): one rect a line, or two translucent fills would overlap in a darker seam.
            if let last = frames.last, abs(last.midY - frame.midY) < max(height, 1) / 2 {
                frames[frames.count - 1] = last.union(frame)
            } else {
                frames.append(frame)
            }
            return true
        }
        return frames
    }

    /// Draws `highlights` with the view's background, so the text is drawn over them.
    func drawHighlights(in dirtyRect: NSRect) {
        guard !highlights.isEmpty else { return }
        let radius = (highlightFontSize * TextEditingStyle.highlightCornerRadius).rounded(.up)
        for highlight in highlights {
            highlight.fill.setFill()
            for frame in frames(of: highlight) where frame.intersects(dirtyRect) {
                NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()
            }
        }
    }

    /// The size of the text a highlight is made for: what the person types in, else the view's font.
    private var highlightFontSize: CGFloat {
        (typingAttributes[.font] as? NSFont)?.pointSize ?? font?.pointSize ?? NSFont.systemFontSize
    }
}
