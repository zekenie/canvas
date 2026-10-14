import Adornments
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

// What the data of a relationship costs where it is read and written (`RelationCardBenchmarks.swift`): the chips of 450 arrows in
// a frame, each saying how many fields its relationship type gives the arrow (the values are shown nowhere on the board), a keystroke
// in an arrow's card (the commit and the chip made again), and a keystroke in one relationship's cell at a hub of 1,000
// relationships. The figures are the design's. Run them alone with `TEST_FILTER="Relationship data benchmarks" ./build.sh bench`
// (release, the thread's CPU).

extension Budget {
    /// What 450 arrows that each hold a relationship add to a frame in full at 100% over the same arrows of a relationship type
    /// with no fields: each chip's number, a kept face (the thread's CPU, release).
    static let relationshipChipsFrame = 3.0
    /// A keystroke in an arrow's card: the field's commit on one of 450 arrows of a relationship type with fields, and its chip
    /// made again. A proposal: 1 ms (the thread's CPU, release).
    static let arrowCardKeystroke = 1.0
    /// A keystroke in one relationship's cell at a hub of 1,000 relationships: the commit of the arrow's field every service
    /// hears, which stamps the arrow alone and rechecks no end. A proposal: 1 ms (the thread's CPU, release). The open card's
    /// own reload (1,000 lines made again) is reported beside it and held to nothing.
    static let relationCardKeystroke = 1.0
}

/// The board of these benchmarks: a relationship type `in` that holds four fields, one with none (`plain`: a relationship's arrow
/// with free ends has an issue to ring whichever type it is of, so the baseline has the rings too), and the notes and arrows the case needs.
@MainActor private struct DataBoard {
    var shapes: [AnyShapeRecord] = []
    let feature = ShapeID(), layer = ShapeID(), related = ShapeID(), plain = ShapeID()

    init() {
        func type(_ id: ShapeID, _ title: String, _ schema: String, at origin: CGPoint) -> AnyShapeRecord {
            var note = ShapeRecord(id: id, StickyNote(frame: CGRect(origin: origin, size: CGSize(width: 200, height: 200)), text: MentionText(plain: title)))
            note[TypeSchemaProperty.self] = SchemaText(schema)
            note[TitleProperty.self] = title
            return AnyShapeRecord(note)
        }
        let fields = #"{"type": "object", "properties": {"role": {"type": "string"}, "since": {"type": "string"}, "until": {"type": "string"}, "hours": {"type": "number"}}}"#
        shapes.append(type(feature, "Feature", FieldFixtures.wide(1).schema, at: CGPoint(x: 0, y: -1_200)))
        shapes.append(type(layer, "Layer", FieldFixtures.wide(3).schema, at: CGPoint(x: 400, y: -1_200)))
        var relationship = type(related, "in", fields, at: CGPoint(x: 800, y: -1_200))
        relationship[RelationshipProperty.self] = true
        shapes.append(relationship)
        var bare = type(plain, "Plain", TypeSchemaProperty.starter, at: CGPoint(x: 1_200, y: -1_200))
        bare[RelationshipProperty.self] = true
        shapes.append(bare)
        shapes.append(AnyShapeRecord(ShapeRecord(id: ShapeID(), Arrow(start: Self.bound(feature), end: Self.bound(related)))))
        shapes.append(AnyShapeRecord(ShapeRecord(id: ShapeID(), Arrow(start: Self.bound(related), end: Self.bound(layer)))))
    }

    static func bound(_ id: ShapeID) -> ArrowTerminal {
        .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
    }
}

