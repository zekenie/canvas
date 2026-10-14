import Adornments
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit
import Topology
import Types

// The chip of a relationship that is a misfit is red with a wave, and so is its pill in the row of the note at the end that
// fits; a warning (an end that is free) turns neither; the chip is plain where there is no check to ask. Over bonds, in
// `RelationScene`'s editor (a Feature, a Layer and the relationship type `in` between them).

/// The relationship's chips on an arrow, as the editor lays them out.
@MainActor func arrowChips(of arrow: ShapeID, in editor: CanvasEditor) -> [AdornmentFrame] {
    editor.adornmentFrames(of: arrow).filter { $0.adornment == .of(TypeChips.self) }
}

@MainActor let chipToneTests = Suite("The chip of a misfit", [
    test("the chip of a note that is typed asks the check nothing: only a shape of a kind that relates can be a misfit") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        let note = s.editor.addSlip("Typed", of: [s.feature], at: CGPoint(x: 40, y: 900))
        let checks = try require(s.editor.fieldChecks)
        let made = checks.checksMade
        let hooks = try require(s.editor.service(RelationshipHooks.self))
        expectEqual(hooks.tone(note), .plain)
        expectEqual(checks.checksMade, made, "no check of a note was made for its chip")
    },
    test("a chip is red with a wave while an end of its arrow is a misfit, plain again once it fits, and a free end turns it no more than a fit does") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        let fits = s.relate(s.note, s.layerNote)
        let other = s.editor.addSlip("Another", of: [s.feature], at: CGPoint(x: 40, y: 900))
        let misfit = s.relate(s.note, other)
        let plain = try require(arrowChips(of: fits, in: s.editor).first)
        expectEqual(plain.label.text, "in")
        expect(!plain.label.isWrong, "a relationship that fits is a chip as any")
        let red = try require(arrowChips(of: misfit, in: s.editor).first)
        expectEqual(red.label.text, "in")
        expect(red.label.isWrong, "the second end is a Feature, not a Layer")
        expectEqual(red.label.tint?.style, .light)
        // Re-aimed onto a Layer: healed with nothing refused; back onto a Feature: red again.
        s.editor.transact("Re-aim") { $0.update(misfit, as: Bond.self) { $0.props.to = s.layerNote } }
        expect(arrowChips(of: misfit, in: s.editor).allSatisfy { !$0.label.isWrong }, "the chip follows the end")
        s.editor.transact("Re-aim") { $0.update(misfit, as: Bond.self) { $0.props.to = other } }
        expect(arrowChips(of: misfit, in: s.editor).allSatisfy { $0.label.isWrong })
        s.editor.undo()
        expect(arrowChips(of: misfit, in: s.editor).allSatisfy { !$0.label.isWrong }, "the undo heals it")
        s.editor.redo()
        expect(arrowChips(of: misfit, in: s.editor).allSatisfy { $0.label.isWrong })
        // A warning is not a misfit: an end let go leaves the chip as a free end is, orange in the issues and plain here.
        s.editor.transact("Free") { $0.update(misfit, as: Bond.self) { $0.props.to = nil } }
        expect(arrowChips(of: misfit, in: s.editor).allSatisfy { !$0.label.isWrong }, "a free end is a warning")
    },
    test("the chip turns with the arrow's verdict when no commit touched the arrow: a note that gains or loses its type, a type unmarked") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        let arrow = s.relate(s.note, s.layerNote)
        expect(arrowChips(of: arrow, in: s.editor).allSatisfy { !$0.label.isWrong })
        let record = s.editor.document[arrow]
        s.editor.removeTypeLink(s.layer, from: s.layerNote)
        expect(arrowChips(of: arrow, in: s.editor).allSatisfy { $0.label.isWrong }, "the note at the end is no Layer now")
        expectEqual(s.editor.document[arrow], record, "the arrow was not written")
        s.editor.undo()
        expect(arrowChips(of: arrow, in: s.editor).allSatisfy { !$0.label.isWrong })
        // Only the relationship type's chip is red: a plain type on the arrow keeps its own.
        let plain = s.editor.addSlipType(featureRowsSchema, title: "Plain", at: CGPoint(x: 40, y: 1300))
        s.editor.addTypeLink(plain, to: arrow)
        s.editor.removeTypeLink(s.layer, from: s.layerNote)
        let frames = arrowChips(of: arrow, in: s.editor)
        expectEqual(frames.map { $0.label.text ?? "" }, ["in", "Plain"])
        expect(frames[0].label.isWrong && !frames[1].label.isWrong, "the relationship's chip alone")
    },
    test("with no check in the list the chip is plain") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        let other = s.editor.addSlip("Another", of: [s.feature], at: CGPoint(x: 40, y: 900))
        let misfit = s.relate(s.note, other)
        let hooks = try require(s.editor.service(RelationshipHooks.self))
        expectEqual(hooks.tone(misfit), .wrong)
        expectEqual(RelationshipHooks(nameIt: { _ in false }).tone(misfit), .plain, "the default tone asks no check")
    },
    test("the pill in the row of the note at the end that fits is red with a wave; the row of the other end shows nothing wrong and the pill heals with the arrow") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        let other = s.editor.addSlip("Another", of: [s.feature], at: CGPoint(x: 40, y: 900))
        let fits = s.relate(s.note, s.layerNote)
        let misfit = s.relate(s.note, other)
        let (pills, _) = try s.pills(s.note, "layer")
        expectEqual(pills.map(\.arrow).sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }, [fits, misfit].sorted { $0.rawValue.uuidString < $1.rawValue.uuidString })
        let wrong = try require(pills.first { $0.arrow == misfit })
        expect(wrong.isWrong, "the end that does not fit")
        expect(!(try require(pills.first { $0.arrow == fits }).isWrong))
        // Heals with the arrow, with nothing written to the note.
        s.editor.transact("Re-aim") { $0.update(misfit, as: Bond.self) { $0.props.to = s.layerNote } }
        expect(try s.pills(s.note, "layer").pills.allSatisfy { !$0.isWrong }, "healed")
        s.editor.undo()
        expect(try s.pills(s.note, "layer").pills.contains { $0.isWrong }, "and red again by the undo")
    },
])
