import Adornments
import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Foundation
import Geometry
import LanguageModels
import Mentions
import Selection
import ShippedTesting
import StickyNotes
import TestKit
import Titles
import Types
import Validation

// Board 2 of the relationships wireframes, frames 3 and 4: a type related to itself ("friends with another Feature"), on
// the shipped list with real notes and real arrows, by each way in. Two port drags (Feature to the relationship type, and
// the relationship type back to Feature), `Relate to Feature` from Feature's words, and one `canvas draw` script. Each
// makes two arrows bowed apart, never one two-headed arrow; a relationship between two Feature notes then fits in either
// direction, and the rows on a Feature note are one where the two ends are named alike and two where they are not.

private let friends = "friends"

/// What a pill is moved right, past the length a test names, to leave the arrow as long as it was when the type was a square note
/// (an arrow stops short of a pill by its standoff), the pill level with the note it comes from, so the arrow is level.
private let capsuleGap: CGFloat = 22

extension Minute {
    /// A note marked as a relationship type, as Is a ▸ does it, beside the types.
    fileprivate func addRelationshipTypeNote(at origin: CGPoint = CGPoint(x: 500, y: 40)) -> ShapeID {
        let id = ShapeID()
        // Stored the size it is drawn at, so `origin` is where its pill starts (a pill is drawn about the middle of the box it stores).
        editor.transact { $0.insert(AnyShapeRecord(ShapeRecord(id: id, StickyNote(frame: CGRect(origin: origin, size: TypePills.pill(title: nil, fields: 0).size), text: "")))) }
        editor.makeRelationshipType(id)
        editor.selectedShapeIDs = []
        editor.undoHistory.seal()
        return id
    }

    /// A second Feature note with a value.
    fileprivate func addFeatureNote(at origin: CGPoint = CGPoint(x: 400, y: 500)) -> ShapeID {
        let id = ShapeID()
        var record = ShapeRecord(id: id, StickyNote(frame: CGRect(origin: origin, size: CGSize(width: 200, height: 200)), text: ""))
        record[IsAProperty.self] = [TypeLink(feature)]
        record[FieldValuesProperty.self] = FieldValues(["purpose": "reset a password"])
        editor.transact { $0.insert(AnyShapeRecord(record)) }
        editor.undoHistory.seal()
        return id
    }

    /// The arrows from `from` to `to`.
    fileprivate func arrows(from: ShapeID, to: ShapeID) -> [ShapeRecord<Arrow>] {
        arrows.filter { $0.props.start.binding?.shapeID == from && $0.props.end.binding?.shapeID == to }
    }

    /// Which side of the chord between two shapes' centers an arrow's middle is on: +1 or -1, 0 on it.
    fileprivate func side(of arrow: ShapeID, between a: ShapeID, and b: ShapeID) throws -> Int {
        let middle = try require(editor.arrowGeometry(of: arrow)).middle
        let (from, to) = (try center(a), try center(b))
        let cross = (to.x - from.x) * (middle.y - from.y) - (to.y - from.y) * (middle.x - from.x)
        return abs(cross) < 1e-6 ? 0 : cross > 0 ? 1 : -1
    }

    /// The name an end arrow gives its row, typed.
    fileprivate func name(_ arrow: ShapeID, _ text: String) {
        editor.transact("Typing") { $0.update(arrow, as: Arrow.self) { $0.props.text = MentionText(plain: text) } }
    }

    /// The far notes in the pills of a note's row of this name.
    fileprivate func pills(of note: ShapeID, in row: String) -> [ShapeID]? {
        guard let content = rows.rows(of: note).first(where: { $0.name == row })?.content else { return nil }
        if case .related(let pills, _) = content { return pills.compactMap(\.target) }
        return []
    }

