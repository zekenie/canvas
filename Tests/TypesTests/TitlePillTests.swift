import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Find
import Foundation
import Geometry
import TestKit
import Titles
import Types

// A note titled from its field shows no title pill (the type's chip alone, and the name in its row, folded or
// not), a title set by hand shows its pill as any title does, and Find says the name once, from the row.

private let person = FieldFixtures.namedPersonID, employee = FieldFixtures.namedEmployeeID
private let name = FieldPath(field: "name")
private let wide = ShapeID()

/// Counts how often a pill look is asked of a note, and says nothing.
@MainActor private final class LookCount {
    var asked = 0
}

private struct CountingLookPlugin: CanvasPlugin {
    let count: LookCount
    var id: PluginID { "counting-look" }
    func register(into registrar: inout PluginRegistrar) {
        let count = count
        registrar.forShapes(holding: IsAProperty.self) { scope in
            scope.titlePillLook { _, _, _ in
                count.asked += 1
                return nil
            }
        }
    }
}

/// Slips (which draw rows) and memos (which draw none) over the type plugins with Find, Person titled by its
/// name, Employee a Person, and a Wide of ten fields that is one too: twelve fields, the name folded.
@MainActor private struct Bench {
    let editor: CanvasEditor
    let scheduler = ManualScheduler()
    let count = LookCount()

    init() throws {
        var plugins = typePlugins()
        let types = try require(plugins.firstIndex { $0.id == .types }, "the types plugin")
        plugins.insert(FindPlugin(), at: types)
        plugins += [RowSlipsPlugin(), FieldFindPlugin(), TitleFindPlugin(), CountingLookPlugin(count: count)]
        editor = CanvasEditor(registry: try Registry(plugins: plugins), scheduler: scheduler)
        editor.addFieldSlips([FieldFixtures.namedPerson, FieldFixtures.namedEmployee])
        editor.addTypeLink(person, to: employee)
        let own = (1...10).map { "\"e\($0)\": { \"type\": \"string\" }" }.joined(separator: ", ")
        editor.addSlipType("{ \"type\": \"object\", \"properties\": { \(own) } }", title: "Wide", at: CGPoint(x: 1200, y: 40), id: wide)
        editor.addTypeLink(person, to: wide)
    }

    /// A slip that is each of the types, below the types.
    @discardableResult
    func slip(of types: [ShapeID], at origin: CGPoint = CGPoint(x: 40, y: 700), width: CGFloat = 240) -> ShapeID {
        editor.addSlip("", of: types, at: origin, width: width)
    }

    func type(_ text: String, into id: ShapeID) throws {
        try require(editor.fieldWriter).setTyped(text, as: .text, at: name, of: id)
    }

    func retitle(_ id: ShapeID, _ title: String?) {
        editor.transact("Rename") { $0.update(id) { $0[TitleProperty.self] = title } }
    }

    func pill(_ id: ShapeID) -> AdornmentLabel? { editor.adornmentFrames(of: id).first { $0.adornment == .of(TitlePill.self) }?.label }
    func chips(_ id: ShapeID) -> [String] { editor.adornmentFrames(of: id).filter { $0.adornment == .of(TypeChips.self) }.map { $0.label.text ?? "" } }

    @discardableResult
    func search(_ query: String) throws -> FindState {
        let find = try require(editor.find)
        if !find.isActive { find.open() }
        find.query = query
        while find.isIndexing { scheduler.advance(by: .zero) }
        _ = try awaitResult { await find.settled() }
        return find
    }
}

