import AppKit
import TestKit
import TextEditing

// `EditingTextView.highlights`: ranges of the text drawn on a rounded background under it, as a
// mention's pill is. Where they go, when the view draws them again, and what it draws, over a text
// view in an unshown window. Slash commands mark a command typed on a line with them (SlashCommandsTests).

private let sand = NSColor(red: 1, green: 0.9, blue: 0.4, alpha: 1)

private func mark(_ location: Int, _ length: Int) -> TextHighlight {
    TextHighlight(range: NSRange(location: location, length: length), fill: sand)
}

/// A text view of the kind `make` makes, in an unshown window, the keyboard in it.
@MainActor private func textInWindow<View: EditingTextView>(_ string: String, _ make: (CGRect) -> View) -> (window: NSWindow, view: View) {
    let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    let view = make(CGRect(x: 0, y: 0, width: 300, height: 200))
    view.string = string
    window.contentView = view
    window.makeFirstResponder(view)
    return (window, view)
}

@MainActor private func highlightedText(_ string: String = "apple banana cherry") -> (window: NSWindow, view: EditingTextView) {
    textInWindow(string) { EditingTextView(frame: $0) }
}

/// A text view that counts the times it was told to be drawn again. (`needsDisplay` can't say: AppKit
/// keeps the dirty rects an earlier request left, so it doesn't go back to false when set to it.)
@MainActor private final class RedrawCountingText: EditingTextView {
    private(set) var redraws = 0

    override var needsDisplay: Bool {
        didSet { if needsDisplay { redraws += 1 } }
    }
}

@MainActor let highlightTests = Suite("Highlights", [
    test("a highlight is a rect around its text, a little wider at both ends than the text, centered in its line") {
        let (_, view) = highlightedText()
        let apple = try require(view.frames(of: mark(0, 5)).first)
        let banana = try require(view.frames(of: mark(6, 6)).first)
        let whole = try require(view.frames(of: mark(0, 19)).first)
        expectEqual(view.frames(of: mark(0, 5)).count, 1)
        expect(apple.width > 0 && apple.width < banana.maxX, "apple is the first of the line")
        expect(banana.minX > apple.minX && banana.maxX < whole.maxX, "banana is after it and before the end")
        expectEqual(whole.minX, apple.minX, "the same start")
        expectEqual(apple.height, banana.height)
        expect(apple.minX < view.textContainerOrigin.x + (view.textContainer?.lineFragmentPadding ?? 0), "reaching past the text's start")
        let line = try require(view.caretFrame)
        expect(apple.height <= line.height, "no taller than the line")
        expect(abs(apple.midY - line.midY) < 2, "centered in it: \(apple) in \(line)")
    },

    test("a range that wraps is a rect a line") {
        let (_, view) = highlightedText(String(repeating: "banana ", count: 40))
        let frames = view.frames(of: mark(0, 280))
        expect(frames.count >= 3, "\(frames.count) lines: \(frames)")
        for (above, below) in zip(frames, frames.dropFirst()) { expect(below.minY > above.minY, "one under the other: \(above), \(below)") }
        for frame in frames { expect(frame.minX >= 0 && frame.maxX <= view.bounds.width + 4, "within the view: \(frame)") }
    },

    test("nothing is drawn for a range that is empty or isn't in the text") {
        let (_, view) = highlightedText()
        expectEqual(view.frames(of: mark(0, 0)), [])
        expectEqual(view.frames(of: mark(15, 10)), [], "past the end")
        expectEqual(view.frames(of: mark(40, 2)), [], "beyond it")
        expectEqual(view.frames(of: mark(-1, 3)), [])
        expectEqual(view.frames(of: mark(NSNotFound, 3)), [])
        expectEqual(view.frames(of: mark(19, 1)), [], "at the end")
    },

    test("the view is drawn again when its highlights change, and not when they don't; read-only, it lets go of them") {
        let (_, view) = textInWindow("apple banana cherry") { RedrawCountingText(frame: $0) }
        let first = view.redraws
        view.highlights = [mark(0, 5)]
        expect(view.redraws > first, "a change draws again")
        let drawn = view.redraws
        view.highlights = [mark(0, 5)]
        expectEqual(view.redraws, drawn, "the same highlights draw nothing again")
        view.highlights = [mark(0, 5), mark(6, 6)]
        expect(view.redraws > drawn, "another change does")
        let changed = view.redraws
        view.isEditable = false
        expectEqual(view.highlights, [])
        expect(view.redraws > changed, "and letting go of them")
        view.isEditable = true
        expectEqual(view.highlights, [], "and they don't come back")
    },

    test("it draws the fill where the frame is, in the view's coordinates, and not beside it") {
        let (_, view) = highlightedText()
        let highlight = mark(6, 6)
        let frame = try require(view.frames(of: highlight).first)
        view.highlights = [highlight]
        let rep = try require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        @MainActor func color(_ x: CGFloat, _ y: CGFloat) -> NSColor? {
            rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB)
        }
        // Where the text can't be: the highlight's padding before its first letter (2 points, so a point
        // and a half in is past the rect's anti-aliased edge and short of the glyph), and below the line.
        // The fill is sand, (1, 0.9, 0.4): pale in red and green, well under the background in blue.
        let padding = try require(color(frame.minX + 1.5, frame.midY))
        expect(padding.redComponent > 0.95 && padding.greenComponent > 0.85 && padding.blueComponent < 0.7, "the fill: \(padding)")
        let beside = try require(color(frame.minX + 4, frame.maxY + 60))
        expect(beside.redComponent > 0.95 && beside.greenComponent > 0.95 && beside.blueComponent > 0.95, "the view's background: \(beside)")
        // The rounded corner leaves its corner pixel to the background.
        let corner = try require(color(frame.minX + 0.2, frame.minY + 0.2))
        expect(corner.blueComponent > 0.9, "a rounded corner: \(corner)")
    },
])
