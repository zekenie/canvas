import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Composition
import CoreGraphics
import Foundation
import Locking
import StickyNotes
import TestKit
import Titles
import Types

// What a typed value costs (`FieldBenchmarks.swift`): a keystroke in a field is one commit on one shape, so
// it costs what a commit costs, never the board. The generated board's notes, one of them the type (the
// Order of `FieldFixtures`), a fifth of the plain notes its instances (some 1,000 among 10,000 shapes).

extension Budget {
    /// One keystroke's write through the field writer (`editor.fieldWriter`, `setTyped`) into a field of one
    /// Order among 10,000 shapes, the median of 100 in one field (the thread's CPU, release): the step named once,
    /// `FieldValues.setting` on one record, the commit every service hears for one changed shape: some 0.35 ms
    /// (0.338, 0.346 and 0.353 in three runs alone, load average 12), about three times that.
    static let fieldKeystroke = 1.0
}

@MainActor let fieldBenchmarks = Suite("Field benchmarks", [
    test("a keystroke in a field of one Order among 10,000 shapes is one commit on one shape") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for size in sizes {
            var shapes = generatedBoard(shapes: size).shapes
            var type: ShapeID?, instances: [ShapeID] = []
            var noteIndex = 0
            for index in shapes.indices where shapes[index].kind == StickyNote.kind && shapes[index][TypeSchemaProperty.self] == nil && shapes[index][LockedProperty.self] != true {
                defer { noteIndex += 1 }
                if type == nil {
                    shapes[index][TypeSchemaProperty.self] = SchemaText(FieldFixtures.order.schema)
                    shapes[index][TitleProperty.self] = FieldFixtures.order.title
                    type = shapes[index].id
                } else if noteIndex % 5 == 0, let type {
                    shapes[index][IsAProperty.self] = [TypeLink(type)]
                    instances.append(shapes[index].id)
                }
            }
            let editor = CanvasEditor(registry: try Registry(plugins: shippedPlugins(pasteboard)), document: CanvasDocument(shapes: shapes), scheduler: ManualScheduler())
            let writer = try require(editor.fieldWriter)
            let order = try require(instances.last)
            let note = FieldPath(field: "giftNote")
            var n = 0
            let keystroke = median(runs: 100, onThread: true) {
                n += 1
                expect(writer.setTyped(String(repeating: "a", count: n), as: .text, at: note, of: order))
            }
            expectEqual(writer.values(of: order).value(at: note), .string(String(repeating: "a", count: n)))
            report(String(format: "%6d shapes, %d orders, a keystroke in a field: %6.3f ms (budget %.0f)", size, instances.count, keystroke, Budget.fieldKeystroke))
            if holdsToBudgets { expect(keystroke < Budget.fieldKeystroke, "a keystroke in a field over \(size) shapes took \(keystroke) ms") }
        }
    },
])