    /// Both arrows of a type related to itself, as the story's two drags make them: Feature into the relationship type, and
    /// the relationship type back to Feature.
    fileprivate func relateToItself(through type: ShapeID) throws -> (out: ShapeID, back: ShapeID) {
        try drag(from: feature, to: type)
        let out = try require(arrows(from: feature, to: type).first, "an arrow into the relationship type").id
        try drag(from: type, to: feature)
        let back = try require(arrows(from: type, to: feature).first, "an arrow back").id
        return (out, back)
    }

    /// What a pair of arrows between a type and a relationship type reads as: two arrows, one head each, the second bowed
    /// off the first's line.
    fileprivate func expectTwoArrows(_ pair: (out: ShapeID, back: ShapeID), type: ShapeID, _ message: String) throws {
        expectEqual(arrows.count, 2, "\(message): two arrows")
        for id in [pair.out, pair.back] {
            let arrow = try require(arrows.first { $0.id == id })
            expect(arrow.props.endArrowhead && !arrow.props.startArrowhead, "\(message): one head, at the end")
        }
        let out = try require(arrows.first { $0.id == pair.out }), back = try require(arrows.first { $0.id == pair.back })
        expectEqual(out.props.bend, 0, "\(message): the first is straight")
        expectEqual(abs(back.props.bend), 34, "\(message): the second is stored bent apart from it")
        expectEqual(try side(of: pair.out, between: feature, and: type), 0, "\(message): the first lies on the line between the two")
        expect(try side(of: pair.back, between: feature, and: type) != 0, "\(message): the second bows off it")
        let graph = try require(editor.relationships?.graph)
        expectEqual(graph.relationshipTypes(joining: feature, and: feature), [type], "\(message): the type is related to itself")
        expectEqual(graph.sides(of: type).from.map(\.type), [feature])
        expectEqual(graph.sides(of: type).to.map(\.type), [feature])
    }
}

