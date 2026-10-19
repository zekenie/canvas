@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import Mentions
import Selection
import TestKit
import Titles
import Types

// The relation rows as shown: the pills of a note's relationships, what each far end is, the names pills are laid out
// with and the notes that show them, the faces of a pill and of a type's row, and that a row's presence writes
// nothing of the note. Over `RelationScene` (RelationRowTests.swift), in an editor driven as a person would.

private struct Failure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

extension RelationScene {
    /// A note of the Layer type named `words`.
    @discardableResult
    func addLayerNote(_ words: String, at origin: CGPoint = CGPoint(x: 800, y: 1500)) -> ShapeID {
        editor.addSlip(words, of: [layer], at: origin)
    }

    /// The pills of a row of a note, and what is counted in `+N`.
    func pills(_ id: ShapeID, _ name: String) throws -> (pills: [ShownPill], more: Int) {
        guard case .related(let pills, let more) = try row(id, name).content else { throw Failure("pills in \(name)") }
        return (pills, more)
    }

    /// A point on a pill of a row, in the view (the camera is the identity).
    func point(onPill place: Int, of id: ShapeID, _ name: String) throws -> CGPoint {
        let shown = try row(id, name)
        guard case .related(let pills, _) = shown.content, pills.indices.contains(place) else { throw Failure("a pill \(place) in \(name)") }
        return CGPoint(x: shown.valueRect.minX + pills[place].x + pills[place].width / 2, y: shown.rect.midY)
    }

    /// The scheduler's due actions: a pill's click is followed on its next turn.
    func settle() { harness.scheduler.advance(by: .zero) }
}

