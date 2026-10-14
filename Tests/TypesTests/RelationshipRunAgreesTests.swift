@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Draw
import Foundation
import Mentions
import Queries
import TestKit
import Titles
import Topology
import Types
import Validation

// A run says what the board then says. Each script is run dry, for real and
// again, and each row's `is`, `endOf`, `fits`, `relates` and `problems` is held against what the committed editor
// says a moment later: the check, Validation's kept issues, `:misfit`, the index's ends and sides.

private let schema = #"{\"type\": \"object\", \"properties\": {}}"#

@MainActor private func runEditor() throws -> CanvasEditor {
    let editor = try bondEditor(more: [DrawPlugin(), TitleNamesPlugin(), TypeNamesPlugin(), FieldValuesPlugin(), ValidationChecksPlugin(), BondEdgesPlugin(),
                                       QueriesPlugin(), TitleQueriesPlugin(), ValidationQueriesPlugin(), TypeQueriesPlugin()])
    editor.viewportDidResize(to: CGSize(width: 800, height: 600))
    return editor
}

@MainActor private func ran(_ script: String, on editor: CanvasEditor, dryRun: Bool = false) throws -> (rows: [JSONObject], warnings: [JSONObject]) {
    let result = try draw(script: script, dryRun: dryRun, reveal: false, program: "canvas", in: editor)
    let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(result))
    func objects(_ key: String) -> [JSONObject] { (json[key]?.arrayValue ?? []).compactMap(\.objectValue) }
    return (objects("changes"), objects("warnings"))
}

private func said(_ rows: [JSONObject]) -> [String] {
    rows.map { row in
        var parts: [String] = []
        for key in ["line", "kind", "title", "from", "to", "is", "endOf", "fits", "relates", "problems"] {
            if let value = row[key] { parts.append("\(key)=\(text(value))") }
        }
        return parts.joined(separator: " ")
    }
}

private func text(_ value: JSONValue) -> String {
    switch value {
    case .string(let s): return s
    case .number(let n): return "\(n)"
    case .bool(let b): return "\(b)"
    case .null: return "null"
    case .array(let items): return "[" + items.map(text).joined(separator: ", ") + "]"
    case .object(let object): return "{" + object.keys.sorted().map { "\($0): \(text(object[$0] ?? .null))" }.joined(separator: ", ") + "}"
    }
}

@MainActor private func title(_ id: ShapeID?, _ editor: CanvasEditor) -> String {
    guard let id, let record = editor.shape(inFile: id) else { return "?" }
    return editor.registry.title(of: record) ?? "?"
}

/// What the committed editor says of every bond and relationship type, in the words a row would use.
@MainActor private func board(_ editor: CanvasEditor) throws -> [String: [String]] {
    let relationships = try require(editor.relationships), checks = try require(editor.fieldChecks)
    let graph = relationships.graph
    let misfits = Set(try queried("bond:misfit", on: editor).rows.map(\.id))
    var out: [String: [String]] = [:]
    for record in editor.document.shapes {
        if let bond = record.typed(as: Bond.self)?.props {
            let list = (record[IsAProperty.self] ?? []).map { title($0.shape, editor) }
            let key = "\(title(bond.from, editor))->\(title(bond.to, editor)) is \(list)"
            let problems = checks.fullCheck(of: record).problems.map(\.message).sorted()
            let issues = editor.issues(record.id).map(\.message).sorted()
            var lines = ["problems=\(problems)", "issues=\(issues)", "misfit=\(misfits.contains(record.id))"]
            if let end = relationships.end(record.id) { lines.append("endOf=\(title(end.type, editor)) \(end.side)") }
            if list.isEmpty, let ends = relationships.subjects(of: record.id) {
                lines.append("fits=\(graph.fitting(from: ends.from.reading, to: ends.to.reading).taken.map { title($0, editor) })")
            }
            out[key] = lines
        } else if graph.isRelationshipType(record.id) {
            let sides = graph.sides(of: record.id)
            out["type \(title(record.id, editor))"] = ["from=\(sides.types(on: .from).map { title($0, editor) })", "to=\(sides.types(on: .to).map { title($0, editor) })"]
        }
    }
    return out
}