@MainActor let relationshipSelfShippedTests = Suite("A type related to itself, shipped", [
    test("two port drags: Feature into a relationship type and the relationship type back to Feature make two one-headed arrows bowed apart, each in its own step; one Undo takes the second, and both are an end of the type") {
        let m = try Minute()
        defer { m.close() }
        let editor = m.editor
        let type = m.addRelationshipTypeNote()
        let start = editor.document
        try m.drag(from: m.feature, to: type)
        expectEqual(editor.undoHistory.undoName, "Add Arrow")
        expect(editor.menuToPopUp == nil, "no list: an end is taken at once")
        let out = try require(m.arrows(from: m.feature, to: type).first, "an arrow into the relationship type")
        expectEqual(editor.relationships?.end(out.id)?.side, .from)
        expectEqual(editor.relationships?.end(out.id)?.type, type)
        let afterFirst = editor.document
        try m.drag(from: type, to: m.feature)
        expectEqual(editor.undoHistory.undoName, "Add Arrow")
        let back = try require(m.arrows(from: type, to: m.feature).first, "an arrow back")
        expectEqual(editor.relationships?.end(back.id)?.side, .to)
        try m.expectTwoArrows((out.id, back.id), type: type, "drawn")
        expectEqual(m.arrows.count, 2, "never one two-headed arrow between the two")
        editor.undo()
        expectEqual(editor.document, afterFirst, "one Undo takes the second drag and nothing of the first")
        editor.redo()
        try m.expectTwoArrows((out.id, back.id), type: type, "redone")
        editor.undo()
        editor.undo()
        expectEqual(editor.document, start)
        expect(m.model.requests.isEmpty, "no step asked the model")
    },
    test("an end of the type says nothing on the line, whatever its length: no `from`, no label, no cut; the line is part of the one through the pill") {
        for length in [20, 40, 80] as [CGFloat] {
            let m = try Minute()
            defer { m.close() }
            let editor = m.editor
            let feature = try m.frame(m.feature)
            let type = m.addRelationshipTypeNote(at: CGPoint(x: feature.maxX + length + capsuleGap, y: feature.midY - TypesStyle.pillHeight / 2))
            let arrow = editor.galleryArrow(m.feature, type)
            let geometry = try require(editor.shapeContext.geometry(of: arrow))
            expectEqual(geometry.label, nil, "\(length) units: no label")
            expect(editor.adornmentFrames(of: arrow).isEmpty, "\(length) units: nothing is drawn beside it: \(editor.adornmentFrames(of: arrow).map(\.label.text))")
            expectEqual(editor.arrowGeometry(of: arrow)?.endArrowhead, false, "no head at the pill, whatever it stores")
        }
    },
    test("a note's rows: one row where the two ends are named alike, one named for the type where neither is named, two where they are named apart; the type's own note says it runs both ways") {
        let m = try Minute()
        defer { m.close() }
        let type = m.addRelationshipTypeNote()
        let pair = try m.relateToItself(through: type)
        // Neither end is named: one row, named for the type at the other end.
        expectEqual(m.names(of: m.featureNote), ["purpose", "feature"])
        m.name(pair.out, friends)
        m.name(pair.back, friends)
        expectEqual(m.names(of: m.featureNote), ["purpose", friends], "named alike: one row")
        expectEqual(m.rows.rows(of: m.feature).last?.name, friends)
        expectEqual(m.rows.rows(of: m.feature).last?.content, .relationType(direction: "↔", chips: [m.feature], more: 0), "and the type says both ways")
        m.name(pair.back, "friend of")
        expectEqual(m.names(of: m.featureNote), ["purpose", friends, "friend of"], "named apart: two rows")
        expectEqual(m.rows.rows(of: m.feature).suffix(2).map(\.name), [friends, "friend of"])
        expectEqual(m.rows.rows(of: m.feature).suffix(2).map(\.content), [.relationType(direction: "→", chips: [m.feature], more: 0), .relationType(direction: "←", chips: [m.feature], more: 0)])
        m.name(pair.back, "")
        expectEqual(m.names(of: m.featureNote), ["purpose", friends, "feature"], "one named and one not: two rows")
    },
    test("a relationship between two notes of the type fits in either direction, and a drag between them takes the relationship type at once; the rows list the other note whichever way the arrow ran") {
        let m = try Minute()
        defer { m.close() }
        let editor = m.editor
        let type = m.addRelationshipTypeNote()
        let pair = try m.relateToItself(through: type)
        m.name(pair.out, friends)
        m.name(pair.back, friends)
        let other = m.addFeatureNote()
        editor.selectedShapeIDs = []
        try m.drag(from: m.featureNote, to: other)
        let there = try require(m.arrows(from: m.featureNote, to: other).first)
        expectEqual(there[IsAProperty.self]?.map(\.shape), [type], "of the relationship type at once")
        expect(editor.menuToPopUp == nil, "no list")
        expectEqual(editor.undoHistory.undoName, "Add Arrow")
        try m.drag(from: other, to: m.featureNote)
        let backAgain = try require(m.arrows(from: other, to: m.featureNote).first)
        expectEqual(backAgain[IsAProperty.self]?.map(\.shape), [type])
        for arrow in [there, backAgain] {
            expectEqual(editor.validation?.result(for: arrow.id)?.issues.map(\.message) ?? [], [], "it fits")
            expectEqual(editor.relationships?.fits(of: arrow.id).map(\.fit.isMisfit), [false])
        }
        expectEqual(m.pills(of: m.featureNote, in: friends), [other], "the first note lists the other, once")
        expectEqual(m.pills(of: other, in: friends), [m.featureNote])
        // Named apart, the from end is `friends` and the to end `friend of`: a note has both rows.
        m.name(pair.back, "friend of")
        expectEqual(m.names(of: other), ["purpose", friends, "friend of"])
        expect(m.pills(of: m.featureNote, in: friends) == [other] && m.pills(of: m.featureNote, in: "friend of") == [other], "each row lists the arrows of its side")
        editor.undo()
        expect(m.model.requests.isEmpty, "no step asked the model")
    },
    test("Relate to Feature from Feature's words: the same two arrows bowed apart, the same rows by name, a relationship between two notes that fits, and the model never asked") {
        let m = try Minute()
        defer { m.close() }
        let editor = m.editor
        editor.transact("Typing") { $0.update(m.feature, as: StickyNote.self) { $0.props.text = MentionText([.text("friends with another "), .mention(m.feature, label: "Feature")]) } }
        editor.selectedShapeIDs = [m.feature]
        editor.undoHistory.seal()
        let known = Set(editor.document.shapes.map(\.id))
        let pill = try require(editor.mentionPills(of: m.feature).first?.frame, "a pill in the words")
        m.h.click(at: m.h.view(CGPoint(x: pill.midX, y: pill.midY)))
        let queued = try require(editor.menuToPopUp)
        expectEqual(queued.menu.items.map(\.title), ["Relate to Feature"])
        try queued.menu.choose("Relate to Feature")
        editor.menuDidPopUp()
        editor.closeCard()
        let type = try require(editor.document.shapes.first { !known.contains($0.id) && $0[RelationshipProperty.self] == true }).id
        let out = try require(m.arrows(from: m.feature, to: type).first).id, back = try require(m.arrows(from: type, to: m.feature).first).id
        try m.expectTwoArrows((out, back), type: type, "offered")
        expectEqual(m.names(of: m.featureNote), ["purpose", "feature"])
        m.name(out, friends)
        m.name(back, friends)
        expectEqual(m.names(of: m.featureNote), ["purpose", friends], "named alike: one row")
        m.name(back, "friend of")
        expectEqual(m.names(of: m.featureNote), ["purpose", friends, "friend of"], "named apart: two rows")
        let other = m.addFeatureNote()
        try m.drag(from: m.featureNote, to: other)
        let there = try require(m.arrows(from: m.featureNote, to: other).first)
        expectEqual(there[IsAProperty.self]?.map(\.shape), [type], "a drag between two notes of the type takes it")
        expectEqual(editor.validation?.result(for: there.id)?.issues.map(\.message) ?? [], [])
        expect(m.model.requests.isEmpty, "the model was never asked")
    },
    test("a port's drag from Feature back onto Feature: the same two arrows bowed apart through a new relationship type, its name typed in its pill, no arrow from Feature to itself, one step; a second drag makes a second") {
        let m = try Minute()
        defer { m.close() }
        let editor = m.editor
        let start = try m.bytes()
        let known = Set(editor.document.shapes.map(\.id))
        try m.drag(from: m.feature, to: m.feature)
        let type = try require(editor.document.shapes.first { !known.contains($0.id) && $0[RelationshipProperty.self] == true }).id
        expectEqual(editor.selectedShapeIDs, [type])
        expectEqual(editor.editingShapeID, type, "its name is typed in the pill")
        let out = try require(m.arrows(from: m.feature, to: type).first).id, back = try require(m.arrows(from: type, to: m.feature).first).id
        try m.expectTwoArrows((out, back), type: type, "dragged")
        expect(m.arrows(from: m.feature, to: m.feature).isEmpty, "no arrow from Feature to itself")
        expectEqual(m.names(of: m.featureNote), ["purpose", "feature"])
        let field = try require(m.pillField)
        field.insertText(friends, replacementRange: NSRange(location: 0, length: 0))
        field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        expectEqual(editor.document[type]?[TitleProperty.self], friends)
        expectEqual(editor.undoHistory.undoName, TypesStyle.newRelationshipType)
        try m.drag(from: m.feature, to: m.feature)
        try require(m.pillField).doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        expectEqual(editor.relationships?.graph.relationshipTypes(joining: m.feature, and: m.feature).count, 2, "a second")
        expectEqual(m.arrows.count, 4)
        editor.undo()
        editor.undo()
        expect(try m.bytes() == start, "two Undos return the bytes")
        expect(m.model.requests.isEmpty, "no step asked the model")
    },
    test("Feature in a locked frame, dragged onto itself: nothing can be made, so nothing is left, no arrow from Feature to itself, and no step") {
        let m = try Minute()
        defer { m.close() }
        _ = m.frameAround(locked: true)
        let before = m.editor.document
        let steps = m.editor.undoHistory.undoName
        try m.drag(from: m.feature, to: m.feature)
        expectEqual(m.editor.document, before)
        expectEqual(m.editor.undoHistory.undoName, steps)
        expect(m.editor.card == nil)
        #if DEBUG
        expectEqual(m.editor.relationships?.heldConnections, [])
        #endif
    },
    test("Relate to ▸ on a type whose words name nothing lists the type itself, the drag by keys: a pick relates it to itself, and it stays listed for another") {
        let m = try Minute()
        defer { m.close() }
        let editor = m.editor
        editor.selection = m.feature
        let menu = try require(editor.menuForSelection(omitting: []))
        let relate = try require(menu.item(withTitle: TypesStyle.relateTo)?.submenu, "\(menu.outline)")
        expectEqual(relate.items.map(\.title), ["Feature"])
        try menu.choose(TypesStyle.relateTo, "Feature")
        editor.endEditing()
        let graph = try require(editor.relationships?.graph)
        let type = try require(graph.relationshipTypes(joining: m.feature, and: m.feature).first)
        let out = try require(m.arrows(from: m.feature, to: type).first).id, back = try require(m.arrows(from: type, to: m.feature).first).id
        try m.expectTwoArrows((out, back), type: type, "picked")
        expectEqual(editor.undoHistory.undoName, TypesStyle.newRelationshipType)
        editor.selection = m.feature
        let again = try require(editor.menuForSelection(omitting: []))
        expectEqual(again.item(withTitle: TypesStyle.relateTo)?.submenu?.items.map(\.title), ["Feature"], "still listed")
        editor.selection = type
        expectEqual(try require(editor.menuForSelection(omitting: [])).item(withTitle: TypesStyle.relateTo), nil, "not on the relationship type")
        editor.selection = m.featureNote
        expectEqual(try require(editor.menuForSelection(omitting: [])).item(withTitle: TypesStyle.relateTo), nil, "nor on a note that is no type")
    },
    test("a note related to itself: a port's drag never ends on its own note, a row's pick refuses it, and what a script's arrow from a note to itself does is pinned") {
        let m = try Minute()
        defer { m.close() }
        let editor = m.editor
        let type = m.addRelationshipTypeNote()
        let pair = try m.relateToItself(through: type)
        m.name(pair.out, friends)
        m.name(pair.back, friends)
        let before = editor.document
        // A drag from a note's dot back onto the note itself is a free release: the arrow is taken back.
        try m.drag(from: m.featureNote, to: m.featureNote)
        expectEqual(m.arrows.count, 2, "no arrow from a note to itself")
        expectEqual(editor.document.shapes.map(\.id), before.shapes.map(\.id))
        // A row's pick of the note itself refuses it.
        let row = try require(editor.relationships?.graph.rows(for: [m.feature], isType: false).first)
        expectEqual(editor.relate(m.featureNote, to: m.featureNote, in: row), nil, "refused")
        expectEqual(m.arrows.count, 2)
    },
])