@MainActor let relationShownTests = Suite("Relation rows as shown", [
    test("a relationship is a pill in the row of each of its two notes, by the name each shows, and a row with none reads `add …`") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        let zed = s.addLayerNote("Zed"), alpha = s.addLayerNote("Alpha"), mid = s.addLayerNote("Mid")
        let arrows = [zed, alpha, mid].map { s.relate(s.note, $0) }
        let (pills, more) = try s.pills(s.note, "in")
        expectEqual(more, 0)
        expectEqual(pills.map(\.label), ["Alpha", "Mid", "Zed"], "by the name each shows, whatever order the arrows were drawn in")
        expectEqual(pills.map(\.target), [alpha, mid, zed])
        expectEqual(pills.map(\.arrow), [arrows[1], arrows[2], arrows[0]])
        expect(pills.allSatisfy { $0.isLive && $0.via == nil && !$0.isWrong })
        expectEqual(pills.map(\.state), [.note(alpha), .note(mid), .note(zed)])
        expectEqual(pills[0].x, 0)
        expectEqual(pills[1].x, pills[0].width + TypesStyle.pillGap)
        // The other end's row shows the other note.
        let back = try s.pills(alpha, "feature")
        expectEqual(back.pills.map(\.target), [s.note])
        expectEqual(back.pills.first?.label, "Sign in")
        // A note not in it shows an empty row, and the row's words are its name.
        expectEqual(try s.row(s.layerNote, "feature").content, .empty("add feature"))
        // Neither note stored anything for it.
        expectEqual(s.editor.document[s.note]?[FieldValuesProperty.self], nil)
    },
    test("a note with many relationships shows as many pills as fit and counts the rest, the first always") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        for index in 0..<30 { s.relate(s.note, s.addLayerNote("Layer \(index)", at: CGPoint(x: 40 + 30 * Double(index), y: 1500))) }
        let row = try s.row(s.note, "in")
        guard case .related(let pills, let more) = row.content else { throw Failure("pills") }
        expect(more > 0 && pills.count + more == 30, "as many as fit, the rest counted: \(pills.count) and \(more)")
        let last = try require(pills.last)
        expect(last.x + last.width + TypesStyle.pillGap <= row.valueRect.width + 0.5, "the pills fit the column")
        expectEqual(pills.first?.label, "Layer 0")
    },
    test("every state of a far end is a pill through the pill the arrow ends on: solid for a note, dashed for the rest") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        // A note the pill may stand for.
        s.editor.open(s.layerNote)
        let relay = s.editor.addRelay(standingFor: [s.layerNote], says: "Foundation")
        s.editor.addBond(s.note, relay, of: [s.rel])
        var (pills, _) = try s.pills(s.note, "in")
        expectEqual(pills.count, 1)
        expectEqual(pills[0].state, .note(s.layerNote))
        expectEqual(pills[0].target, s.layerNote)
        expectEqual(pills[0].via, relay)
        expect(pills[0].isLive, "it reads through")
        expectEqual(pills[0].destination, s.layerNote)
        // The note private again: the pill is there and may not stand for it.
        s.editor.transact { $0.update(s.layerNote) { $0.meta[Open.self] = nil } }
        (pills, _) = try s.pills(s.note, "in")
        expectEqual(pills[0].state, .notAdmitted(s.layerNote, needs: "open"))
        expect(!pills[0].isLive)
        expectEqual(pills[0].target, s.layerNote)
        expectEqual(pills[0].label, "Foundation", "the note's live name")
        expectEqual(pills[0].destination, relay, "a dashed pill goes to the pill")
        // The note gone: the pill keeps the name it says.
        s.editor.open(s.layerNote)
        s.editor.transact("Delete") { $0.delete([s.layerNote]) }
        (pills, _) = try s.pills(s.note, "in")
        expectEqual(pills[0].state, .gone(called: "Foundation"))
        expect(!pills[0].isLive && pills[0].target == nil)
        expectEqual(pills[0].label, "Foundation")
        expectEqual(pills[0].destination, relay)
        s.editor.undo()
        (pills, _) = try s.pills(s.note, "in")
        expectEqual(pills[0].state, .note(s.layerNote), "undo brings it back")
        // A pill that finds several, one that stands for nothing.
        let query = s.editor.addRelay(standingFor: [s.layerNote, s.note], says: "every layer", at: CGPoint(x: 40, y: 1700))
        let nothing = s.editor.addRelay(standingFor: [], says: "", at: CGPoint(x: 400, y: 1700))
        s.editor.addBond(s.note, query, of: [s.rel])
        s.editor.addBond(s.note, nothing, of: [s.rel])
        let (all, more) = try s.pills(s.note, "in")
        expectEqual(more, 0)
        expectEqual(all.count, 3)
        let found = try require(all.first { if case .query = $0.state { true } else { false } })
        expectEqual(found.state, .query(called: "every layer"))
        expectEqual(found.label, "every layer")
        expect(!found.isLive && found.target == nil && found.via == query)
        let blank = try require(all.first { $0.state == .empty })
        expect(!blank.isLive && blank.target == nil && blank.via == nothing)
        expectEqual(blank.label, FieldWords.noteBlank)
    },
    test("a relationship whose arrow has a free end is in no row, and shows again when the arrow is bound") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        let arrow = s.editor.addBond(s.note, nil, of: [s.rel])
        expectEqual(try s.row(s.note, "in").content, .empty("add in"))
        s.editor.transact("Bind") { $0.update(arrow, as: Bond.self) { $0.props.to = s.layerNote } }
        expectEqual(try s.pills(s.note, "in").pills.map(\.target), [s.layerNote])
    },
    test("a pill is laid out with the name of the note it stands for, and the notes that show it are filed: a rename lets go of exactly their rows, and a keystroke below the first line of the note lets go of none") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        let third = s.editor.addSlip("Another feature", of: [s.feature], at: CGPoint(x: 800, y: 500))
        let other = s.addLayerNote("Elsewhere")
        s.relate(s.note, s.layerNote)
        s.relate(third, s.layerNote)
        s.relate(s.note, other)
        let bystander = s.editor.addSlip("Not related", of: [s.feature], at: CGPoint(x: 1200, y: 500))
        for id in [s.note, third, bystander, s.layerNote, other] { _ = s.rows(id) }
        expectEqual(s.book.pillLabels[s.layerNote], "Foundation")
        expectEqual(s.book.holders[s.layerNote], [s.note, third])
        expectEqual(s.book.holders[other], [s.note])
        expectEqual(s.book.holders[s.note], [s.layerNote, other], "the far notes' pills of this note")
        let long = "Ahead of the foundation, with a name that is longer than it was"
        let wasWide = try s.pills(s.note, "in").pills.first { $0.target == s.layerNote }?.width ?? 0
        let built = s.book.rowsShown
        s.editor.transact("Rename") { $0.update(s.layerNote, as: RowSlip.self) { $0.props.text = MentionText(plain: long) } }
        for id in [s.note, third, bystander, other] { _ = s.rows(id) }
        // The two notes that show it were built again, and the layer note's own row (its pill is Sign in's).
        expectEqual(s.book.rowsShown - built, 2, "the two notes that show the pill, no other")
        expectEqual(s.book.pillLabels[s.layerNote], long)
        let nowWide = try s.pills(s.note, "in").pills.first { $0.target == s.layerNote }?.width ?? 0
        expect(nowWide > wasWide, "the pill is laid out with the new name: \(wasWide) then \(nowWide)")
        // A keystroke below the first line: the name is the same.
        let kept = s.book.rowsShown
        s.editor.transact("Type") { $0.update(s.layerNote, as: RowSlip.self) { $0.props.text = MentionText(plain: long + "\nmore below") } }
        for id in [s.note, third, bystander, other] { _ = s.rows(id) }
        expectEqual(s.book.rowsShown - kept, 0, "no holder is let go of")
        // A note that goes: the rows that show it are let go of.
        let before = s.book.rowsShown
        s.editor.transact("Delete") { $0.delete([s.layerNote]) }
        for id in [s.note, third] { _ = s.rows(id) }
        expectEqual(s.book.rowsShown - before, 2)
        expectEqual(try s.pills(s.note, "in").pills.map(\.target), [other])
        expectEqual(try s.row(third, "in").content, .empty("add in"))
    },
    test("a relationship moved, re-aimed or drawn on a far board shows in the rows of its notes") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        // The arrow is drawn on the pocket's board, from the far feature note to the far layer note.
        let far = AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: s.away, to: s.awayLayer))), id = far.id
        var typed = far
        typed[IsAProperty.self] = [TypeLink(s.rel)]
        s.editor.transact(on: BoardID(owner: s.pocket), "Draw") { $0.insert(typed) }
        expect(s.editor.relationships?.relations(of: s.away).map(\.arrow) == [id])
        expect(s.editor.showBoard(BoardID(owner: s.pocket)))
        guard case .related(let pills, 0) = try s.row(s.away, "in").content else { throw Failure("a pill") }
        expectEqual(pills.map(\.target), [s.awayLayer])
        expect(s.editor.showBoard(.root))
    },
])

