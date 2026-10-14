import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import CoreGraphics
import Foundation
import Mentions
import Selection
import TestKit
import Types

// A real press on the chip of an arrow's relationship, which is a press off the open card as well.

@MainActor let chipPressTests = Suite("A press on an arrow's chip", [
    test("it opens the arrow's card; pressed again it is a press off the open card, which closes it, and the click opens the card afresh") {
        let r = try ArrowCardRig()
        defer { r.close() }
        let undo = r.editor.undoHistory.undoName
        let chip = try require(r.chips.first)
        let point = CGPoint(x: chip.rect.midX, y: chip.rect.midY)
        r.s.harness.click(at: point)
        r.s.harness.scheduler.advance(by: .zero)
        expectEqual(r.cards.openTarget?.shape, r.arrow, "first press opens")
        expectEqual(r.editor.selectedShapeIDs, [r.arrow])
        r.s.harness.click(at: point)
        r.s.harness.scheduler.advance(by: .zero)
        expectEqual(r.cards.openTarget?.shape, r.arrow, "the second press leaves the card open")
        expectEqual(r.editor.undoHistory.undoName, undo, "and makes no step")
    },
])
