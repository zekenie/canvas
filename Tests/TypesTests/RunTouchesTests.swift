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

// What a run's writes reach, in Types (`FieldChecks.touched(by:reading:)`, the `touches` of the rule over values and
// relationships), and the check of the shapes reached, over the run's own graph: a second relationship drawn at a note
// whose row allows one is an error of the note, which the run did not write. Each change is made in a transaction that
// is thrown away, asked as `canvas draw` asks (what Validation says the writes touch, each shape's issues before and
// after over its own board), then made for real and held against what Validation keeps a moment later.

private struct Thrown: Error {}

private let schema = #"{"type": "object", "properties": {"level": {"type": "string"}}}"#
private let narrowed = #"{"type": "object", "properties": {"level": {"type": "string", "enum": ["a", "b"]}}}"#
private let needing = #"{"type": "object", "properties": {"level": {"type": "string"}, "team": {"type": "string"}}, "required": ["team"]}"#
private let two = "jobs has 2 notes, and should have at most 1"

/// Person relates to Company by Employment (`jobs`, and `staff` on the Company's side), drawn with slips, which show
/// rows. Ann and Bo are Persons, Acme and Globex Companies; Ann works at Acme. Far is a Company on the pocket's board,
/// open, so a relay can stand for it.
@MainActor private struct World {
    let editor: CanvasEditor
    var person = ShapeID(), employment = ShapeID(), company = ShapeID()
    var from = ShapeID(), to = ShapeID()
    var ann = ShapeID(), bo = ShapeID(), acme = ShapeID(), globex = ShapeID(), far = ShapeID(), pocket = ShapeID()
    var annAtAcme = ShapeID()

