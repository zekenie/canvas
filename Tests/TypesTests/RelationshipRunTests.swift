@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Draw
import Foundation
import Mentions
import TestKit
import Titles
import Topology
import Types
import Validation

// A run's own graph: what a transaction that has not committed says of relationships, from the ends, the
// types and the lists it wrote itself (`RelationshipIndex.graph(in:)`), kept as the run goes on, and the
// check of an arrow over it (`FieldChecks.check(of:reading:)`). Over bonds.

private let employmentWords = "Employment runs to a Company. “foundation” is a Layer."

/// A run's records: the types, the relationship type and its ends, the notes and the arrows, as a script writes them.
@MainActor private struct Run {
    let person = ShapeID(), company = ShapeID(), layer = ShapeID(), employment = ShapeID()
    let fromEnd = ShapeID(), toEnd = ShapeID()
    let ann = ShapeID(), acme = ShapeID(), foundation = ShapeID(), job = ShapeID(), misfit = ShapeID()

    func records() -> [AnyShapeRecord] {
        var related = slipTypeRecord(TypeSchemaProperty.starter, title: "Employment", at: CGPoint(x: 400, y: 40), id: employment)
        related[RelationshipProperty.self] = true
        func arrow(_ id: ShapeID, _ from: ShapeID, _ to: ShapeID, of types: [ShapeID] = []) -> AnyShapeRecord {
            var record = AnyShapeRecord(ShapeRecord(id: id, Bond(from: from, to: to)))
            if !types.isEmpty { record[IsAProperty.self] = types.map(TypeLink.init) }
            return record
        }
        return [typeRecord(TypeSchemaProperty.starter, title: "Person", id: person),
                typeRecord(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 40, y: 200), id: company),
                typeRecord(TypeSchemaProperty.starter, title: "Layer", at: CGPoint(x: 40, y: 360), id: layer),
                related,
                instanceRecord("Ann", of: [person], at: CGPoint(x: 500, y: 400), id: ann),
                instanceRecord("Acme", of: [company], at: CGPoint(x: 800, y: 400), id: acme),
                instanceRecord("foundation", of: [layer], at: CGPoint(x: 800, y: 700), id: foundation),
                arrow(fromEnd, person, employment), arrow(toEnd, employment, company),
                arrow(job, ann, acme, of: [employment]), arrow(misfit, ann, foundation, of: [employment])]
    }
}

@MainActor private func said(_ editor: CanvasEditor, _ record: AnyShapeRecord?, in reading: LayoutReading?) -> [String] {
    guard let record, let reading, let checks = editor.fieldChecks else { return ["no reading"] }
    return checks.check(of: record, reading: reading).problems.map(\.message)
}

@MainActor private func says(_ editor: CanvasEditor, _ record: AnyShapeRecord?, in transaction: Transaction) -> [String] {
    said(editor, record, in: transaction.shapes.reading)
}

@MainActor private func relationArrows(_ relationships: RelationshipIndex, of note: ShapeID, in transaction: Transaction) -> [ShapeID] {
    transaction.shapes.reading.map { relationships.relations(of: note, in: $0).map(\.arrow) } ?? []
}

