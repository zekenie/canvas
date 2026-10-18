@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Geometry
import Mentions
import Selection
import TestKit
import Titles
import Topology
import Types

// What the row book keeps of the rows it has shown, and what it lets go of: the names pills were laid out with, the pills a
// row reads through, the file put in place, and undo and redo of what changes the rows. Over `RelationScene`
// (RelationRowTests.swift).

private struct Failure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

@MainActor let relationRowKeptTests = Suite("Relation rows kept", [
    test("a file put in place drops the rows kept, the names their pills were laid out with, and the pills they read through") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        s.relate(s.note, s.layerNote)
        let relay = s.editor.addRelay(standingFor: [s.away], says: "Away")
        s.editor.addBond(relay, s.layerNote, of: [s.rel])
        _ = s.rows(s.note)
        _ = s.rows(s.layerNote)
        expect(!s.book.pillLabels.isEmpty && !s.book.holders.isEmpty && !s.book.viaHolders.isEmpty, "something is kept before")
        let other = ShapeID(), ann = ShapeID()
        s.editor.replaceFile(with: CanvasFile(root: CanvasDocument(shapes: [slipTypeRecord(featureRowsSchema, words: "x", title: "Feature", id: other), slipRecord("Ann", of: [other], id: ann)])), showing: .root)
        expectEqual(s.names(ann), ["purpose"], "no ends in the file put in place")
        expect(s.book.holders.isEmpty && s.book.pillLabels.isEmpty && s.book.viaHolders.isEmpty, "and nothing is kept after")
    },
    test("rows beyond the capacity let go of everything kept, and the rows are still right") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        let count = 2_100
        var records: [AnyShapeRecord] = []
        for index in 0..<count {
            let note = slipRecord("F\(index)", of: [s.feature], at: CGPoint(x: 40 + Double(index % 50) * 10, y: 3000 + Double(index / 50) * 10))
            var arrow = ShapeRecord(id: ShapeID(), Bond(from: note.id, to: s.layerNote))
            arrow[IsAProperty.self] = [TypeLink(s.rel)]
            records.append(note)
            records.append(AnyShapeRecord(arrow))
        }
        s.editor.transact("Many") { transaction in for record in records { transaction.insert(record) } }
        for record in records where record.kind == records[0].kind { _ = s.rows(record.id) }
        expect((s.book.holders[s.layerNote]?.count ?? 0) <= 2_048, "the kept names were wiped when the rows were: \(s.book.holders[s.layerNote]?.count ?? 0)")
        guard case .related(let pills, _) = try s.row(records[0].id, "in").content else { throw Failure("a pill") }
        expectEqual(pills.map(\.target), [s.layerNote])
        expectEqual(s.book.pillLabels[s.layerNote], "Foundation")
    },
    test("a rename of a type with no ends changes nothing: no layout, no row let go of") {
        let s = try RelationScene()
        _ = s.rows(s.note)
        let layout = s.editor.layoutRevision, height = try s.height(s.note)
        s.editor.transact("Rename") { $0.update(s.feature) { $0[TitleProperty.self] = "Story" } }
        expectEqual(s.editor.layoutRevision, layout)
        expectEqual(try s.height(s.note), height)
        expect(s.heard.changes.allSatisfy { !$0.rows && $0.layout.isEmpty }, "nothing announced of rows: \(s.heard.changes)")
    },
    test("a file with no relationship type reads no relation state: no template, no row and no end") {
        let idle = try rowEditor()
        let type = idle.addSlipType(featureRowsSchema, title: "Feature")
        let instance = idle.addSlip("A", of: [type])
        let book = try require(idle.rowBook)
        let index = try require(idle.relationships)
        let revision = index.revision
        expect(!index.isActive)
        expectEqual(book.rows(of: instance).map(\.name), ["purpose"])
        idle.transact("Rename") { $0.update(type) { $0[TitleProperty.self] = "Story" } }
        expectEqual(index.revision, revision)
        expect(index.rows(for: [type], isType: false).isEmpty && index.relations(of: instance).isEmpty)
    },
    test("a file put in place announces everything, and its notes are the height a fresh read gives") {
        let s = try RelationScene()
        let end = s.fromEnd()
        s.toEnd()
        let before = try s.height(s.note)
        expect(before > (try s.stored(s.note)))
        // The same shapes without their ends.
        let bonds = try require(s.editor.document[end]).kind
        let kept = s.editor.file.root.shapes.filter { $0.kind != bonds }
        s.editor.replaceFile(with: CanvasFile(root: CanvasDocument(shapes: kept), children: s.editor.file.children), showing: .root)
        expectEqual(s.heard.last?.everything, true)
        let fresh = try bondEditor(file: s.editor.file)
        expectEqual(s.editor.frame(inFile: s.note), fresh.frame(inFile: s.note), "what a fresh read gives")
        expectEqual(s.names(s.note), ["purpose"])
        expectEqual(try s.height(s.note), try s.stored(s.note) + TypesStyle.rowsLead + TypesStyle.rowHeight, "no end is drawn, so no row")
    },
    test("undo and redo of an end drawn, an end deleted, a mark flip and a lineage edit give the rows and the frames of the step they undo") {
        let s = try RelationScene()
        let task = s.editor.addSlipType(featureRowsSchema, words: "", title: "Task", at: CGPoint(x: 40, y: 900))
        let taskNote = s.editor.addSlip("A task", of: [task], at: CGPoint(x: 700, y: 900))
        let ids = [s.note, s.layerNote, s.away, s.awayLayer, s.feature, s.layer, task, taskNote]
        @MainActor func state() throws -> ([[String]], [CGFloat]) { (ids.map { s.names($0) }, try ids.map { try s.height($0) }) }
        @MainActor func agrees(_ when: String) throws {
            let fresh = try bondEditor(file: s.editor.file)
            _ = fresh.showBoard(BoardID(owner: s.pocket))
            _ = fresh.showBoard(.root)
            for id in ids {
                expectEqual(s.names(id), try require(fresh.rowBook).rows(of: id).map(\.name), "\(when): rows of a note")
                expectEqual(s.editor.frame(inFile: id), fresh.frame(inFile: id), "\(when): frame")
            }
        }
        var end: ShapeID?
        let steps: [(String, () -> Void)] = [
            ("an end drawn", { end = s.fromEnd() }),
            ("the other end drawn", { s.toEnd() }),
            ("a lineage edit", { s.editor.addTypeLink(s.feature, to: task) }),
            ("a mark flip", { s.editor.transact("Unmark") { $0.update(s.rel) { $0[RelationshipProperty.self] = nil } } }),
            ("the mark given back", { s.editor.transact("Mark") { $0.update(s.rel) { $0[RelationshipProperty.self] = true } } }),
            ("an end deleted", { if let end { s.editor.transact("Delete") { $0.delete([end]) } } }),
        ]
        for (name, step) in steps {
            let before = try state()
            step()
            let after = try state()
            try agrees(name)
            s.editor.undo()
            expect(try state() == before, "\(name), undone")
            try agrees("\(name), undone")
            s.editor.redo()
            expect(try state() == after, "\(name), redone")
            try agrees("\(name), redone")
        }
    },
    test("a pill is drawn straight, and drawn again with the new name after the note it stands for is renamed") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        s.relate(s.note, s.layerNote)
        s.editor.viewportDidResize(to: CGSize(width: 1200, height: 900))
        #if DEBUG
        let before = MentionDrawingCounts.pillsDrawnStraight
        let first = renderBitmap(s.editor, size: CGSize(width: 1200, height: 900))
        let drawn = MentionDrawingCounts.pillsDrawnStraight - before
        expect(drawn >= 2, "a pill in each of the two rows: \(drawn)")
        s.editor.transact("Rename") { $0.update(s.layerNote, as: RowSlip.self) { $0.props.text = MentionText(plain: "A much longer name for the foundation") } }
        let again = MentionDrawingCounts.pillsDrawnStraight
        let second = renderBitmap(s.editor, size: CGSize(width: 1200, height: 900))
        expect(MentionDrawingCounts.pillsDrawnStraight - again >= 2, "drawn again")
        expect(largestDifference(first, second, in: CGRect(x: 0, y: 0, width: 1200, height: 900)) > 0, "and not as it was")
        #endif
    },
])

