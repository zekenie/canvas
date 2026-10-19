import Adornments
import Canvas
import CanvasTesting
import CoreGraphics
import Selection
import TestKit

// `ChipFade`: a chip that shows a moment and then fades, for any plugin. It's in full for 1.5 s
// (500 ms re-checks, while the pointer's on it), then fades over 300 ms in 16 ms frames, telling
// Adornments each frame, and is gone.

/// A clickable chip a test shows with `ChipFade`, showing a flag at the opacity the fade says.
enum Ghost {}
extension Ghost: Adornment {
    static var placement: AdornmentPlacement { .aboveTopRight }
}
extension Ghost: ClickableAdornment {
    static func click(_ click: AdornmentClick, in editor: CanvasEditor) {}
}

/// A second chip, to show two on one shape fade apart.
enum Echo {}
extension Echo: Adornment {
    static var placement: AdornmentPlacement { .aboveTopRight }
    static var order: Int { 310 }
}

@MainActor func fadingChips() -> Contributor {
    Contributor(id: "fading-chips") { r in
        r.forEveryShape { scope in
            scope.adornment(Ghost.self) { shape, context in
                context.service(ChipFade.self)?.opacity(of: Ghost.self, on: shape.id).map { flagLabel.opacity($0) }
            }
        }
        r.forEveryShape { scope in
            scope.adornment(Echo.self) { shape, context in
                context.service(ChipFade.self)?.opacity(of: Echo.self, on: shape.id).map { pinLabel.opacity($0) }
            }
        }
    }
}

extension EditorHarness {
    @MainActor var fade: ChipFade { editor.service(ChipFade.self)! }

    /// Shows a chip, and tells Adornments, as a plugin does.
    @MainActor func show<A: Adornment>(_ chip: A.Type, on id: ShapeID) {
        fade.show(chip, on: id)
        editor.adornmentsDidChange(for: [id])
    }

    /// What a shape's chip is drawn at: nil for none.
    @MainActor func opacity(of id: ShapeID, chip: AdornmentID) -> CGFloat? {
        editor.adornmentFrames(of: id).first { $0.adornment == chip }?.label.opacity
    }
}