/// The same, as a run's rows say it.
private func rowsSay(_ rows: [JSONObject]) -> [String: [String]] {
    var out: [String: [String]] = [:]
    for row in rows where row["did"]?.stringValue != "deleted" {
        if row["kind"]?.stringValue == "bond" {
            let list = (row["is"]?.arrayValue ?? []).compactMap(\.stringValue)
            let key = "\(row["from"]?.stringValue ?? "?")->\(row["to"]?.stringValue ?? "?") is \(list)"
            let problems = (row["problems"]?.arrayValue ?? []).compactMap { $0["message"]?.stringValue }.sorted()
            var lines = ["problems=\(problems)"]
            if let end = row["endOf"]?.objectValue { lines.append("endOf=\(end["type"]?.stringValue ?? "?") \(end["side"]?.stringValue ?? "?")") }
            if list.isEmpty { lines.append("fits=\((row["fits"]?.arrayValue ?? []).compactMap(\.stringValue))") }
            out[key] = lines
        } else if let relates = row["relates"]?.objectValue {
            func side(_ key: String) -> [String] { (relates[key]?.arrayValue ?? []).compactMap(\.stringValue) }
            out["type \(row["title"]?.stringValue ?? "?")"] = ["from=\(side("from"))", "to=\(side("to"))"]
        }
    }
    return out
}

/// Runs `script` dry, for real and again on `editor`, and says each place a run and the board disagree.
@MainActor private func disagreements(_ script: String, on editor: CanvasEditor, restatesAll: Bool = true) throws -> [String] {
    var found: [String] = []
    let dry = try ran(script, on: editor, dryRun: true)
    let real = try ran(script, on: editor)
    if said(dry.rows) != said(real.rows) { found.append("dry \(said(dry.rows)) real \(said(real.rows))") }
    let now = try board(editor)
    for (key, lines) in rowsSay(real.rows) {
        guard let kept = now[key] else {
            found.append("the run names \(key), the board has no such: \(now.keys.sorted())")
            continue
        }
        for line in lines where !line.hasPrefix("fits=[]") || kept.contains(where: { $0.hasPrefix("fits=") }) {
            if line.hasPrefix("problems=") {
                // The row's problems are the check's, Validation's errors are among them, and :misfit is true exactly when an error is.
                if !kept.contains(line) { found.append("\(key): the run says \(line), the board \(kept)") }
            } else if !kept.contains(line) {
                found.append("\(key): the run says \(line), the board \(kept)")
            }
        }
    }
    if restatesAll {
        let again = try ran(script, on: editor)
        let unchanged = again.rows.filter { $0["did"]?.stringValue != "unchanged" && $0["did"]?.stringValue != "deleted" }
        if !unchanged.isEmpty { found.append("run again is not unchanged: \(said(unchanged))") }
        let first = rowsSay(real.rows), second = rowsSay(again.rows)
        for (key, lines) in first where second[key] != lines { found.append("\(key): first \(lines), again \(String(describing: second[key]))") }
    }
    return found
}

/// What the check, Validation and :misfit hold of the board, each against the others.
@MainActor private func boardSplits(_ editor: CanvasEditor) throws -> [String] {
    var found: [String] = []
    let checks = try require(editor.fieldChecks)
    let misfits = Set(try queried("bond:misfit", on: editor).rows.map(\.id))
    for record in editor.document.shapes where record.typed(as: Bond.self) != nil {
        let check = checks.fullCheck(of: record)
        let wrong = check.problems.filter { $0.kind == .wrong }.map(\.message).sorted()
        let errors = editor.issues(record.id).filter { $0.severity == .error }.map(\.message).sorted()
        if wrong != errors { found.append("check \(wrong) against Validation \(errors)") }
        if check.isMisfit != misfits.contains(record.id) { found.append(":misfit \(misfits.contains(record.id)) against the check \(check.problems.map(\.message))") }
    }
    return found
}

