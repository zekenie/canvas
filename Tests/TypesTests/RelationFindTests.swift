import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Find
import Foundation
import Geometry
import Mentions
import TestKit
import Titles
import Types

// ⌘F over a relationship: the values an arrow holds are found on the arrow, the hit marks the relationship's chip (the values are
// shown nowhere on the board, and the chip opens them), and a row's pills are not searched (the note a pill names is found on its own).

private let employmentSchema = #"{"type": "object", "properties": {"role": {"type": "string"}, "since": {"type": "string", "format": "date"}}}"#

/// Find ahead of Types, as the shipped list has it, then slips, bonds and the field values' plugin.
@MainActor
private struct Bench {
    let editor: CanvasEditor
    let scheduler = ManualScheduler()
    let person: ShapeID, company: ShapeID, employment: ShapeID
    let ann: ShapeID, acme: ShapeID, job: ShapeID

    init() throws {
        var plugins = typePlugins()
        let types = try require(plugins.firstIndex { $0.id == .types }, "the types plugin")
        plugins.insert(FindPlugin(), at: types)
        plugins += [RowSlipsPlugin(), BondsPlugin(), RelaysPlugin(), PocketsPlugin(), FieldFindPlugin()]
        editor = CanvasEditor(registry: try Registry(plugins: plugins), scheduler: scheduler)
        editor.viewportDidResize(to: CGSize(width: 1200, height: 900))
        person = editor.addSlipType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 40, y: 40))
        company = editor.addSlipType(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 440, y: 40))
        let relationship = editor.addRelationshipType("Employment", at: CGPoint(x: 240, y: 40))
        employment = relationship
        editor.transact { $0.update(relationship) { $0[TypeSchemaProperty.self] = SchemaText(employmentSchema) } }
        editor.addBond(person, employment, name: "jobs")
        editor.addBond(employment, company, name: "staff")
        ann = editor.addSlip("Ann", of: [person], at: CGPoint(x: 40, y: 500))
        acme = editor.addSlip("Acme", of: [company], at: CGPoint(x: 640, y: 700))
        job = editor.addBond(ann, acme, of: [employment])
    }

    func set(_ id: ShapeID, _ values: JSONObject) {
        editor.transact { $0.update(id) { $0[FieldValuesProperty.self] = FieldValues(values) } }
    }

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

@MainActor let relationFindTests = Suite("Field values for Find, on an arrow", [
    test("a relationship's values are found on its arrow, one text for each field that has a value, and the hit marks the relationship's pill") {
        let b = try Bench()
        b.set(b.job, ["role": "Staff engineer", "since": "2021-03-01"])
        let find = try b.search("engineer")
        expectEqual(find.results.map(\.id), [b.job])
        expectEqual(find.texts(of: b.job), ["Staff engineer", "Mar 1, 2021"])
        let marks = find.rects(of: try require(find.currentHit?.hit, "a hit"), in: b.job)
        expectEqual(marks.count, 1)
        let mark = try require(marks.first)
        let bounds = try require(b.editor.shapeContext.geometry(of: b.job)?.bounds)
        let chip = try require(b.editor.adornmentFrames(of: b.job).first { $0.adornment == .of(RelationshipPill.self) }, "the relationship's pill").rect
        _ = bounds
        expect(abs(mark.minX - chip.minX) < 0.5 && abs(mark.minY - chip.minY) < 0.5 && abs(mark.width - chip.width) < 0.5,
               "the mark is the chip: \(mark) against \(chip)")
        _ = try b.search("2021")
        expectEqual(find.results.map(\.id), [b.job])
        _ = try b.search("nothing of the sort")
        expectEqual(find.results.map(\.id), [])
    },
    test("the mark on a relationship's pill follows the zoom, as the pill does: it is the label's, in world units") {
        let b = try Bench()
        b.set(b.job, ["role": "Staff engineer"])
        let find = try b.search("engineer")
        let hit = try require(find.currentHit?.hit, "a hit")
        _ = find.rects(of: hit, in: b.job)
        b.editor.camera = Camera(origin: .zero, zoom: 2)
        let mark = try require(find.rects(of: hit, in: b.job).first)
        let chip = try require(b.editor.adornmentFrames(of: b.job).first { $0.adornment == .of(RelationshipPill.self) }, "the pill").rect
        expect(abs(mark.minX - chip.minX) < 0.5 && abs(mark.width - chip.width) < 0.5,
               "at 200% the mark is the pill as it is there: \(mark) against \(chip)")
    },
    test("an edit finds the new value, a value taken away finds nothing, and Undo finds it again") {
        let b = try Bench()
        b.set(b.job, ["role": "Staff engineer"])
        var find = try b.search("engineer")
        expectEqual(find.results.map(\.id), [b.job])
        b.set(b.job, ["role": "Designer"])
        find = try b.search("engineer")
        expectEqual(find.results.map(\.id), [])
        find = try b.search("designer")
        expectEqual(find.results.map(\.id), [b.job])
        b.editor.undo()
        find = try b.search("engineer")
        expectEqual(find.results.map(\.id), [b.job])
    },
    test("a row's pills are not searched: the note a pill names is found once, on the note, and not on the notes whose rows show its pill") {
        let b = try Bench()
        let named = #"{"type": "object", "properties": {"name": {"type": "string"}}}"#
        b.editor.transact { transaction in
            transaction.update(b.company) { $0[TypeSchemaProperty.self] = SchemaText(named) }
        }
        b.set(b.acme, ["name": "Acme Corp"])
        b.set(b.job, ["role": "Staff engineer"])
        // Ann's row shows a pill for Acme and Acme's row a pill for Ann.
        expectEqual(try b.search("acme corp").results.map(\.id), [b.acme])
        expectEqual(try b.search("ann").results.map(\.id), [], "a note's name is no value of its arrow")
    },
    test("a field added to the relationship type makes the values already on an arrow found, with no commit to the arrow") {
        let b = try Bench()
        b.set(b.job, ["role": "Staff engineer", "team": "Platform"])
        var find = try b.search("platform")
        expectEqual(find.results.map(\.id), [], "no field names a team yet")
        let withTeam = #"{"type": "object", "properties": {"role": {"type": "string"}, "team": {"type": "string"}}}"#
        b.editor.transact { $0.update(b.employment) { $0[TypeSchemaProperty.self] = SchemaText(withTeam) } }
        find = try b.search("platform")
        expectEqual(find.results.map(\.id), [b.job])
    },
])
