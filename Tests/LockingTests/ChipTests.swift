import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Locking
import Selection
import TestKit

// The chip is an 18-point disc 9 points above its shape's top edge, ending at the shape's right
// edge: from 27 to 9 points above the edge, and 18 points in from the corner. A shape's shadow
// reaches 6 points out, and the disc's edge is antialiased, so it's checked in its middle. These
// tests' box has its top-right corner at (250, 100), so its chip's middle is at (241, 82).

/// A box whose chip is at `chipCenter`.
let chipBox = CGRect(x: 100, y: 100, width: 150, height: 100)
let chipCenter = CGPoint(x: 241, y: 82)
/// The middle of the chip, where every pixel is the chip's.
let chipMiddle = CGRect(x: 236, y: 77, width: 10, height: 10)
let wholeView = CGRect(x: 0, y: 0, width: 400, height: 300)
/// Out of the way of any chip, for the pointer.
let elsewhere = CGPoint(x: 380, y: 280)

@MainActor func render(_ h: EditorHarness) -> NSBitmapImageRep { renderBitmap(h.editor, size: wholeView.size) }

@MainActor let chipTests = Suite("The lock chip", [
    test("a locked shape has a chip just above its top-right corner, and nothing else changes") {
        let h = try lockingHarness()
        let box = h.add(Box(chipBox))
        let unlocked = render(h)
        h.editor.lock([box])
        let locked = render(h)
        expect(changedPixels(unlocked, locked, in: chipMiddle) > 90, "the chip")
        expectEqual(changedPixels(unlocked, locked, in: CGRect(x: 0, y: 0, width: 230, height: 300)), 0, "nothing left of it")
        expectEqual(changedPixels(unlocked, locked, in: CGRect(x: 0, y: 93, width: 400, height: 207)), 0, "nothing on the shape, or below")
        expectEqual(changedPixels(unlocked, locked, in: CGRect(x: 253, y: 0, width: 147, height: 300)), 0, "nothing right of it")
        expectEqual(changedPixels(unlocked, locked, in: CGRect(x: 0, y: 0, width: 400, height: 71)), 0, "nothing higher")
    },
    test("the chip keeps its size on screen as the view zooms in") {
        let h = try lockingHarness()
        let box = h.add(Box(CGRect(x: 50, y: 50, width: 75, height: 50)))
        h.editor.camera = Camera(origin: .zero, zoom: 2)                            // its top-right corner at (250, 100)
        let unlocked = render(h)
        h.editor.lock([box])
        let locked = render(h)
        expect(changedPixels(unlocked, locked, in: chipMiddle) > 90, "the chip")
        expectEqual(changedPixels(unlocked, locked, in: CGRect(x: 0, y: 0, width: 400, height: 71)), 0, "no bigger")
        expectEqual(changedPixels(unlocked, locked, in: CGRect(x: 0, y: 0, width: 230, height: 300)), 0)
    },
    test("below 35%, where shapes are skeletons, a locked shape shows no chip, so a click where it would be unlocks nothing; at 35% the chip is there") {
        let h = try lockingHarness()
        let box = h.add(Box(CGRect(x: chipBox.minX / 0.3, y: chipBox.minY / 0.3, width: chipBox.width / 0.3, height: chipBox.height / 0.3)))
        h.editor.camera = Camera(origin: .zero, zoom: 0.3)                          // the box where `chipBox` is at 100%
        let plain = render(h)
        h.editor.lock([box])
        expectEqual(changedPixels(plain, render(h), in: wholeView), 0, "no chip, nor anything else")
        expectEqual(h.editor.adornmentFrames(of: box), [], "none laid out")
        h.click(at: chipCenter)
        expect(h.editor.isLocked(box), "nothing there to click")
        h.editor.skeletonZoom = 0.2                                                 // in full at 30%
        expect(changedPixels(plain, render(h), in: chipMiddle) > 90, "in full, the chip")
    },
    test("the chip shakes with its shape") {
        let h = try lockingHarness()
        let box = h.add(Box(chipBox))
        h.editor.lock([box])
        let still = render(h)
        h.editor.setDrawingOffset(CGPoint(x: 5, y: 0), for: box)                    // where a shake has it, at its widest
        let shaken = render(h)
        for y in stride(from: 74, through: 88, by: 2) {
            for x in stride(from: 234, through: 248, by: 2) {
                expectEqual(pixel(shaken, at: CGPoint(x: x + 5, y: y)), pixel(still, at: CGPoint(x: x, y: y)), "(\(x), \(y))")
            }
        }
    },
])