private let world = """
memo "Person" schema: "\(schema)"
memo "Employment" right of "Person" schema: "\(schema)" relationship: true
memo "Company" right of "Employment" schema: "\(schema)"
memo "Layer" below "Company" schema: "\(schema)"
edge "Person" -> "Employment" text: "jobs" endRule: {"onlyOne": true}
edge "Employment" -> "Company"
memo "Ann" below "Person" is: "Person"
memo "Bo" below "Ann" is: "Person"
memo "Acme" below "Layer" is: "Company"
memo "foundation" below "Acme" is: "Layer"
"""

@MainActor let relationshipRunAgreesTests = Suite("A run says what the board then says", [
    test("all in one script, the arrows first and the types last") {
        let editor = try runEditor()
        let script = """
        edge "Ann" -> "Acme" is: "Employment"
        edge "Ann" -> "foundation" is: "Employment"
        edge "Ann" -> "Bo" is: "Employment"
        edge "Bo" -> "Acme"
        edge "Bo" -> "foundation"
        edge "Employment" -> "Company"
        edge "Person" -> "Employment" text: "jobs" endRule: {"onlyOne": true}
        memo "foundation" is: "Layer"
        memo "Acme" right of "foundation" is: "Company"
        memo "Bo" right of "Acme" is: "Person"
        memo "Ann" right of "Bo" is: "Person"
        memo "Layer" below "foundation" schema: "\(schema)"
        memo "Company" right of "Layer" schema: "\(schema)"
        memo "Employment" right of "Company" schema: "\(schema)" relationship: true
        memo "Person" right of "Employment" schema: "\(schema)"
        """
        expectEqual(try disagreements(script, on: editor), [])
        expectEqual(try boardSplits(editor), [])
    },
    test("a subtype, an open side, an arrow between two types with is:, an arrow from a type's note") {
        let editor = try runEditor()
        let script = world + "\n" + """
        memo "Startup" below "foundation" schema: "\(schema)" is: "Company"
        memo "Initech" below "Startup" is: "Startup"
        memo "Mentor" right of "Company" schema: "\(schema)" relationship: true
        edge "Person" -> "Mentor"
        edge "Ann" -> "Initech" is: "Employment"
        edge "Ann" -> "foundation" is: "Mentor"
        edge "foundation" -> "Ann" is: "Mentor"
        edge "Person" -> "Company" is: "Employment"
        edge "Person" -> "Acme" is: "Employment"
        edge "Bo" -> "Initech"
        edge "Bo" -> "foundation"
        """
        expectEqual(try disagreements(script, on: editor), [])
        expectEqual(try boardSplits(editor), [])
    },
    test("a later run changes what an earlier one drew: an end moved, a type unmarked, a type marked, an end's type deleted") {
        let editor = try runEditor()
        _ = try ran(world + "\n" + """
        edge "Ann" -> "Acme" is: "Employment"
        edge "Ann" -> "foundation" is: "Employment"
        edge "Bo" -> "Acme"
        """, on: editor)
        // The to end moves from Company to Layer: the fit of each restated arrow turns over.
        expectEqual(try disagreements("""
        delete edge "Employment" -> "Company"
        edge "Employment" -> "Layer"
        edge "Ann" -> "Acme" is: "Employment"
        edge "Ann" -> "foundation" is: "Employment"
        edge "Bo" -> "Acme"
        memo "Employment" relationship: true schema: "\(schema)"
        """, on: editor, restatesAll: false), [], "an end moved")
        expectEqual(try boardSplits(editor), [])
        // Unmarked: nothing is judged.
        expectEqual(try disagreements("""
        memo "Employment" relationship: null schema: "\(schema)"
        edge "Ann" -> "Acme" is: "Employment"
        edge "Ann" -> "foundation" is: "Employment"
        edge "Bo" -> "Acme"
        edge "Person" -> "Employment"
        """, on: editor), [], "unmarked")
        expectEqual(try boardSplits(editor), [])
        // Marked again.
        expectEqual(try disagreements("""
        memo "Employment" relationship: true schema: "\(schema)"
        edge "Ann" -> "Acme" is: "Employment"
        edge "Ann" -> "foundation" is: "Employment"
        edge "Bo" -> "Acme"
        edge "Person" -> "Employment"
        edge "Employment" -> "Layer"
        """, on: editor), [], "marked again")
        expectEqual(try boardSplits(editor), [])
        // The to end's type deleted: the side is open.
        expectEqual(try disagreements("""
        delete "Layer"
        memo "Employment" relationship: true schema: "\(schema)"
        edge "Ann" -> "Acme" is: "Employment"
        edge "Bo" -> "Acme"
        edge "Person" -> "Employment"
        """, on: editor, restatesAll: false), [], "an end's type deleted")
        expectEqual(try boardSplits(editor), [])
    },
    test("a note retyped, and a type that stops building on an end, by the run that restates the arrow") {
        let editor = try runEditor()
        _ = try ran(world + "\n" + """
        memo "Startup" below "foundation" schema: "\(schema)" is: "Company"
        memo "Initech" below "Startup" is: "Startup"
        edge "Ann" -> "Acme" is: "Employment"
        edge "Ann" -> "Initech" is: "Employment"
        """, on: editor)
        expectEqual(try disagreements("""
        memo "Acme" is: "Layer"
        memo "Startup" schema: "\(schema)" is: "Layer"
        edge "Ann" -> "Acme" is: "Employment"
        edge "Ann" -> "Initech" is: "Employment"
        """, on: editor), [])
        expectEqual(try boardSplits(editor), [])
    },
    test("the order of a side's types in relates, in a run that marks a type an older arrow already ran into") {
        let editor = try runEditor()
        _ = try ran("""
        memo "Person" schema: "\(schema)"
        memo "Agency" below "Person" schema: "\(schema)"
        memo "Hire" right of "Person" schema: "\(schema)"
        memo "Company" right of "Hire" schema: "\(schema)"
        edge "Agency" -> "Hire"
        """, on: editor)
        expectEqual(try disagreements("""
        memo "Hire" schema: "\(schema)" relationship: true
        edge "Person" -> "Hire"
        edge "Hire" -> "Company"
        """, on: editor, restatesAll: false), [])
    },
    test("the order of a side's types when a note at an older arrow becomes a type in the run: relates and the misfit's words") {
        let editor = try runEditor()
        _ = try ran("""
        memo "Agency"
        memo "Person" below "Agency" schema: "\(schema)"
        memo "Hire" right of "Person" schema: "\(schema)" relationship: true
        memo "Company" right of "Hire" schema: "\(schema)"
        edge "Agency" -> "Hire"
        edge "Person" -> "Hire"
        edge "Hire" -> "Company"
        memo "Acme" below "Company" is: "Company"
        memo "Initech" below "Acme" is: "Company"
        edge "Acme" -> "Initech" is: "Hire"
        """, on: editor)
        let script = """
        memo "Agency" schema: "\(schema)"
        memo "Hire" schema: "\(schema)" relationship: true
        edge "Acme" -> "Initech" is: "Hire"
        """
        let dry = try ran(script, on: editor, dryRun: true)
        let real = try ran(script, on: editor)
        let again = try ran(script, on: editor)
        expectEqual(said(dry.rows), said(real.rows), "a dry run says what the run says")
        expectEqual(said(again.rows), said(real.rows), "and the run again says what the first said: the board has not changed")
        let hire = try require(editor.document.shapes.first { editor.registry.title(of: $0) == "Hire" })
        let sides = try require(editor.relationships).graph.sides(of: hire.id)
        expectEqual(real.rows.first { $0["title"]?.stringValue == "Hire" }?["relates"]?["from"]?.arrayValue?.compactMap(\.stringValue),
                    sides.types(on: .from).map { title($0, editor) }, "relates.from of the run against the committed sides")
        let arrow = try require(editor.document.shapes.first { $0.typed(as: Bond.self) != nil && !($0[IsAProperty.self] ?? []).isEmpty })
        expectEqual(real.rows.last?["problems"]?.arrayValue?.compactMap { $0["message"]?.stringValue } ?? [], editor.issues(arrow.id).map(\.message),
                    "the misfit's words in the run's row against Validation's a moment later")
    },
    test("the run's graph is the graph a fresh compile gives, the rows of an end type with two relationship types in their order") {
        // Two relationship types with an end each at Person, drawn in one transaction: the rows Person's notes get, in a
        // run and committed. Thirty times, for the order of ids.
        for round in 0..<30 {
            let editor = try bondEditor()
            let person = ShapeID(), first = ShapeID(), second = ShapeID(), company = ShapeID()
            var inRun: RelationshipEnds?
            editor.transact("Run") { transaction in
                transaction.insert(typeRecord(TypeSchemaProperty.starter, title: "Person", id: person))
                transaction.insert(typeRecord(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 40, y: 200), id: company))
                for (id, name) in [(first, "First"), (second, "Second")] {
                    var record = slipTypeRecord(TypeSchemaProperty.starter, title: name, at: CGPoint(x: 400, y: id == first ? 40 : 300), id: id)
                    record[RelationshipProperty.self] = true
                    transaction.insert(record)
                }
                transaction.insert(AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: person, to: first))))
                transaction.insert(AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: person, to: second))))
                transaction.insert(AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: first, to: company))))
                if let reading = transaction.shapes.reading { inRun = editor.relationships?.graph(in: reading).ends }
            }
            let committed = try require(editor.relationships).graph.ends
            let run = try require(inRun)
            expectEqual(run.sides, committed.sides, "round \(round): the sides")
            expectEqual(run.rows[person]?.map(\.key.type), committed.rows[person]?.map(\.key.type), "round \(round): Person's rows, by relationship type, in order")
            if run.rows[person]?.map(\.key.type) != committed.rows[person]?.map(\.key.type) { break }
        }
    },
])

