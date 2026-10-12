import AppKit
@_spi(Host) import Canvas
import Boards
import CanvasTesting
import CoreGraphics
import Foundation
import Geometry
import LanguageModels
import Locking
import Mentions
import ShippedTesting
import StickyNotes
import TestKit
import Titles
import Topology
import Types
import Validation

// What a pointer costs (`LinkPicker`, Types; [types](../../.claude/rules/types.md)): the list over a pointer's field,
// the notes of the type on any board ranked as the `@` picker ranks them. The thread's CPU time, release;
// `./build.sh bench` holds the budgets and `./test.sh` only reports them.

extension Budget {
    /// A keystroke in the list over a pointer's field, the one that opens it included, over a file of 10,000 shapes: (a) a
    /// thousand Persons on two boards, (b) six Persons, all on the other board. `among:` is the cheap path: the set of the
    /// type's notes (`affected(by:)`, O(their number)) and two passes over it, so it costs what the type has, not the file.
    /// The `@` picker's.
    static let linkPickerKeystroke = pickerKeystroke
    /// Topology's index (and Mentions' catalog) built as a file of 10,000 shapes opens where 1,000 notes hold a pointer and a list
    /// of two (the `field-link` source walks each one's values), over the same file with those values as plain text of the same
    /// length: one dictionary hit for `fieldValues` a typeable note, a walk of the values of one that has them, a 2-byte test a
    /// string. -0.20, +0.25 and -0.12 ms over an index of some 24 ms (release, wall clock, load average 5.2 to 5.8): below what a
    /// run moves by, held at the design's 5 ms.
    static let linkEdgesOpen = 5.0
    /// A frame of 150 Orders with a customer and two guests (450 pills) in full at 40%, over the same with the same names as plain
    /// text: +2.27, +1.95 and +1.94 ms (34.4 ms a frame in all; release, the thread's CPU, three runs alone at a load average of
    /// 3.5), some 4.5 µs a pill: the target looked up, the kept text found (`MentionTextMemo`), the pill's fill, hairline and label
    /// drawn straight into the context. The design's 5 ms, two and a half times the median. It was +14.0, +13.5 and +13.9 (31 µs a
    /// pill, a budget of 45) while each pill was an attachment's image, which string drawing draws into a bitmap of its own
    /// and then draws that, each frame, and the row wrote its token and read it again at each draw.
    static let linkRowsFrame = 5.0
    /// Renaming a Person 1,000 Orders point at, the commit, Validation's read after it and the frame after, over renaming a
    /// Person nobody points at: +23.8, +28.3 and +25.3 ms (release, the thread's CPU, load average 5.2 to 5.8), of which the commit
    /// is 1.1 (0.4 for the other), Validation's read 22 (the 1,000 carriers rechecked by every rule, some 22 µs a shape against the
    /// 5 µs of a first read's, the pointers' part a small share of it) and the frame some 11 (the carriers in view build their
    /// rows and pills again). Three times the median: the design's 10 ms does not hold.
    static let linkTargetRename = 75.0
    /// A keystroke in the words of that Person that leaves its name (its second line), the commit and Validation's read after
    /// it, over the same keystroke in a Person nobody points at: +0.006, -0.004 and +0.004 ms (of 0.05 at 100 Orders and 0.22 at
    /// 1,000): one state read and a compare of the target's state, and nothing is let go. `fieldChecksKeystroke`'s.
    static let linkTargetEdit = fieldChecksKeystroke
}

