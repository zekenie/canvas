import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Geometry
import Titles
import References
import TestKit

// What a pill that isn't public says while the pointer rests on it, and what drawing a frame of
// pills costs once they've been drawn: nothing built again.

@MainActor private func popover(over id: ShapeID, in h: EditorHarness) throws -> String? {
    let frame = try require(h.editor.document[id]).box ?? .zero
    h.move(to: h.view(CGPoint(x: frame.minX + 60, y: frame.midY)))
    h.wait(600)
    return h.editor.popover?.text.string
}

@MainActor let helpTests = Suite("Resting on a pill, and drawing many", [
    test("a pill that isn't public says so; a gone or unavailable one, a live one and words say nothing (Deleted and Not available are on the pill)") {
        let h = try referenceHarness()
        let gone = h.addReference(to: ShapeID(), label: "Old roadmap")
        expectEqual(try popover(over: gone, in: h), nil, "Deleted is the word on the pill")
        let nowhere = ShapeID()
        let hidden = ShapeRecord(Box(boxFrame))
        let other = try referenceHarness(file: CanvasFile(root: CanvasDocument(), children: [nowhere: CanvasDocument(shapes: [AnyShapeRecord(hidden)])]))
        expectEqual(try popover(over: other.addReference(to: hidden.id, label: "Out of sight"), in: other), nil, "Not available is the word on the pill")
        let secret = h.addBox("secret", public: false, at: CGRect(x: 100, y: 400, width: 100, height: 100))
        let notPublic = h.addReference(to: secret, label: "secret", at: CGPoint(x: 400, y: 400))
        expectEqual(try popover(over: notPublic, in: h), "Not public")
        let found = h.addReference(words: "secrets", query: "\"secret\"", at: CGPoint(x: 400, y: 700))
        h.answer()
        expectEqual(try popover(over: found, in: h), "Not public", "a query whose every match isn't public, as a pill for one")
        let live = h.addReference(to: h.addBox("shapes"), label: "shapes", at: CGPoint(x: 400, y: 500))
        expectEqual(try popover(over: live, in: h), nil)
        expectEqual(try popover(over: h.addReference(words: "stuff", at: CGPoint(x: 400, y: 600)), in: h), nil)
    },
    test("a pill too narrow for Deleted or Not available, or zoomed out past its line, says it on the pointer") {
        let h = try referenceHarness()
        expectEqual(try popover(over: h.addReference(to: ShapeID(), label: "Q"), in: h), "Deleted", "cut in the narrowest pill")
        expectEqual(try popover(over: h.addReference(to: ShapeID(), label: "Old roadmap", at: CGPoint(x: 400, y: 300)), in: h), nil, "whole on a wider one")
        let nowhere = ShapeID()
        let hidden = ShapeRecord(Box(boxFrame))
        let other = try referenceHarness(file: CanvasFile(root: CanvasDocument(), children: [nowhere: CanvasDocument(shapes: [AnyShapeRecord(hidden)])]))
        let narrow = other.addReference(to: hidden.id, label: "Q")
        expectEqual(try popover(over: narrow, in: other), "Not available", "cut on the pill: said whole here")
        let roomy = other.addReference(to: hidden.id, label: "Out of sight", at: CGPoint(x: 400, y: 400))
        expectEqual(try popover(over: roomy, in: other), nil, "whole on the pill")
        other.editor.camera = Camera(origin: .zero, zoom: 0.5)
        expectEqual(try popover(over: roomy, in: other), "Not available", "zoomed out the line isn't drawn")
    },
    test("a frame of pills drawn again builds no label and no symbol: they're kept") {
        let h = try referenceHarness()
        for row in 0..<20 {
            let box = h.addBox("target \(row)", at: CGRect(x: 100 + CGFloat(row % 5) * 160, y: 650, width: 100, height: 100))
            h.addReference(to: box, label: "target \(row)", at: CGPoint(x: 100 + CGFloat(row % 5) * 160, y: 20 + CGFloat(row / 5) * 40))
        }
        _ = render(h.editor)
        let built = referenceLooksBuilt
        _ = render(h.editor)
        expectEqual(referenceLooksBuilt, built, "nothing built again")
        h.editor.transact { $0.update(h.editor.document.shapes.first { $0.kind == "box" }!.id) { $0[TitleProperty.self] = "renamed" } }
        _ = render(h.editor)
        expect(referenceLooksBuilt - built <= 1, "a rename builds its label alone: \(referenceLooksBuilt - built)")
    },
])
