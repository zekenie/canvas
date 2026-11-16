import Adornments
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Selection
import TestKit

// A clickable adornment may say what it is (`ClickableAdornment.help(for:in:)`): the canvas shows it as the
// system tooltip while the pointer rests on the chip. It's asked of the one hovered, with its shape and tag.

/// A chip at the row's right end that says how many times it has been asked, and for which shape.
enum Tip {}
extension Tip: Adornment {
    static var placement: AdornmentPlacement { .aboveTopRight }
    static var order: Order<Self> { .last }
}
extension Tip: ClickableAdornment {
    static func click(_ click: AdornmentClick, in editor: CanvasEditor) {}
    static func help(for click: AdornmentClick, in editor: CanvasEditor) -> String? {
        asked.append(click)
        return tipWords.isEmpty ? nil : "\(tipWords) \(editor.adornmentFrames(of: click.shape).count)"
    }
}

/// A group of tagged chips whose help is its tag's.
enum TaggedTips {}
extension TaggedTips: Adornment {
    static var placement: AdornmentPlacement { .aboveTopLeft }
}
extension TaggedTips: ClickableAdornment {
    static func click(_ click: AdornmentClick, in editor: CanvasEditor) {}
    static func help(for click: AdornmentClick, in editor: CanvasEditor) -> String? { click.tag.map { "About \($0.raw)" } }
}

/// What the tip says, nil's blank; the asks it has heard.
@MainActor var tipWords = "Tip"
@MainActor var asked: [AdornmentClick] = []

@MainActor let helpTests = Suite("A clickable adornment's help", [
    test("hovering a chip with help gives the canvas that help, asked of it with its shape and where it is; leaving it takes it away") {
        tipWords = "Tip"
        asked = []
        let h = try adornedHarness([everyShape(Tip.self) { _ in pinLabel }])
        let box = h.add(Box(boxFrame))
        expectEqual(h.editor.pointerHelp, nil, "nothing hovered")
        h.move(to: flagCenter)
        expectEqual(h.editor.pointerHelp, "Tip 1")
        expectEqual(asked.last, AdornmentClick(shape: box, tag: nil, rect: CGRect(x: 282, y: 73, width: 18, height: 18)))
        h.move(to: CGPoint(x: 350, y: 250))
        expectEqual(h.editor.pointerHelp, nil)
    },
    test("a chip that says nothing, or nothing in words, has no help; so has a clickable one that doesn't speak, and a press hides it") {
        tipWords = ""
        let h = try adornedHarness([everyShape(Tip.self) { _ in pinLabel }, everyShape(Pin.self, id: "pins") { _ in nil }])
        h.add(Box(boxFrame))
        h.move(to: flagCenter)
        expectEqual(h.editor.hoveredButton != nil, true)
        expectEqual(h.editor.pointerHelp, nil)
        tipWords = "Tip"
        h.move(to: CGPoint(x: 350, y: 250))
        h.move(to: flagCenter)
        expectEqual(h.editor.pointerHelp, "Tip 1")
        h.press(at: flagCenter)
        expectEqual(h.editor.pointerHelp, nil, "a press is under way")
        h.release()
    },
    test("a chip with no help of its own (the default) has none") {
        let h = try adornedHarness([everyShape(Pin.self) { _ in pinLabel }])
        h.add(Box(boxFrame))
        h.move(to: flagCenter)
        expectEqual(h.editor.hoveredButton != nil, true)
        expectEqual(h.editor.pointerHelp, nil)
    },
    test("each chip of a group has its own, by its tag") {
        let h = try adornedHarness([Contributor(id: "tagged") { $0.forEveryShape { scope in
            scope.adornments(TaggedTips.self) { _, _ in [chip("alpha"), chip("beta")] }
        } }])
        let box = h.add(Box(boxFrame))
        let frames = h.editor.adornmentFrames(of: box).filter { $0.adornment == AdornmentID.of(TaggedTips.self) }
        expectEqual(frames.count, 2)
        for frame in frames {
            h.move(to: h.editor.camera.toView(CGPoint(x: frame.rect.midX, y: frame.rect.midY)))
            expectEqual(h.editor.pointerHelp, "About \(frame.tag?.raw ?? "?")")
        }
    },
    test("the help is asked again after a commit while the pointer rests on the chip, so it follows what the shape now says") {
        tipWords = "Tip"
        let h = try adornedHarness([everyShape(Tip.self) { _ in pinLabel }])
        let box = h.add(Box(boxFrame))
        h.move(to: flagCenter)
        expectEqual(h.editor.pointerHelp, "Tip 1")
        tipWords = "Changed"
        h.editor.transact("Touch") { $0.update(box, as: Box.self) { $0.props.frame.size.width += 1 } }
        expectEqual(h.editor.pointerHelp, "Changed 1", "asked again once the commit has settled")
        tipWords = "Again"
        h.editor.canvasButtonsDidChange()
        expectEqual(h.editor.pointerHelp, "Again 1")
        tipWords = "Changed"
        h.editor.canvasButtonsDidChange()
        expectEqual(h.editor.pointerHelp, "Changed 1")
    },
])
