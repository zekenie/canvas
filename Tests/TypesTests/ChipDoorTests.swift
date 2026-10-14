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

// the chip's doors.

@MainActor let chipDoorTests = Suite("The doors of an arrow's chip", [
    test("the chip of a relationship type with no fields opens nothing though a plain type beside it has fields: its menu") {
        let r = try ArrowCardRig(fields: nil)
        defer { r.close() }
        let plain = r.editor.addSlipType(roleSchema, title: "Plain", at: CGPoint(x: 40, y: 1300))
        r.editor.addTypeLink(plain, to: r.arrow)
        let click = try r.click("in")
        TypeChips.click(click, in: r.editor)
        expect(r.cards.openTarget == nil, "the relationship type `in` has no fields: its chip keeps its menu, not the card of Plain's fields")
    },
    test("no number on the chip of a relationship type with no fields, though a plain type beside it has fields") {
        let r = try ArrowCardRig(fields: nil)
        defer { r.close() }
        let plain = r.editor.addSlipType(roleSchema, title: "Plain", at: CGPoint(x: 40, y: 1300))
        r.editor.addTypeLink(plain, to: r.arrow)
        let chips = r.chips
        expectEqual(chips.map(\.label.text), ["in", "Plain"])
        expect(chips.allSatisfy { $0.label.count == nil }, "a relationship type with no fields: no number, \(chips.map(\.label.count))")
    },
])
