import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Geometry
import Publishing
import Titles
import References
import TestKit

// What a pill that stands for nothing says while the pointer rests on it, and what drawing a frame of
// pills costs once they've been drawn: nothing built again.

@MainActor private func popover(over id: ShapeID, in h: EditorHarness) throws -> String? {
    let frame = try require(h.editor.document[id]).box ?? .zero
    h.move(to: h.view(CGPoint(x: frame.minX + 60, y: frame.midY)))
    h.wait(600)
    return h.editor.popover?.text.string
}

@MainActor let helpTests = Suite("Resting on a pill, and drawing many", [
    test("a pill that stands for nothing says why: Deleted, Not available, Not public; a live one and words say nothing") {
        let h = try referenceHarness()
        let gone = h.addReference(to: ShapeID(), label: "Old roadmap")
        expectEqual(try popover(over: gone, in: h), "Deleted")
        let nowhere = ShapeID()
        let hidden = ShapeRecord(Box(boxFrame))
        let other = try referenceHarness(file: CanvasFile(root: CanvasDocument(), children: [nowhere: CanvasDocument(shapes: [AnyShapeRecord(hidden)])]))
        expectEqual(try popover(over: other.addReference(to: hidden.id, label: "Out of sight"), in: other), "Not available")
        let secret = h.addBox("secret", public: false, at: CGRect(x: 100, y: 400, width: 100, height: 100))
        let notPublic = h.addReference(to: secret, label: "secret", at: CGPoint(x: 400, y: 400))
        expectEqual(try popover(over: notPublic, in: h), "Not public")
        let live = h.addReference(to: h.addBox("shapes"), label: "shapes", at: CGPoint(x: 400, y: 500))
        expectEqual(try popover(over: live, in: h), nil)
        expectEqual(try popover(over: h.addReference(words: "stuff", at: CGPoint(x: 400, y: 600)), in: h), nil)
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
