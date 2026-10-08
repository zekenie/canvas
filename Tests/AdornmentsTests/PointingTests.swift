import Adornments
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Selection
import TestKit

// A clickable adornment is a canvas button (Selection's): in the select tool, a press and a release
// on it click it, before anything under it. The test box's pin is at the row's right end, a disc 18
// across centered at (291, 82). Any other adornment is its shape's (Selection's `DecorationHits`):
// a press, a hover or a release on it is on its shape. The test box's caption is at the row's left
// end, from (100, 73), 18 tall.

/// Which shapes are pinned: something a service keeps, and says when it changes.
@MainActor final class Pins {
    var pinned: Set<ShapeID> = []
}

extension Pins: EditorService {}

/// Pins on the shapes the `Pins` service has pinned.
@MainActor func pinsPlugin() -> Contributor {
    Contributor(id: "pins") { r in
        r.service { _ in Pins() }
        r.adornmentForEveryShape(Pin.self) { shape, context in context.service(Pins.self)?.pinned.contains(shape.id) == true ? pinLabel : nil }
    }
}

@MainActor let pointingTests = Suite("Clicking an adornment", [
    test("a press and a release on a pin click it, once, and select nothing; the selection stays") {
        clicked = []
        let h = try adornedHarness([everyShape(Pin.self) { _ in pinLabel }])
        let box = h.add(Box(boxFrame))
        h.click(at: flagCenter)
        expectEqual(clicked, [box])
        expectEqual(h.editor.selectedShapeIDs, [])
        h.editor.selection = box
        h.click(at: flagCenter)
        expectEqual(clicked, [box, box])
        expectEqual(h.editor.selectedShapeIDs, [box])
    },
    test("the pointing hand shows over a pin, which is hovered, and pressed while the pointer's on it; released off it, nothing") {
        clicked = []
        let h = try adornedHarness([everyShape(Pin.self) { _ in pinLabel }])
        let box = h.add(Box(boxFrame))
        let button = AnyHashable(AdornmentButton(Pin.self, on: box))
        h.move(to: flagCenter)
        expectEqual(h.editor.cursor, .pointingHand)
        expectEqual(h.editor.hoveredButton, button)
        expectEqual(h.editor.hovered, nil)
        h.press(at: flagCenter)
        expectEqual(h.editor.pressedButton, button)
        h.drag(to: CGPoint(x: 350, y: 250))
        expectEqual(h.editor.pressedButton, nil)
        h.release()
        expectEqual(clicked, [])
        h.move(to: CGPoint(x: 350, y: 250))
        expectEqual(h.editor.cursor, .standard)
    },
    test("only a clickable adornment is a button; in other tools a pin is only drawn") {
        clicked = []
        let h = try adornedHarness([everyShape(Pin.self) { _ in pinLabel }, everyShape(Caption.self, id: "captions") { _ in AdornmentLabel("Lobby") }])
        h.add(Box(boxFrame))
        expectEqual(h.editor.button(atViewPoint: CGPoint(x: 110, y: 82)), nil, "a caption")
        h.editor.setTool(.hand)
        h.click(at: flagCenter)
        expectEqual(clicked, [])
    },
    test("a pin's hit is a disc, 3 points past its edge: its box's corner isn't") {
        let h = try adornedHarness([everyShape(Pin.self) { _ in pinLabel }])
        let box = h.add(Box(boxFrame))
        let button = AnyHashable(AdornmentButton(Pin.self, on: box))
        expectEqual(h.editor.button(atViewPoint: flagCenter), button)
        expectEqual(h.editor.button(atViewPoint: CGPoint(x: flagCenter.x + 11.9, y: flagCenter.y)), button, "3 points past its edge")
        expectEqual(h.editor.button(atViewPoint: CGPoint(x: flagCenter.x, y: flagCenter.y - 12.5)), nil, "more")
        expectEqual(h.editor.button(atViewPoint: CGPoint(x: 281, y: 72)), nil, "its box's corner, outside the disc")
        expectEqual(h.editor.button(atViewPoint: CGPoint(x: 291, y: 110)), nil, "on the shape")
    },
    test("a pin goes by where its shape is, not where a shake draws it, at every zoom") {
        let h = try adornedHarness([everyShape(Pin.self) { _ in pinLabel }])
        let box = h.add(Box(boxFrame))
        let button = AnyHashable(AdornmentButton(Pin.self, on: box))
        h.editor.setDrawingOffset(CGPoint(x: 5, y: 0), for: box)
        expectEqual(h.editor.button(atViewPoint: CGPoint(x: flagCenter.x - 11, y: flagCenter.y)), button)
        h.editor.skeletonZoom = 0                                    // in full at every zoom: a skeleton shows no pin
        h.editor.camera = Camera(origin: .zero, zoom: 0.125)         // the box's top-right corner at (37.5, 12.5); the pin 9 across
        expectEqual(h.editor.button(atViewPoint: CGPoint(x: 33, y: 1)), button)
        expectEqual(h.editor.button(atViewPoint: CGPoint(x: 33, y: 10.5)), nil)
        h.editor.skeletonZoom = 0.35
        expectEqual(h.editor.button(atViewPoint: CGPoint(x: 33, y: 1)), nil, "none on a skeleton")
    },
    test("a front shape's caption over a back shape's pin takes the press, as it's drawn over it") {
        clicked = []
        let h = try adornedHarness([everyShape(Pin.self) { $0.box?.minX == 100 ? pinLabel : nil },
                                    everyShape(Caption.self, id: "captions") { $0.box?.minX == 250 ? AdornmentLabel(longText) : nil }])
        h.add(Box(boxFrame))                                                   // its pin at 282 to 300
        let front = h.add(Box(CGRect(x: 250, y: 100, width: 150, height: 100)))  // its caption from 250, in front
        expectEqual(h.editor.button(atViewPoint: flagCenter), nil)
        h.click(at: flagCenter)
        expectEqual(clicked, [])
        expectEqual(h.editor.selectedShapeIDs, [front], "the caption's shape")
    },
    test("a pin that comes with a commit under a still pointer is hovered at once, and one that goes, let go of") {
        let h = try adornedHarness([everyShape(Pin.self) { ($0.box?.width ?? 0) >= 200 ? pinLabel : nil }])
        let box = h.add(Box(CGRect(x: 100, y: 100, width: 190, height: 120)))  // near enough to be looked at, with no pin
        h.move(to: flagCenter)
        expectEqual(h.editor.hoveredButton, nil)
        h.editor.transact { $0.update(box) { $0.box = boxFrame } }
        expectEqual(h.editor.hoveredButton, AnyHashable(AdornmentButton(Pin.self, on: box)))
        expectEqual(h.editor.cursor, .pointingHand)
        h.editor.transact { $0.delete([box]) }
        expectEqual(h.editor.hoveredButton, nil)
        expectEqual(h.editor.cursor, .standard)
    },
    test("a pin that comes or goes other than with a commit is found once its plugin says so (`adornmentsDidChange`)") {
        let h = try adornedHarness([pinsPlugin()])
        let box = h.add(Box(boxFrame))
        let pins = try require(h.editor.service(Pins.self))
        h.move(to: flagCenter)
        pins.pinned = [box]
        h.editor.adornmentsDidChange(for: [box])
        expectEqual(h.editor.hoveredButton, AnyHashable(AdornmentButton(Pin.self, on: box)))
        expectEqual(h.editor.adornmentFrames(of: box).map(\.adornment), [.of(Pin.self)])
        pins.pinned = []
        h.editor.adornmentsDidChange(for: [box])
        expectEqual(h.editor.hoveredButton, nil)
        expectEqual(h.editor.adornmentFrames(of: box), [])
    },
])

