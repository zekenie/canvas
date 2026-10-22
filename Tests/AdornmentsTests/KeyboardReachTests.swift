import Adornments
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TestKit

// Principle 2, shared first: a clickable adornment a plugin puts on shapes, with no key code of its own,
// is a part of its shape (Selection's `ShapeParts`), reached with ⌥Tab and clicked with Return and Space,
// in the scope it is registered in, named by its label. One that shows a moment and fades is left out.

@MainActor let keyboardReachTests = Suite("Adornments from the keyboard", [
    test("a clickable adornment with no key code is reached with ⌥Tab and clicked with Return and Space, on the rect it is laid out at") {
        let h = try adornedHarness([everyShape(Pin.self) { _ in pinLabel }])
        clicks = []
        let box = h.add(Box(boxFrame))
        let pin = try require(h.editor.adornmentFrames(of: box).first)
        h.editor.selection = box
        expect(h.key(Chord.optionTab))
        let part = try require(h.editor.focusedPart)
        expectEqual(part.title, "Pin", "a symbol alone is called by its type")
        expectEqual(part.role, .button)
        expectEqual(part.rect, pin.rect)
        expect(h.key(Chord.return))
        expectEqual(clicks, [AdornmentClick(shape: box, rect: pin.rect)])
        expect(h.key(Chord.space))
        expectEqual(clicks.count, 2)
        expect(!h.editor.isHandHeld)
        expectEqual(h.editor.selectedShapeIDs, [box])
    },
    test("only where the adornment is: a kind out of its scope has no part, and a chip with text is called by it; a group's chips are each a part") {
        let h = try adornedHarness([everyShape(Pin.self, where: { $0.kind == Box.kind }) { _ in pinLabel }, chipsPlugin(["Person", "Place"])])
        let box = h.add(Box(boxFrame))
        let disc = h.add(Disc(CGRect(x: 100, y: 260, width: 200, height: 30)))
        expectEqual(h.editor.shapeParts(of: box).map(\.title), ["Person", "Place", "Pin"])
        expectEqual(h.editor.shapeParts(of: disc).map(\.title), ["Person", "Place"])
        h.editor.selection = box
        clicks = []
        h.key(Chord.optionTab)
        h.key(Chord.optionTab)
        h.key(Chord.return)
        expectEqual(clicks.map(\.tag), [AdornmentTag("Place")])
    },
    test("a chip that shows a moment and fades is no part: what its click does has a command") {
        let h = try adornedHarness([fadingChips()])
        let box = h.add(Box(boxFrame))
        h.show(Ghost.self, on: box)
        expect(!h.editor.adornmentFrames(of: box).isEmpty, "it shows")
        expect(h.editor.shapeParts(of: box).isEmpty)
        h.editor.selection = box
        h.key(Chord.optionTab)
        expect(!h.editor.hasFocusedPart)
    },
    test("zoomed out, where a skeleton shows no adornments, a shape has none for parts; the report names each adornment's parts and scope") {
        let h = try adornedHarness([everyShape(Pin.self) { _ in pinLabel }])
        let box = h.add(Box(boxFrame))
        expectEqual(h.editor.shapeParts(of: box).count, 1)
        h.editor.selection = box
        h.key(Chord.optionTab)
        expect(h.editor.hasFocusedPart)
        h.editor.camera.zoom = 0.1
        expect(h.editor.drawsSkeleton(of: box))
        expect(h.editor.shapeParts(of: box).isEmpty)
        expect(!h.editor.hasFocusedPart, "the focus went with the chip")
        expect(h.editor.registry.report.contains("parts Pin → every shape"), h.editor.registry.report)
    },
])