/// A file of two boards (`size` shapes in all) with `persons` of its plain, named notes made Persons, `onChild` of them
/// on the second board; the type is the first type note of the root, titled `Person`.
@MainActor private func personFile(shapes size: Int, persons: Int, onChild: Int) -> (file: CanvasFile, type: ShapeID, owner: ShapeID) {
    let file = generatedFile(root: size / 2, children: [size / 2])
    let names = ["Ann Lee", "Anders Holm", "Dana Novak", "Bo Park", "Fay Ng", "Cy Lin"]
    var type: ShapeID?, owner: ShapeID?
    var made = (root: 0, child: 0)
    func convert(_ document: CanvasDocument, isChild: Bool) -> CanvasDocument {
        CanvasDocument(shapes: document.shapes.map { record in
            var record = record
            if record.kind == StickyNote.kind, record[TypeSchemaProperty.self] != nil {
                if !isChild, type == nil {
                    type = record.id
                    record[TitleProperty.self] = "Person"
                }
            } else if record.kind == StickyNote.kind, record[LockedProperty.self] != true {
                let wanted = isChild ? onChild : persons - onChild
                let count = isChild ? made.child : made.root
                if count < wanted, let type {
                    record[IsAProperty.self] = [TypeLink(type)]
                    record[TitleProperty.self] = "\(names[count % names.count]) \(count)"
                    if isChild { made.child += 1 } else { made.root += 1 }
                } else if !isChild, owner == nil {
                    owner = record.id
                }
            }
            return record
        })
    }
    let root = convert(file.root, isChild: false)
    let children = file.children.mapValues { convert($0, isChild: true) }
    return (CanvasFile(root: root, children: children), type!, owner!)
}

@MainActor let pointerBenchmarks = Suite("Pointer benchmarks", [
    test("a keystroke in the list over a pointer's field, the one that opens it included, costs the type's notes, not the file: a thousand Persons on two boards, six on the other board") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let registry = try Registry(plugins: shippedPlugins(pasteboard))
        for size in sizes {
            var lines: [String] = []
            var worst = 0.0
            for (label, persons, onChild) in [("a thousand on two boards", min(1_000, size / 10), min(500, size / 20)), ("six, all on the other board", 6, 6)] {
                let made = personFile(shapes: size, persons: persons, onChild: onChild)
                let editor = CanvasEditor(registry: registry, file: made.file, scheduler: ManualScheduler())
                let opening = median(runs: 21, onThread: true) { _ = LinkPicker(editor: editor, owner: made.owner, type: made.type) }
                let picker = LinkPicker(editor: editor, owner: made.owner, type: made.type)
                expectEqual(picker.choices.count, min(persons, 50), "the Persons, on any board, from the first keystroke (a list shows at most 50)")
                var slowest = (query: "", ms: opening)
                for query in ["a", "an", "ann", "ann l", "zzq", "paln"] {
                    let before = String(query.dropLast())
                    let ms = median(runs: 21, prepare: { picker.setQuery(before) }, onThread: true) { picker.setQuery(query) }
                    if ms > slowest.ms { slowest = (query, ms) }
                }
                picker.setQuery("ann")
                expect(!picker.choices.isEmpty, "a typed query ranks the type's notes")
                lines.append(String(format: "%@: open %6.3f ms, the slowest keystroke %6.3f ms (\"%@\")", label, opening, slowest.ms, slowest.query))
                worst = max(worst, opening, slowest.ms)
            }
            report(String(format: "%6d shapes, the list over a pointer's field, %@ (budget %.0f)", size, lines.joined(separator: "; "), Budget.linkPickerKeystroke))
            if holdsToBudgets { expect(worst < Budget.linkPickerKeystroke, "a keystroke in the list over \(size) shapes took \(worst) ms") }
        }
    },
])

// MARK: What pointers cost in a file