@MainActor let chipFadeTests = Suite("Fading chips", [
    test("a chip shows in full for 1.5 s, fades over 300 ms, and is gone") {
        let h = try adornedHarness([fadingChips()])
        let box = h.add(Box(boxFrame))
        let ghost = AdornmentID.of(Ghost.self)
        expectEqual(h.fade.opacity(of: Ghost.self, on: box), nil)
        expect(h.editor.adornmentFrames(of: box).isEmpty)
        h.show(Ghost.self, on: box)
        expectEqual(h.fade.opacity(of: Ghost.self, on: box), 1)
        expect(h.fade.isShowing(Ghost.self, on: box))
        h.wait(1400)
        expectEqual(h.opacity(of: box, chip: ghost), 1, "still in full")
        h.wait(100 + 160)                                   // 1500 ms to start, and 10 of its frames
        let half = try require(h.opacity(of: box, chip: ghost))
        expect(half > 0.2 && half < 0.8, "fading: \(half)")
        h.wait(200)
        expectEqual(h.opacity(of: box, chip: ghost), nil, "gone")
        expect(!h.fade.isShowing(Ghost.self, on: box))
        expect(h.editor.adornmentFrames(of: box).isEmpty)
    },
    test("the fade is a frame every 16 ms, each telling Adornments, and the opacity only goes down") {
        let h = try adornedHarness([fadingChips()])
        let box = h.add(Box(boxFrame))
        h.show(Ghost.self, on: box)
        h.wait(1500)
        var seen: [CGFloat] = []
        for _ in 0..<19 {
            h.wait(16)
            if let opacity = h.fade.opacity(of: Ghost.self, on: box) { seen.append(opacity) }
        }
        expect(seen.count >= 18, "gone by 19 frames (304 ms): \(seen.count)")
        expect(zip(seen, seen.dropFirst()).allSatisfy { $0 > $1 }, "\(seen)")
        // What's drawn follows what the service says, each frame.
        let again = try adornedHarness([fadingChips()])
        let other = again.add(Box(boxFrame))
        again.show(Ghost.self, on: other)
        again.wait(1500 + 16 * 5)
        expectEqual(again.opacity(of: other, chip: .of(Ghost.self)), again.fade.opacity(of: Ghost.self, on: other))
    },
    test("while the pointer's on the chip it stays, looked at again every 500 ms, and it fades once the pointer leaves") {
        let h = try adornedHarness([fadingChips()])
        let box = h.add(Box(boxFrame))
        h.show(Ghost.self, on: box)
        h.move(to: flagCenter)
        expectEqual(h.editor.hoveredButton, AnyHashable(AdornmentButton(Ghost.self, on: box)))
        h.wait(3000)
        expectEqual(h.fade.opacity(of: Ghost.self, on: box), 1, "held in full")
        h.move(to: CGPoint(x: 350, y: 280))
        h.wait(500 + 16)
        expect(h.fade.opacity(of: Ghost.self, on: box).map { $0 < 1 } ?? true, "fading, or gone")
        h.wait(400)
        expect(!h.fade.isShowing(Ghost.self, on: box))
    },
    test("showing a chip that's showing starts its linger over, in the fade too") {
        let h = try adornedHarness([fadingChips()])
        let box = h.add(Box(boxFrame))
        h.show(Ghost.self, on: box)
        h.wait(1000)
        h.show(Ghost.self, on: box)
        h.wait(1000)                                        // 2 s in, 1 s into the second
        expectEqual(h.fade.opacity(of: Ghost.self, on: box), 1)
        h.wait(600)
        expect(h.fade.opacity(of: Ghost.self, on: box).map { $0 < 1 } ?? true)
        h.wait(100)
        h.show(Ghost.self, on: box)
        expectEqual(h.fade.opacity(of: Ghost.self, on: box), 1, "back in full from a fade")
        h.wait(1400)
        expectEqual(h.fade.opacity(of: Ghost.self, on: box), 1)
    },
    test("hiding takes the chip away at once, and says whether it was there") {
        let h = try adornedHarness([fadingChips()])
        let box = h.add(Box(boxFrame))
        expect(!h.fade.hide(Ghost.self, on: box))
        h.show(Ghost.self, on: box)
        expect(h.fade.hide(Ghost.self, on: box))
        expectEqual(h.fade.opacity(of: Ghost.self, on: box), nil)
        h.wait(3000)
        expectEqual(h.fade.opacity(of: Ghost.self, on: box), nil, "and it doesn't come back")
    },
    test("two chips on one shape fade apart") {
        let h = try adornedHarness([fadingChips()])
        let box = h.add(Box(boxFrame))
        h.show(Ghost.self, on: box)
        h.wait(1000)
        h.show(Echo.self, on: box)
        h.wait(600 + 16 * 10)                               // the ghost is fading, the echo isn't
        expect(h.fade.opacity(of: Ghost.self, on: box).map { $0 < 1 } ?? true)
        expectEqual(h.fade.opacity(of: Echo.self, on: box), 1)
        h.fade.hide(Ghost.self, on: box)
        expectEqual(h.fade.opacity(of: Echo.self, on: box), 1)
    },
    test("a shape that's deleted takes its chip, and another board shown stops what was under way") {
        let h = try adornedHarness([PocketsPlugin(), fadingChips()])
        let box = h.add(Box(boxFrame))
        let pocket = h.add(Pocket(CGRect(x: 400, y: 100, width: 100, height: 100)))
        h.show(Ghost.self, on: box)
        h.editor.transact("Delete") { $0.delete([box]) }
        expect(!h.fade.isShowing(Ghost.self, on: box))
        let kept = h.add(Box(boxFrame))
        h.show(Ghost.self, on: kept)
        expect(h.enter(pocket))
        expect(!h.fade.isShowing(Ghost.self, on: kept), "the board left's chips stop there")
        h.wait(3000)
    },
])
