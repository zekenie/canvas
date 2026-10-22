@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Keyboard
import References
import Selection
import TestKit

// The go button as a part (principle 1): ⌥Tab on a reference pill reaches Go to Original and Return
// goes there, as the click on the leading symbol does.

@MainActor let goButtonKeysTests = Suite("The go button from the keyboard", [
    test("⌥Tab on a pill reaches Go to Original, on the symbol's box, and Return goes to the original") {
        let h = try referenceHarness()
        let box = h.addBox("shapes", at: CGRect(x: 100, y: 300, width: 150, height: 100))
        let id = h.addReference(to: box, label: "shapes")
        h.editor.selection = id
        expect(h.key(Chord.optionTab))
        let part = try require(h.editor.focusedPart)
        expectEqual(part.title, "Go to Original")
        expectEqual(part.role, .link)
        let frame = try require(h.editor.document[id]).box ?? .zero
        expect(frame.contains(CGPoint(x: part.rect.midX, y: part.rect.midY)))
        expect(part.rect.midX < frame.minX + 30, "the leading symbol")
        expect(h.key(Chord.return))
        h.wait(0)
        expectEqual(h.editor.selectedShapeIDs, [box])
    },
    test("a pill that stands for nothing there is has no go part") {
        let h = try referenceHarness()
        let gone = h.addReference(to: ShapeID(), label: "gone")
        expect(h.editor.shapeParts(of: gone).allSatisfy { $0.title != "Go to Original" })
    },
])
