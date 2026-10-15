import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Geometry
import Mentions
import Selection
import StickyNotes
import TestKit
import Titles
import Types

// What the offer to relate two types costs (`RelateOfferBenchmarks.swift`): its face is asked on every pointer move over a
// shape, so over a type's note with 20 pills in a file of 200 relationship types it must cost next to nothing off a pill and a
// little on one. The figure is what a move over the type's note costs over the same move over a note that is no type, with
// the same words and the same file (the whole move: the offer's face is not alone in it). The figures are the design's
// proposals; none has been measured on a quiet machine (`./build.sh bench` was not run for them). Run alone with
// `TEST_FILTER="Relate offer benchmarks" ./build.sh bench` (release, the thread's CPU).

extension Budget {
    /// A pointer move over a type's note with 20 pills and 200 relationship types in the file, over the same move over a note
    /// that is no type: off a pill, and on one that names a type it is not yet related to (the whole offer is found: the
    /// schema's bytes scanned, the file's relationship types asked). A proposal: 0.05 ms and 0.3 ms (the thread's CPU, release).
    static let relateOfferMove = (off: 0.05, on: 0.3)
}

/// A Feature type (or, `asType` false, a note that is not one) whose words mention 20 Layer types, in a file of 200
/// relationship types each with an end drawn between two other types.
@MainActor private func offerBoard(asType: Bool) -> (document: CanvasDocument, feature: ShapeID) {
    func bound(_ id: ShapeID) -> ArrowTerminal {
        .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
    }
    func type(_ title: String, at origin: CGPoint, marked: Bool = false) -> AnyShapeRecord {
        var note = ShapeRecord(StickyNote(frame: CGRect(origin: origin, size: CGSize(width: 200, height: 200)), text: MentionText(plain: title)))
        note[TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter)
        note[TitleProperty.self] = title
        if marked { note[RelationshipProperty.self] = true }
        return AnyShapeRecord(note)
    }
    var shapes: [AnyShapeRecord] = []
    let layers = (0..<20).map { type("Layer \($0)", at: CGPoint(x: 2_000 + CGFloat($0 % 10) * 240, y: CGFloat($0 / 10) * 240)) }
    shapes += layers
    // 200 relationship types, each between two other types, so asking a pair walks every one.
    let aux = (0...200).map { type("Aux \($0)", at: CGPoint(x: CGFloat($0 % 40) * 240, y: 3_000 + CGFloat($0 / 40) * 480)) }
    shapes += aux
    for place in 0..<200 {
        let relation = type("Relation \(place)", at: CGPoint(x: CGFloat(place % 40) * 240, y: 3_240 + CGFloat(place / 40) * 480), marked: true)
        shapes.append(relation)
        shapes.append(AnyShapeRecord(ShapeRecord(id: ShapeID(), Arrow(start: bound(aux[place].id), end: bound(relation.id)))))
        shapes.append(AnyShapeRecord(ShapeRecord(id: ShapeID(), Arrow(start: bound(relation.id), end: bound(aux[place + 1].id)))))
    }
    var runs: [MentionRun] = [.text("A feature that is in")]
    for (place, layer) in layers.enumerated() { runs += [.text(" a "), .mention(layer.id, label: "Layer \(place)"), .text(place % 5 == 4 ? ", and" : ",")] }
    var note = ShapeRecord(StickyNote(frame: CGRect(x: 0, y: 0, width: 640, height: 200), text: MentionText(runs)))
    if asType {
        note[TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter)
        note[TitleProperty.self] = "Feature"
    }
    shapes.append(AnyShapeRecord(note))
    return (CanvasDocument(shapes: shapes), note.id)
}

@MainActor private func offerMoves(asType: Bool, _ pasteboard: NSPasteboard) throws -> (off: Double, on: Double) {
    let board = offerBoard(asType: asType)
    let registry = try Registry(plugins: shippedPlugins(pasteboard))
    let h = EditorHarness { CanvasEditor(registry: registry, document: board.document, scheduler: $0) }
    h.editor.viewportDidResize(to: CGSize(width: 1_400, height: 900))
    let box = try require(h.editor.document[board.feature]?.box)
    let pills = h.editor.mentionPills(of: board.feature)
    expectEqual(pills.count, 20, "the words hold 20 pills")
    let pill = try require(pills[9].frame)
    let on = h.view(CGPoint(x: pill.midX, y: pill.midY)), off = h.view(CGPoint(x: box.minX + 3, y: box.minY + 3))
    h.move(to: off)
    // Off a pill: moved there from the pill; on one: moved there from off it. Every move changes the pointer's place.
    let away = median(runs: 21, prepare: { h.move(to: on) }, onThread: true) { h.move(to: off) }
    let onto = median(runs: 21, prepare: { h.move(to: off) }, onThread: true) { h.move(to: on) }
    return (away, onto)
}

@MainActor let relateOfferBenchmarks = Suite("Relate offer benchmarks", [
    test("a pointer move over a type's note with 20 pills, in a file of 200 relationship types, costs next to nothing off a pill and a little on one, over the same move over a note that is no type") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let plain = try offerMoves(asType: false, pasteboard)
        let typed = try offerMoves(asType: true, pasteboard)
        let off = typed.off - plain.off, on = typed.on - plain.on
        report(String(format: "a move over a type's note with 20 pills: off a pill %6.3f ms over a note that is no type (budget %.2f), on one %6.3f ms (budget %.1f); the moves alone %.3f and %.3f",
                      off, Budget.relateOfferMove.off, on, Budget.relateOfferMove.on, typed.off, typed.on))
        if holdsToBudgets {
            expect(off < Budget.relateOfferMove.off, "a move off a pill added \(off) ms")
            expect(on < Budget.relateOfferMove.on, "a move onto a pill added \(on) ms")
        }
    },
])