@MainActor let relationshipRunDetailTests = Suite("Details of a run", [
    test("the rows of an end type keep a relationship type's rows when a second relationship type gets an end there, the graph asked between the two") {
        let editor = try bondEditor()
        let person = ShapeID(), first = ShapeID(), second = ShapeID()
        var once: [ShapeID] = [], twice: [ShapeID] = []
        editor.transact("Run") { transaction in
            guard let relationships = editor.relationships else { return }
            transaction.insert(slipTypeRecord(TypeSchemaProperty.starter, title: "Person", id: person))
            for (id, name) in [(first, "First"), (second, "Second")] {
                var record = slipTypeRecord(TypeSchemaProperty.starter, title: name, at: CGPoint(x: 400, y: id == first ? 40 : 300), id: id)
                record[RelationshipProperty.self] = true
                transaction.insert(record)
            }
            transaction.insert(AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: person, to: first))))
            if let reading = transaction.shapes.reading { once = relationships.graph(in: reading).ends.rows[person]?.map(\.key.type) ?? [] }
            transaction.insert(AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: person, to: second))))
            if let reading = transaction.shapes.reading { twice = relationships.graph(in: reading).ends.rows[person]?.map(\.key.type) ?? [] }
        }
        let committed = try require(editor.relationships).graph.ends.rows[person]?.map(\.key.type) ?? []
        expectEqual(once, [first], "after the first end")
        expectEqual(Set(twice), Set(committed), "after the second, asked again: the rows of both relationship types, as the commit has them")
    },
    test("a plain type on an arrow is warned of when the type and the arrow are drawn in one script, on a board with no relationship type") {
        let script = """
        memo "Friendship" schema: "\(schema)"
        memo "Ann" below "Friendship"
        memo "Bo" below "Ann"
        edge "Ann" -> "Bo" is: "Friendship"
        """
        let words = "“Friendship” isn't a relationship type, so nothing checks this arrow's ends. Mark it with relationship: true."
        // In two runs: the type first, then the arrow. The design's warning (P2).
        let two = try runEditor()
        _ = try ran("""
        memo "Friendship" schema: "\(schema)"
        memo "Ann" below "Friendship"
        memo "Bo" below "Ann"
        """, on: two)
        let later = try ran(#"edge "Ann" -> "Bo" is: "Friendship""#, on: two)
        expectEqual(later.warnings.compactMap { $0["message"]?.stringValue }.filter { $0.contains(words) }.count, 1, "the type on the board, the arrow in the next run")
        // In one run.
        let one = try runEditor()
        let dry = try ran(script, on: one, dryRun: true)
        expectEqual(dry.warnings.compactMap { $0["message"]?.stringValue }.filter { $0.contains(words) }.count, 1, "a dry run of the one script: \(dry.warnings)")
        let real = try ran(script, on: one)
        expectEqual(real.warnings.compactMap { $0["message"]?.stringValue }.filter { $0.contains(words) }.count, 1, "the one script: \(real.warnings)")
    },
    test("a note's relations in a run, through a pill that stands for two notes, are what the commit says a moment later") {
        let editor = try bondEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 40, y: 40))
        let employment = editor.addRelationshipType("Employment")
        let ann = editor.addInstance("Ann", of: [person], at: CGPoint(x: 500, y: 400))
        let bo = editor.addInstance("Bo", of: [person], at: CGPoint(x: 500, y: 600))
        let cy = editor.addInstance("Cy", of: [person], at: CGPoint(x: 800, y: 600))
        editor.open(bo)
        editor.open(cy)
        let pill = editor.addRelay(standingFor: [bo, cy], says: "both")
        var inRun: [String] = []
        let arrow = ShapeID()
        editor.transact("Run") { transaction in
            var record = AnyShapeRecord(ShapeRecord(id: arrow, Bond(from: ann, to: pill)))
            record[IsAProperty.self] = [TypeLink(employment)]
            transaction.insert(record)
            guard let reading = transaction.shapes.reading, let relationships = editor.relationships else { return }
            inRun = relationships.relations(of: bo, in: reading).map { "\($0.arrow == arrow) \($0.side)" }
        }
        let committed = try require(editor.relationships).relations(of: bo).map { "\($0.arrow == arrow) \($0.side)" }
        expectEqual(inRun, committed, "Bo's relations in the run against the commit's")
    },
])

