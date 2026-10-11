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
    /// The field book (`editor.fieldBook`) asked cold for 1,000 distinct lists of three types, each holding a type of six
    /// fields that is built on one of twelve, a group through `#/$defs` among them: each list ordered and its fields
    /// laid out, asked after a schema written to another type, which drops every kept list. Also held after a schema edit
    /// to the first type, which makes every list resolve again (the levels it read are read again too): some 15 ms (release, the thread's CPU, three runs 14.8, 15.1 and 15.2, and 14.9, 15.1 and 15.0
    /// after the edit).
    static let fieldListsResolved = 45.0
    /// 10,000 asks of lists already kept (what a frame of notes in view pays, a stamp compare and a hash of a list
    /// of three ids each): some 1 ms (1.03, 1.03 and 1.05).
    static let fieldListsKept = 3.0
    /// Opening `/is-a`'s list on a plain note of a 10,000-shape file with 140 types (the thread's CPU, release): the
    /// types the note may be, asked of the index once and sorted by name, then kept while the list is open: some 3.5 ms
    /// (3.1, 3.5, 3.6 in three runs alone, load average 6), about three times that.
    static let isAListOpen = 10.0
    /// Picking `New type “X”` from `/is-a`'s list on a plain note of a 10,000-shape file (the thread's CPU, release): the board
    /// read once for the landing (every shape an obstacle, as `/move-near` reads it), the note put down, the link made; held
    /// to a frame (7.1, 7.7, 7.1 ms after the first pick, 15 to 16 for the first, in three runs alone, load average 3).
    static let newTypePick = 16.0
    /// What white paper adds to a frame of 10,000 type notes zoomed out to fit, over the same frame of plain notes
    /// (the thread's CPU, release; 0.2, 0.3, 0.3 in three runs alone, load average 8): the paper resolved once for the appearance drawn, not per note (a dynamic
    /// color resolved per note added 8 ms).
    static let typePaper = 1.0
    /// What their rows add to a frame of 150 type notes of six fields in full at 40%, over the same notes whose
    /// schema has no fields (the same words, paper and pill, and the one row that says `No fields`): five more rows
    /// of name and kind, the kept Core Text lines, dots. A frame of the same notes with a blank type each is some 23
    /// ms (the pills and the paper), so this is what the rows are. Release, the thread's CPU, three runs alone at a load
    /// average of 3: +2.1, +1.7 and -0.5 ms (the design guessed 2 to 4); about three times the median.
    static let typeRowsFrame = 5.0
    /// What rows' bars add to a frame of typed notes drawn as skeletons at 20%, some 350 in view, over the same notes
    /// as plain skeletons: each skeleton's `NoteLayout` (the provider's lookups and its words' kept height), a template
    /// lookup and at most ten rects in one fill. Release, the thread's CPU, three runs alone at a load average of 3:
    /// +1.5, +1.6 and +1.7 ms; held at the design's 2, which all three fit.
    static let typeRowBars = 2.0
    /// A keystroke in a row of one of 1,000 notes that are a Person among 10,000 shapes: the writer's commit and every
    /// service hearing it (the thread's CPU, release; one shape, where a drag event's input is held to 1 ms): 0.21, 0.22 and
    /// 0.22 ms in three runs alone at a load average of 1.2; about three times the median.
    static let rowKeystroke = 0.7
    /// What their values add to a frame of 150 notes that are a type of six fields, all filled, in full at 40%, over the
    /// same notes with the type taken off (the same words and paper): +4.1, +4.4 and +4.3 ms in three runs alone (release, the
    /// thread's CPU, load average 1.2; the design guessed 3 to 6). Held at the design's 9, twice the median, not three times it:
    /// three times would be 13, past what the design allowed.
    static let valueRowsFrame = 9.0
}