@MainActor let fieldTitlePillTests = Suite("The title from a field and its pill", [
    test("a note titled from its field has the chip alone; a title by hand shows its pill, and typing the name to match hides it again") {
        let t = try Bench()
        let ann = t.slip(of: [person])
        try t.type("Ann Lee", into: ann)
        expectEqual(t.editor.title(ann), "Ann Lee")
        expectEqual(t.pill(ann), nil, "the name is in its row")
        expectEqual(t.chips(ann), ["Person"])
        t.retitle(ann, "Annie")
        expectEqual(t.pill(ann)?.text, "Annie", "set by hand")
        try t.type("Annie", into: ann)
        expectEqual(t.editor.title(ann), "Annie")
        expectEqual(t.pill(ann), nil, "equal again, and following from here")
        try t.type("Anna", into: ann)
        expectEqual(t.editor.title(ann), "Anna")
        expectEqual(t.pill(ann), nil)
    },
    test("a note whose type has no working `$title`, a titled note with no type and a type's own note keep their pills; so does a memo, which draws no rows") {
        let t = try Bench()
        let plain = t.slip(of: [])
        t.retitle(plain, "Ann Lee")
        expectEqual(t.pill(plain)?.text, "Ann Lee")
        let memo = t.editor.add(memo("Ann"))
        t.editor.transact { $0.update(memo) { $0[IsAProperty.self] = [TypeLink(person)]; $0[FieldValuesProperty.self] = FieldValues(["name": "Ann Lee"]); $0[TitleProperty.self] = "Ann Lee" } }
        expectEqual(t.pill(memo)?.text, "Ann Lee", "a kind that draws no rows: nothing else says the name")
        expect(t.pill(person)?.text == "Person" && t.pill(employee)?.text == "Employee", "a type's pill, Employee's type note too (its `is` holds Person)")
        let bare = t.slip(of: [employee], at: CGPoint(x: 400, y: 700))
        t.retitle(bare, "Bo")
        expectEqual(t.pill(bare)?.text, "Bo", "a title that is not the field's value")
    },
    test("an Employee through Person's `$title`, and an Employee of twelve fields whose name is folded into `from Person`, show no pill; a ninth row on a type leaves its instances' pills hidden") {
        let t = try Bench()
        let bo = t.slip(of: [employee], at: CGPoint(x: 40, y: 700))
        try t.type("Bo Park", into: bo)
        expectEqual(t.editor.title(bo), "Bo Park")
        expectEqual(t.pill(bo), nil)
        let folded = t.slip(of: [wide], at: CGPoint(x: 700, y: 700))
        try t.type("Cy Day", into: folded)
        expectEqual(t.editor.title(folded), "Cy Day")
        let rows = try require(t.editor.rowBook).rows(of: folded)
        expect(rows.contains { $0.name.hasPrefix("from") }, "the name is in the fold: \(rows.map(\.name))")
        expect(!rows.contains { $0.name == "name" }, "and no row of its own")
        expectEqual(t.pill(folded), nil, "the fold is a place rows show")
        // Person gains fields until Employee passes eight rows and folds Person's.
        let more = (1...7).map { "\"p\($0)\": { \"type\": \"string\" }" }.joined(separator: ", ")
        let schema = "{ \"type\": \"object\", \"properties\": { \"name\": { \"type\": \"string\" }, \(more), \"$title\": { \"x-canvas-from\": \"name\" } } }"
        t.editor.transact("More") { $0.update(person) { $0[TypeSchemaProperty.self] = SchemaText(schema) } }
        expectEqual(t.pill(bo), nil, "still no pill, though the rows moved")
        expectEqual(t.pill(folded), nil)
    },
    test("changing the type's `$title` makes its instances' pills again with no commit on them, and it comes back after undo") {
        let t = try Bench()
        let ann = t.slip(of: [person])
        try t.type("Ann Lee", into: ann)
        expectEqual(t.pill(ann), nil)
        let revision = t.editor.revision
        let schema = try require(t.editor.schema(person)).replacingOccurrences(of: "\"name\" }", with: "\"email\" }")
        t.editor.transact("Retitle") { $0.update(person) { $0[TypeSchemaProperty.self] = SchemaText(schema) } }
        expectEqual(t.editor.revision, revision + 1, "one commit, on the type")
        expectEqual(t.editor.title(ann), "Ann Lee", "it is a copy: re-titled nobody")
        expectEqual(t.pill(ann)?.text, "Ann Lee", "no longer the field's value, so it shows as one set by hand")
        t.editor.undo()
        expectEqual(t.pill(ann), nil)
    },
    test("the cover zoomed out still says the name; the look is asked when the label is made, not again by a second draw") {
        let t = try Bench()
        let ann = t.slip(of: [person], at: CGPoint(x: 40, y: 700), width: 600)
        try t.type("Ann Lee", into: ann)
        _ = t.pill(ann)
        let asked = t.count.asked
        _ = t.pill(ann)
        _ = t.editor.adornmentFrames(of: ann)
        expectEqual(t.count.asked, asked, "the label is kept")
        t.editor.camera = Camera(origin: .zero, zoom: 0.3)
        expectEqual(t.editor.titleCover(of: ann)?.text, "Ann Lee")
    },
])

@MainActor let titleFindTests = Suite("Find and a title from a field", [
    test("the name is one hit, the row's; the folded Employee's is marked on the fold; a rename by hand adds the title's hit") {
        let t = try Bench()
        let ann = t.slip(of: [person])
        try t.type("Ann Lee", into: ann)
        let find = try t.search("lee")
        expectEqual(find.results.map(\.id), [ann])
        expectEqual(find.texts(of: ann), ["Ann Lee"], "the row's text alone")
        let folded = t.slip(of: [wide], at: CGPoint(x: 700, y: 700))
        try t.type("Cy Day", into: folded)
        let day = try t.search("day")
        expectEqual(day.results.map(\.id), [folded])
        expectEqual(day.texts(of: folded), ["Cy Day"], "one hit, the fold's")
        t.retitle(ann, "Annie")
        _ = try t.search("annie")
        expectEqual(find.texts(of: ann), ["Ann Lee", "Annie"], "set by hand: its pill is there to ring")
    },
    test("after the type drops `$title`, the title's text comes back with no commit on the note") {
        let t = try Bench()
        let ann = t.slip(of: [person])
        try t.type("Ann Lee", into: ann)
        let find = try t.search("lee")
        expectEqual(find.texts(of: ann), ["Ann Lee"])
        let bare = try require(t.editor.schema(person)).replacingOccurrences(of: ",\n    \"$title\": { \"x-canvas-from\": \"name\" }", with: "")
        expect(!bare.contains("$title"), "the schema is rewritten without it")
        t.editor.transact("Drop") { $0.update(person) { $0[TypeSchemaProperty.self] = SchemaText(bare) } }
        _ = try t.search("lee")
        expectEqual(find.texts(of: ann), ["Ann Lee", "Ann Lee"], "the row's, and the title's")
    },
])
