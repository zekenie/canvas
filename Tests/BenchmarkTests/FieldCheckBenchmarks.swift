import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Composition
import CoreGraphics
import Foundation
import Mentions
import StickyNotes
import TestKit
import Titles
import Types
import Validation

// What the check of a note's values costs (`FieldChecks`, Types; [types](../../.claude/rules/types.md)): a list of
// types compiled, an answer kept and asked a frame at a time, validation's first read with the rule over the
// same file with those notes untyped, a keystroke in a field, and a type edit that reaches 10,000 notes. The
// thread's CPU time, release; `./build.sh bench` holds the budgets and `./test.sh` only reports them.

extension Budget {
    /// 1,000 distinct lists of three types (a type of eleven fields and a group through `#/$defs`, one built on it with
    /// six more, and one of the twelve others), each list's check built and one note of it checked, in a file of 10,000
    /// shapes: the validators compiled for each list. Also after a schema edit to the first type, which every list
    /// is built on, so each is found stale, read again and built. Some 85 ms (80.9, 84.5 and 85.4 in three runs alone,
    /// load average 7; 82.3, 86.8 and 88.3 after the edit): held at the design's ceiling, not three times the median.
    static let fieldChecksCompiled = 150.0
    /// 10,000 asks of notes whose answers are kept (what a frame of notes in view pays: three reads of a note's added
    /// values, a lookup by id, two compares that end at the storage's identity and a stamp): some 3.3 ms (3.28, 3.33 and 3.51;
    /// 4.1 to 4.3 at load 7 to 40), 0.33 µs an ask, of which the reads of the record are some 0.3 (the design guessed
    /// 0.2 to 0.5): held at the design's ceiling.
    static let fieldChecksKept = 5.0
    /// Validation's first read of a file of 10,000 shapes with a thousand typed notes holding six values each, over the same
    /// read with their answers already kept: the answers made inside it (a note's values checked once). Some 1.5 ms (1.46,
    /// 0.39 and 1.48; the read itself is 50 ms and moves by that much between runs).
    static let fieldChecksFirstRead = 10.0
    /// The same with every typed note of the board (some 6,000) holding no values: each takes the list's one answer of no
    /// values, and the difference is lost in the read's own noise (-0.3, -2.2 and -6.1 ms).
    static let fieldChecksFirstReadEmpty = 10.0
    /// A value written to one of the board's 6,000 typed notes, the commit and the read after it, over the same to an untyped
    /// note: the one note checked again, nothing else. 0.008 ms (0.008, 0.006 and 0.020, of 0.23 for the commit and the
    /// read); held at the design's ceiling, since the difference is below what a run moves by.
    static let fieldChecksKeystroke = 0.2
}

/// A type of six fields for the notes to hold: a name needed, a count of at least 0, an email, a date, a choice, tags.
private let recordSchema = #"""
{"type": "object", "properties": {
  "name": {"type": "string"}, "count": {"type": "integer", "minimum": 0}, "email": {"type": "string", "format": "email"},
  "due": {"type": "string", "format": "date"}, "status": {"enum": ["draft", "paid", "shipped"]},
  "tags": {"type": "array", "items": {"type": "string", "maxLength": 12}}}, "required": ["name"]}
