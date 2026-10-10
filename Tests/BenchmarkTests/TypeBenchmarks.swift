import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Composition
import CoreGraphics
import Foundation
import Geometry
import LanguageModels
import Mentions
import Selection
import SlashCommands
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
    /// What a frame of 1,000 instances in view at 40%, with their chips, costs after a drag of all of them over the
    /// same frame still: the chips are laid out where the shapes are, never made again for a move (the thread's CPU;
    /// release, 0.5 ms more, against 6.7 when a move made each shape's chips again).
    static let typesDragFrame = 3.0
    /// Opening `/is-a`'s list on a plain note of a 10,000-shape file with 140 types (the thread's CPU, release): the
    /// types the note may be, asked of the index once and sorted by name, then kept while the list is open: some 3.5 ms
    /// (3.1, 3.5, 3.6 in three runs alone, load average 6), about three times that.
    static let isAListOpen = 10.0
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

    test("opening the /is-a list over 10,000 notes costs what the types are: a plain note is passed over by one lookup, and no keystroke asks again") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for size in sizes {
            let (document, types, _, _) = typedBoard(shapes: size)
            let editor = CanvasEditor(registry: try Registry(plugins: shippedPlugins(pasteboard)), document: document, scheduler: ManualScheduler())
            let index = try require(editor.types)
            let plain = document.shapes.first { (record: AnyShapeRecord) -> Bool in
                record.kind == StickyNote.kind && record[TypeSchemaProperty.self] == nil && record[IsAProperty.self] == nil
            }
            let owner = try require(plain).id
            let command = try require(editor.slashCommands?.command(named: "is-a", for: owner))
            let open = { _ = command.choices() }
            let first = median(runs: 1, onThread: true, open)
            let opening = median(runs: 21, onThread: true, open)
            let rows = command.choices()
            expect(rows.first?.title == "Type" && rows.dropFirst().allSatisfy { index.isType(ShapeID(UUID(uuidString: $0.id)!)) }, "Type, then the types")
            report(String(format: "%6d shapes, %d types, the /is-a list: the first open %6.3f ms, then %6.3f ms (budget %.0f)",
                          size, types.count, first, opening, Budget.isAListOpen))
            if holdsToBudgets {
                expect(opening < Budget.isAListOpen, "opening /is-a's list over \(size) shapes took \(opening) ms")
            }
        }
    },

    test("a frame of a thousand instances in view with their chips, each after a drag of all of them, costs little more than the same frame still") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        let count = holdsToBudgets ? 1_000 : 300
        var type = ShapeRecord(StickyNote(frame: CGRect(x: -400, y: 0, width: 200, height: 200), text: MentionText(plain: "A person")))
        type[TitleProperty.self] = "Person"
        type[TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter)
        var shapes = [AnyShapeRecord(type)]
        var instances: [ShapeID] = []
        for index in 0..<count {
            let frame = CGRect(x: CGFloat(index % 40) * 70, y: CGFloat(index / 40) * 50, width: 60, height: 40)
            var note = ShapeRecord(StickyNote(frame: frame, text: MentionText(plain: "Ann \(index)")))
            note[IsAProperty.self] = [TypeLink(type.id)]
            shapes.append(AnyShapeRecord(note))
            instances.append(note.id)
        }
        let document = CanvasDocument(shapes: shapes)
        @MainActor func frame(moving: Bool) throws -> Double {
            let editor = CanvasEditor(registry: try Registry(plugins: shippedPlugins(pasteboard)), document: document, scheduler: ManualScheduler())
            editor.viewportDidResize(to: viewport)
            editor.camera = Camera(origin: .zero, zoom: 0.4)
            var step = 0.0
            let pan = { @MainActor () -> Void in
                step = step == 0 ? 1 : 0
                if moving {
                    // A drag of every instance in view: the commit (not measured) and the frame after it, whose
                    // chips must not be made again, only laid out where the shapes are.
                    editor.transact("Move") { $0.translate(Set(instances), by: CGPoint(x: step == 0 ? -1 : 1, y: 0)) }
                } else {
                    editor.camera = Camera(origin: CGPoint(x: step / 0.4, y: 0), zoom: 0.4)
                }
            }
            draw(editor, into: context, size: viewport)
            draw(editor, into: context, size: viewport)
            return median(runs: 11, prepare: { pan() }, onThread: true) { draw(editor, into: context, size: viewport) }
        }
        let still = try frame(moving: false), dragged = try frame(moving: true)
        report(String(format: "%6d instances in view at 40%%, all dragged: the frame after each event %5.1f ms, %.1f more than still %5.1f (budget %.0f more)",
                      count, dragged, dragged - still, still, Budget.typesDragFrame))
        if holdsToBudgets { expect(dragged - still < Budget.typesDragFrame, "dragging \(count) instances added \(dragged - still) ms to a frame") }
    },
])