/// The generated board with `typed` of its plain notes made Orders (a customer, two guests), and four Persons: Ann Lee, Bo Park and Cy Lin,
/// whom the Orders point at (the customer Ann, the guests Bo and Cy), and Lonely, whom no one does. `links` says whether
/// the values are pointers (tokens) or plain text as long as a token.
@MainActor private func orderBoard(shapes size: Int, typed: Int, links: Bool) -> (document: CanvasDocument, orders: [ShapeID], ann: ShapeID, lonely: ShapeID) {
    var shapes = generatedBoard(shapes: size).shapes
    let person = ShapeID(), order = ShapeID()
    let schema = FieldKind.pointerSchema(to: person)
    func typeNote(_ id: ShapeID, _ title: String, _ text: String) -> AnyShapeRecord {
        var note = ShapeRecord(id: id, StickyNote(frame: CGRect(x: -900, y: id == person ? 0 : 300, width: 200, height: 200), text: MentionText(plain: title)))
        note[TypeSchemaProperty.self] = SchemaText(text)
        note[TitleProperty.self] = title
        return AnyShapeRecord(note)
    }
    let ids = (ann: ShapeID(), bo: ShapeID(), cy: ShapeID(), lonely: ShapeID())
    var people: [AnyShapeRecord] = []
    for (place, (id, name)) in [(ids.ann, "Ann Lee"), (ids.bo, "Bo Park"), (ids.cy, "Cy Lin"), (ids.lonely, "Lonely")].enumerated() {
        var note = ShapeRecord(id: id, StickyNote(frame: CGRect(x: -900 + CGFloat(place) * 220, y: 600, width: 200, height: 200), text: MentionText(plain: name)))
        note[IsAProperty.self] = [TypeLink(person)]
        note[TitleProperty.self] = name
        people.append(AnyShapeRecord(note))
    }
    let pointer = String(decoding: try! JSONEncoder().encode(schema), as: UTF8.self)
    shapes.append(typeNote(person, "Person", #"{"type": "object", "properties": {"name": {"type": "string"}}}"#))
    shapes.append(typeNote(order, "Order", #"{"type": "object", "properties": {"customer": \#(pointer), "guests": {"type": "array", "items": \#(pointer)}}}"#))
    shapes += people
    func value(_ id: ShapeID, _ name: String) -> JSONValue {
        let token = FieldLink(target: id, stored: name).value
        return links ? token : .string(String(repeating: "x", count: token.stringValue?.count ?? 0))
    }
    var orders: [ShapeID] = []
    for index in shapes.indices where shapes[index].kind == StickyNote.kind && shapes[index][TypeSchemaProperty.self] == nil && shapes[index][IsAProperty.self] == nil {
        guard orders.count < typed else { break }
        shapes[index][IsAProperty.self] = [TypeLink(order)]
        shapes[index][FieldValuesProperty.self] = FieldValues(["customer": value(ids.ann, "Ann Lee"), "guests": .array([value(ids.bo, "Bo Park"), value(ids.cy, "Cy Lin")])])
        orders.append(shapes[index].id)
    }
    return (CanvasDocument(shapes: shapes), orders, ids.ann, ids.lonely)
}

@MainActor let pointerFileBenchmarks = Suite("Pointer file benchmarks", [
    test("Topology's index of a file where 1,000 notes hold a pointer and a list of two costs little more than the same file with those values as text") {
        let codec = BoardCodec(registry: try ShippedPlugins.registry(model: ScriptedLanguageModel()))
        for size in sizes {
            @MainActor func index(links: Bool) throws -> Double {
                let board = orderBoard(shapes: size, typed: min(1_000, size / 10), links: links)
                let data = try codec.encode(board.document)
                let watch = Stopwatch()
                let timed = try Registry(plugins: pluginsTimingMentions(watch))
                var times: [Double] = []
                for _ in 0..<7 {
                    let editor = CanvasEditor(registry: timed, document: try codec.decode(data).document, scheduler: ManualScheduler())
                    times.append(watch.milliseconds)
                    if links { expectEqual(editor.topology?.edges(of: board.ann, .incoming, types: .only(FieldLinkEdge.id)).count, board.orders.count) }
                }
                return times.sorted()[times.count / 2]
            }
            let links = try index(links: true), text = try index(links: false)
            report(String(format: "%6d shapes, %d notes holding a pointer and a list of two: Topology's index and Mentions' catalog %6.2f ms, %6.2f over the same file with the values as text (budget %.0f)",
                          size, min(1_000, size / 10), links, links - text, Budget.linkEdgesOpen))
            if holdsToBudgets, size >= 10_000 { expect(links - text < Budget.linkEdgesOpen, "the field-link edges of \(size) shapes added \(links - text) ms to opening") }
        }
    },
    test("a frame of 150 Orders with a pointer and a list of two in full at 40% costs little more than the same with the names as text") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let viewport = CGSize(width: 2_100, height: 1_000)
        @MainActor func frame(links: Bool) throws -> Double {
            let board = orderBoard(shapes: 300, typed: 150, links: links)
            // The Orders are the first 150 plain notes of a 300-shape board: its columns are 300 apart, so they sit in the top rows.
            let editor = CanvasEditor(registry: try Registry(plugins: shippedPlugins(pasteboard)), document: board.document, scheduler: ManualScheduler())
            editor.viewportDidResize(to: viewport)
            editor.camera = Camera(origin: CGPoint(x: 0, y: 0), zoom: 0.4)
            let context = try bitmapContext(viewport)
            draw(editor, into: context, size: viewport)
            draw(editor, into: context, size: viewport)
            var step = 0.0
            return median(runs: 11, prepare: { step = step == 0 ? 1 : 0; editor.camera = Camera(origin: CGPoint(x: step / 0.4, y: 0), zoom: 0.4) }, onThread: true) {
                draw(editor, into: context, size: viewport)
            }
        }
        let withLinks = try frame(links: true), withText = try frame(links: false)
        report(String(format: "150 Orders, a pointer and a list of two each (450 pills), in full at 40%%: a frame %5.2f ms, %5.2f more than the same with the names as text (%5.2f) (budget %.0f more)",
                      withLinks, withLinks - withText, withText, Budget.linkRowsFrame))
        if holdsToBudgets { expect(withLinks - withText < Budget.linkRowsFrame, "450 pills added \(withLinks - withText) ms to a frame") }
    },
    test("renaming a Person 1,000 Orders point at, the commit, Validation's read after it and the frame after, costs little more than renaming one nobody does; a keystroke in its words that leaves its name costs nothing more") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        for size in sizes {
            let board = orderBoard(shapes: size, typed: min(1_000, size / 10), links: true)
            let editor = CanvasEditor(registry: try Registry(plugins: shippedPlugins(pasteboard)), document: board.document, scheduler: ManualScheduler())
            editor.viewportDidResize(to: viewport)
            let target = board.orders[board.orders.count / 2]
            let frame = try require(editor.shapeContext.frame(of: target))
            editor.camera = camera(centering: frame, at: 0.4, in: viewport)
            _ = editor.validation?.results
            draw(editor, into: context, size: viewport)
            // Every Order's answer is made and kept, as Validation's first read makes them.
            expectEqual(editor.validation?.results.isEmpty, true, "no Order is wrong or warned")
            var n = 0
            let pointedAt = median(runs: 21, prepare: { n += 1 }, onThread: true) {
                editor.transact("Rename") { $0.update(board.ann) { $0[TitleProperty.self] = "Name \(n)" } }
                _ = editor.validation?.results
                draw(editor, into: context, size: viewport)
            }
            let alone = median(runs: 21, prepare: { n += 1 }, onThread: true) {
                editor.transact("Rename") { $0.update(board.lonely) { $0[TitleProperty.self] = "Name \(n)" } }
                _ = editor.validation?.results
                draw(editor, into: context, size: viewport)
            }
            let edit = median(runs: 31, prepare: { n += 1 }, onThread: true) {
                editor.transact("Type") { $0.update(board.ann, as: StickyNote.self) { $0.props.text = MentionText(plain: "Name\nline \(n)") } }
                _ = editor.validation?.results
            }
            let editAlone = median(runs: 31, prepare: { n += 1 }, onThread: true) {
                editor.transact("Type") { $0.update(board.lonely, as: StickyNote.self) { $0.props.text = MentionText(plain: "Name\nline \(n)") } }
                _ = editor.validation?.results
            }
            #if DEBUG
            let linkChecks = editor.fieldChecks?.linkChecksMade
            editor.transact("Type") { $0.update(board.ann, as: StickyNote.self) { $0.props.text = MentionText(plain: "Name\nlast line") } }
            _ = editor.validation?.results
            expectEqual(editor.fieldChecks?.linkChecksMade, linkChecks, "a keystroke below the name checks no pointer again")
            #endif
            report(String(format: "%6d shapes, %d Orders point at the Person: renaming it, the commit, Validation's read and the frame %6.2f ms, %6.2f more than one nobody points at (budget %.0f); a keystroke in its words %6.3f ms, %6.3f more than in one nobody points at (budget %.1f)",
                          size, board.orders.count, pointedAt, pointedAt - alone, Budget.linkTargetRename, edit, edit - editAlone, Budget.linkTargetEdit))
            if holdsToBudgets, size >= 10_000 {
                expect(pointedAt - alone < Budget.linkTargetRename, "renaming a target of \(board.orders.count) pointers cost \(pointedAt - alone) ms more")
                expect(edit - editAlone < Budget.linkTargetEdit, "a keystroke in a target's words cost \(edit - editAlone) ms more")
            }
        }
    },
])