/// A caption on every shape, `text`.
@MainActor func captions(_ text: String = "Lobby") -> Contributor {
    everyShape(Caption.self, id: "captions") { _ in AdornmentLabel(text) }
}

/// The select tool sees through boxes 150 wide.
@MainActor func unselectableNarrowBoxes() -> Contributor {
    Contributor(id: "unselectable") { $0.contribute({ $0.box?.width != 150 }, to: ShapeSelectability.self, for: .any) }
}

extension CanvasEditor {
    /// A shape's caption, in world units.
    func caption(of id: ShapeID) throws -> CGRect {
        try require(adornmentFrames(of: id).first { $0.adornment == .of(Caption.self) }).rect
    }
}

@MainActor let shapePointingTests = Suite("Pointing at an adornment", [
    test("a press on a caption selects its shape, a drag from it moves the shape, and the pointer on it hovers the shape") {
        let h = try adornedHarness([captions()])
        let box = h.add(Box(boxFrame))
        let caption = try h.editor.caption(of: box)
        let on = CGPoint(x: caption.minX + 12, y: caption.midY)
        h.move(to: on)
        expectEqual(h.editor.hovered, box)
        expectEqual(h.editor.hoveredButton, nil)
        expectEqual(h.editor.cursor, .standard, "not a button")
        h.move(to: CGPoint(x: caption.maxX + 10, y: caption.midY))
        expectEqual(h.editor.hovered, nil, "beside it, the canvas")
        h.press(at: on)
        expectEqual(h.editor.selectedShapeIDs, [box])
        h.drag(to: on + CGPoint(x: 30, y: 40))
        h.release()
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 130, y: 140), "a lone box follows from the press")
        expectEqual(h.editor.selectedShapeIDs, [box])
    },
    test("the release is hit again: a click on a back shape's caption, drawn over a front shape, settles on the back shape") {
        let h = try adornedHarness([captions()])
        let back = h.add(Box(boxFrame))                                          // its caption from (100, 73)
        let front = h.add(Box(CGRect(x: 50, y: 60, width: 300, height: 30)))     // under the caption, which draws over it
        let on = CGPoint(x: 112, y: 82)
        expectEqual(h.editor.selectableShape(at: on), back)
        expectEqual(h.editor.selectableShape(at: CGPoint(x: 330, y: 82)), front, "beside it, the front shape")
        h.editor.selectedShapeIDs = [back, front]
        h.click(at: on)
        expectEqual(h.editor.selectedShapeIDs, [back])
        h.editor.selectedShapeIDs = [back, front]
        h.hold(.shift)
        h.click(at: on)
        h.hold([])
        expectEqual(h.editor.selectedShapeIDs, [front], "⇧ takes the caption's shape away")
    },
    test("a double-click on a card's caption edits the card, and places no card there") {
        let h = try adornedHarness([captions()])
        let card = h.add(Card(boxFrame))
        let on = CGPoint(x: 112, y: 82)
        h.click(at: on)
        h.press(at: on, clickCount: 2)
        expectEqual(h.editor.editingShapeID, card)
        h.release()
        expectEqual(h.editor.document.shapes.map(\.id), [card])
    },
    test("an unselectable shape's caption is seen through, to a caption beneath it; alone, a press there is on the canvas") {
        let h = try adornedHarness([captions(), unselectableNarrowBoxes()])
        let box = h.add(Box(boxFrame))
        h.add(Box(CGRect(x: 100, y: 100, width: 150, height: 120)))            // in front, its caption over the box's
        h.add(Box(CGRect(x: 400, y: 100, width: 150, height: 120)))            // alone: its caption from (400, 73)
        expectEqual(h.editor.selectableShape(at: CGPoint(x: 112, y: 82)), box)
        h.move(to: CGPoint(x: 412, y: 82))
        expectEqual(h.editor.hovered, nil)
        h.press(at: CGPoint(x: 412, y: 82))
        h.drag(to: CGPoint(x: 380, y: 60))
        expectEqual(h.editor.brush, CGRect(x: 380, y: 60, width: 32, height: 22), "a drag from there is a marquee")
        h.release()
        expectEqual(h.editor.selectedShapeIDs, [])
    },
    test("of two shapes' adornments in one place, the front shape's; of one shape's, the nearest") {
        let h = try adornedHarness([everyShape(Flag.self) { _ in flagLabel }, everyShape(Pin.self, id: "pins") { _ in pinLabel }])
        let back = h.add(Box(boxFrame))
        let front = h.add(Box(boxFrame))
        // The flag at the row's right end, 282 to 300; the pin 4 points before it, 260 to 278.
        expectEqual(h.editor.selectableShape(at: flagCenter), front)
        expectEqual(h.editor.button(atViewPoint: CGPoint(x: 279.5, y: 82)), AnyHashable(AdornmentButton(Pin.self, on: front)), "nearer the pin")
        expectEqual(h.editor.button(atViewPoint: CGPoint(x: 280.5, y: 82)), nil, "nearer the flag, which isn't a button")
        expectEqual(h.editor.selectableShape(at: CGPoint(x: 280.5, y: 82)), front)
        h.editor.transact { $0.delete([front]) }
        expectEqual(h.editor.selectableShape(at: flagCenter), back)
    },
    test("a hit is the capsule and 3 points around it, where its shape is, not where a shake draws it") {
        let h = try adornedHarness([captions()])
        let box = h.add(Box(boxFrame))
        let caption = try h.editor.caption(of: box)                            // 18 tall: its ends are half discs
        let points: [(CGPoint, ShapeID?, String)] = [
            (CGPoint(x: caption.maxX + 2.9, y: caption.midY), box, "3 points past its end"),
            (CGPoint(x: caption.maxX + 3.1, y: caption.midY), nil, "more"),
            (CGPoint(x: caption.midX, y: caption.minY - 2.9), box, "3 points above it"),
            (CGPoint(x: caption.midX, y: caption.minY - 3.1), nil, "more"),
            (CGPoint(x: caption.minX - 1, y: caption.minY - 1), nil, "its box's corner, outside the capsule"),
        ]
        for (point, hit, what) in points { expectEqual(h.editor.selectableShape(at: point), hit, what) }
        h.editor.setDrawingOffset(CGPoint(x: 5, y: 0), for: box)
        expectEqual(h.editor.selectableShape(at: CGPoint(x: caption.minX - 2, y: caption.midY)), box, "2 points left of where it is")
        expectEqual(h.editor.selectableShape(at: CGPoint(x: caption.maxX + 6, y: caption.midY)), nil, "a point past where it's drawn")
    },
])
