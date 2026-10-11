import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Find
import Foundation
import Geometry
import TestKit
import Types

// ⌘F finding a value (`FieldFindPlugin`): the texts a note that is one shows in its rows, found, each hit
// marking its row's value; a value in a row with more in it marks that row, a folded one the fold; and
// the instances of a type that changed are read against the type as it is, in the commit's own turn.

/// What the last commit changed, for a test to hold a drag's change set up to the book.
@MainActor
private final class ChangeProbe {
    var last: ChangeSet?
}

private struct ChangeProbePlugin: CanvasPlugin {
    let probe: ChangeProbe
    var id: PluginID { "change-probe" }
    func register(into registrar: inout PluginRegistrar) {
        let probe = probe
        registrar.service { _ in ProbeService(probe: probe) }
    }
}

@MainActor
private final class ProbeService {
    let probe: ChangeProbe
    init(probe: ChangeProbe) { self.probe = probe }
}

extension ProbeService: EditorService {
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) { probe.last = changes }
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {}
}

/// An editor over the type plugins with Find ahead of Types, where the shipped list has it, then slips and
/// the field values' plugin.
@MainActor
private struct Bench {
    let editor: CanvasEditor
    let scheduler = ManualScheduler()
    let probe = ChangeProbe()
    var book: RowBook { editor.rowBook! }

    init() throws {
        var plugins = typePlugins()
        let types = try require(plugins.firstIndex { $0.id == .types }, "the types plugin")
        plugins.insert(FindPlugin(), at: types)
        plugins += [RowSlipsPlugin(), FieldFindPlugin(), ChangeProbePlugin(probe: probe)]
        editor = CanvasEditor(registry: try Registry(plugins: plugins), scheduler: scheduler)
    }

    @discardableResult
    func add(_ types: [FieldFixtures.TypeText]) -> [ShapeID] { editor.addFieldSlips(types) }

    /// A slip that is each of the types, below the types, holding these values.
    @discardableResult
    func note(_ types: [ShapeID], _ values: JSONObject = [:], at origin: CGPoint = CGPoint(x: 40, y: 600)) -> ShapeID {
        let id = editor.addSlip("Note", of: types, at: origin)
        set(id, values)
        return id
    }

    func set(_ id: ShapeID, _ values: JSONObject) {
        editor.transact { $0.update(id) { $0[FieldValuesProperty.self] = FieldValues(values) } }
    }

    func row(_ id: ShapeID, _ name: String) throws -> ShownRow {
        try require(book.rows(of: id).first { $0.name == name }, "a row \(name)")
    }

    /// Opens Find on `query` and waits for its answer.
    @discardableResult
    func search(_ query: String) throws -> FindState {
        let find = try require(editor.find)
        if !find.isActive { find.open() }
        find.query = query
        while find.isIndexing { scheduler.advance(by: .zero) }
        _ = try awaitResult { await find.settled() }
        return find
    }

    /// The current hit's marks, world units.
    func marks(_ find: FindState, in id: ShapeID) throws -> [CGRect] {
        find.rects(of: try require(find.currentHit?.hit, "a hit"), in: id)
    }
}

/// Whether a mark lies on a row.
private func lies(_ mark: CGRect, on row: ShownRow) -> Bool { row.rect.insetBy(dx: -2.5, dy: -1).contains(mark) }

