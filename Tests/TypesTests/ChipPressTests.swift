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

@MainActor let chipPressTests = Suite("A press on an arrow's pill", [
    test("it opens the arrow's card; the pill is the rect the card hangs from, so a press on it is not a press off the card and its click closes it, and a third opens it afresh") {
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
        expectEqual(r.cards.openTarget?.shape, nil, "the second click on the pill closes it, as asking again does")
        r.s.harness.click(at: point)
        r.s.harness.scheduler.advance(by: .zero)
        expectEqual(r.cards.openTarget?.shape, r.arrow, "the third opens it afresh")
        expectEqual(r.editor.undoHistory.undoName, undo, "and none makes a step")
    },
])