@MainActor let relationPillFaceTests = Suite("Pills and rows as faces", [
    test("the pointer over a live pill hovers its note, over a dashed pill the pill it goes to") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        s.relate(s.note, s.layerNote)
        let relay = s.editor.addRelay(standingFor: [s.awayLayer], says: "Down", at: CGPoint(x: 400, y: 1700))
        let third = s.editor.addSlip("Third", of: [s.feature], at: CGPoint(x: 1600, y: 500))
        s.editor.addBond(third, relay, of: [s.rel])
        expect(!(try s.pills(third, "in").pills.first?.isLive ?? true), "the pill may not stand for it")
        s.harness.move(to: try s.point(onPill: 0, of: s.note, "in"))
        expectEqual(s.editor.hovered, s.layerNote)
        s.harness.move(to: try s.point(onPill: 0, of: third, "in"))
        expectEqual(s.editor.hovered, relay)
    },
    test("zoomed out, where a note is a skeleton, a click on its pill is the note's") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        s.relate(s.note, s.layerNote)
        let point = try s.point(onPill: 0, of: s.note, "in")
        s.editor.camera.setZoom(0.2, around: .zero)
        expect(s.editor.drawsSkeletons)
        s.harness.click(at: s.harness.view(point))
        s.settle()
        expectEqual(s.editor.selection, s.note)
    },
    test("a click on an empty relation row of a read-only note shakes it and writes nothing") {
        let log = RefusalLog()
        let s = try RelationScene(more: [FreezingPlugin(log: log)])
        s.fromEnd()
        s.toEnd()
        s.editor.freeze([s.note])
        let before = s.editor.document[s.note]
        let row = try s.row(s.note, "in")
        s.harness.click(at: CGPoint(x: row.valueRect.minX + 6, y: row.rect.midY))
        s.settle()
        expectEqual(log.refusals, [[s.note]])
        expectEqual(s.editor.document[s.note], before)
    },
    test("a pill for a note on a board the app can't show is dashed, unavailable, and goes to the pill") {
        let orphan = ShapeID(), hidden = ShapeID(), feature = ShapeID(), layer = ShapeID(), rel = ShapeID(), note = ShapeID()
        var related = slipTypeRecord(TypeSchemaProperty.starter, title: "in", at: CGPoint(x: 240, y: 40), id: rel)
        related[RelationshipProperty.self] = true
        var open = slipRecord("Down", of: [layer], at: .zero, id: hidden)
        open.meta[Open.self] = true
        let file = CanvasFile(root: CanvasDocument(shapes: [
            slipTypeRecord(featureRowsSchema, words: "A feature", title: "Feature", at: CGPoint(x: 40, y: 40), id: feature),
            slipTypeRecord(layerRowsSchema, words: "A layer", title: "Layer", at: CGPoint(x: 440, y: 40), id: layer),
            related,
            slipRecord("Sign in", of: [feature], at: CGPoint(x: 40, y: 500), id: note),
        ]), children: [orphan: CanvasDocument(shapes: [open])])
        let harness = try EditorHarness { scheduler in try rowEditor(scheduler: scheduler, file: file, more: [BondsPlugin(), RelaysPlugin(), PocketsPlugin()]) }
        let editor = harness.editor
        editor.addBond(feature, rel)
        editor.addBond(rel, layer)
        let relay = editor.addRelay(standingFor: [hidden], says: "Down")
        editor.addBond(note, relay, of: [rel])
        guard case .related(let pills, _)? = try require(editor.rowBook).rows(of: note).first(where: { $0.name == "in" })?.content, let pill = pills.first else {
            throw Failure("a pill")
        }
        expectEqual(pill.state, .unavailable(called: "Down"))
        expect(!pill.isLive && pill.target == nil)
        expectEqual(pill.label, "Down")
        expectEqual(pill.destination, relay)
    },
])