/// How often the select tool has looked for a button under the pointer: a plugin whose buttons are
/// never there, asked first (it's last), counting.
@MainActor final class ButtonSearches { var count = 0 }

@MainActor func countingSearches(_ searches: ButtonSearches) -> Contributor {
    Contributor(id: "button-searches") { r in
        r.canvasButtons(at: { _, _ -> String? in
            searches.count += 1
            return nil
        }, click: { _, _ in })
    }
}

// Clicking the chip. A click on a locked shape's unlocks it, and the chip shows the lock open for
// 1.5 s (longer while the pointer's on it), then fades over 0.3 s, a frame every 16 ms: gone 1.8 s
// after the click at most, once the pointer has left it.

@MainActor let chipClickTests = Suite("Clicking the lock chip", [
    test("a click on a locked shape's chip unlocks it; the chip shows the lock open, and a click on that locks it again") {
        let h = try lockingHarness()
        let box = h.add(Box(chipBox))
        let plain = render(h)
        h.editor.lock([box])
        let locked = render(h)
        h.click(at: chipCenter)
        expect(!h.editor.isLocked(box))
        h.move(to: elsewhere)
        let open = render(h)
        expect(changedPixels(plain, open, in: chipMiddle) > 90, "still a chip")
        expect(changedPixels(locked, open, in: chipMiddle) > 5, "with the lock open")
        h.click(at: chipCenter)
        expect(h.editor.isLocked(box))
        h.move(to: elsewhere)
        h.wait(3000)
        expectEqual(changedPixels(locked, render(h), in: wholeView), 0, "locked, as it was, and it stays")
    },
    test("the open lock goes on its own, and a click where it was is then a click on the canvas") {
        let h = try lockingHarness()
        let box = h.add(Box(chipBox))
        let plain = render(h)
        h.editor.lock([box])
        h.click(at: chipCenter)
        h.move(to: elsewhere)
        h.wait(1400)
        expect(changedPixels(plain, render(h), in: chipMiddle) > 90, "a second and a half")
        h.wait(400)
        expectEqual(changedPixels(plain, render(h), in: wholeView), 0, "then gone")
        h.click(at: chipCenter)
        expect(!h.editor.isLocked(box))
    },
    test("the open lock fades, rather than going at once") {
        let h = try lockingHarness()
        let box = h.add(Box(chipBox))
        let plain = render(h)
        h.editor.lock([box])
        h.click(at: chipCenter)
        h.move(to: elsewhere)
        let open = render(h)
        h.wait(1484 + 160)                          // halfway through the fade
        let fading = render(h)
        let point = CGPoint(x: chipCenter.x, y: chipCenter.y - 7)       // on the disc, above the lock
        let (full, half, none) = (pixel(open, at: point)[0], pixel(fading, at: point)[0], pixel(plain, at: point)[0])
        expect(full < half && half < none, "\(full) < \(half) < \(none)")
    },
    test("while the pointer's on the open lock it stays, and it goes once the pointer leaves") {
        let h = try lockingHarness()
        let box = h.add(Box(chipBox))
        let plain = render(h)
        h.editor.lock([box])
        h.click(at: chipCenter)                     // the pointer stays on it
        h.wait(3000)
        expect(changedPixels(plain, render(h), in: chipMiddle) > 90, "still there")
        h.move(to: elsewhere)
        h.wait(1000)
        expectEqual(changedPixels(plain, render(h), in: wholeView), 0, "gone")
    },
    test("unlocking from the menu opens the lock for a moment too, and it goes") {
        let h = try lockingHarness()
        let box = h.add(Box(chipBox))
        let plain = render(h)
        h.editor.lock([box])
        try require(h.secondaryClick(at: CGPoint(x: 150, y: 150))).choose("Unlock")
        h.editor.selection = nil
        h.move(to: elsewhere)
        expect(changedPixels(plain, render(h), in: chipMiddle) > 90, "open")
        h.click(at: chipCenter)
        expect(h.editor.isLocked(box), "a click locks it again, as after a click on the chip")
        h.editor.unlock([box])
        h.move(to: elsewhere)
        h.wait(2000)
        expectEqual(changedPixels(plain, render(h), in: wholeView), 0)
    },
    test("the pointing hand shows over a chip; hovered, it draws lighter, and pressed, darker") {
        let h = try lockingHarness()
        let box = h.add(Box(chipBox))
        h.editor.lock([box])
        let point = CGPoint(x: chipCenter.x, y: chipCenter.y - 7)       // on the disc, above the lock
        let normal = pixel(render(h), at: point)[0]
        h.move(to: chipCenter)
        expectEqual(h.editor.cursor, .pointingHand)
        expectEqual(h.editor.hoveredButton, AnyHashable(AdornmentButton(LockChip.self, on: box)))
        let hovered = pixel(render(h), at: point)[0]
        h.press(at: chipCenter)
        expectEqual(h.editor.pressedButton, AnyHashable(AdornmentButton(LockChip.self, on: box)))
        let pressed = pixel(render(h), at: point)[0]
        expect(pressed < normal && normal < hovered, "\(pressed) < \(normal) < \(hovered)")
        h.drag(to: elsewhere)
        expectEqual(h.editor.pressedButton, nil, "off it, not pressed")
        h.release()
        expect(h.editor.isLocked(box), "released off it, nothing")
        h.move(to: elsewhere)
        expectEqual(h.editor.cursor, .standard)
    },
    test("a click on the chip changes nothing else: the selection stays, and a shape under the chip isn't pressed") {
        let h = try lockingHarness()
        let box = h.add(Box(chipBox))
        let over = h.add(Box(CGRect(x: 220, y: 40, width: 80, height: 50)))       // above the box in the stack, under its chip
        h.editor.lock([box])
        h.editor.selection = box
        h.click(at: chipCenter)
        expect(!h.editor.isLocked(box))
        expectEqual(h.editor.selectedShapeIDs, [box])
        expectEqual(h.editor.document[over]?.box, CGRect(x: 220, y: 40, width: 80, height: 50))
    },
    test("a chip that comes with a commit under a still pointer is hovered at once, and one that goes, let go of") {
        let h = try lockingHarness()
        let box = h.add(Box(chipBox))
        h.move(to: chipCenter)
        expectEqual(h.editor.hoveredButton, nil)
        h.editor.lock([box])
        expectEqual(h.editor.hoveredButton, AnyHashable(AdornmentButton(LockChip.self, on: box)))
        expectEqual(h.editor.cursor, .pointingHand)
        h.editor.transact { $0.delete([box]) }         // refused: it's locked
        h.editor.unlock([box])
        h.editor.transact { $0.delete([box]) }
        expectEqual(h.editor.hoveredButton, nil)
        expectEqual(h.editor.cursor, .standard)
    },
    test("unlocking many shapes at once, locking them again or deleting them looks under the pointer once a commit, not once a shape") {
        let searches = ButtonSearches()
        let h = try lockingHarness([countingSearches(searches)])
        let boxes = (0..<20).map { i in h.add(Box(CGRect(x: 50 * CGFloat(i), y: 150, width: 40, height: 40))) }
        h.editor.lock(boxes)
        h.move(to: CGPoint(x: 31, y: 132))                                          // on the first box's chip
        searches.count = 0
        h.editor.unlock(boxes)
        expectEqual(searches.count, 1, "the select tool's one look once services have settled: Locking's word, as it hears the commit, waits for it")
        expect(boxes.allSatisfy { h.editor.adornmentFrames(of: $0).count == 1 }, "every lock shows open")
        expectEqual(h.editor.hoveredButton, AnyHashable(AdornmentButton(LockChip.self, on: boxes[0])), "the open lock under the pointer, hovered")
        searches.count = 0
        h.editor.lock(boxes)                                                         // while their locks show open
        expectEqual(searches.count, 1, "locked again")
        h.editor.unlock(boxes)
        searches.count = 0
        h.editor.transact { $0.delete(Set(boxes)) }
        expectEqual(searches.count, 1, "deleted with their locks open")
        expectEqual(h.editor.hoveredButton, nil)
    },
    test("in other tools a chip is only drawn: the hand tool pans where it is") {
        let h = try lockingHarness()
        let box = h.add(Box(chipBox))
        h.editor.lock([box])
        h.editor.setTool(.hand)
        h.click(at: chipCenter)
        expect(h.editor.isLocked(box))
    },
    test("a chip hit is a disc: its corner's box isn't") {
        let h = try lockingHarness()
        let box = h.add(Box(chipBox))
        h.editor.lock([box])
        expectEqual(h.editor.button(atViewPoint: chipCenter), AnyHashable(AdornmentButton(LockChip.self, on: box)))
        expectEqual(h.editor.button(atViewPoint: CGPoint(x: 252, y: 82)), AnyHashable(AdornmentButton(LockChip.self, on: box)), "a little past its edge")
        expectEqual(h.editor.button(atViewPoint: CGPoint(x: 230, y: 71)), nil, "its box's corner, outside the disc")
        expectEqual(h.editor.button(atViewPoint: CGPoint(x: 241, y: 110)), nil, "on the shape")
    },
])
