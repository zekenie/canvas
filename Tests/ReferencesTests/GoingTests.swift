import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import References
import Selection
import TestKit

// Going to the original: the pill's leading symbol is a canvas button (hovered, pressed, clicked),
// and the context menu's first item and the panel's button run the same command. A button press
// doesn't select the pill first, so Back returns to where the person was.

/// Where the leading symbol's middle is, in view points.
@MainActor private func symbol(of id: ShapeID, in h: EditorHarness) throws -> CGPoint {
    let frame = try require(h.editor.document[id]).box ?? .zero
    return h.view(CGPoint(x: frame.minX + 18, y: frame.midY))
}

/// A box on a board of its own, which a pocket on the root owns: its id, and its pocket's.
@MainActor private func boxInPocket(_ h: EditorHarness) throws -> (box: ShapeID, pocket: ShapeID) {
    let pocket = h.add(Pocket(CGRect(x: 600, y: 100, width: 100, height: 100)))
    expect(h.enter(pocket))
    let box = h.addBox("inside")
    expect(h.editor.showBoard(.root))
    return (box, pocket)
}

@MainActor let goingTests = Suite("Going to the original", [
    test("the leading symbol is a button wherever there's an original to go to: live, and not public; not missing or not available, not the label, not zoomed out") {
        let h = try referenceHarness()
        let live = h.addReference(to: h.addBox("shapes"), label: "shapes")
        let hidden = h.addReference(to: h.addBox("secret", public: false, at: CGRect(x: 100, y: 400, width: 100, height: 100)), label: "secret",
                                    at: CGPoint(x: 400, y: 400))
        let gone = h.addReference(to: ShapeID(), label: "gone", at: CGPoint(x: 400, y: 500))
        let words = h.addReference(words: "stuff", at: CGPoint(x: 400, y: 600))
        expect(h.editor.button(atViewPoint: try symbol(of: live, in: h)) != nil, "live")
        expect(h.editor.button(atViewPoint: try symbol(of: hidden, in: h)) != nil, "private: there's still a shape to go to")
        expect(h.editor.button(atViewPoint: try symbol(of: gone, in: h)) == nil, "missing")
        expect(h.editor.button(atViewPoint: try symbol(of: words, in: h)) == nil, "words: the matches come with dynamic mode")
        let frame = try require(h.editor.document[live]).box ?? .zero
        expect(h.editor.button(atViewPoint: CGPoint(x: frame.minX + 50, y: frame.midY)) == nil, "not its label")
        expect(h.editor.button(atViewPoint: CGPoint(x: frame.minX + 18 + 8 + 3, y: frame.midY)) != nil, "a few points around the symbol, 4 in all")
        expect(h.editor.button(atViewPoint: CGPoint(x: frame.minX + 18 + 8 + 6, y: frame.midY)) == nil, "and no more")
        h.editor.camera = Camera(origin: .zero, zoom: 0.3)
        expect(h.editor.button(atViewPoint: CGPoint(x: (frame.minX + 18) * 0.3, y: frame.midY * 0.3)) == nil, "zoomed out it shows no symbol")
    },
    test("under a shape that covers the pill, it isn't there; and while the pill is edited, it isn't either") {
        let h = try referenceHarness()
        let id = h.addReference(to: h.addBox("shapes"), label: "shapes")
        let frame = try require(h.editor.document[id]).box ?? .zero
        expect(h.editor.button(atViewPoint: h.view(CGPoint(x: frame.minX + 18, y: frame.midY))) != nil)
        h.addBox("over", at: frame.insetBy(dx: -20, dy: -20))
        expect(h.editor.button(atViewPoint: h.view(CGPoint(x: frame.minX + 18, y: frame.midY))) == nil, "a shape in front takes the press")
        h.editor.undo()
        h.editor.beginEditing(id)
        expect(h.editor.button(atViewPoint: h.view(CGPoint(x: frame.minX + 18, y: frame.midY))) == nil, "while it's edited, a click is the text's")
    },
    test("the pointer on the symbol hovers the button, and the pill draws the accent's disc over the symbol; pressed, a step darker") {
        let h = try referenceHarness()
        let id = h.addReference(to: h.addBox("shapes"), label: "shapes")
        let frame = try require(h.editor.document[id]).box ?? .zero
        let box = CGRect(x: frame.minX + 10, y: frame.midY - 8, width: 16, height: 16)
        let rest = render(h.editor)
        h.move(to: try symbol(of: id, in: h))
        expect(h.editor.hoveredButton != nil, "hovered")
        expectEqual(h.editor.cursor, .pointingHand, "the pointing hand")
        let hovered = render(h.editor)
        var accent = 0, arrow = 0
        for y in Int(box.minY)..<Int(box.maxY) {
            for x in Int(box.minX)..<Int(box.maxX) {
                let p = pixel(hovered, at: CGPoint(x: x, y: y))
                if p[2] > p[0] + 60 { accent += 1 }
                if p[0] > 230, p[1] > 230, p[2] > 230, hypot(CGFloat(x) - box.midX, CGFloat(y) - box.midY) < 5 { arrow += 1 }
            }
        }
        expect(accent > 20, "the accent's blue disc: \(accent) pixels")
        expect(arrow >= 6, "the white arrow in it, not a solid disc: \(arrow) pixels")
        expect(changedPixels(rest, hovered, in: box) > 20, "it changed the symbol's box")
        h.press()
        expect(h.editor.pressedButton != nil, "pressed")
        let pressed = render(h.editor)
        expect(changedPixels(hovered, pressed, in: box) > 0, "darker while it's pressed")
        h.release()
        h.move(to: CGPoint(x: frame.minX + 60, y: frame.midY))
        expect(h.editor.hoveredButton == nil, "off it, nothing")
        expectEqual(changedPixels(rest, render(h.editor), in: box), 0, "and the symbol is as it was")
    },
    test("a click on the symbol goes to the shape: it's selected, in view, one step back, and the pill isn't selected first") {
        let h = try referenceHarness()
        let box = h.addBox("shapes", at: CGRect(x: 100, y: 100, width: 150, height: 100))
        let id = h.addReference(to: box, label: "shapes")
        h.editor.selectedShapeIDs = []
        h.click(at: try symbol(of: id, in: h))
        h.wait(0)
        expectEqual(h.editor.selectedShapeIDs, [box], "the original, not the pill")
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [], "Back returns to where the person was")
    },
    test("across boards: it shows the other board, selects the shape there, and Back comes back") {
        let h = try referenceHarness([PocketsPlugin(), pocketTitles])
        let (box, pocket) = try boxInPocket(h)
        let id = h.addReference(to: box, label: "inside")
        h.click(at: try symbol(of: id, in: h))
        h.wait(0)
        expectEqual(h.editor.board, BoardID(owner: pocket))
        expectEqual(h.editor.selectedShapeIDs, [box])
        h.editor.goBack()
        expectEqual(h.editor.board, .root, "one step back")
    },
    test("a locked pill still goes, and a click on the symbol of a pill with nothing to go to does what any click does: selects it") {
        let log = RefusalLog()
        let h = try referenceHarness([FreezingPlugin(log: log)])
        let box = h.addBox("shapes")
        let id = h.addReference(to: box, label: "shapes")
        h.editor.freeze([id])
        expect(h.editor.isReadOnly(id), "frozen")
        h.click(at: try symbol(of: id, in: h))
        h.wait(0)
        expectEqual(h.editor.selectedShapeIDs, [box], "it went")
        expect(log.refusals.isEmpty, "going changes nothing, so nothing was refused")
        let gone = h.addReference(to: ShapeID(), label: "gone", at: CGPoint(x: 400, y: 500))
        h.click(at: try symbol(of: gone, in: h))
        expectEqual(h.editor.selectedShapeIDs, [gone], "no button there: the pill is pressed, as anywhere on it")
    },
    test("the menu has Go to Original first, dimmed when there's nothing to go to, and not on a reference of words; it goes as the button does") {
        let h = try referenceHarness()
        let box = h.addBox("shapes")
        let id = h.addReference(to: box, label: "shapes")
        let frame = try require(h.editor.document[id]).box ?? .zero
        let menu = try require(h.secondaryClick(at: h.view(CGPoint(x: frame.midX, y: frame.midY))))
        expectEqual(menu.outline.first, "Go to Original", "first")
        try menu.choose("Go to Original")
        h.wait(0)
        expectEqual(h.editor.selectedShapeIDs, [box])
        let gone = h.addReference(to: ShapeID(), label: "gone", at: CGPoint(x: 400, y: 500))
        let goneMenu = try require(h.secondaryClick(at: h.view(CGPoint(x: 440, y: 516))))
        expectEqual(goneMenu.outline.first, "(Go to Original)", "dimmed: the shape is deleted")
        h.editor.selectedShapeIDs = []
        let words = h.addReference(words: "stuff", at: CGPoint(x: 400, y: 600))
        let wordsMenu = try require(h.secondaryClick(at: h.view(CGPoint(x: 440, y: 616))))
        expect(!wordsMenu.outline.contains("Go to Original") && !wordsMenu.outline.contains("(Go to Original)"), "none for words: \(wordsMenu.outline)")
        _ = (gone, words)
    },
    test("the command goes from the only selected reference, and is dimmed for anything else") {
        let h = try referenceHarness()
        let box = h.addBox("shapes")
        let id = h.addReference(to: box, label: "shapes")
        h.editor.selectedShapeIDs = [id]
        expect(h.editor.canPerform(.goToOriginal))
        h.editor.selectedShapeIDs = [box]
        expect(!h.editor.canPerform(.goToOriginal), "a box isn't a reference")
        h.editor.selectedShapeIDs = [id, box]
        expect(!h.editor.canPerform(.goToOriginal), "nor are two")
        h.editor.selectedShapeIDs = [id]
        h.editor.perform(.goToOriginal)
        h.wait(0)
        expectEqual(h.editor.selectedShapeIDs, [box])
    },
])
