import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Mentions
import StickyNotes
import TableOfContents
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
    /// A schema edit to the type 10,000 notes holding six values are instances of (a limit changed), the commit and the
    /// read after it: the type's check built once, each note checked again and the rules asked of all. Some 53 ms (52.8, 52.4
    /// and 56.6 alone, load average 4; 80 to 105 at load 12), 85 with the table of contents' rows read after it (84.8, 86.9,
    /// 88.0): three times the median, under the design's 250 ms ceiling.
    static let fieldChecksTypeEdit = 160.0
    /// The same edit when it changes nothing the check reads (a description): the reached notes whose check is still current
    /// keep their answer and are not named, so only the types are read again. Some 2.7 ms (2.6, 2.7 and 2.9; 57 to 73 ms
    /// when every reached note was named, over the design's 40 ms ceiling).
    static let fieldChecksTypeEditUnread = 8.0
    /// A drag of 1,000 typed notes holding values (the commit and the read after it) over the same drag of untyped ones: no
    /// answer is made (debug builds count them) and none is looked at; the difference is the typed notes' other services (the
    /// is-a edges move with them). 0.94, 1.02 and 0.90 ms of some 5.9 (load average 4).
    static let fieldChecksDrag = 3.0
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
    test("a schema edit to the type 10,000 notes holding six values are instances of, the commit and the read after it: one that changes a limit, and one the check does not read") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for size in sizes {
            let registry = try Registry(plugins: shippedPlugins(pasteboard))
            // As many instances as the board has shapes: the board's plain notes (some 6,000 of 10,000) and notes added to them.
            let (base, type, existing) = board(shapes: size, typed: size, holding: true)
            var shapes = base.shapes
            for n in existing.count..<size {
                var note = ShapeRecord(StickyNote(frame: CGRect(x: CGFloat(n % 100) * 130, y: -200 - CGFloat(n / 100) * 130, width: 100, height: 100), text: MentionText(plain: "Extra \(n)")))
                note[IsAProperty.self] = [TypeLink(type)]
                note[FieldValuesProperty.self] = values(n)
                shapes.append(AnyShapeRecord(note))
            }
            let document = CanvasDocument(shapes: shapes)
            // `fresh` writes the schema once (the first edit of a run compiles nothing more than a later one would), reads everything once.
            @MainActor func edit(read contents: Bool, changing limit: Bool) throws -> Double {
                let editor = CanvasEditor(registry: registry, document: document, scheduler: ManualScheduler())
                let list = try require(editor.tableOfContents)
                _ = editor.validation?.results
                if contents { _ = list.entries }
                var n = 0
                return median(runs: 5, prepare: { n += 1 }, onThread: true) {
                    let text = limit ? recordSchema.replacingOccurrences(of: #""minimum": 0"#, with: #""minimum": \#(n % 2)"#)
                                     : recordSchema.replacingOccurrences(of: #""required""#, with: #""description": "edit \#(n)", "required""#)
                    editor.transact("Write Schema") { $0.update(type) { $0[TypeSchemaProperty.self] = SchemaText(text) } }
                    _ = editor.validation?.results
                    if contents { _ = list.entries }
                }
            }
            let limit = try edit(read: false, changing: true), limitRows = try edit(read: true, changing: true)
            let other = try edit(read: false, changing: false), otherRows = try edit(read: true, changing: false)
            report(String(format: "%6d instances holding six values, a schema edit, the commit and the read after it: a limit %7.1f ms (budget %.0f), with the table of contents read %7.1f; one the check does not read %7.1f ms (budget %.0f), with the table of contents read %7.1f",
                          size, limit, Budget.fieldChecksTypeEdit, limitRows, other, Budget.fieldChecksTypeEditUnread, otherRows))
            if holdsToBudgets, size >= 10_000 {
                expect(limit < Budget.fieldChecksTypeEdit, "an edit to a limit took \(limit) ms")
                expect(other < Budget.fieldChecksTypeEditUnread, "an edit the check does not read took \(other) ms")
            }
        }
    },
    test("a drag of a thousand typed notes holding values, the commit and the read after it, checks nothing and costs little more than the same drag of untyped ones") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for size in sizes {
            let registry = try Registry(plugins: shippedPlugins(pasteboard))
            let count = min(1_000, size / 10)
            @MainActor func drag(untyped: Bool) throws -> Double {
                let board = board(shapes: size, typed: count, holding: true, untyped: untyped)
                let editor = CanvasEditor(registry: registry, document: board.document, scheduler: ManualScheduler())
                _ = editor.validation?.results
                if !untyped { for id in board.notes { _ = editor.document[id].map { editor.fieldChecks?.check(of: $0) } } }
                #if DEBUG
                let made = editor.fieldChecks?.checksMade
                #endif
                var step = 0
                let ms = median(runs: 11, prepare: { step += 1 }, onThread: true) {
                    editor.transact("Drag") { $0.translate(Set(board.notes), by: CGPoint(x: step % 2 == 0 ? -1 : 1, y: 0)) }
                    _ = editor.validation?.results
                }
                #if DEBUG
                expectEqual(editor.fieldChecks?.checksMade, made, "a drag checks nothing")
                #endif
                return ms
            }
            let typed = try drag(untyped: false), plain = try drag(untyped: true)
            report(String(format: "%6d shapes, a drag of %d typed notes holding values: the commit and the read after it %6.2f ms, %6.2f over the same untyped (budget %.1f)",
                          size, count, typed, typed - plain, Budget.fieldChecksDrag))
            if holdsToBudgets, size >= 10_000 { expect(typed - plain < Budget.fieldChecksDrag, "a drag of typed notes added \(typed - plain) ms") }
        }
    },
    test("10,000 emails, dates, links and UUIDs go through the validator's formats: reported") {
        let formats = ["email": "bo@acme.com", "date": "2026-03-03", "uri": "https://acme.com/a?b=1", "uuid": "123e4567-e89b-42d3-a456-426614174000",
                       "date-time": "2026-03-03T09:30:00Z", "time": "09:30:00Z"]
        let validator = SchemaValidator(JSONSchema(["type": "object", "properties": .object(formats.keys.reduce(into: [:]) { $0[$1] = ["type": "string", "format": .string($1)] })]), formats: .standard)
        let value = JSONValue.object(formats.mapValues { .string($0) })
        var wrong = 0
        let ms = median(runs: 11, onThread: true) { for _ in 0..<10_000 { wrong += validator.violations(of: value).count } }
        expectEqual(wrong, 0, "every value fits its format")
        report(String(format: "10,000 notes of %d formats each through the validator %6.2f ms, %.3f µs a value", formats.count, ms, ms * 1000 / 10_000 / Double(formats.count)))
    },
])