"""#

private func values(_ n: Int) -> FieldValues {
    FieldValues(["name": .string("Note \(n)"), "count": .number(Double(n % 7)), "email": n % 10 == 0 ? "bad@" : "bo@acme.com", "due": "2024-03-03",
                 "status": "paid", "tags": ["a", "b"]])
}

/// The generated board with its first `types` notes made types, and then `typed` of the plain notes after them instances of
/// the first, holding six values each if `holding`; `typed` of them are left untyped, with the same values, if `untyped`.
@MainActor private func board(shapes size: Int, typed: Int, holding: Bool, untyped: Bool = false) -> (document: CanvasDocument, type: ShapeID, notes: [ShapeID]) {
    var shapes = generatedBoard(shapes: size).shapes
    var type: ShapeID?
    var notes: [ShapeID] = []
    for index in shapes.indices where shapes[index].kind == StickyNote.kind && shapes[index][TypeSchemaProperty.self] == nil {
        if type == nil {
            shapes[index][TypeSchemaProperty.self] = SchemaText(recordSchema)
            shapes[index][TitleProperty.self] = "Record"
            type = shapes[index].id
            continue
        }
        guard notes.count < typed, let type else { break }
        if !untyped { shapes[index][IsAProperty.self] = [TypeLink(type)] }
        if holding { shapes[index][FieldValuesProperty.self] = values(notes.count) }
        notes.append(shapes[index].id)
    }
    return (CanvasDocument(shapes: shapes), type!, notes)
}

@MainActor let fieldCheckBenchmarks = Suite("Field check benchmarks", [
    test("1,000 distinct lists of types have their checks built, and again after a schema edit to the first type") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for size in sizes {
            let base = generatedBoard(shapes: size)
            var types: [ShapeID] = []
            var shapes = base.shapes
            var noteIndex = 0
            for index in shapes.indices where shapes[index].kind == StickyNote.kind {
                defer { noteIndex += 1 }
                if noteIndex % 50 == 0 {
                    shapes[index][TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter)
                    shapes[index][TitleProperty.self] = "Type \(types.count)"
                    types.append(shapes[index].id)
                }
            }
            let document = CanvasDocument(shapes: shapes)
            let registry = try Registry(plugins: shippedPlugins(pasteboard))
            func text(_ fields: Int, prefix: String, extra: String = "", note: Int = 0) -> String {
                let properties = (0..<fields).map { #""\#(prefix)\#($0)": {"type": "string", "maxLength": 40, "description": "\#(note)"}"# } + (extra.isEmpty ? [] : [extra])
                return #"{"type": "object", "properties": {\#(properties.joined(separator: ", "))}, "required": ["\#(prefix)0"], "$defs": {"address": {"type": "object", "properties": {"street": {"type": "string"}, "city": {"type": "string"}}}}}"#
            }
            let group = ##""address": {"$ref": "#/$defs/address"}"##
            let first = types[0], second = types[1]
            let others = types.filter { $0 != second }
            var lists: [[ShapeID]] = []
            search: for x in others {
                for y in others where y != x {
                    lists.append([x, second, y])
                    if lists.count == 1_000 { break search }
                }
            }
            let records = lists.enumerated().map { place, list -> AnyShapeRecord in
                var note = ShapeRecord(StickyNote(frame: CGRect(x: 0, y: 0, width: 100, height: 100), text: MentionText(plain: "List \(place)")))
                note[IsAProperty.self] = list.map(TypeLink.init)
                note[FieldValuesProperty.self] = FieldValues(["f0": "x", "g0": "y", "address": ["city": "Oslo"]])
                return AnyShapeRecord(note)
            }
            var edit = 0
            @MainActor func fresh() throws -> (CanvasEditor, FieldChecks) {
                let editor = CanvasEditor(registry: registry, document: document, scheduler: ManualScheduler())
                editor.transact("Types") {
                    $0.update(first) { $0[TypeSchemaProperty.self] = SchemaText(text(11, prefix: "f", extra: group)) }
                    $0.update(second) {
                        $0[TypeSchemaProperty.self] = SchemaText(text(6, prefix: "g"))
                        $0[IsAProperty.self] = [TypeLink(first)]
                    }
                }
                return (editor, try require(editor.fieldChecks))
            }
            var cold: [Double] = []
            var afterEdit: [Double] = []
            for _ in 0..<3 {
                let (editor, checks) = try fresh()
                _ = try require(editor.fieldBook)
                cold.append(threadCPUTime { for record in records { _ = checks.fullCheck(of: record) } }.milliseconds)
                edit += 1
                editor.transact("Write") { $0.update(first) { $0[TypeSchemaProperty.self] = SchemaText(text(11, prefix: "f", extra: group, note: edit)) } }
                afterEdit.append(threadCPUTime { for record in records { _ = checks.fullCheck(of: record) } }.milliseconds)
                #if DEBUG
                expect(checks.checkersMade >= lists.count, "a checker for each list")
                #endif
            }
            let built = middle(cold), again = middle(afterEdit)
            report(String(format: "%6d shapes, %d lists of three: each check built and one note checked %6.2f ms, again after a schema edit to the first type %6.2f ms (budget %.0f)",
                          size, lists.count, built, again, Budget.fieldChecksCompiled))
            if holdsToBudgets, size >= 10_000 {
                expect(lists.count == 1_000, "\(lists.count) lists")
                expect(built < Budget.fieldChecksCompiled, "building \(lists.count) checks took \(built) ms")
                expect(again < Budget.fieldChecksCompiled, "building \(lists.count) checks after an edit took \(again) ms")
            }
        }
    },
    test("10,000 asks of notes whose answers are kept cost a stamp and a lookup each") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let (document, type, _) = board(shapes: 300, typed: 0, holding: false)
        let editor = CanvasEditor(registry: try Registry(plugins: shippedPlugins(pasteboard)), document: document, scheduler: ManualScheduler())
        let checks = try require(editor.fieldChecks)
        let records = (0..<10_000).map { n -> AnyShapeRecord in
            var note = ShapeRecord(StickyNote(frame: CGRect(x: 0, y: 0, width: 100, height: 100), text: MentionText(plain: "Note \(n)")))
            note[IsAProperty.self] = [TypeLink(type)]
            note[FieldValuesProperty.self] = values(n)
            return AnyShapeRecord(note)
        }
        for record in records { _ = checks.fullCheck(of: record) }
        #if DEBUG
        let made = checks.checksMade
        #endif
        let kept = median(runs: 11, onThread: true) { for record in records { _ = checks.check(of: record) } }
        #if DEBUG
        expectEqual(checks.checksMade, made, "asking again checks nothing")
        #endif
        report(String(format: "10,000 asks of kept answers %6.2f ms (budget %.0f)", kept, Budget.fieldChecksKept))
        if holdsToBudgets { expect(kept < Budget.fieldChecksKept, "10,000 asks of kept answers took \(kept) ms") }
    },
    test("validation's first read makes the answers of a thousand typed notes with six values, or of every typed note with none, at a small cost over the same read with the answers kept") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for size in sizes {
            let registry = try Registry(plugins: shippedPlugins(pasteboard))
            // The read with the answers made inside it, over the same read after they were: what the rule adds is making them.
            @MainActor func firstRead(typed: Int, holding: Bool, warm: Bool) throws -> (ms: Double, notes: Int) {
                let (document, _, notes) = board(shapes: size, typed: typed, holding: holding)
                var editor = CanvasEditor(registry: registry, document: document, scheduler: ManualScheduler())
                let ms = median(runs: 5, prepare: {
                    editor = CanvasEditor(registry: registry, document: document, scheduler: ManualScheduler())
                    if warm, let checks = editor.fieldChecks { for id in notes { _ = editor.document[id].map { checks.check(of: $0) } } }
                }, onThread: true) {
                    _ = editor.validation?.results
                }
                return (ms, notes.count)
            }
            let thousand = min(1_000, size / 10)
            let valued = try firstRead(typed: thousand, holding: true, warm: false), valuedKept = try firstRead(typed: thousand, holding: true, warm: true)
            // As many typed notes as the board has (some 6,000 of the 10,000 shapes are plain notes).
            let bare = try firstRead(typed: size, holding: false, warm: false), bareKept = try firstRead(typed: size, holding: false, warm: true)
            report(String(format: "%6d shapes, %d typed notes holding six values: validation's first read %6.2f ms, %6.2f over the same with the answers kept (budget %.0f); %d typed holding none %6.2f ms, %6.2f over (budget %.0f)",
                          size, valued.notes, valued.ms, valued.ms - valuedKept.ms, Budget.fieldChecksFirstRead, bare.notes, bare.ms, bare.ms - bareKept.ms, Budget.fieldChecksFirstReadEmpty))
            if holdsToBudgets, size >= 10_000 {
                expect(valued.ms - valuedKept.ms < Budget.fieldChecksFirstRead, "making \(valued.notes) answers inside the first read added \(valued.ms - valuedKept.ms) ms")
                expect(bare.ms - bareKept.ms < Budget.fieldChecksFirstReadEmpty, "making \(bare.notes) empty answers inside the first read added \(bare.ms - bareKept.ms) ms")
            }
        }
    },
    test("a value written to one of 10,000 typed notes, the commit and the read after it, costs little more than the same to an untyped note") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for size in sizes {
            let registry = try Registry(plugins: shippedPlugins(pasteboard))
            let typedBoard = board(shapes: size, typed: size, holding: true)
            let untypedBoard = board(shapes: size, typed: size, holding: true, untyped: true)
            @MainActor func keystroke(_ board: (document: CanvasDocument, type: ShapeID, notes: [ShapeID])) throws -> Double {
                let editor = CanvasEditor(registry: registry, document: board.document, scheduler: ManualScheduler())
                _ = editor.validation?.results
                let note = board.notes[board.notes.count / 2]
                var typed = 0
                return median(runs: 31, prepare: { typed += 1 }, onThread: true) {
                    editor.transact("Change Name") { $0.update(note) { $0[FieldValuesProperty.self] = FieldValues(["name": .string(String(repeating: "x", count: typed)), "email": "bo@acme.com"]) } }
                    _ = editor.validation?.results
                }
            }
            let typed = try keystroke(typedBoard), plain = try keystroke(untypedBoard)
            report(String(format: "%6d shapes, a keystroke in a typed note's field: the read after the commit %6.3f ms, %6.3f over the same untyped (budget %.1f)",
                          size, typed, typed - plain, Budget.fieldChecksKeystroke))
            if holdsToBudgets, size >= 10_000 { expect(typed - plain < Budget.fieldChecksKeystroke, "a keystroke added \(typed - plain) ms") }
        }
    },
])
