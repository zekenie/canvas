import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Mentions
import Selection
import StickyNotes
import TestKit
import Titles
import Types

// Connect (⌘L) gives the arrow what a port's drag gives it: between two notes a relationship type fits, the
// type is taken in the Connect step; when several fit, the list opens at the arrow with the first highlighted, and
// Escape (the list dropped) leaves a plain arrow. Over a Feature type and a Layer type with a note each, as the
// first minute's drag has them.

extension Minute {
    /// ⌘L on the canvas.
    @discardableResult func pressConnect() -> Bool {
        h.hold(.command)
        defer { h.hold([]) }
        return h.key("l")
    }

    /// A second relationship type that Feature notes have to Layer notes: a pill beside the first, an arrow into it from
    /// Feature and one out of it to Layer, each a port's drag.
    func addRelationshipType(_ title: String, from: ShapeID, to: ShapeID) throws -> ShapeID {
        let id = ShapeID()
        var record = ShapeRecord(id: id, StickyNote(frame: CGRect(origin: CGPoint(x: 500, y: 300), size: TypePills.pill(title: nil, fields: 0).size), text: ""))
        record[TitleProperty.self] = title
        editor.transact { $0.insert(AnyShapeRecord(record)) }
        editor.makeRelationshipType(id)
        editor.selectedShapeIDs = []
        try drag(from: from, to: id)
        editor.selectedShapeIDs = []
        try drag(from: id, to: to)
        editor.selectedShapeIDs = []
        editor.undoHistory.seal()
        return id
    }

    /// The arrow between the two notes, if one was drawn.
    var noteArrows: [ShapeRecord<Arrow>] {
        arrows.filter { $0.props.start.binding?.shapeID == featureNote && $0.props.end.binding?.shapeID == layerNote }
    }
}

@MainActor let connectParityShippedTests = Suite("Connect gives a drag's arrow, shipped", [
    test("with one fitting type, ⌘L gives the arrow, type and fields a port's drag between the same notes gives, in one step, Connect") {
        let dragged = try Minute()
        defer { dragged.close() }
        let draggedType = try dragged.nameTheType()
        try dragged.drag(from: dragged.featureNote, to: dragged.layerNote)
        let byDrag = try require(dragged.noteArrows.first)
        let keyed = try Minute()
        defer { keyed.close() }
        let keyedType = try keyed.nameTheType()
        keyed.editor.selectedShapeIDs = [keyed.featureNote, keyed.layerNote]
        keyed.editor.undoHistory.seal()
        expect(keyed.pressConnect())
        let byKey = try require(keyed.noteArrows.first)
        expectEqual(byDrag[IsAProperty.self]?.map(\.shape), [draggedType])
        expectEqual(byKey[IsAProperty.self]?.map(\.shape), [keyedType], "the type is taken")
        expectEqual(byKey[FieldValuesProperty.self], byDrag[FieldValuesProperty.self])
        expectEqual(byKey.props.endArrowhead, byDrag.props.endArrowhead)
        expectEqual(byKey.props.startArrowhead, byDrag.props.startArrowhead)
        expectEqual(keyed.arrows.count, dragged.arrows.count)
        expect(keyed.editor.menuToPopUp == nil, "no list")
        expectEqual(keyed.editor.selectedShapeIDs, [keyed.featureNote, keyed.layerNote], "the selection stays")
        expectEqual(keyed.editor.undoHistory.undoName, "Connect")
        let before = keyed.editor.document
        keyed.editor.undo()
        expectEqual(keyed.noteArrows.count, 0, "one Undo takes the arrow and its type together")
        keyed.editor.redo()
        expectEqual(keyed.editor.document, before)
    },
    test("with several fitting types the list pops at the arrow, the first highlighted; dropped, the arrow stays plain") {
        let m = try Minute()
        defer { m.close() }
        let first = try m.nameTheType("in")
        let second = try m.addRelationshipType("owns", from: m.feature, to: m.layer)
        m.editor.selectedShapeIDs = [m.featureNote, m.layerNote]
        m.editor.undoHistory.seal()
        expect(m.pressConnect())
        let arrow = try require(m.noteArrows.first)
        let queued = try require(m.editor.menuToPopUp, "the list")
        let titles = queued.menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        expect(titles.contains("in") && titles.contains("owns") && titles.last == "Plain arrow", "\(titles)")
        expect(m.editor.menuItemToHighlight === queued.menu.items.first, "the first is highlighted")
        expectEqual(m.editor.selection, arrow.id, "the arrow is the subject of the list")
        expectEqual(arrow[IsAProperty.self]?.map(\.shape) ?? [], [], "plain until a pick")
        expect([first, second].count == 2)
        // Escape drops the menu: the arrow stays plain, a Connect step.
        m.editor.menuDidPopUp()
        expectEqual(m.noteArrows.first?[IsAProperty.self]?.map(\.shape) ?? [], [])
        expectEqual(m.editor.undoHistory.undoName, "Connect")
    },
])
