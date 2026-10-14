import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Foundation
import Geometry
import Mentions
import StickyNotes
import TestKit
import Titles
import Types

// What the rows of relationships cost in a frame (`RelationRowBenchmarks.swift`): a note's relation rows are drawn from
// what is kept of it, a pill straight into the context, the dashed line one stroked path, and zoomed out a name bar and
// nothing that reads a relation. The pills' figure is measured (`relationRowsFrame`); the others are the design's, and held.
// Run them alone with `TEST_FILTER="Relation rows" ./build.sh bench`.

extension Budget {
    /// What 450 pills add to a frame of 150 notes of a Feature type in full at 40%, each holding three relationships (to
    /// three Layer notes), over the same notes and 450 arrows of another relationship type that has no end at Feature, so each
    /// row is the empty `add layer`, an arrow and its chip are in the frame either way, and the pills are what differs: a pill's
    /// one `drawMentionText` into the context, the rows built once and kept.
    /// Measured: 7.23, 7.69 and 6.90 ms in three runs alone (the empty rows' frame 45 ms), 16 us a pill, and the budget about a
    /// third over the median (the thread's CPU, release). A pill is `drawMentionText` into the context, as `linkRowsFrame`
    /// (5 ms, which this replaced, for 450 pills of the same kind) assumed, and its parts cost more than that figure had them: the
    /// name looked up as it is now at each draw (3.5 us, so a rename is never drawn stale), the memo's key (1.4), the capsule's
    /// white fill and hairline (4) and the label as `NSString` draws it (7), which a kept Core Text line does not draw as it does
    /// (a point lower, heavier). The row, its name, its `+N` and `›` come with it.
    static let relationRowsFrame = 10.0
    /// What 450 notes of an end type each with an empty `add layer` row and its dashed line add to a frame in full at
    /// 40%, over the same 450 notes before the end was drawn, which have no such row: the row's name and its words as
    /// kept Core Text lines, and one stroked path each. A proposal.
    static let relationEmptyRowsFrame = 3.0
    /// What 350 notes of an end type, each with one relation row more, add to a frame as skeletons at 20%, over the same
    /// notes with no end drawn: a name's bar a row, no value bar, no relation read. The design's proposal is `typeRowBars`'.
    static let relationSkeletonFrame = Budget.typeRowBars
}

/// A Feature type (one field), a Layer type and a relationship type `in`, off the top of the board, with an end drawn from
/// each type to the relationship type when `ends`; `count` notes of Feature in `columns` columns (340 by 240 apart, 200
/// stored and 320 laid out), each holding a value; three notes of Layer beside the types; and, when `relationships`, an
/// arrow from each Feature note to each Layer note, of the relationship type or plain when `typed` is false.
@MainActor private func relationBoard(notes count: Int, columns: Int, ends: Bool, relationships: Bool = false, typed: Bool = true) -> (document: CanvasDocument, note: ShapeID) {
    func bound(_ id: ShapeID) -> ArrowTerminal {
        .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
    }
    let feature = ShapeID(), layer = ShapeID(), related = ShapeID(), other = ShapeID()
    var shapes: [AnyShapeRecord] = []
    func type(_ id: ShapeID, _ title: String, _ schema: String, at origin: CGPoint) -> AnyShapeRecord {
        var note = ShapeRecord(id: id, StickyNote(frame: CGRect(origin: origin, size: CGSize(width: 200, height: 200)), text: MentionText(plain: title)))
        note[TypeSchemaProperty.self] = SchemaText(schema)
        note[TitleProperty.self] = title
        return AnyShapeRecord(note)
    }
    shapes.append(type(feature, "Feature", FieldFixtures.wide(1).schema, at: CGPoint(x: 0, y: -1_200)))
    shapes.append(type(layer, "Layer", FieldFixtures.wide(3).schema, at: CGPoint(x: 400, y: -1_200)))
    var relationship = type(related, "in", TypeSchemaProperty.starter, at: CGPoint(x: 800, y: -1_200))
    relationship[RelationshipProperty.self] = true
    shapes.append(relationship)
    // A second relationship type with no end drawn at Feature: the arrows that are not `in` hold it, so a relationship's arrow and
    // its chip are in a frame either way and only what the rows show differs.
    var otherType = type(other, "other", TypeSchemaProperty.starter, at: CGPoint(x: 1_200, y: -1_200))
    otherType[RelationshipProperty.self] = true
    shapes.append(otherType)
    if ends {
        shapes.append(AnyShapeRecord(ShapeRecord(id: ShapeID(), Arrow(start: bound(feature), end: bound(related)))))
        shapes.append(AnyShapeRecord(ShapeRecord(id: ShapeID(), Arrow(start: bound(related), end: bound(layer)))))
    }
    var layers: [ShapeID] = [], firstNote = ShapeID()
    for place in 0..<3 {
        var note = ShapeRecord(StickyNote(frame: CGRect(x: 400 * Double(place), y: -600, width: 200, height: 200), text: MentionText(plain: "Layer \(["A", "B", "C"][place])")))
        note[IsAProperty.self] = [TypeLink(layer)]
        layers.append(note.id)
        shapes.append(AnyShapeRecord(note))
    }
    for place in 0..<count {
        let frame = CGRect(x: CGFloat(place % columns) * 340, y: CGFloat(place / columns) * 240, width: 200, height: 200)
        var note = ShapeRecord(StickyNote(frame: frame, text: MentionText(plain: "Sign in")))
        note[IsAProperty.self] = [TypeLink(feature)]
        note[FieldValuesProperty.self] = FieldValues(["f1": "sign in with no password"])
        if place == 0 { firstNote = note.id }
        shapes.append(AnyShapeRecord(note))
        if relationships {
            for target in layers {
                var arrow = AnyShapeRecord(ShapeRecord(id: ShapeID(), Arrow(start: bound(note.id), end: bound(target))))
                arrow[IsAProperty.self] = [TypeLink(typed ? related : other)]
                shapes.append(arrow)
            }
        }
    }
    return (CanvasDocument(shapes: shapes), firstNote)
}