/// A type of six text fields, a note of `words` titled Person at `origin`.
@MainActor private func sixFieldType(at origin: CGPoint) -> AnyShapeRecord {
    var note = ShapeRecord(id: FieldFixtures.wideID, StickyNote(frame: CGRect(origin: origin, size: CGSize(width: 200, height: 200)),
                                                                 text: MentionText(plain: "A thing with six fields.")))
    note[TypeSchemaProperty.self] = SchemaText(FieldFixtures.wide(6).schema)
    note[TitleProperty.self] = "Person"
    return AnyShapeRecord(note)
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

    test("picking New type beside a note of a 10,000-shape file takes under a frame: the board read once, the note placed, the link made") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for size in sizes {
            let (document, _, _, _) = typedBoard(shapes: size)
            let editor = CanvasEditor(registry: try Registry(plugins: shippedPlugins(pasteboard)), document: document, scheduler: ManualScheduler())
            let owner = try require(document.shapes.first { (record: AnyShapeRecord) -> Bool in
                record.kind == StickyNote.kind && record[TypeSchemaProperty.self] == nil && record[IsAProperty.self] == nil
            }).id
            let command = try require(editor.slashCommands?.command(named: "is-a", for: owner))
            let row = try require(command.choice(otherwise: "Company"), "the New type row")
            var picks = 0
            let state = try require(editor.slashCommands)
            let pick = { @MainActor () -> Void in
                picks += 1
                expect(state.run(command, on: owner, choosing: row))
            }
            let first = median(runs: 1, onThread: true, pick)
            let opening = median(runs: 7, prepare: {
                editor.endEditing()
                editor.undo()
            }, onThread: true, pick)
            expect(editor.document.shapes.count == document.shapes.count + 1, "one note placed by the last pick")
            report(String(format: "%6d shapes, picking New type: the first %6.3f ms, then %6.3f ms (budget %.0f)", size, first, opening, Budget.newTypePick))
            if holdsToBudgets { expect(opening < Budget.newTypePick, "picking New type over \(size) shapes took \(opening) ms") }
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
    test("the field book resolves 1,000 distinct lists of types cold, again after a schema edit, and answers kept ones at a lookup each") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for size in sizes {
            let (document, types, _, _) = typedBoard(shapes: size)
            let editor = CanvasEditor(registry: try Registry(plugins: shippedPlugins(pasteboard)), document: document, scheduler: ManualScheduler())
            let book = try require(editor.fieldBook)
            let first = types[0], second = types[1], spare = types[2]
            func text(_ fields: Int, prefix: String, extra: String = "", note: Int = 0) -> String {
                let properties = (0..<fields).map { #""\#(prefix)\#($0)": {"type": "string", "description": "\#(note)"}"# } + (extra.isEmpty ? [] : [extra])
                return #"{"type": "object", "properties": {\#(properties.joined(separator: ", "))}, "required": ["\#(prefix)0"], "$defs": {"address": {"type": "object", "properties": {"street": {"type": "string"}, "city": {"type": "string"}}}}}"#
            }
            let group = ##""address": {"$ref": "#/$defs/address"}"##
            @MainActor func write(_ id: ShapeID, _ schema: String) {
                editor.transact("Write") { $0.update(id) { $0[TypeSchemaProperty.self] = SchemaText(schema) } }
            }
            editor.transact("Types") {
                $0.update(first) { $0[TypeSchemaProperty.self] = SchemaText(text(11, prefix: "f", extra: group)) }
                $0.update(second) {
                    $0[TypeSchemaProperty.self] = SchemaText(text(6, prefix: "g"))
                    $0[IsAProperty.self] = [TypeLink(first)]
                }
            }
            // Distinct lists of three: the second type among two others, in each place.
            let others = types.filter { $0 != second }
            var lists: [[ShapeID]] = []
            search: for x in others {
                for y in others where y != x {
                    lists.append([x, second, y])
                    if lists.count == 1_000 { break search }
                }
            }
            @MainActor func ask() { for list in lists { _ = book.fields(types: list) } }
            var note = 0
            let cold = median(runs: 11, prepare: {
                note += 1
                let before = book.revision
                write(spare, text(2, prefix: "a", note: note))
                expect(book.revision != before, "a type's schema written moves the revision")
            }, onThread: true) { ask() }
            let afterEdit = median(runs: 11, prepare: {
                note += 1
                write(first, text(11, prefix: "f", extra: group, note: note))
            }, onThread: true) { ask() }
            #if DEBUG
            let made = book.resolutionsMade
            write(first, text(11, prefix: "f", extra: group, note: note + 1))
            ask()
            expectEqual(book.resolutionsMade - made, lists.count, "one resolution for each distinct list after an edit")
            ask()
            expectEqual(book.resolutionsMade - made, lists.count, "and none for lists kept")
            #endif
            let resolved = book.fields(types: try require(lists.first))
            expect(resolved.fields.count >= 12 + 6, "the first type's twelve and the second's six, among the rest")
            ask()
            let rounds = max(1, 10_000 / lists.count)
            let kept = median(runs: 11, onThread: true) { for _ in 0..<rounds { ask() } } * 10_000 / Double(rounds * lists.count)
            report(String(format: "%6d shapes, %d types, %d lists of three: resolved cold %6.2f ms, again after a schema edit %6.2f ms (budget %.0f); 10,000 asks kept %6.2f ms (budget %.0f)",
                          size, types.count, lists.count, cold, afterEdit, Budget.fieldListsResolved, kept, Budget.fieldListsKept))
            if holdsToBudgets, size >= 10_000 {
                expect(lists.count == 1_000, "\(lists.count) lists")
                expect(cold < Budget.fieldListsResolved, "resolving \(lists.count) lists cold took \(cold) ms")
                expect(afterEdit < Budget.fieldListsResolved, "resolving \(lists.count) lists again after a schema edit took \(afterEdit) ms")
                expect(kept < Budget.fieldListsKept, "10,000 asks of kept lists took \(kept) ms")
            }
        }
    },
    test("showing 10,000 stored dates, and reading 1,000 typed ones, is reported (rows draw them every frame in view)") {
        let us = Locale(identifier: "en_US")
        var days: [JSONValue] = []
        for n in 0..<10_000 { days.append(.string(String(format: "%04d-%02d-%02d", 2000 + n % 40, 1 + n % 12, 1 + n % 28))) }
        var typed: [String] = []
        for n in 0..<1_000 { typed.append("Mar \(n % 28 + 1), \(2000 + n % 40)") }
        _ = FieldText.shown(days[0], as: .date, locale: us)
        let shown = median(runs: 11, onThread: true) { for day in days { _ = FieldText.shown(day, as: .date, locale: us) } }
        let read = median(runs: 11, onThread: true) { for text in typed { _ = FieldText.value(from: text, as: .date, locale: us) } }
        report(String(format: "10,000 shown(.date) %6.2f ms; 1,000 typed written dates read %6.2f ms", shown, read))
    },
    test("10,000 type notes zoomed out to fit the board, white paper and covers, fit in a frame: the first and each after") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        for size in sizes {
            // Notes 60 x 40, titled, 96 apart in rows of 125: 10,000 fill 12,000 x 7,680, all in view at 10%.
            // The control is the same board with plain notes (yellow, no schema). No words and no fields: a type
            // with words and none of the second says `No fields` under them and is 320 wide, which is rows' cost.
            @MainActor func frames(types: Bool) throws -> (first: Double, next: Double, zoom: CGFloat) {
                let shapes = (0..<size).map { i -> AnyShapeRecord in
                    var note = ShapeRecord(StickyNote(frame: CGRect(x: CGFloat(i % 125) * 96, y: CGFloat(i / 125) * 96, width: 60, height: 40)))
                    if types { note[TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter) }
                    note[TitleProperty.self] = "Note \(i)"
                    return AnyShapeRecord(note)
                }
                let editor = CanvasEditor(registry: try Registry(plugins: shippedPlugins(pasteboard)), document: CanvasDocument(shapes: shapes), scheduler: ManualScheduler())
                editor.viewportDidResize(to: viewport)
                editor.camera = Camera(fitting: editor.shapeBounds, in: viewport, inset: 0)
                expect(editor.drawsSkeletons, "zoomed out, shapes are skeletons")
                let first = median(runs: 1, onThread: true) { draw(editor, into: context, size: viewport) }
                var step = 0.0
                let next = median(runs: 11, prepare: { step = step == 0 ? 1 : 0; editor.camera = Camera(fitting: editor.shapeBounds, in: viewport, inset: step) }, onThread: true) {
                    draw(editor, into: context, size: viewport)
                }
                return (first, next, editor.camera.zoom)
            }
            let plain = try frames(types: false), type = try frames(types: true)
            report(String(format: "%6d type notes zoomed out to fit (%.0f%%): the first frame %5.1f ms (reported), the next %5.1f (budget %.0f, and %.1f more than plain notes' %5.1f); plain notes' first %5.1f",
                          size, type.zoom * 100, type.first, type.next, Budget.zoomedOut, type.next - plain.next, plain.next, plain.first))
            // The first frame is reported: a board of 10,000 type notes costs its first draw more than one of
            // plain notes whatever the skeleton does (it's the same with the skeleton reading no schema).
            if holdsToBudgets {
                expect(type.next < Budget.zoomedOut, "a frame of \(size) type notes zoomed out took \(type.next) ms")
                expect(type.next - plain.next < Budget.typePaper, "the paper added \(type.next - plain.next) ms to a frame of \(size) notes zoomed out")
            }
        }
    },
    test("a keystroke in a row of one of 1,000 notes that are a Person among 10,000 shapes is one commit of one shape; the frame after it is a frame") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        for size in sizes {
            var shapes = generatedBoard(shapes: size).shapes
            let type = sixFieldType(at: CGPoint(x: -400, y: 0))
            let values = FieldValues(["f1": "Ann", "f2": "Lee", "f3": "ann@acme.com", "f4": "Leeds", "f5": "gift", "f6": "none"])
            var instances: [ShapeID] = []
            for index in shapes.indices where shapes[index].kind == StickyNote.kind && instances.count < 1_000 && shapes[index][TypeSchemaProperty.self] == nil {
                shapes[index][IsAProperty.self] = [TypeLink(type.id)]
                shapes[index][FieldValuesProperty.self] = values
                instances.append(shapes[index].id)
            }
            shapes.append(type)
            let editor = CanvasEditor(registry: try Registry(plugins: shippedPlugins(pasteboard)), document: CanvasDocument(shapes: shapes), scheduler: ManualScheduler())
            editor.viewportDidResize(to: viewport)
            let target = instances[instances.count / 2]
            let writer = try require(editor.fieldWriter)
            var n = 0
            let keystroke = median(runs: 21, onThread: true) {
                n += 1
                writer.setTyped("Ann \(n)", as: .text, at: FieldPath(field: "f1"), of: target)
            }
            expect(writer.values(of: target).value(at: FieldPath(field: "f1")) == .string("Ann \(n)"), "the keystroke wrote")
            let frame = try require(editor.shapeContext.frame(of: target))
            editor.camera = camera(centering: frame, at: 1, in: viewport)
            draw(editor, into: context, size: viewport)
            let after = median(runs: 11, prepare: {
                n += 1
                writer.setTyped("Ann \(n)", as: .text, at: FieldPath(field: "f1"), of: target)
            }, onThread: true) { draw(editor, into: context, size: viewport) }
            report(String(format: "%6d shapes, %d notes that are a Person: a keystroke in a row %5.2f ms (budget %.1f), the frame after it %5.1f ms (budget %.0f)",
                          size, instances.count, keystroke, Budget.rowKeystroke, after, Budget.frame))
            if holdsToBudgets, size >= 10_000 {
                expect(keystroke < Budget.rowKeystroke, "a keystroke in a row took \(keystroke) ms among \(size) shapes")
                expect(after < Budget.frame, "the frame after a keystroke took \(after) ms among \(size) shapes")
            }
        }
    },
    test("150 notes that are a type of six fields, filled, in full at 40%, cost little more in a frame than the same notes with the type taken off") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let size = CGSize(width: 2_100, height: 1_000)
        @MainActor func board(typed: Bool) throws -> CanvasEditor {
            var shapes = (0..<150).map { i -> AnyShapeRecord in
                let frame = CGRect(x: CGFloat(i % 15) * 340, y: CGFloat(i / 15) * 240, width: 200, height: 200)
                var note = ShapeRecord(StickyNote(frame: frame, text: MentionText(plain: "Ann Lee, staff engineer.")))
                if typed {
                    note[IsAProperty.self] = [TypeLink(FieldFixtures.wideID)]
                    note[FieldValuesProperty.self] = FieldValues(["f1": "Ann", "f2": "Lee", "f3": "ann@acme.com", "f4": "Leeds", "f5": "gift", "f6": "none"])
                }
                return AnyShapeRecord(note)
            }
            if typed { shapes.append(sixFieldType(at: CGPoint(x: 0, y: -400))) }
            let editor = CanvasEditor(registry: try Registry(plugins: shippedPlugins(pasteboard)), document: CanvasDocument(shapes: shapes), scheduler: ManualScheduler())
            editor.viewportDidResize(to: size)
            editor.camera = Camera(origin: CGPoint(x: 0, y: 0), zoom: 0.4)
            return editor
        }
        @MainActor func frames(_ editor: CanvasEditor) throws -> Double {
            let context = try bitmapContext(size)
            draw(editor, into: context, size: size)
            draw(editor, into: context, size: size)
            var step = 0.0
            return median(runs: 11, prepare: { step = step == 0 ? 1 : 0; editor.camera = Camera(origin: CGPoint(x: step / 0.4, y: 0), zoom: 0.4) }, onThread: true) {
                draw(editor, into: context, size: size)
            }
        }
        let typed = try board(typed: true)
        let first = try require(typed.document.shapes.first).id
        expectEqual(try require(typed.rowBook).rows(of: first).count, 6)
        let withValues = try frames(typed), without = try frames(try board(typed: false))
        report(String(format: "150 notes that are a type of six fields, filled, in full at 40%%: a frame %5.2f ms, %5.2f more than the same notes untyped (%5.2f) (budget %.0f more)",
                      withValues, withValues - without, without, Budget.valueRowsFrame))
        if holdsToBudgets { expect(withValues - without < Budget.valueRowsFrame, "values' rows added \(withValues - without) ms to a frame of 150 notes in full") }
    },
    test("a frame of 150 type notes with their rows in full at 40%, and of 350 as skeletons at 20% with the rows' bars, costs little more than the same notes with none") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let words = "A thing with six fields, as a type's words say it."
        /// What each note of a board is: a type of six fields, a type whose schema has none (the words, the paper and
        /// the pill alike, and one row that says `No fields`), or a plain note at the size a type of six is laid out.
        enum Notes { case sixFields, noFields, plain(height: CGFloat) }
        /// `count` notes of the same words in `columns` columns, 340 by 240 apart, the editor over them at `zoom`.
        @MainActor func board(_ count: Int, columns: Int, _ notes: Notes, size: CGSize, zoom: CGFloat) throws -> CanvasEditor {
            let shapes = (0..<count).map { i -> AnyShapeRecord in
                var frame = CGRect(x: CGFloat(i % columns) * 340, y: CGFloat(i / columns) * 240, width: 200, height: 200)
                var type: String?
                switch notes {
                case .sixFields: type = FieldFixtures.wide(6).schema
                case .noFields: type = #"{"type": "object"}"#
                case .plain(let height): frame.size = CGSize(width: TypesStyle.rowsMinimumWidth, height: height)
                }
                var note = ShapeRecord(StickyNote(frame: frame, text: MentionText(plain: words)))
                if let type { note[TypeSchemaProperty.self] = SchemaText(type) }
                return AnyShapeRecord(note)
            }
            let editor = CanvasEditor(registry: try Registry(plugins: shippedPlugins(pasteboard)), document: CanvasDocument(shapes: shapes), scheduler: ManualScheduler())
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
        // 150 in full: 15 columns by 10 rows, 5,100 by 2,400 world units, at 40%. Over the same notes saying `No fields`.
        let full = CGSize(width: 2_100, height: 1_000)
        let six = try board(150, columns: 15, .sixFields, size: full, zoom: 0.4)
        let first = try require(six.document.shapes.first).id
        let paper = try require(six.shapeContext.frame(of: first))
        expectEqual(paper.width, TypesStyle.rowsMinimumWidth)
        expectEqual(try require(six.rowBook).rows(of: first).count, 6)
        let none = try board(150, columns: 15, .noFields, size: full, zoom: 0.4)
        let withRows = try frames(six, size: full, zoom: 0.4), withNone = try frames(none, size: full, zoom: 0.4)
        report(String(format: "150 type notes of six fields in full at 40%%: a frame %5.2f ms, %5.2f more than the same notes saying `No fields` (%5.2f) (budget %.0f more)",
                      withRows, withRows - withNone, withNone, Budget.typeRowsFrame))
        // 350 as skeletons: 25 columns by 14 rows at 20%. Over plain notes' skeletons of the same size.
        let far = CGSize(width: 1_800, height: 700)
        let typedFar = try board(350, columns: 25, .sixFields, size: far, zoom: 0.2)
        expect(typedFar.drawsSkeletons, "zoomed out, shapes are skeletons")
        let plainFar = try board(350, columns: 25, .plain(height: paper.height), size: far, zoom: 0.2)
        let typedBars = try frames(typedFar, size: far, zoom: 0.2), plainBars = try frames(plainFar, size: far, zoom: 0.2)
        report(String(format: "350 type notes as skeletons at 20%%: a frame %5.2f ms, %5.2f more than plain notes' (%5.2f) (budget %.1f more)",
                      typedBars, typedBars - plainBars, plainBars, Budget.typeRowBars))
        if holdsToBudgets {
            expect(withRows - withNone < Budget.typeRowsFrame, "rows added \(withRows - withNone) ms to a frame of 150 type notes in full")
            expect(typedBars - plainBars < Budget.typeRowBars, "rows' bars added \(typedBars - plainBars) ms to a frame of 350 type notes as skeletons")
        }
    },
])