@MainActor let relationshipRunPillTests = Suite("A run that changes a pill an end is drawn at", [
    test("an end drawn at a pill for a type, the pill pointed at another type by the run: the run's sides and the check of a relationship are the commit's") {
        for open in [true, false] {
            let editor = try bondEditor()
            let person = editor.addSlipType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 40, y: 40))
            let company = editor.addSlipType(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 40, y: 200))
            if open {
                editor.open(person)
                editor.open(company)
            }
            let employment = editor.addRelationshipType("Employment")
            let pill = editor.addRelay(standingFor: [person], says: "a type")
            editor.addBond(pill, employment)
            let ann = editor.addInstance("Ann", of: [person], title: "Ann", at: CGPoint(x: 500, y: 400))
            let acme = editor.addInstance("Acme", of: [company], title: "Acme", at: CGPoint(x: 800, y: 400))
            let job = editor.addBond(ann, acme, of: [employment])
            let relationships = try require(editor.relationships)
            expectEqual(relationships.graph.sides(of: employment).types(on: .from), [person], "to begin with, Employment runs from a Person (open: \(open))")
            expectEqual(editor.issues(job).map(\.message), [])
            var sidesInRun: [ShapeID]?
            var saidInRun: [String]?
            editor.transact("Run") { transaction in
                transaction.update(pill, as: Relay.self) { $0.props.stands = [Citation(company)] }
                guard let reading = transaction.shapes.reading, let record = transaction.document[job], let checks = editor.fieldChecks else { return }
                sidesInRun = relationships.graph(in: reading).sides(of: employment).types(on: .from)
                saidInRun = checks.check(of: record, reading: reading).problems.map(\.message)
            }
            expectEqual(relationships.graph.sides(of: employment).types(on: .from), [company], "committed: it runs from a Company now (open: \(open))")
            expectEqual(sidesInRun, [company], "and the run that pointed the pill there said so (open: \(open))")
            expectEqual(saidInRun, editor.issues(job).map(\.message), "the check of Ann's job in the run against Validation's a moment later (open: \(open))")
        }
    },
])