@MainActor let fieldFindTests = Suite("Field values for Find", [
    test("a plain value is found, and its mark is on its row's value") {
        let t = try Bench()
        t.add([FieldFixtures.person])
        let id = t.note([FieldFixtures.personID], ["name": "Ann Lee", "email": "ann@acme.com"])
        let find = try t.search("lee")
        expectEqual(find.results.map(\.id), [id])
        expectEqual(find.texts(of: id), ["Ann Lee", "ann@acme.com"])
        let name = try t.row(id, "name")
        let marks = try t.marks(find, in: id)
        expectEqual(marks.count, 1)
        let mark = try require(marks.first)
        expect(lies(mark, on: name), "on the name row: \(mark) in \(name.rect)")
        expect(mark.contains(CGPoint(x: name.valueRect.minX + 4, y: name.rect.midY)), "round the value")
        expect(mark.minX >= name.valueRect.minX - TypesStyle.fieldFocusOutset - 0.5, "and not over the name")
        _ = try t.search("acme")
        expect(try t.marks(find, in: id).first.map { lies($0, on: try t.row(id, "email")) } == true, "the email's row")
    },
    test("a value inside a group, a list of groups, pairs, a list, an either and a thing no control suits is found on the row that holds it") {
        let t = try Bench()
        t.add([FieldFixtures.address, FieldFixtures.order, FieldFixtures.everyKind.a, FieldFixtures.everyKind.b])
        let a = t.note([FieldFixtures.kindsAID], ["venue": ["name": "The Loft", "city": "Leeds"], "tags": ["gift", "candles"],
                                                  "shippingAddress": ["street": "12 Main St"]], at: CGPoint(x: 40, y: 700))
        let b = t.note([FieldFixtures.kindsBID], ["labels": ["size": "L", "colour": "red"], "payment": ["cardNumber": "4111"],
                                                  "anything": ["note": "hello there"]], at: CGPoint(x: 440, y: 700))
        let o = t.note([FieldFixtures.orderID], ["lineItems": [["product": "Mug", "quantity": 2], ["product": "Plate", "quantity": 1]]],
                       at: CGPoint(x: 840, y: 700))
        for (query, id, name) in [("loft", a, "venue"), ("candles", a, "tags"), ("main", a, "shipping address"), ("colour", b, "labels"),
                                  ("red", b, "labels"), ("4111", b, "payment"), ("hello", b, "anything"), ("plate", o, "line items")] {
            let find = try t.search(query)
            expectEqual(find.results.map(\.id), [id], query)
            let mark = try require(try t.marks(find, in: id).first, query)
            expect(lies(mark, on: try t.row(id, name)), "\(query) marks the \(name) row")
        }
    },
    test("a field that is folded is found on the fold: `+12 more` at the left") {
        let t = try Bench()
        t.add([FieldFixtures.wide(20)])
        let id = t.note([FieldFixtures.wideID], ["f15": "needle", "f2": "thread"])
        var find = try t.search("needle")
        expectEqual(find.results.map(\.id), [id])
        let fold = try t.row(id, "+12 more")
        var mark = try require(try t.marks(find, in: id).first)
        expect(lies(mark, on: fold), "on the fold: \(mark) in \(fold.rect)")
        expect(mark.minX < fold.rect.minX + 8, "from the left edge, where the fold's words are")
        find = try t.search("thread")
        mark = try require(try t.marks(find, in: id).first)
        expect(lies(mark, on: try t.row(id, "f2")), "a row that is shown is marked itself")
    },
    test("a yes or no has no text, a type's own note holds nothing to find, and a kind that says nowhere its rows go is not read") {
        let t = try Bench()
        let types = t.add([FieldFixtures.everyKind.a, FieldFixtures.person])
        let box = t.note([FieldFixtures.kindsAID], ["done": true], at: CGPoint(x: 40, y: 700))
        let find = try t.search("yes")
        expectEqual(find.results.map(\.id), [])
        expectEqual(find.texts(of: box), [])
        // Values held by a type's note are not its rows'.
        t.set(types[0], ["name": "Ann Lee"])
        expectEqual(try t.search("lee").results.map(\.id), [])
        expectEqual(find.texts(of: types[0]), [])
        // A memo that is a Person says nowhere its rows go.
        let plain = t.editor.add(memo("Ann Lee"))
        t.editor.transact { $0.update(plain) { $0[IsAProperty.self] = [TypeLink(FieldFixtures.personID)]; $0[FieldValuesProperty.self] = FieldValues(["name": "Ann Lee"]) } }
        expectEqual(try t.search("lee").results.map(\.id), [])
        expectEqual(find.texts(of: plain), [])
        expectEqual(find.indexedShapes, 0)
    },
    test("a date is found as it is shown, a number by its value, a choice by its label") {
        let t = try Bench()
        t.add([FieldFixtures.everyKind.a])
        let id = t.note([FieldFixtures.kindsAID], ["due": "2026-03-03", "price": 9.5, "status": "paid"])
        let due = FieldText.shown(.string("2026-03-03"), as: .date)
        let find = try t.search(due)
        expectEqual(find.results.map(\.id), [id])
        expectEqual(find.texts(of: id), ["9.5", due, "paid"])
    },
    test("after a type's field turns from Text to Date, an instance that did not change is found as the date, in the commit's own turn, and the layout is announced once") {
        let t = try Bench()
        let event = ShapeID()
        let text = #"{"type": "object", "properties": {"when": {"type": "string"}}}"#
        let date = #"{"type": "object", "properties": {"when": {"type": "string", "format": "date"}}}"#
        t.editor.addSlipType(text, title: "Event", at: CGPoint(x: 40, y: 40), id: event)
        let id = t.note([event], ["when": "2026-03-03"])
        let find = try t.search("2026")
        expectEqual(find.texts(of: id), ["2026-03-03"])
        let shown = FieldText.shown(.string("2026-03-03"), as: .date)
        expect(shown != "2026-03-03", "a date reads otherwise than it is stored")
        let layouts = t.editor.layoutRevision
        t.editor.transact("Date") { $0.update(event) { $0[TypeSchemaProperty.self] = SchemaText(date) } }
        expectEqual(find.texts(of: id), [shown], "the instance is read against the type as it is now, in this very commit")
        expectEqual(t.editor.layoutRevision, layouts + 1, "announced once, not twice")
        t.editor.undo()
        expectEqual(find.texts(of: id), ["2026-03-03"], "and as it was, after undo")
    },
    test("a drag names nothing, wakes nothing, and has the index hear nothing early") {
        let t = try Bench()
        t.add([FieldFixtures.person])
        let id = t.note([FieldFixtures.personID], ["name": "Ann Lee"])
        _ = try t.search("lee")
        let reads = try require(t.editor.types).recordsRead
        let layouts = t.editor.layoutRevision
        t.editor.transact("Move") { $0.translate([id], by: CGPoint(x: 10, y: 10)) }
        let drag = try require(t.probe.last)
        expect(drag.added.isEmpty && drag.removed.isEmpty && drag.elsewhere.isEmpty && drag.changed == drag.moved, "a drag's change set")
        expectEqual(t.book.reached(by: drag), [])
        expectEqual(try require(t.editor.types).recordsRead, reads, "no type read")
        expectEqual(t.editor.layoutRevision, layouts)
        // A change to a value names no instance either: no type changed.
        t.set(id, ["name": "Ann Leigh"])
        expectEqual(try require(t.probe.last).changed, [id])
        expectEqual(t.book.reached(by: try require(t.probe.last)), [])
        expectEqual(try t.search("leigh").results.map(\.id), [id], "and the value is read again")
    },
])