@MainActor let relationRowBenchmarks = Suite("Relation rows benchmarks", [
    test("450 pills in view cost little more in a frame than the same notes with empty relation rows, and 450 empty rows with their dashed line little more than the notes before the end") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        @MainActor func editor(_ board: (document: CanvasDocument, note: ShapeID), size: CGSize, zoom: CGFloat) throws -> CanvasEditor {
            let editor = CanvasEditor(registry: try Registry(plugins: shippedPlugins(pasteboard)), document: board.document, scheduler: ManualScheduler())
            editor.viewportDidResize(to: size)
            editor.camera = Camera(origin: .zero, zoom: zoom)
            return editor
        }
        /// The median frame, the camera nudged between frames, after two to warm what is kept.
        @MainActor func frames(_ editor: CanvasEditor, size: CGSize, zoom: CGFloat) throws -> Double {
            let context = try bitmapContext(size)
            draw(editor, into: context, size: size)
            draw(editor, into: context, size: size)
            var step = 0.0
            return median(runs: 11, prepare: { step = step == 0 ? 1 : 0; editor.camera = Camera(origin: CGPoint(x: step / zoom, y: 0), zoom: zoom) }, onThread: true) {
                draw(editor, into: context, size: size)
            }
        }
        // 450 pills: 150 notes in 15 columns by 10 rows, 5,100 by 2,400 world units, at 40%, each with three relationships.
        let full = CGSize(width: 2_100, height: 1_000)
        let pilledBoard = relationBoard(notes: 150, columns: 15, ends: true, relationships: true)
        let pilled = try editor(pilledBoard, size: full, zoom: 0.4)
        let emptyBoard = relationBoard(notes: 150, columns: 15, ends: true, relationships: true, typed: false)
        let empty = try editor(emptyBoard, size: full, zoom: 0.4)
        let content = try require(try require(pilled.rowBook).rows(of: pilledBoard.note).first(where: { $0.relation != nil })?.content, "the first note has a relation row")
        guard case .related(let pills, 0) = content else {
            expect(false, "the first note's relation row holds its pills: \(content)")
            return
        }
        expectEqual(pills.count, 3)
        expectEqual(try require(empty.rowBook).rows(of: emptyBoard.note).last?.content, .empty("add layer"))
        let withPills = try frames(pilled, size: full, zoom: 0.4), withEmpty = try frames(empty, size: full, zoom: 0.4)
        report(String(format: "150 notes with three pills each (450) in full at 40%%: a frame %5.2f ms, %5.2f more than the same notes with empty relation rows (%5.2f) (budget %.0f more)",
                      withPills, withPills - withEmpty, withEmpty, Budget.relationRowsFrame))
        // 450 empty rows: 450 notes, 30 columns by 15 rows at 40%, with the end drawn and before it.
        let wide = CGSize(width: 4_200, height: 1_500)
        let ended = try editor(relationBoard(notes: 450, columns: 30, ends: true), size: wide, zoom: 0.4)
        let before = try editor(relationBoard(notes: 450, columns: 30, ends: false), size: wide, zoom: 0.4)
        let withRows = try frames(ended, size: wide, zoom: 0.4), without = try frames(before, size: wide, zoom: 0.4)
        report(String(format: "450 notes with an empty `add layer` row and its dashed line in full at 40%%: a frame %5.2f ms, %5.2f more than the same notes before the end (%5.2f) (budget %.0f more)",
                      withRows, withRows - without, without, Budget.relationEmptyRowsFrame))
        if holdsToBudgets {
            expect(withPills - withEmpty < Budget.relationRowsFrame, "450 pills added \(withPills - withEmpty) ms to a frame in full")
            expect(withRows - without < Budget.relationEmptyRowsFrame, "450 empty relation rows added \(withRows - without) ms to a frame in full")
        }
    },
    test("350 notes of an end type as skeletons at 20% cost little more in a frame than the same notes before the end: a relation row is a name's bar and reads no relation") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let far = CGSize(width: 1_800, height: 700)
        @MainActor func frame(ends: Bool) throws -> Double {
            let editor = CanvasEditor(registry: try Registry(plugins: shippedPlugins(pasteboard)),
                                      document: relationBoard(notes: 350, columns: 25, ends: ends).document, scheduler: ManualScheduler())
            editor.viewportDidResize(to: far)
            editor.camera = Camera(origin: .zero, zoom: 0.2)
            expect(editor.drawsSkeletons, "zoomed out, shapes are skeletons")
            let context = try bitmapContext(far)
            draw(editor, into: context, size: far)
            draw(editor, into: context, size: far)
            var step = 0.0
            return median(runs: 11, prepare: { step = step == 0 ? 1 : 0; editor.camera = Camera(origin: CGPoint(x: step / 0.2, y: 0), zoom: 0.2) }, onThread: true) {
                draw(editor, into: context, size: far)
            }
        }
        let withRows = try frame(ends: true), without = try frame(ends: false)
        report(String(format: "350 notes of an end type as skeletons at 20%%: a frame %5.2f ms, %5.2f more than the same notes before the end (%5.2f) (budget %.1f more)",
                      withRows, withRows - without, without, Budget.relationSkeletonFrame))
        if holdsToBudgets { expect(withRows - without < Budget.relationSkeletonFrame, "a relation row's bar added \(withRows - without) ms to a frame of 350 skeletons") }
    },
])