@MainActor let relationCardBenchmarks = Suite("Relationship data benchmarks", [
    test("450 arrows that each hold a relationship, their chips saying how many fields it has, cost little more in a frame than the same arrows of a type with no fields; a keystroke in an arrow's card is 1 ms") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        // 450 free arrows, 150 long, 30 columns by 15 rows at 160 by 60 apart: all in a view of 4,800 by 900 at 100%.
        @MainActor func board(typed type: KeyPath<DataBoard, ShapeID>, values: Bool) -> (document: CanvasDocument, arrows: [ShapeID]) {
            var made = DataBoard()
            var arrows: [ShapeID] = []
            for place in 0..<450 {
                let from = CGPoint(x: CGFloat(place % 30) * 160 + 5, y: CGFloat(place / 30) * 60 + 20)
                var arrow = AnyShapeRecord(ShapeRecord(id: ShapeID(), Arrow(start: .free(from), end: .free(CGPoint(x: from.x + 150, y: from.y)))))
                arrow[IsAProperty.self] = [TypeLink(made[keyPath: type])]
                if values { arrow[FieldValuesProperty.self] = FieldValues(["role": "engineer", "since": "2021", "until": "2027", "hours": 32]) }
                arrows.append(arrow.id)
                made.shapes.append(arrow)
            }
            return (CanvasDocument(shapes: made.shapes), arrows)
        }
        let size = CGSize(width: 4_800, height: 900)
        @MainActor func frame(_ board: (document: CanvasDocument, arrows: [ShapeID])) throws -> (ms: Double, counted: Int, editor: CanvasEditor) {
            let editor = CanvasEditor(registry: try Registry(plugins: shippedPlugins(pasteboard)), document: board.document, scheduler: ManualScheduler())
            editor.viewportDidResize(to: size)
            editor.camera = Camera(origin: .zero, zoom: 1)
            let context = try bitmapContext(size)
            draw(editor, into: context, size: size)
            draw(editor, into: context, size: size)
            let counted = board.arrows.filter { editor.adornmentFrames(of: $0).contains { $0.adornment == .of(TypeChips.self) && $0.label.count == 4 } }.count
            var step = 0.0
            let ms = median(runs: 11, prepare: { step = step == 0 ? 1 : 0; editor.camera = Camera(origin: CGPoint(x: step, y: 0), zoom: 1) }, onThread: true) {
                draw(editor, into: context, size: size)
            }
            return (ms, counted, editor)
        }
        let with = try frame(board(typed: \.related, values: true)), without = try frame(board(typed: \.plain, values: false))
        expectEqual(with.counted, 450, "each arrow's chip says its four fields")
        expectEqual(without.counted, 0, "a type with no fields has no number")
        report(String(format: "450 relationships whose chips say how many fields in full at 100%%: a frame %5.2f ms, %5.2f more than the same arrows of a type with no fields (%5.2f) (budget %.0f more)",
                      with.ms, with.ms - without.ms, without.ms, Budget.relationshipChipsFrame))
        // A keystroke in an arrow's card: the field's commit on one of the 450 and its chip made again.
        let editor = with.editor
        let arrows = Array(editor.document.shapes.filter { $0[IsAProperty.self] != nil && $0.typed(as: Arrow.self) != nil }.map(\.id))
        let target = arrows[200]
        var typed = false
        let keystroke = median(runs: 101, prepare: {}, onThread: true) {
            typed.toggle()
            editor.fieldWriter?.setTyped(typed ? "engineer lead" : "engineer", as: .text, at: FieldPath(field: "role"), of: target)
            _ = editor.adornmentFrames(of: target)
        }
        report(String(format: "a keystroke in an arrow's card, the commit and the chip made again, among 450 relationships: %5.3f ms (budget %.1f)", keystroke, Budget.arrowCardKeystroke))
        if holdsToBudgets {
            expect(with.ms - without.ms < Budget.relationshipChipsFrame, "450 relationships' chips added \(with.ms - without.ms) ms to a frame")
            expect(keystroke < Budget.arrowCardKeystroke, "a keystroke in an arrow's card took \(keystroke) ms")
        }
    },
    test("a keystroke in one relationship's cell at a hub of 1,000 relationships is 1 ms: the arrow's own stamp, no end rechecked") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var made = DataBoard()
        let hub = ShapeID()
        var note = ShapeRecord(id: hub, StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: MentionText(plain: "Hub")))
        note[IsAProperty.self] = [TypeLink(made.feature)]
        made.shapes.append(AnyShapeRecord(note))
        var arrows: [ShapeID] = []
        for place in 0..<1_000 {
            var layer = ShapeRecord(StickyNote(frame: CGRect(x: 400 + CGFloat(place % 50) * 240, y: CGFloat(place / 50) * 240, width: 200, height: 200), text: MentionText(plain: "Layer \(place)")))
            layer[IsAProperty.self] = [TypeLink(made.layer)]
            made.shapes.append(AnyShapeRecord(layer))
            var arrow = AnyShapeRecord(ShapeRecord(id: ShapeID(), Arrow(start: DataBoard.bound(hub), end: DataBoard.bound(layer.id))))
            arrow[IsAProperty.self] = [TypeLink(made.related)]
            arrows.append(arrow.id)
            made.shapes.append(arrow)
        }
        let editor = CanvasEditor(registry: try Registry(plugins: shippedPlugins(pasteboard)), document: CanvasDocument(shapes: made.shapes), scheduler: ManualScheduler())
        let target = arrows[500]
        expectEqual(editor.relationships?.relations(of: hub).count, 1_000, "the hub holds its thousand relationships")
        var typed = false
        let keystroke = median(runs: 101, prepare: {}, onThread: true) {
            typed.toggle()
            editor.fieldWriter?.setTyped(typed ? "engineer lead" : "engineer", as: .text, at: FieldPath(field: "role"), of: target)
        }
        report(String(format: "a keystroke in one relationship's cell at a hub of 1,000 relationships, the commit: %5.3f ms (budget %.1f)", keystroke, Budget.relationCardKeystroke))
        if holdsToBudgets { expect(keystroke < Budget.relationCardKeystroke, "a keystroke at a hub took \(keystroke) ms") }
    },
])