    init(jobs: EndRule? = EndRule(needed: false, onlyOne: true), staff: EndRule? = nil) throws {
        let editor = try bondEditor(more: [DrawPlugin(), TitleNamesPlugin(), TypeNamesPlugin(), FieldValuesPlugin(), ValidationChecksPlugin(), BondEdgesPlugin()])
        self.editor = editor
        editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        func slip(_ title: String, of types: [ShapeID], at origin: CGPoint) -> ShapeID {
            var record = slipRecord("", of: types, at: origin)
            record[TitleProperty.self] = title
            record.meta[Open.self] = true
            editor.transact { $0.insert(record) }
            return record.id
        }
        func type(_ title: String, at origin: CGPoint, marked: Bool = false) -> ShapeID {
            var record = slipTypeRecord(schema, title: title, at: origin)
            if marked { record[RelationshipProperty.self] = true }
            editor.transact { $0.insert(record) }
            return record.id
        }
        person = type("Person", at: CGPoint(x: 40, y: 40))
        employment = type("Employment", at: CGPoint(x: 400, y: 40), marked: true)
        company = type("Company", at: CGPoint(x: 760, y: 40))
        from = editor.addBond(person, employment, name: "jobs", rule: jobs)
        to = editor.addBond(employment, company, name: "staff", rule: staff)
        ann = slip("Ann", of: [person], at: CGPoint(x: 40, y: 400))
        bo = slip("Bo", of: [person], at: CGPoint(x: 40, y: 600))
        acme = slip("Acme", of: [company], at: CGPoint(x: 760, y: 400))
        globex = slip("Globex", of: [company], at: CGPoint(x: 760, y: 600))
        let far = slip("Far", of: [company], at: CGPoint(x: 760, y: 800))
        self.far = far
        let pocket = ShapeID()
        self.pocket = pocket
        editor.transact { $0.insert(AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 0, y: 3000, width: 100, height: 100))))) }
        _ = editor.transact("Move") { $0.move([far], toBoardOwnedBy: pocket) }
        annAtAcme = editor.addBond(ann, acme, of: [employment])
        _ = editor.validation?.results
    }

    func title(_ id: ShapeID) -> String {
        editor.shape(inFile: id).flatMap { editor.registry.title(of: $0) } ?? id.description
    }

    /// What `body`'s writes would bring to shapes they do not write, by title: for each shape Validation says they
    /// touch, the issues it has after them over its own board that it had not before. Nothing is committed.
    func brings(_ body: (inout Transaction) -> Void) -> [String: [String]] {
        var found: [String: [String]] = [:]
        let editor = editor, registry = editor.registry
        try? editor.transact { transaction in
            body(&transaction)
            let shapes = transaction.shapes
            for id in registry.validationTouched(by: transaction.pending, in: shapes) {
                guard let board = transaction.board(containing: id) else { continue }
                let there = transaction.contents(of: board)
                guard let now = there[id] else { continue }
                let after = registry.validationIssues(of: now, in: shapes.over(there)).map(\.message)
                var before: [String] = []
                if let was = editor.file.board(containing: id) {
                    let document = editor.contents(of: was)
                    if let record = document[id] { before = registry.validationIssues(of: record, in: editor.shapeContext.over(document)).map(\.message) }
                }
                let new = after.filter { !before.contains($0) }
                if !new.isEmpty { found[title(id)] = new }
            }
            throw Thrown()
        }
        return found
    }

    /// The same writes made for real: what Validation then keeps of each shape on the board shown, and what its rules
    /// say of one on the pocket's board, by title; only the shapes that have an issue.
    func made(_ body: (inout Transaction) -> Void) -> [String: [String]] {
        editor.transact("Change") { body(&$0) }
        var found: [String: [String]] = [:]
        for record in editor.document.shapes {
            let issues = editor.issues(record.id).map(\.message)
            if !issues.isEmpty { found[title(record.id)] = issues }
        }
        let board = editor.contents(of: BoardID(owner: pocket))
        for record in board.shapes {
            let issues = editor.registry.validationIssues(of: record, in: editor.shapeContext.over(board), editor: editor).map(\.message)
            if !issues.isEmpty { found[title(record.id)] = issues }
        }
        return found
    }

    /// A run's writes say what the board then shows: `expected` is brought, and once the writes are made it is what is
    /// kept (with `kept`, the issues that were there already).
    func expectBrings(_ expected: [String: [String]], kept: [String: [String]] = [:], _ why: String, _ body: (inout Transaction) -> Void) {
        expectEqual(brings(body), expected, why)
        expectEqual(made(body), expected.merging(kept) { brought, _ in brought }, "\(why): the board, once it is made")
    }

    func bond(_ from: ShapeID, _ to: ShapeID, name: String = "", of types: [ShapeID] = [], rule: EndRule? = nil) -> AnyShapeRecord {
        var record = AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: from, to: to, text: MentionText(plain: name))))
        if !types.isEmpty { record[IsAProperty.self] = types.map(TypeLink.init) }
        if let rule { record[RelationshipEndProperty.self] = rule }
        return record
    }
}

@MainActor private func ran(_ script: String, on editor: CanvasEditor, dryRun: Bool = false) throws -> (rows: [JSONObject], warnings: [JSONObject]) {
    let result = try draw(script: script, dryRun: dryRun, reveal: false, program: "canvas", in: editor)
    let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(result))
    func objects(_ key: String) -> [JSONObject] { (json[key]?.arrayValue ?? []).compactMap(\.objectValue) }
    return (objects("changes"), objects("warnings"))
}