@MainActor let relationshipRunFarWriteTests = Suite("A run that writes on another board", [
    test("an end deleted on another board, and a relationship type unmarked there, by the run: the check of an arrow in the run is the commit's") {
        for unmark in [false, true] {
            let pocket = ShapeID(), person = ShapeID(), company = ShapeID(), layer = ShapeID(), employment = ShapeID(), toEnd = ShapeID()
            let ann = ShapeID(), foundation = ShapeID(), arrow = ShapeID()
            var related = slipTypeRecord(TypeSchemaProperty.starter, title: "Employment", at: CGPoint(x: 400, y: 40), id: employment)
            related[RelationshipProperty.self] = true
            var typed = AnyShapeRecord(ShapeRecord(id: arrow, Bond(from: ann, to: foundation)))
            typed[IsAProperty.self] = [TypeLink(employment)]
            let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 0, y: 900, width: 100, height: 100)))),
                                                                instanceRecord("Ann", of: [person], title: "Ann", at: CGPoint(x: 500, y: 400), id: ann),
                                                                instanceRecord("foundation", of: [layer], title: "foundation", at: CGPoint(x: 800, y: 400), id: foundation),
                                                                typed]),
                                  children: [pocket: CanvasDocument(shapes: [
                                      slipTypeRecord(TypeSchemaProperty.starter, title: "Person", id: person),
                                      slipTypeRecord(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 40, y: 200), id: company),
                                      slipTypeRecord(TypeSchemaProperty.starter, title: "Layer", at: CGPoint(x: 40, y: 360), id: layer),
                                      related,
                                      AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: person, to: employment))),
                                      AnyShapeRecord(ShapeRecord(id: toEnd, Bond(from: employment, to: company)))])])
            let editor = try bondEditor(file: file)
            expectEqual(editor.issues(arrow).map(\.message), ["Employment runs to a Company. “foundation” is a Layer."], "to begin with, a misfit")
            var inRun: [String]?
            editor.transact("Run") { transaction in
                if unmark {
                    transaction.update(inFile: employment) { $0[RelationshipProperty.self] = nil }
                } else {
                    transaction.delete(inFile: [toEnd])
                }
                guard let reading = transaction.shapes.reading, let record = transaction.document[arrow], let checks = editor.fieldChecks else { return }
                inRun = checks.check(of: record, reading: reading).problems.map(\.message)
            }
            expectEqual(editor.issues(arrow).map(\.message), [], "committed: \(unmark ? "no relationship type" : "the to side is open"), so nothing is wrong")
            expectEqual(inRun, [], "and the run that \(unmark ? "unmarked the type" : "deleted the end") on the other board says the same of the arrow")
        }
    },
])