@MainActor let relationFaceTests = Suite("Clicks on relation rows", [
    test("a click on a live pill goes to its note, and a read-only note goes too") {
        let s = try RelationScene(more: [FreezingPlugin(log: RefusalLog())])
        s.fromEnd()
        s.toEnd()
        s.relate(s.note, s.layerNote)
        s.harness.click(at: try s.point(onPill: 0, of: s.note, "in"))
        s.settle()
        expectEqual(s.editor.selection, s.layerNote)
        // The other end's pill goes back.
        s.harness.click(at: try s.point(onPill: 0, of: s.layerNote, "feature"))
        s.settle()
        expectEqual(s.editor.selection, s.note)
        s.editor.freeze([s.note])
        s.harness.click(at: try s.point(onPill: 0, of: s.note, "in"))
        s.settle()
        expectEqual(s.editor.selection, s.layerNote, "going to a note changes nothing in the locked one")
    },
    test("a click on a dashed pill goes to the pill, never to a note") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        let relay = s.editor.addRelay(standingFor: [s.layerNote], says: "Foundation")
        s.editor.addBond(s.note, relay, of: [s.rel])
        let pill = try require(try s.pills(s.note, "in").pills.first)
        expect(!pill.isLive, "the note is private: the pill may not stand for it")
        s.harness.click(at: try s.point(onPill: 0, of: s.note, "in"))
        s.settle()
        expectEqual(s.editor.selection, relay)
    },
    test("a click on a type's relation row goes to the relationship type, anywhere in the row") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        let row = try s.row(s.feature, "in")
        s.harness.click(at: CGPoint(x: row.nameRect.minX + 4, y: row.rect.midY))
        s.settle()
        expectEqual(s.editor.selection, s.rel)
        s.harness.click(at: CGPoint(x: row.valueRect.maxX - 4, y: row.rect.midY))
        s.settle()
        expectEqual(s.editor.selection, s.rel)
        // The dashed line is no row, and nor are the fields above it.
        s.editor.selection = nil
        let purpose = try s.row(s.feature, "purpose")
        s.harness.click(at: CGPoint(x: row.valueRect.maxX - 4, y: (purpose.rect.maxY + row.rect.minY) / 2))
        s.settle()
        expect(s.editor.selection != s.rel, "the dashed line goes nowhere")
    },
    test("a row that holds a relationship ends in `›` after its pills and its count, and an empty row has none; a click on it opens the row's card (a read-only note's to be read), anywhere else on the value the list") {
        let s = try RelationScene(more: [FreezingPlugin(log: RefusalLog())])
        s.fromEnd()
        s.toEnd()
        expect(s.book.chevronRect(of: try s.row(s.note, "in")) == nil, "an empty row says add and nothing more")
        s.relate(s.note, s.layerNote)
        let row = try s.row(s.note, "in")
        let chevron = try require(s.book.chevronRect(of: row))
        let pill = try require(try s.pills(s.note, "in").pills.first)
        expect(chevron.minX >= row.valueRect.minX + pill.x + pill.width, "after the pill: \(chevron) \(pill.x + pill.width)")
        expect(chevron.maxX <= row.valueRect.maxX + 0.5, "inside the column")
        // With many, after the count; the pills leave it room.
        for index in 0..<30 { s.relate(s.note, s.addLayerNote("Layer \(index)", at: CGPoint(x: 40 + 30 * Double(index), y: 1500))) }
        let crowded = try s.row(s.note, "in")
        guard case .related(let pills, let more) = crowded.content, let last = pills.last else { throw Failure("pills") }
        expect(more > 0)
        let crowdedChevron = try require(s.book.chevronRect(of: crowded))
        expect(crowdedChevron.minX >= crowded.valueRect.minX + last.x + last.width + TypesStyle.pillGap + 1, "after the +N")
        expect(crowdedChevron.maxX <= crowded.valueRect.maxX + 0.5, "the pills left it room")
        // Locked: the card opens to be read, with no session.
        s.editor.freeze([s.note])
        s.harness.click(at: CGPoint(x: crowdedChevron.midX, y: crowded.rect.midY))
        s.settle()
        let open = try require(s.editor.fieldCards?.openTarget)
        expectEqual(open.shape, s.note)
        expectEqual(open.target, .relations(try s.featureRow().key))
        expect(s.editor.fieldCards?.openForm?.isReadOnly == true, "read to be read")
        s.editor.fieldCards?.close()
        // Not locked: the note is the click's, and its editing begins in the row (the card is asked for on its next turn, by the
        // rows view: the shipped list's test holds that).
        s.editor.freeze([s.note], false)
        s.editor.selection = nil
        s.harness.click(at: CGPoint(x: crowdedChevron.midX, y: crowded.rect.midY))
        s.settle()
        expectEqual(s.editor.selection, s.note, "the note is selected")
        expect(s.editor.fieldCards?.openTarget == nil, "and no card yet")
    },
    test("a click on the value of an empty relation row writes nothing: the list it opens is the rows view's, and the note is the click's") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        let before = s.editor.document[s.note]
        let row = try s.row(s.note, "in")
        s.harness.click(at: CGPoint(x: row.valueRect.minX + 6, y: row.rect.midY))
        s.settle()
        expect(s.book.makePicker != nil, "a list can be made for the row")
        expectEqual(s.editor.document[s.note], before)
        expectEqual(s.editor.selection, s.note, "the note is the click's")
    },
])

@MainActor let relationWriteTests = Suite("What a relation row writes", [
    test("a row's presence writes no property of the note: an end drawn, a relationship drawn, deleted and undone leave its record as it was") {
        let s = try RelationScene()
        s.set(s.note, ["purpose": .string("sign in with no password")])
        let before = s.editor.document[s.note], layerBefore = s.editor.document[s.layerNote]
        let steps = s.editor.undoHistory.undoName
        s.fromEnd()
        s.toEnd()
        _ = s.rows(s.note)
        expectEqual(s.editor.document[s.note], before, "the end gave it a row and changed nothing it stores")
        let relation = s.relate(s.note, s.layerNote)
        _ = s.rows(s.note)
        expectEqual(s.editor.document[s.note], before, "a relationship names no value of either note")
        expectEqual(s.editor.document[s.layerNote], layerBefore)
        s.editor.transact("Delete") { $0.delete([relation]) }
        expectEqual(s.editor.document[s.note], before)
        s.editor.undo()
        s.editor.undo()
        s.editor.undo()
        s.editor.undo()
        expectEqual(s.editor.document[s.note], before)
        expectEqual(s.editor.undoHistory.undoName, steps, "the rows made no step of their own")
    },
])