@MainActor let runTouchesTests = Suite("What a run's writes reach, and what it says of them", [
    test("the example: a second job drawn for Ann, whose row allows one, is a warning that names her, on the edge's line; a dry run says the same; the board agrees") {
        let w = try World()
        let script = #"edge "Ann" -> "Globex" is: "Employment""#
        let warning: JSONObject = ["line": 1, "message": .string("\"Ann\": \(two)"), "severity": "error", "attribute": "jobs"]
        let dry = try ran(script, on: w.editor, dryRun: true)
        expectEqual(dry.warnings, [warning])
        expectEqual(w.editor.issues(w.ann), [], "nothing committed")
        let real = try ran(script, on: w.editor)
        expectEqual(real.warnings, [warning])
        expectEqual(real.rows.map { $0["did"] }, ["connected"], "Ann has no row: the run did not write her")
        expectEqual(w.editor.issues(w.ann).map(\.message), [two])
        expectEqual(w.editor.issues(w.ann).map(\.field), ["jobs"])
        expectEqual(try ran(script, on: w.editor).warnings, [], "run again, it brings nothing")
        // And a third, to a Person: the arrow's own misfit, and another issue of Ann's, by its words.
        expectEqual(try ran(#"edge "Ann" -> "Bo" is: "Employment""#, on: w.editor).warnings.map { $0["message"] },
                    [#"edge "Ann" -> "Bo": Employment runs to a Company. “Bo” is a Person."#, #""Ann": jobs has 3 notes, and should have at most 1"#])
    },
    test("the check of a note the run touches is made over the run's graph, as it is for a note the run draws") {
        let w = try World()
        let checks = try require(w.editor.fieldChecks)
        let ann = try require(w.editor.document[w.ann])
        expectEqual(checks.check(of: ann).problems.map(\.message), [])
        var inside: [String] = []
        let second = w.bond(w.ann, w.globex, of: [w.employment])
        try? w.editor.transact { transaction in
            transaction.insert(second)
            if let reading = transaction.shapes.reading { inside = checks.check(of: ann, reading: reading).problems.map(\.message) }
            throw Thrown()
        }
        expectEqual(inside, [two], "Ann's record is as committed, and an arrow at her is not")
    },
    test("a relationship drawn, deleted, re-aimed and retyped reaches the notes at its ends") {
        let w = try World()
        let second = w.bond(w.ann, w.globex, of: [w.employment])
        w.expectBrings(["Ann": [two]], "drawn") { $0.insert(second) }
        w.expectBrings([:], "deleted: what a run mends it does not say") { $0.delete([second.id]) }
        let plain = w.bond(w.ann, w.globex)
        w.expectBrings([:], "a plain arrow is nobody's relationship") { $0.insert(plain) }
        w.expectBrings(["Ann": [two]], "retyped") { $0.update(plain.id) { $0[IsAProperty.self] = [TypeLink(w.employment)] } }
        w.expectBrings([:], "the type taken off again") { $0.update(plain.id) { $0[IsAProperty.self] = nil } }
        let bos = w.bond(w.bo, w.globex, of: [w.employment])
        w.expectBrings([:], "Bo's first job") { $0.insert(bos) }
        w.expectBrings(["Ann": [two]], "re-aimed from Bo to Ann") { $0.update(bos.id, as: Bond.self) { $0.props.from = w.ann } }
    },
    test("an end given a rule, renamed, deleted and drawn reaches the notes of its end type whose rows it changes") {
        let w = try World(jobs: nil)
        _ = w.editor.addBond(w.ann, w.globex, of: [w.employment])
        expectEqual(w.editor.issues(w.ann), [], "no rule yet")
        w.expectBrings(["Ann": [two]], "a rule set") { $0.update(w.from) { $0[RelationshipEndProperty.self] = EndRule(needed: false, onlyOne: true) } }
        let roles = "roles has 2 notes, and should have at most 1"
        w.expectBrings(["Ann": [roles]], "renamed: the issue is another, by its words") {
            $0.update(w.from, as: Bond.self) { $0.props.text = MentionText(plain: "roles") }
        }
        w.expectBrings(["Bo": ["roles is needed"]], kept: ["Ann": [roles]], "made needed too: Bo, with no job, has a row left empty, an issue of the third level") {
            $0.update(w.from) { $0[RelationshipEndProperty.self] = EndRule(needed: true, onlyOne: true) }
        }
        w.expectBrings([:], "the end deleted: its row goes, and the issue with it") { $0.delete([w.from]) }
        let again = w.bond(w.person, w.employment, name: "jobs", rule: EndRule(needed: false, onlyOne: true))
        w.expectBrings(["Ann": [two]], "the end drawn again, with its rule") { $0.insert(again) }
    },
    test("a mark and a type that builds on another reach the notes and the arrows they change") {
        let w = try World()
        _ = w.editor.addBond(w.ann, w.globex, of: [w.employment])
        expectEqual(w.editor.issues(w.ann).map(\.message), [two])
        w.expectBrings([:], "the mark taken off: no relationship is one, and what a run mends it does not say") { $0.update(w.employment) { $0[RelationshipProperty.self] = nil } }
        w.expectBrings(["Ann": [two]], "the mark put back") { $0.update(w.employment) { $0[RelationshipProperty.self] = true } }
        // Cy is an Employee, which is nobody's end: two jobs break nothing until Employee builds on Person.
        let employee = slipTypeRecord(schema, title: "Employee", at: CGPoint(x: 40, y: 1000))
        var cy = slipRecord("", of: [employee.id], at: CGPoint(x: 40, y: 1200))
        cy[TitleProperty.self] = "Cy"
        w.editor.transact { $0.insert(employee); $0.insert(cy) }
        let first = w.editor.addBond(cy.id, w.acme, of: [w.employment])
        _ = w.editor.addBond(cy.id, w.globex, of: [w.employment])
        expectEqual(w.editor.issues(cy.id), [])
        expectEqual(w.editor.issues(first).count, 1, "an Employee is no Person yet: a misfit")
        let brought = w.brings { $0.update(employee.id) { $0[IsAProperty.self] = [TypeLink(w.person)] } }
        expectEqual(brought, ["Cy": [two]], "Employee builds on Person: Cy reads the jobs row, and the two arrows fit (mended, so not said)")
        expectEqual(w.made { $0.update(employee.id) { $0[IsAProperty.self] = [TypeLink(w.person)] } }, ["Ann": [two], "Cy": [two]])
    },
    test("a type restated reaches its instances, near and far: a held value its fields now refuse is an error, a field made needed the third level") {
        let w = try World()
        var dee = slipRecord("", of: [w.person], at: CGPoint(x: 400, y: 1400))
        dee[TitleProperty.self] = "Dee"
        dee[FieldValuesProperty.self] = FieldValues(["level": "c"])
        w.editor.transact { $0.insert(dee) }
        _ = w.editor.transact("Move") { $0.move([dee.id], toBoardOwnedBy: w.pocket) }
        w.editor.transact { $0.update(w.ann) { $0[FieldValuesProperty.self] = FieldValues(["level": "c"]) } }
        w.editor.transact { $0.update(w.bo) { $0[FieldValuesProperty.self] = FieldValues(["level": "a"]) } }
        let missing = "team is needed"
        expectEqual(w.brings { $0.update(w.person) { $0[TypeSchemaProperty.self] = SchemaText(needing) } },
                    ["Ann": [missing], "Bo": [missing], "Dee": [missing]], "a field made needed is an issue of the third level for each instance, near and far")
        let wrong = w.brings { $0.update(w.person) { $0[TypeSchemaProperty.self] = SchemaText(narrowed) } }
        expectEqual(Set(wrong.keys), ["Ann", "Dee"], "Bo's value is one of the two: \(wrong)")
        expectEqual(wrong["Ann"], wrong["Dee"], "near and far say the same")
        expectEqual(wrong["Ann"]?.count, 1)
        expectEqual(w.made { $0.update(w.person) { $0[TypeSchemaProperty.self] = SchemaText(narrowed) } }, wrong, "and the board, once it is made")
    },
    test("a type restated by a run that breaks instances it does not restate warns of each, near and far, on the type's line") {
        let editor = try typeEditorWithDraw()
        func quoting(_ json: String) -> String { json.replacingOccurrences(of: "\"", with: "\\\"") }
        _ = try ran("""
        memo "Grade" schema: "\(quoting(schema))"
        memo "Near" below "Grade" is: "Grade" fieldValues: {"level": "c"}
        memo "Far" below "Near" is: "Grade" fieldValues: {"level": "c"}
        memo "Fine" below "Far" is: "Grade" fieldValues: {"level": "a"}
        """, on: editor)
        let pocket = ShapeID()
        editor.transact { $0.insert(AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 0, y: 3000, width: 100, height: 100))))) }
        let far = try require(editor.document.shapes.first { editor.registry.title(of: $0) == "Far" }).id
        _ = editor.transact("Move") { $0.move([far], toBoardOwnedBy: pocket) }
        let script = "memo \"Grade\" schema: \"\(quoting(narrowed))\""
        let dry = try ran(script, on: editor, dryRun: true)
        let said = try ran(script, on: editor)
        expectEqual(said.rows.map { $0["did"] }, ["updated"])
        expectEqual(said.warnings.map { $0["line"] }, [1, 1])
        let messages = said.warnings.compactMap { $0["message"]?.stringValue }
        expectEqual(messages.map { String($0.prefix(7)) }, ["\"Far\": ", "\"Near\":"], "by name, and Fine's value is one of the two: \(messages)")
        expectEqual(said.warnings.map { $0["severity"] }, ["error", "error"])
        expectEqual(said.warnings.map { $0["attribute"] }, ["level", "level"])
        expectEqual(dry.warnings, said.warnings, "a dry run says the same")
        let near = try require(editor.document.shapes.first { editor.registry.title(of: $0) == "Near" }).id
        expectEqual(editor.issues(near).map { "\"Near\": " + $0.message }, [messages.last ?? ""], "the board says it of Near")
        // A field made needed is what each note still needs: said of each, with its own level.
        let needed = try ran("memo \"Grade\" schema: \"\(quoting(needing))\"", on: editor)
        expectEqual(needed.warnings.map { $0["severity"] }, ["incomplete", "incomplete", "incomplete"])
        expectEqual(needed.warnings.compactMap { $0["message"]?.stringValue }, ["\"Far\": team is needed", "\"Fine\": team is needed", "\"Near\": team is needed"])
        expectEqual(needed.warnings.map { $0["line"] }, [1, 1, 1])
    },
    test("a relationship deleted or re-aimed away from a Needed row leaves its note needing it, and one drawn at the row, on any board, mends it and is not said") {
        let needed = "staff is needed"
        let setup = ["Globex": [needed], "Far": [needed]]       // the Companies no one works at
        let deleted = try World(jobs: nil, staff: EndRule(needed: true, onlyOne: false))
        deleted.expectBrings(["Acme": [needed]], kept: setup, "Ann's job deleted: Acme has no one") { $0.delete([deleted.annAtAcme]) }
        let aimed = try World(jobs: nil, staff: EndRule(needed: true, onlyOne: false))
        aimed.expectBrings(["Acme": [needed]], kept: ["Far": [needed]], "re-aimed from Acme to Globex: Acme is empty, Globex mended (not said)") {
            $0.update(aimed.annAtAcme, as: Bond.self) { $0.props.to = aimed.globex }
        }
        let drawn = try World(jobs: nil, staff: EndRule(needed: true, onlyOne: false))
        drawn.expectBrings([:], kept: ["Far": [needed]], "a second job at Globex mends it: nothing is said of a note that is better off, near or far") {
            $0.insert(drawn.bond(drawn.bo, drawn.globex, of: [drawn.employment]))
        }
        let pill = try World(jobs: nil, staff: EndRule(needed: true, onlyOne: false))
        let relay = pill.editor.addRelay(standingFor: [pill.far], says: "Far", at: CGPoint(x: 400, y: 800))
        pill.expectBrings([:], kept: ["Globex": [needed]], "a job at the far Company through a pill mends it, on the board it is on") {
            $0.insert(pill.bond(pill.bo, relay, of: [pill.employment]))
        }
    },
    test("a relationship drawn into a pill reaches the note the pill stands for, on another board; a pill re-pointed, the note it now names") {
        let w = try World(staff: EndRule(needed: false, onlyOne: true))
        let staff = "staff has 2 notes, and should have at most 1"
        let first = w.editor.addRelay(standingFor: [w.far], says: "Far", at: CGPoint(x: 400, y: 800))
        _ = w.editor.addBond(w.bo, first, of: [w.employment])
        let second = AnyShapeRecord(ShapeRecord(id: ShapeID(), Relay(CGRect(x: 400, y: 900, width: 100, height: 32), stands: [w.far], says: "Far")))
        let into = w.bond(w.ann, second.id, of: [w.employment])
        w.expectBrings(["Far": [staff], "Ann": [two]], "Far has two on its staff, through two pills; Ann her second job") {
            $0.insert(second)
            $0.insert(into)
        }
        // A pill re-pointed takes the relationship from one note and gives it to another.
        _ = w.editor.addBond(w.bo, w.globex, of: [w.employment])
        expectEqual(w.editor.issues(w.globex), [], "Globex has Bo alone")
        let repointed = w.brings { $0.update(second.id, as: Relay.self) { $0.props.stands = [Citation(w.globex)] } }
        expectEqual(repointed["Globex"], [staff], "Ann's arrow runs to Globex now: \(repointed)")
        expectEqual(repointed["Far"], nil, "and Far is mended")
        // The note behind the pills made private, on its own board: each arrow into a pill for it runs to an end it
        // cannot read, which is a warning of the arrow, and the run wrote neither arrow.
        let closed = w.brings { $0.update(inFile: w.far) { $0.meta[Open.self] = nil } }
        expectEqual(Set(closed.keys), [w.title(into.id), w.title(w.editor.document.shapes.first { $0.typed(as: Bond.self)?.props.to == first }?.id ?? into.id)],
                    "the two arrows, named by their ids since a bond has no title: \(closed)")
        expect(closed.values.allSatisfy { $0.count == 1 && $0[0].contains("Far") }, "\(closed)")
        w.editor.transact { $0.update(inFile: w.far) { $0.meta[Open.self] = nil } }
        expectEqual(w.editor.issues(into.id).map(\.message), closed[w.title(into.id)], "and the board says the same of the arrow")
    },
    test("a type deleted warns the type that refers to it, in the run as on the board") {
        let editor = try fieldEditor()
        _ = editor.validation?.results
        let registry = editor.registry
        var brought: [String] = []
        var touched: Set<ShapeID> = []
        try? editor.transact { transaction in
            transaction.delete([FieldFixtures.addressID])
            touched = registry.validationTouched(by: transaction.pending, in: transaction.shapes)
            if let order = transaction.document[FieldFixtures.orderID] { brought = registry.validationIssues(of: order, in: transaction.shapes).map(\.message) }
            throw Thrown()
        }
        expect(touched.contains(FieldFixtures.orderID), "Order refers to Address")
        expectEqual(brought, ["Refers to “Address”, which is gone."])
        editor.transact("Delete") { $0.delete([FieldFixtures.addressID]) }
        expectEqual(editor.issues(FieldFixtures.orderID).map(\.message), brought)
    },
    test("an arrow left at a relationship type with one end free says so in a run too, and a mark reaches it") {
        let w = try World()
        let checks = try require(w.editor.fieldChecks)
        var said: [String] = []
        try? w.editor.transact { transaction in
            transaction.update(w.to, as: Bond.self) { $0.props.to = nil }
            if let reading = transaction.shapes.reading, let record = transaction.document[w.to] { said = checks.check(of: record, reading: reading).problems.map(\.message) }
            throw Thrown()
        }
        w.editor.transact { $0.update(w.to, as: Bond.self) { $0.props.to = nil } }
        expectEqual(said, w.editor.issues(w.to).map(\.message), "the run's check of the arrow it wrote is the board's")
        expectEqual(said.count, 1, "\(said)")
        // The mark taken off and put back, of an arrow the run does not write: the line is the type's while it is marked.
        w.editor.transact { $0.update(w.employment) { $0[RelationshipProperty.self] = nil } }
        let unmarked = w.editor.issues(w.to).map(\.message)
        expectEqual(unmarked.count, 1, "left at a type with a name on it: \(unmarked)")
        expect(unmarked != said, "and it no longer names a relationship type")
        let back = w.brings { $0.update(w.employment) { $0[RelationshipProperty.self] = true } }
        expectEqual(back[w.title(w.to)], said, "the mark back: the line names the type again, on an arrow the run did not write")
    },
    test("a rule set at a type with 1,000 instances that then break: twenty are said and the rest counted, within the run's budget") {
        let w = try World(jobs: nil)
        var records: [AnyShapeRecord] = []
        for index in 0..<1_000 {
            var note = slipRecord("", of: [w.person], at: CGPoint(x: 1200 + Double(index % 40) * 260, y: Double(index / 40) * 200))
            note[TitleProperty.self] = "P" + String(format: "%04d", index)
            records.append(note)
            records.append(w.bond(note.id, w.acme, of: [w.employment]))
            records.append(w.bond(note.id, w.globex, of: [w.employment]))
        }
        w.editor.transact { transaction in for record in records { transaction.insert(record) } }
        _ = w.editor.validation?.results
        let script = #"edge "Person" -> "Employment" endRule: {"onlyOne": true}"#
        var result: (rows: [JSONObject], warnings: [JSONObject])?
        var failure: String?
        let took = threadCPUTime {
            do { result = try ran(script, on: w.editor) } catch { failure = "\(error)" }
        }
        expectEqual(failure, nil)
        let warnings = result?.warnings ?? []
        expectEqual(warnings.count, 21)
        expectEqual(warnings.first?["message"], .string("\"P0000\": \(two)"))
        expectEqual(warnings.prefix(20).map { $0["line"] }, Array(repeating: 1, count: 20))
        expectEqual(warnings.last?["message"], #"and 980 more shapes now have issues: ask canvas query ":invalid, :warned, :incomplete""#)
        expectEqual(warnings.last?["line"], nil)
        expectEqual(w.editor.document.shapes.filter { !w.editor.issues($0.id).isEmpty }.count, 1_000, "the board says it of every one")
        expect(took < .milliseconds(600), "a rule set at 1,000 instances, each checked before and after, took \(took)")
    },
    test("a run of 2,500 arrows that are no relationship names nothing, for a lookup each, with relationship types in the file and with none") {
        @MainActor func cost(live: Bool) throws -> Duration {
            let editor = try typeEditorWithDraw()
            let a = editor.addType(TypeSchemaProperty.starter, title: "A", at: CGPoint(x: 40, y: 40))
            let b = editor.addType(TypeSchemaProperty.starter, title: "B", at: CGPoint(x: 40, y: 200))
            if live {
                let relation = editor.addRelationshipType("Rel")
                editor.addBond(a, relation, rule: EndRule(needed: false, onlyOne: true))
                editor.addBond(relation, b)
            }
            var notes: [AnyShapeRecord] = []
            for index in 0..<100 { notes.append(instanceRecord("n\(index)", of: [index % 2 == 0 ? a : b], title: "n\(index)", at: CGPoint(x: 400 + Double(index) * 20, y: 40))) }
            editor.transact { transaction in for record in notes { transaction.insert(record) } }
            var bonds: [AnyShapeRecord] = []
            for i in 0..<50 { for j in 0..<50 { bonds.append(AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: notes[i * 2].id, to: notes[j * 2 + 1].id)))) } }
            var took = Duration.zero
            var named: Set<ShapeID>?
            try? editor.transact { transaction in
                for record in bonds { transaction.insert(record) }
                let pending = transaction.pending, shapes = transaction.shapes
                let reading = try require(shapes.reading)
                // The run's graph reads the log once, as the run's own report has it do: not this question's cost.
                _ = editor.relationships?.graph(in: reading)
                took = threadCPUTime { named = FieldChecks.touched(by: pending, reading: reading) }
                throw Thrown()
            }
            expectEqual(named, [], "no arrow of the 2,500 is a relationship or an end (\(live ? "with" : "without") a relationship type)")
            return took
        }
        let plain = try cost(live: false), live = try cost(live: true)
        expect(plain < .milliseconds(40), "2,500 arrows in a file with no relationship type took \(plain)")
        expect(live < .milliseconds(60), "2,500 arrows that are no relationship, in a file with a relationship type, took \(live)")
    },
])