@MainActor let relationshipRunTests = Suite("A run's own graph", [
    test("a run that writes a relationship type, its ends and the notes in one transaction judges an arrow by them, with nothing committed") {
        let editor = try bondEditor()
        let run = Run()
        var verdicts: [[String]] = []
        var sides: (from: Int, to: Int)?
        var committed: Bool?
        editor.transact("Run") { transaction in
            for record in run.records() { transaction.insert(record) }
            guard let reading = transaction.shapes.reading, let relationships = editor.relationships else { return }
            let graph = relationships.graph(in: reading)
            sides = (graph.sides(of: run.employment).from.count, graph.sides(of: run.employment).to.count)
            committed = relationships.graph.isRelationshipType(run.employment)
            verdicts = [run.job, run.misfit].map { said(editor, transaction.document[$0], in: reading) }
        }
        expectEqual(committed, false, "the committed index knows none of it")
        expectEqual(sides?.from, 1, "the run's from end")
        expectEqual(sides?.to, 1, "the run's to end")
        expectEqual(verdicts[0], [], "Ann works for Acme: it fits")
        expectEqual(verdicts[1], [employmentWords], "a Layer is no Company")
        expectEqual(editor.issues(run.misfit).map(\.message), [employmentWords], "the commit's own check says the same")
        expectEqual(editor.issues(run.job).map(\.message), [])
    },
    test("a run's graph is the committed one with a relationship type nobody committed or wrote: no copy is made") {
        let editor = try bondEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        var same: Bool?
        var applications = 0
        editor.transact("Run") { transaction in
            transaction.insert(instanceRecord("Ann", of: [person], at: CGPoint(x: 500, y: 400)))
            for index in 0..<50 { transaction.insert(instanceRecord("n\(index)", of: [person], at: CGPoint(x: 500, y: CGFloat(500 + index)))) }
            guard let reading = transaction.shapes.reading, let relationships = editor.relationships else { return }
            same = relationships.graph(in: reading).types.relationshipTypes == relationships.graph.types.relationshipTypes
            #if DEBUG
            applications = relationships.runApplications
            #endif
        }
        expectEqual(same, true)
        expectEqual(applications, 0, "with no relationship type committed or written, no entry is applied")
    },
    test("an arrow written in a run is an end only if its other end is a type in the run: a note made a type in the same run turns the arrow") {
        let editor = try bondEditor()
        let related = editor.addRelationshipType("Employment")
        let person = ShapeID(), end = ShapeID()
        var before: Int?, after: Int?
        editor.transact("Run") { transaction in
            transaction.insert(AnyShapeRecord(ShapeRecord(id: person, memo("Person"))))
            transaction.insert(AnyShapeRecord(ShapeRecord(id: end, Bond(from: person, to: related))))
            guard let reading = transaction.shapes.reading, let relationships = editor.relationships else { return }
            before = relationships.graph(in: reading).sides(of: related).from.count
            transaction.update(person) { $0[TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter) }
            after = relationships.graph(in: transaction.shapes.reading ?? reading).sides(of: related).from.count
        }
        expectEqual(before, 0, "a note is no end of a relationship type")
        expectEqual(after, 1, "a type is")
    },
    test("a committed relationship type: an end deleted in the run, a type unmarked, and a note retyped are in the run's graph, and not the committed one") {
        let s = try bondEditor()
        let person = s.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 40, y: 40))
        let company = s.addType(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 40, y: 200))
        let layer = s.addType(TypeSchemaProperty.starter, title: "Layer", at: CGPoint(x: 40, y: 360))
        let employment = s.addRelationshipType("Employment")
        s.addBond(person, employment)
        let toEnd = s.addBond(employment, company)
        let ann = s.addInstance("Ann", of: [person], at: CGPoint(x: 500, y: 400))
        let acme = s.addInstance("Acme", of: [company], at: CGPoint(x: 800, y: 400))
        let job = s.addBond(ann, acme, of: [employment])
        var inRun: [[String]] = []
        s.transact("Run") { transaction in
            guard let relationships = s.relationships else { return }
            let jobRecord = transaction.document[job]
            inRun.append(says(s, jobRecord, in: transaction))
            transaction.update(acme) { $0[IsAProperty.self] = [TypeLink(layer)] }
            inRun.append(says(s, jobRecord, in: transaction))
            transaction.update(acme) { $0[IsAProperty.self] = [TypeLink(company)] }
            inRun.append(says(s, jobRecord, in: transaction))
            transaction.delete([toEnd])
            inRun.append(says(s, jobRecord, in: transaction))
            transaction.update(acme) { $0[IsAProperty.self] = [TypeLink(layer)] }
            inRun.append(says(s, jobRecord, in: transaction))
            transaction.update(employment) { $0[RelationshipProperty.self] = nil }
            inRun.append(says(s, jobRecord, in: transaction))
            expect(transaction.shapes.reading.map { relationships.graph(in: $0).sides(of: employment).to.isEmpty } == true)
        }
        expectEqual(inRun[0], [])
        expectEqual(inRun[1], ["Employment runs to a Company. “Acme” is a Layer."], "retyped in the run")
        expectEqual(inRun[2], [], "and back")
        expectEqual(inRun[3], [], "no end on the to side: open")
        expectEqual(inRun[4], [], "so a Layer is as good as a Company")
        expectEqual(inRun[5], [], "unmarked: no relationship type, nothing is judged")
    },
    test("an end read through a pill, a free end and a pill that is gone are judged in a run as they are committed") {
        let editor = try bondEditor()
        let run = Run()
        let relay = ShapeID(), gonePill = ShapeID(), freeArrow = ShapeID(), pillArrow = ShapeID(), goneArrow = ShapeID()
        var says: [[String]] = []
        editor.transact("Run") { transaction in
            for record in run.records() { transaction.insert(record) }
            var open = AnyShapeRecord(ShapeRecord(id: relay, Relay(CGRect(x: 0, y: 700, width: 100, height: 32), stands: [run.foundation], says: "Layer pill")))
            open.meta[Open.self] = nil
            transaction.insert(open)
            transaction.insert(AnyShapeRecord(ShapeRecord(id: gonePill, Relay(CGRect(x: 0, y: 760, width: 100, height: 32), stands: [ShapeID()], says: "Gone Co"))))
            var free = AnyShapeRecord(ShapeRecord(id: freeArrow, Bond(from: run.ann, to: nil)))
            free[IsAProperty.self] = [TypeLink(run.employment)]
            transaction.insert(free)
            var viaPill = AnyShapeRecord(ShapeRecord(id: pillArrow, Bond(from: run.ann, to: relay)))
            viaPill[IsAProperty.self] = [TypeLink(run.employment)]
            transaction.insert(viaPill)
            var viaGone = AnyShapeRecord(ShapeRecord(id: goneArrow, Bond(from: run.ann, to: gonePill)))
            viaGone[IsAProperty.self] = [TypeLink(run.employment)]
            transaction.insert(viaGone)
            let reading = transaction.shapes.reading
            says = [freeArrow, pillArrow, goneArrow].map { said(editor, transaction.document[$0], in: reading) }
        }
        expectEqual(says[0], ["Employment isn’t attached at both ends."], "a free end")
        expectEqual(says[1], ["Employment runs to “foundation”, which isn’t open."], "a pill that stands for a note that is not open")
        expectEqual(says[2], ["Employment runs to “Gone Co”, which is gone."], "a pill whose note is in no board")
        expectEqual(editor.issues(freeArrow).map(\.message), says[0], "the commit says the same")
        expectEqual(editor.issues(pillArrow).map(\.message), says[1])
        expectEqual(editor.issues(goneArrow).map(\.message), says[2])
    },
    test("the log is read once: a run of n shapes written one at a time and asked each time applies n entries, not n squared") {
        let editor = try bondEditor()
        let run = Run()
        editor.transact("Seed") { transaction in
            for record in run.records() { transaction.insert(record) }
        }
        let person = run.person
        var applied = 0, count = 0
        editor.transact("Run") { transaction in
            guard let relationships = editor.relationships else { return }
            for index in 0..<200 {
                transaction.insert(instanceRecord("n\(index)", of: [person], at: CGPoint(x: 500, y: CGFloat(500 + index))))
                if let reading = transaction.shapes.reading {
                    _ = relationships.graph(in: reading)
                    count = reading.writeCount
                }
            }
            #if DEBUG
            applied = relationships.runApplications
            #endif
        }
        #if DEBUG
        expectEqual(count, 200)
        expectEqual(applied, 200, "each write applied once")
        #endif
    },
    test("a note's relations in a run are the committed ones less the run's changes and the run's own, kept between two writes") {
        let editor = try bondEditor()
        let run = Run()
        editor.transact("Seed") { transaction in
            for record in run.records() where record.id != run.misfit { transaction.insert(record) }
        }
        let bo = ShapeID(), also = ShapeID()
        var first: [ShapeID] = [], second: [ShapeID] = [], third: [ShapeID] = [], again: [ShapeID] = []
        var made = 0
        editor.transact("Run") { transaction in
            guard let relationships = editor.relationships else { return }
            first = relationArrows(relationships, of: run.acme, in: transaction)
            transaction.insert(instanceRecord("Bo", of: [run.person], id: bo))
            var arrow = AnyShapeRecord(ShapeRecord(id: also, Bond(from: bo, to: run.acme)))
            arrow[IsAProperty.self] = [TypeLink(run.employment)]
            transaction.insert(arrow)
            second = relationArrows(relationships, of: run.acme, in: transaction)
            again = relationArrows(relationships, of: run.acme, in: transaction)
            transaction.delete([run.job])
            third = relationArrows(relationships, of: run.acme, in: transaction)
            #if DEBUG
            made = relationships.runRelationsMade
            #endif
        }
        expectEqual(first, [run.job], "committed")
        expectEqual(Set(second), [run.job, also], "and the run's own")
        expectEqual(again, second)
        expectEqual(third, [also], "the committed one deleted in the run")
        #if DEBUG
        expectEqual(made, 3, "asked four times, worked out three: the second ask was between the same two writes")
        #endif
    },
    test("a run's graph is made again for another run, and for a reading taken before what it has read") {
        let editor = try bondEditor()
        let run = Run()
        var early: LayoutReading?
        var counts: [Int] = []
        editor.transact("One") { transaction in
            for record in run.records() { transaction.insert(record) }
            early = transaction.shapes.reading
            transaction.insert(instanceRecord("Z", of: [run.person], at: CGPoint(x: 900, y: 900)))
            guard let reading = transaction.shapes.reading, let relationships = editor.relationships, let early else { return }
            counts.append(relationships.graph(in: reading).sides(of: run.employment).from.count)
            counts.append(relationships.graph(in: early).sides(of: run.employment).from.count)
            counts.append(relationships.graph(in: reading).sides(of: run.employment).from.count)
        }
        expectEqual(counts, [1, 1, 1], "an older reading is read from its own log")
        editor.transact("Two") { transaction in
            guard let reading = transaction.shapes.reading, let relationships = editor.relationships else { return }
            expectEqual(relationships.graph(in: reading).sides(of: run.employment).from.count, 1, "the next run is the committed graph and a log of nothing")
        }
    },
])

