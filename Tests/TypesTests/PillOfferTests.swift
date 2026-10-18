import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Selection
import TestKit
import Types

// The dashed empty pill: a plain arrow between two notes that a relationship type fits, when it is the only shape selected, shows
// one where a pill would sit (`RelationshipOfferPill`), and a click on it lists the types that fit, as a port's release lists
// them; a pick types the arrow. It goes when the arrow is deselected, or is not alone, or has a type, or none fits.

@MainActor private func offer(of arrow: ShapeID, in editor: CanvasEditor) -> AdornmentFrame? {
    editor.adornmentFrames(of: arrow).first { $0.adornment == .of(RelationshipOfferPill.self) }
}

@MainActor let pillOfferTests = Suite("The dashed pill on a selected plain arrow", [
    test("it shows a dashed empty pill where the label would be, in the room the geometry keeps, on the only selected plain arrow a type fits; it goes when the arrow is deselected") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        let arrow = s.editor.addBond(s.note, s.layerNote)
        expectEqual(offer(of: arrow, in: s.editor), nil, "not selected")
        expectEqual(s.editor.shapeContext.geometry(of: arrow)?.label, nil, "no label: the line is whole")
        s.editor.selection = arrow
        let ghost = try require(offer(of: arrow, in: s.editor), "selected")
        expectEqual(ghost.label.mark, .ghost)
        expectEqual(ghost.rect, s.editor.shapeContext.geometry(of: arrow)?.labelLead)
        expectEqual(ghost.rect.height, 18)
        s.editor.selection = nil
        expectEqual(offer(of: arrow, in: s.editor), nil, "deselected")
        expectEqual(s.editor.shapeContext.geometry(of: arrow)?.label, nil, "and the line is whole again")
    },
    test("it follows the file's relationship types while the arrow stays selected: the type unmarked, it goes; marked again, it comes back, with no commit to the arrow") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        let arrow = s.editor.addBond(s.note, s.layerNote)
        s.editor.selection = arrow
        expect(offer(of: arrow, in: s.editor) != nil, "selected, a type fits")
        s.editor.makePlainTypes([s.rel])
        expectEqual(offer(of: arrow, in: s.editor), nil, "no relationship type fits it now")
        s.editor.makeRelationshipTypes([s.rel])
        expect(offer(of: arrow, in: s.editor) != nil, "it fits again")
        expectEqual(s.editor.selection, arrow)
    },
    test("not on an arrow that is selected with another shape, that already has a type, that no type fits, or whose end is free") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        let arrow = s.editor.addBond(s.note, s.layerNote)
        s.editor.selectedShapeIDs = [arrow, s.note]
        expectEqual(offer(of: arrow, in: s.editor), nil, "with another shape")
        let typed = s.relate(s.note, s.layerNote)
        s.editor.selection = typed
        expectEqual(offer(of: typed, in: s.editor), nil, "it has a type: its own pill")
        let other = s.editor.addSlip("Another", of: [s.feature], at: CGPoint(x: 40, y: 900))
        let none = s.editor.addBond(s.note, other)
        s.editor.selection = none
        expectEqual(offer(of: none, in: s.editor), nil, "Feature to Feature: no type fits")
        let free = s.editor.addBond(s.note, nil)
        s.editor.selection = free
        expectEqual(offer(of: free, in: s.editor), nil, "an end let go")
    },
    test("a click lists the types that fit, the taken ones first, a rule and a gray Plain arrow, under the pill; a pick types the arrow and the dashed pill gives way to its own") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        let arrow = s.editor.addBond(s.note, s.layerNote)
        s.editor.selection = arrow
        let ghost = try require(offer(of: arrow, in: s.editor))
        RelationshipOfferPill.click(AdornmentClick(shape: arrow, tag: ghost.tag, rect: ghost.rect), in: s.editor)
        let popped = try require(s.editor.menuToPopUp, "a list")
        expectEqual(popped.menu.outline, ["in", "—", "Plain arrow"])
        expectEqual(popped.rect, ghost.rect, "it hangs from the pill")
        let undo = s.editor.undoHistory.undoName
        try popped.menu.choose("in")
        s.editor.menuDidPopUp()
        expectEqual(s.editor.document[arrow]?[IsAProperty.self]?.map(\.shape), [s.rel])
        expect(s.editor.undoHistory.undoName != undo, "a step of its own")
        expectEqual(offer(of: arrow, in: s.editor), nil)
        let pill = s.editor.adornmentFrames(of: arrow).first { $0.adornment == .of(RelationshipPill.self) }
        expectEqual(pill?.label.text, "in", "the pill is the type's now")
        expectEqual(s.editor.selection, arrow, "still selected")
    },
    test("Plain arrow leaves it as drawn, and the dashed pill stays: nothing is written") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        let arrow = s.editor.addBond(s.note, s.layerNote)
        s.editor.selection = arrow
        let record = s.editor.document[arrow]
        let ghost = try require(offer(of: arrow, in: s.editor))
        RelationshipOfferPill.click(AdornmentClick(shape: arrow, tag: ghost.tag, rect: ghost.rect), in: s.editor)
        try require(s.editor.menuToPopUp).menu.choose("Plain arrow")
        s.editor.menuDidPopUp()
        expectEqual(s.editor.document[arrow], record)
        expect(offer(of: arrow, in: s.editor) != nil)
    },
])
