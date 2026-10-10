import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Composition
import CoreGraphics
import Foundation
import LanguageModels
import Selection
import StickyNotes
import TestKit
import Titles
import Types

// What a shape is (`TypeBenchmarks.swift`): the index of the file's types and instances built as it
// opens, a type renamed with a thousand instances among the shapes, and a drag of them, which reads
// nothing. The generated board's notes, a fiftieth of them types and a sixth of the others instances (a thousand
// among ten thousand shapes).

extension Budget {
    /// Types' service (the index of types and instances, and the sync beside it), made as a file of
    /// 10,000 shapes opens, with a hundred and twenty types and a thousand instances: every record's kind looked
    /// at once, the few that can be either read: some 5 ms (the sync beside it costs next to nothing).
    static let typeIndex10k = 10.0
    /// What renaming a type that 1,000 notes are instances of adds to the commit, over renaming one
    /// that none are: the instances' chips made again (a set of ids forgotten, one redraw).
    static let renameType = 1.0
}

/// The generated board's notes made types (every fiftieth), and instances (every sixth that isn't):
/// the document, the types, the instances of the first type, and the first type.
@MainActor private func typedBoard(shapes size: Int) -> (document: CanvasDocument, types: [ShapeID], instances: [ShapeID], first: ShapeID) {
    let base = generatedBoard(shapes: size)
    var types: [ShapeID] = [], instances: [ShapeID] = []
    var noteIndex = 0
    var shapes = base.shapes
    for index in shapes.indices where shapes[index].kind == StickyNote.kind {
        defer { noteIndex += 1 }
        if noteIndex % 50 == 0 {
            shapes[index][TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter)
            shapes[index][TitleProperty.self] = "Type \(types.count)"
            types.append(shapes[index].id)
        }
    }
    noteIndex = 0
    for index in shapes.indices where shapes[index].kind == StickyNote.kind && shapes[index][TypeSchemaProperty.self] == nil {
        defer { noteIndex += 1 }
        if noteIndex % 6 == 0, let first = types.first {
            // Every instance is an instance of the first type, and of another but the last, which none is.
            shapes[index][IsAProperty.self] = [TypeLink(first), TypeLink(types[1 + noteIndex % (types.count - 2)])]
            instances.append(shapes[index].id)
        }
    }
    return (CanvasDocument(shapes: shapes), types, instances, types[0])
}

@MainActor let typeBenchmarks = Suite("Type benchmarks", [
    test("Types' service, made as a file of types and instances opens, within the index's budget") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for size in sizes {
            let (document, types, instances, first) = typedBoard(shapes: size)
            let watch = ThreadStopwatch()
            var plugins = shippedPlugins(pasteboard)
            let at = try require(plugins.firstIndex { $0.id == .types })
            plugins.insert(Contributor(id: "bench-stopwatch-end") { r in r.service { _ in ThreadStopwatchEnd(watch) } }, at: at + 1)
            plugins.insert(Contributor(id: "bench-stopwatch-start") { r in r.service { _ in ThreadStopwatchStart(watch) } }, at: at)
            let registry = try Registry(plugins: plugins)
            var runs: [Double] = []
            for _ in 0..<5 {
                let editor = CanvasEditor(registry: registry, document: document, scheduler: ManualScheduler())
                runs.append(watch.milliseconds)
                let index = try require(editor.types)
                expect(index.types.isSuperset(of: types), "the board's own types too")
                expectEqual(index.instances(of: first).count, instances.count)
            }
            let opened = middle(runs)
            report(String(format: "%6d shapes, %d types and %d instances, Types' service as the file opens: %6.2f ms (budget %.0f)",
                          size, types.count, instances.count, opened, Budget.typeIndex10k))
            if holdsToBudgets, size >= 10_000 {
                expect(opened < Budget.typeIndex10k, "Types' service for \(size) shapes took \(opened) ms")
            }
        }
    },

    test("renaming a type with 1,000 instances costs little more than renaming one with none; a drag of the instances reads no record") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for size in sizes {
            let (document, types, instances, first) = typedBoard(shapes: size)
            let editor = CanvasEditor(registry: try Registry(plugins: shippedPlugins(pasteboard)), document: document, scheduler: ManualScheduler())
            let index = try require(editor.types)
            let alone = try require(types.last { index.instances(of: $0).isEmpty })
            var n = 0
            @MainActor func rename(_ id: ShapeID) {
                n += 1
                editor.transact { $0.update(id) { $0[TitleProperty.self] = "Renamed \(n)" } }
            }
            let withInstances = median(runs: 21, onThread: true) { rename(first) }
            let withNone = median(runs: 21, onThread: true) { rename(alone) }
            expectEqual(index.name(of: TypeLink(first)), .live("Renamed \(n - 21)"))
            let dragged = Set(instances)
            #if DEBUG
            let reads = index.recordsRead
            #endif
            let drag = median(runs: 21, onThread: true) { editor.transact("Move") { $0.translate(dragged, by: CGPoint(x: 1, y: 1)) } }
            #if DEBUG
            expectEqual(index.recordsRead, reads, "a drag reads no record")
            #endif
            report(String(format: "%6d shapes, renaming a type with %d instances: the commit %6.3f ms, %6.3f for one with none (budget: %.0f more); a drag of the instances' commit %6.3f",
                          size, instances.count, withInstances, withNone, Budget.renameType, drag))
            if holdsToBudgets {
                expect(withInstances - withNone < Budget.renameType, "renaming a type with \(instances.count) instances over \(size) shapes took \(withInstances) ms, against \(withNone)")
            }
        }
    },
])