// MARK: What a run says of an arrow it draws

/// A script run on the editor, its result as JSON: `changes` and `warnings`.
@MainActor private func ran(_ script: String, on editor: CanvasEditor, dryRun: Bool = false) throws -> (rows: [JSONObject], warnings: [JSONObject]) {
    let result = try draw(script: script, dryRun: dryRun, reveal: false, program: "canvas", in: editor)
    let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(result))
    func objects(_ key: String) -> [JSONObject] { (json[key]?.arrayValue ?? []).compactMap(\.objectValue) }
    return (objects("changes"), objects("warnings"))
}

private let schema = #"{\"type\": \"object\", \"properties\": {}}"#

@MainActor let relationshipReportTests = Suite("What a run says of an arrow", [
    test("an end says what it is an end of, on the run that draws it and on the run again; a relationship type says what it relates") {
        let editor = try typeEditorWithDraw()
        let script = """
        memo "Person" schema: "\(schema)"
        memo "Employment" right of "Person" schema: "\(schema)" relationship: true
        memo "Company" right of "Employment" schema: "\(schema)"
        edge "Person" -> "Employment" text: "jobs" endRule: {"onlyOne": true}
        edge "Employment" -> "Company"
        """
        let first = try ran(script, on: editor)
        expectEqual(first.rows[1]["relates"], .object(["from": .array([.string("Person")]), "to": .array([.string("Company")])]), "judged by ends drawn in the same run")
        expectEqual(first.rows[3]["endOf"], .object(["type": "Employment", "side": "from", "row": "jobs", "onlyOne": true]))
        expectEqual(first.rows[4]["endOf"], .object(["type": "Employment", "side": "to"]), "no row, no flag: neither is told")
        expectEqual(first.warnings.map { $0["message"] }, [])
        let again = try ran(script, on: editor)
        expectEqual(again.rows.map { $0["did"] }, Array(repeating: "unchanged", count: 5))
        expectEqual(again.rows.map { $0["endOf"] }, first.rows.map { $0["endOf"] }, "an unchanged row says it too")
        expectEqual(again.rows.map { $0["relates"] }, first.rows.map { $0["relates"] })
        let dry = try ran(script, on: editor, dryRun: true)
        expectEqual(dry.rows.map { $0["endOf"] }, first.rows.map { $0["endOf"] }, "a dry run says the same")
    },
    test("each arrow that says nothing is warned on the run that changes it, once, and not on the run again") {
        let editor = try typeEditorWithDraw()
        _ = try ran("""
        memo "Person" schema: "\(schema)"
        memo "Employment" right of "Person" schema: "\(schema)" relationship: true
        memo "Mentor" right of "Employment" schema: "\(schema)" relationship: true
        memo "Plain" below "Person" schema: "\(schema)"
        memo "Ann" below "Plain"
        """, on: editor)
        @MainActor func said(_ statement: String) throws -> [String] { try ran(statement, on: editor).warnings.compactMap { $0["message"]?.stringValue } }
        expect(try said(#"edge "Person" -> "Plain""#).contains { $0.contains("Both ends are types, so this arrow says nothing") }, "between types")
        expect(try said(#"edge "Employment" -> "Mentor""#).contains { $0.contains("Both ends are relationship types") }, "between relationship types")
        expect(try said(#"edge "Employment" -> "Ann""#).contains { $0.contains("“Ann” isn't a type, so this arrow is not an end of “Employment”.") }, "a note at the far end")
        expect(try said(#"edge "Ann" -> "Plain" endRule: {"needed": true}"#).contains { $0.contains("endRule says something only on") }, "a rule off an end")
        expect(try said(#"edge "Ann" -> "Person" is: "Plain""#).contains { $0.contains("“Plain” isn't a relationship type") }, "a plain type")
        expectEqual(try said(#"edge "Person" -> "Plain""#), [], "unchanged: not said again")
    },
    test("a plain arrow between two notes that fit lists the types in fits and gets none; is: gives it one, and a delete without is: says it took a typed arrow") {
        let editor = try typeEditorWithDraw()
        _ = try ran("""
        memo "Person" schema: "\(schema)"
        memo "Employment" right of "Person" schema: "\(schema)" relationship: true
        memo "Company" right of "Employment" schema: "\(schema)"
        edge "Person" -> "Employment"
        edge "Employment" -> "Company"
        memo "Ann" below "Person" is: "Person"
        memo "Acme" below "Company" is: "Company"
        """, on: editor)
        let plain = try ran(#"edge "Ann" -> "Acme""#, on: editor)
        expectEqual(plain.rows[0]["fits"], .array([.string("Employment")]))
        expectEqual(plain.rows[0]["is"], nil, "no type is picked")
        let typed = try ran(#"edge "Ann" -> "Acme" is: "Employment""#, on: editor)
        expectEqual(typed.rows[0]["did"], "reconnected")
        expectEqual(typed.rows[0]["is"], .array([.string("Employment")]))
        expectEqual(typed.rows[0]["fits"], nil)
        let removed = try ran(#"delete edge "Ann" -> "Acme""#, on: editor)
        expectEqual(removed.rows.first?["is"], .array([.string("Employment")]), "the deleted row says what it was")
        expectEqual(removed.warnings.compactMap { $0["message"]?.stringValue }.count, 1)
    },
])