// MARK: :misfit against the check, through a pill

@MainActor let misfitPillTests = Suite(":misfit and the check through a pill", [
    test("an arrow that misfits at its start, its end a pill that is gone, empty, of two shapes, not open, open") {
        let editor = try runEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 40, y: 40))
        let company = editor.addType(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 40, y: 200))
        let layer = editor.addType(TypeSchemaProperty.starter, title: "Layer", at: CGPoint(x: 40, y: 360))
        let employment = editor.addRelationshipType("Employment")
        editor.addBond(person, employment)
        editor.addBond(employment, company)
        let wrongStart = editor.addInstance("foundation", of: [layer], at: CGPoint(x: 500, y: 400))
        let acme = editor.addInstance("Acme", of: [company], at: CGPoint(x: 800, y: 400))
        let other = editor.addInstance("Other", of: [company], at: CGPoint(x: 800, y: 600))
        let closed = editor.addInstance("Closed", of: [company], at: CGPoint(x: 800, y: 800))
        editor.open(acme)
        editor.open(other)
        let pills: [(String, ShapeID)] = [
            ("gone", editor.addRelay(standingFor: [ShapeID()], says: "Gone", at: CGPoint(x: 40, y: 700))),
            ("empty", editor.addRelay(standingFor: [], at: CGPoint(x: 40, y: 760))),
            ("two", editor.addRelay(standingFor: [acme, other], at: CGPoint(x: 40, y: 820))),
            ("not open", editor.addRelay(standingFor: [closed], at: CGPoint(x: 40, y: 880))),
            ("open", editor.addRelay(standingFor: [acme], at: CGPoint(x: 40, y: 940))),
        ]
        var arrows: [(String, ShapeID)] = []
        for (name, pill) in pills { arrows.append((name, editor.addBond(wrongStart, pill, of: [employment]))) }
        let checks = try require(editor.fieldChecks)
        let misfits = Set(try queried("bond:misfit", on: editor).rows.map(\.id))
        for (name, arrow) in arrows {
            let record = try require(editor.shape(inFile: arrow))
            let check = checks.fullCheck(of: record)
            expectEqual(misfits.contains(arrow), check.isMisfit, "a pill that is \(name): :misfit against the check, which says \(check.problems.map(\.message))")
            expectEqual(editor.issues(arrow).contains { $0.severity == .error }, check.isMisfit, "a pill that is \(name): Validation against the check")
        }
    },
    test(":misfit finds nothing in a file with no relationship type, whatever types the arrows list") {
        let editor = try runEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 40, y: 40))
        let plain = editor.addType(TypeSchemaProperty.starter, title: "Friendship", at: CGPoint(x: 400, y: 40))
        let ann = editor.addInstance("Ann", of: [person], at: CGPoint(x: 500, y: 400))
        let bo = editor.addInstance("Bo", of: [person], at: CGPoint(x: 800, y: 400))
        editor.addBond(ann, bo, of: [plain])
        expectEqual(try queried("bond:misfit", on: editor).rows.map(\.id), [], "a plain type on an arrow is no relationship type")
        expectEqual(try queried("bond:misfit", on: editor).count, 0)
    },
    test(":misfit finds an arrow on a board the editor does not show") {
        let pocket = ShapeID(), person = ShapeID(), company = ShapeID(), layer = ShapeID(), employment = ShapeID(), ann = ShapeID(), foundation = ShapeID(), arrow = ShapeID()
        var related = slipTypeRecord(TypeSchemaProperty.starter, title: "Employment", at: CGPoint(x: 400, y: 40), id: employment)
        related[RelationshipProperty.self] = true
        var typed = AnyShapeRecord(ShapeRecord(id: arrow, Bond(from: ann, to: foundation)))
        typed[IsAProperty.self] = [TypeLink(employment)]
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 0, y: 900, width: 100, height: 100))))]),
                              children: [pocket: CanvasDocument(shapes: [
                                  slipTypeRecord(TypeSchemaProperty.starter, title: "Person", id: person),
                                  slipTypeRecord(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 40, y: 200), id: company),
                                  slipTypeRecord(TypeSchemaProperty.starter, title: "Layer", at: CGPoint(x: 40, y: 360), id: layer),
                                  related,
                                  instanceRecord("Ann", of: [person], title: "Ann", at: CGPoint(x: 500, y: 400), id: ann),
                                  instanceRecord("foundation", of: [layer], title: "foundation", at: CGPoint(x: 800, y: 400), id: foundation),
                                  AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: person, to: employment))),
                                  AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: employment, to: company))),
                                  typed])])
        let editor = try queryBondEditor(file: file)
        expectEqual(try queried("bond:misfit", on: editor).rows.map(\.id), [arrow], "the root is shown, and the arrow is in the pocket")
    },
])

