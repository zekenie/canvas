import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Foundation
import Geometry
import LanguageModels
import Locking
import Mentions
import Publishing
import References
import Selection
import ShippedTesting
import StickyNotes
import Subboards
import TestKit
import Titles
import Types

extension Minute {
    fileprivate func sayWords(_ words: MentionText, of id: ShapeID? = nil) {
        editor.transact("Typing") { $0.update(id ?? feature, as: StickyNote.self) { $0.props.text = words } }
    }
    fileprivate func pillPoint(of id: ShapeID? = nil) throws -> CGPoint {
        let frame = try require(editor.mentionPills(of: id ?? feature).first?.frame, "a pill in the words")
        return h.view(CGPoint(x: frame.midX, y: frame.midY))
    }
}

@MainActor let relateOfferShippedTests = Suite("The offer to relate two types, shipped", [
    test("a type that mentions itself, offered and chosen on the shipped notes: one arrow in and one out, each with one head and the two bent apart, the new type clear of every shape, joining the type to itself, and one Undo returns the bytes, also after a Redo") {
        let m = try Minute()
        defer { m.close() }
        let editor = m.editor
        m.sayWords(MentionText([.text("friends with another "), .mention(m.feature, label: "Feature")]))
        editor.selectedShapeIDs = [m.feature]
        editor.undoHistory.seal()
        let bytes = try m.bytes()
        let known = Set(editor.document.shapes.map(\.id))
        m.h.click(at: try m.pillPoint())
        let queued = try require(editor.menuToPopUp)
        expectEqual(queued.menu.items.map(\.title), ["Relate to Feature"])
        try queued.menu.choose("Relate to Feature")
        editor.menuDidPopUp()
        let added = editor.document.shapes.filter { !known.contains($0.id) }
        expectEqual(added.count, 3, "\(added.map(\.kind))")
        let made = try require(added.first { $0[RelationshipProperty.self] == true }).id
        let toIt = m.arrows.filter { $0.props.start.binding?.shapeID == m.feature && $0.props.end.binding?.shapeID == made }
        let fromIt = m.arrows.filter { $0.props.start.binding?.shapeID == made && $0.props.end.binding?.shapeID == m.feature }
        expectEqual(toIt.count, 1)
        expectEqual(fromIt.count, 1)
        expect(toIt.first?.props.endArrowhead == true && fromIt.first?.props.endArrowhead == true)
        expect(toIt.first?.props.startArrowhead != true && fromIt.first?.props.startArrowhead != true, "never two-headed")
        expectEqual(toIt.first?.props.bend, 0, "the first of the pair is straight")
        expectEqual(fromIt.first.map { abs($0.props.bend) }, 34, "and the second is stored bent apart from it")
        let box = try m.frame(made)
        for other in [m.feature, m.featureNote, m.layer, m.layerNote] { expect(!box.intersects(try m.frame(other)), "overlaps \(other)") }
        let graph = try require(editor.relationships?.graph)
        expectEqual(graph.relationshipTypes(joining: m.feature, and: m.feature), [made])
        editor.closeCard()
        editor.undo()
        expect(try m.bytes() == bytes, "undo byte exact")
        editor.redo()
        editor.undo()
        expect(try m.bytes() == bytes, "undo byte exact after redo")
    },
    test("a locked frame round both types: the offer is shown, the choice is refused, and nothing changes and no step is left") {
        let m = try Minute()
        defer { m.close() }
        let editor = m.editor
        m.sayWords(MentionText([.text("is in a "), .mention(m.layer, label: "Layer")]))
        _ = m.frameAround(locked: true)
        editor.selectedShapeIDs = [m.feature]
        editor.undoHistory.seal()
        let bytes = try m.bytes()
        let undoName = editor.undoHistory.undoName
        m.h.click(at: try m.pillPoint())
        let queued = try require(editor.menuToPopUp, "the offer is shown")
        expectEqual(queued.menu.items.map(\.title), ["Relate to Layer"])
        try queued.menu.choose("Relate to Layer")
        editor.menuDidPopUp()
        editor.closeCard()
        expect(try m.bytes() == bytes, "nothing changed")
        expectEqual(editor.undoHistory.undoName, undoName, "no step left")
    },
    test("a double-click on the pill of an unlocked type drops the menu the first press queued and begins editing the type") {
        let m = try Minute()
        defer { m.close() }
        let editor = m.editor
        m.sayWords(MentionText([.text("is in a "), .mention(m.layer, label: "Layer")]))
        editor.selectedShapeIDs = [m.feature]
        m.h.click(at: try m.pillPoint())
        expect(editor.menuToPopUp != nil)
        m.h.click(at: try m.pillPoint(), clickCount: 2)
        m.h.wait(50)
        expect(editor.menuToPopUp == nil, "menu dropped")
        expectEqual(editor.editingShapeID, m.feature)
    },
    test("a type on a subboard: the offer says it will be made public, choosing makes its pill and the relationship type, the pill is Mentions' again, and one Undo returns both boards byte for byte") {
        let m = try Minute()
        defer { m.close() }
        let editor = m.editor
        let board = ShapeID(), company = ShapeID()
        var sub = ShapeRecord(id: board, Subboard(frame: CGRect(x: 40, y: 1200, width: 240, height: 160)))
        sub[TitleProperty.self] = "Clients"
        editor.transact { $0.insert(AnyShapeRecord(sub)) }
        var c = ShapeRecord(id: company, StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: MentionText(plain: "A company")))
        c[TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter)
        c[TitleProperty.self] = "Company"
        editor.transact(on: BoardID(owner: board), "Draw") { $0.insert(AnyShapeRecord(c)) }
        expect(editor.showBoard(BoardID(owner: board)))
        expect(editor.showBoard(.root))
        m.sayWords(MentionText([.text("works at a "), .mention(company, label: "Company")]))
        editor.selectedShapeIDs = [m.feature]
        editor.undoHistory.seal()
        let bytes = try m.bytes()
        m.h.click(at: try m.pillPoint())
        let q = try require(editor.menuToPopUp, "the offer")
        expectEqual(q.menu.items.map(\.title), ["Relate to Company · will be made public"])
        try q.menu.choose(q.menu.items[0].title)
        editor.menuDidPopUp()
        editor.closeCard()
        let graph = try require(editor.relationships?.graph)
        expectEqual(graph.relationshipTypes(joining: m.feature, and: company).count, 1)
        expectEqual(editor.document.shapes.filter { $0.kind == "reference" }.count, 1, "the pill for Company")
        m.h.click(at: try m.pillPoint())
        expect(editor.menuToPopUp == nil, "joined now: no offer")
        expectEqual(editor.editingShapeID, m.feature, "the pill is Mentions' again")
        editor.endEditing()
        editor.undo()
        expect(try m.bytes() == bytes, "undo exact both boards")
    },
    test("the relationship type made by the offer is named in its pill, from the click and from the context menu alike: the name lands, no model is asked, and one Undo returns the bytes") {
        for viaMenu in [false, true] {
            let m = try Minute()
            defer { m.close() }
            let editor = m.editor
            m.sayWords(MentionText([.text("is in a "), .mention(m.layer, label: "Layer")]))
            editor.selectedShapeIDs = [m.feature]
            editor.undoHistory.seal()
            let bytes = try m.bytes()
            let asked = m.model.requests.count
            let known = Set(editor.document.shapes.map(\.id))
            if viaMenu {
                let menu = try require(m.h.secondaryClick(at: try m.pillPoint()))
                try menu.choose("Relate to Layer")
            } else {
                m.h.click(at: try m.pillPoint())
                try require(editor.menuToPopUp).menu.choose("Relate to Layer")
                editor.menuDidPopUp()
            }
            let made = try require(editor.document.shapes.first { !known.contains($0.id) && $0[RelationshipProperty.self] == true }).id
            let field = try require(m.pillField)
            field.insertText("in", replacementRange: NSRange(location: 0, length: 0))
            field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            expectEqual(editor.editingShapeID, nil)
            expectEqual(editor.document[made]?[TitleProperty.self], "in", "viaMenu \(viaMenu)")
            m.h.scheduler.advance(by: TypeSync<TypeSchemaProperty>.idleDelay)
            m.h.wait(100)
            expectEqual(m.model.requests.filter { $0.messages.first?.text.hasPrefix("<prose>") != true }.count, asked, "model asked viaMenu \(viaMenu)")
            expectEqual(editor.undoHistory.undoName, "New Relationship Type", "viaMenu \(viaMenu)")
            editor.undo()
            expect(try m.bytes() == bytes, "undo exact viaMenu \(viaMenu)")
            expect(!editor.canUndo || editor.undoHistory.undoName != "New Relationship Type", "single step viaMenu \(viaMenu)")
        }
    },
])