private let person = scripted(#"{"type": "object", "properties": {"name": {"type": "string"}}}"#)
private let friendship = scripted(#"{"type": "object", "properties": {"since": {"type": "string"}}}"#)

private func rows(_ result: JSON) -> [JSON] { result["changes"]?.arrayValue ?? [] }

@MainActor let relationshipSelfDrawTests = Suite("A type related to itself, drawn through canvas", [
    test("one script draws the type, its relationship type and both ends, then notes and a friendship: the second end is stored bent apart, the rows are as the names say, a run again is unchanged, and Undo takes the run back") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let script = """
        sticky-note "Person" schema: "\(person)"
        sticky-note "Friendship" right of "Person" relationship: true schema: "\(friendship)"
        edge "Person" -> "Friendship" text: "friends"
        edge "Friendship" -> "Person" text: "friends"
        sticky-note "Ann" below "Person" is: "Person"
        sticky-note "Bo" right of "Ann" is: "Person"
        edge "Ann" -> "Bo" is: "Friendship"
        """
        let made = try JSON(text: canvas(server, ["draw", script]).output)
        expectEqual(rows(made).count, 7)
        let ends = rows(made).filter { $0["endOf"] != nil }
        expectEqual(ends.map { $0["endOf"] }, [.object(["type": "Friendship", "side": "from", "row": "friends"]), .object(["type": "Friendship", "side": "to", "row": "friends"])],
                    "both ends, named alike")
        expectEqual(rows(made).first { $0["relates"] != nil }?["relates"], .object(["from": .array([.string("Person")]), "to": .array([.string("Person")])]))
        expectEqual(rows(made).last?["is"], .array([.string("Friendship")]))
        let arrows = board.editor.document.shapes.compactMap { $0.typed(as: Arrow.self) }
        let ended = arrows.filter { ($0[IsAProperty.self] ?? []).isEmpty }
        expectEqual(ended.count, 2)
        expectEqual(Set(ended.map { abs($0.props.bend) }), [0, 34], "one straight and one stored bent apart")
        expect(ended.allSatisfy { $0.props.endArrowhead && !$0.props.startArrowhead }, "one head each")
        let person = try require(board.editor.document.shapes.first { $0[TitleProperty.self] == "Person" }).id
        let ann = try require(board.editor.document.shapes.first { $0[TitleProperty.self] == "Ann" }).id
        let bo = try require(board.editor.document.shapes.first { $0[TitleProperty.self] == "Bo" }).id
        expectEqual(board.editor.rowBook?.rows(of: ann).map(\.name).last, "friends", "one row")
        expectEqual(board.editor.rowBook?.rows(of: person).last?.content, .relationType(direction: "↔", chips: [person], more: 0))
        _ = bo
        expectEqual(board.editor.undoHistory.undoName, "Draw")
        board.editor.undo()
        expectEqual(board.editor.document.shapes.count, 0, "one step takes the run back")
        board.editor.redo()
        let again = try JSON(text: canvas(server, ["draw", script]).output)
        expectEqual(rows(again).map { $0["did"] }, Array(repeating: "unchanged", count: 7), "run again")
        let dry = try JSON(text: canvas(server, ["draw", "--dry-run", script]).output)
        expectEqual(rows(dry).map { $0["endOf"] }, rows(made).map { $0["endOf"] }, "a dry run says what a real run says")
        // A note related to itself: the connector makes no arrow from a note to itself, so a script is refused, as a port's drag
        // and a row's pick are, and nothing is drawn.
        let count = board.editor.document.shapes.count
        let loop = try canvas(server, ["draw", #"edge "Ann" -> "Ann" is: "Friendship""#])
        expectEqual(loop.status, 1)
        let refusal = try JSON(text: loop.error)
        expectEqual(refusal["error"]?["reason"], "no_channel")
        expectEqual(refusal["error"]?["message"], "a connection on note-link can't end where it starts")
        expectEqual(board.editor.document.shapes.count, count, "nothing drawn")
        // And the relationship type deleted by a script takes both end arrows with it in the run's one step; the friendship stays.
        let friendship = try require(board.editor.document.shapes.first { $0[TitleProperty.self] == "Friendship" }).id
        let withEnds = board.editor.document
        let gone = try canvas(server, ["draw", #"delete "Friendship""#])
        expectEqual(gone.status, 0, gone.error)
        expect(board.editor.document[friendship] == nil)
        let left = board.editor.document.shapes.compactMap { $0.typed(as: Arrow.self) }
        expectEqual(left.count, 1, "only the friendship between the two notes is left")
        expectEqual(left.first?[IsAProperty.self]?.map(\.shape), [friendship], "with a type that is gone")
        board.editor.undo()
        expectEqual(board.editor.document, withEnds, "one Undo brings the type and both ends back")
    },
])
