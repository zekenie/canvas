@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit
import Types
import Validation

// What an arrow's ends say of a relationship, as pure functions: `RelationChecks.arrow` is handed the graph, the
// ends and the names, and `RelationWords` says each sentence. The graph is read from a bond editor, once; the
// ends and the names are made by hand.

/// Person, Company and Layer, Employment from a Person to a Company (or an Agency), and the notes a case judges.
@MainActor private struct World {
    let editor: CanvasEditor
    let person: ShapeID, company: ShapeID, layer: ShapeID, agency: ShapeID, employment: ShapeID
    let ann: ShapeID, acme: ShapeID, foundation: ShapeID, plain: ShapeID
    let labels: [ShapeID: String]

    init() throws {
        editor = try bondEditor()
        person = editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 40, y: 40))
        company = editor.addType(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 40, y: 200))
        layer = editor.addType(TypeSchemaProperty.starter, title: "Layer", at: CGPoint(x: 40, y: 360))
        agency = editor.addType(TypeSchemaProperty.starter, title: "Agency", at: CGPoint(x: 40, y: 520))
        employment = editor.addRelationshipType("Employment")
        editor.addBond(person, employment)
        editor.addBond(employment, company)
        editor.addBond(employment, agency)
        ann = editor.addInstance("Ann", of: [person])
        acme = editor.addInstance("Acme", of: [company])
        foundation = editor.addInstance("foundation", of: [layer])
        plain = editor.addInstance("A note", of: [])
        labels = [person: "Person", company: "Company", ann: "Ann", acme: "Acme", foundation: "foundation", plain: "A note"]
    }

    var graph: RelationshipGraph { editor.relationships!.graph }

    var naming: RelationNaming {
        let labels = labels, graph = graph, editor = editor
        return RelationNaming(label: { labels[$0] ?? "?" },
                              directTypes: { editor.typesOf($0).filter(graph.types.types.contains) },
                              kindName: { _ in nil })
    }

    func read(_ id: ShapeID) -> ReadEnd { ReadEnd(literal: id, reading: .note(id)) }
    func ends(_ from: ShapeID, _ to: ShapeID) -> ConnectionReading { ConnectionReading(from: read(from), to: read(to)) }

    func verdict(_ ends: ConnectionReading?, types: [ShapeID]? = nil, naming: RelationNaming? = nil) -> ArrowVerdict {
        RelationChecks.arrow(types: types ?? [employment], ends: ends, graph: graph, naming: naming ?? self.naming)
    }
}

@MainActor let relationCheckerTests = Suite("The check of an arrow's ends", [
    test("an arrow that runs from a Person to a Company says nothing; a Person's subtype and an Agency fit as well") {
        let w = try World()
        expectEqual(w.verdict(w.ends(w.ann, w.acme)), ArrowVerdict())
        let employee = w.editor.addType(TypeSchemaProperty.starter, title: "Employee", at: CGPoint(x: 400, y: 40))
        w.editor.addTypeLink(w.person, to: employee)
        let bo = w.editor.addInstance("Bo", of: [employee])
        let agent = w.editor.addInstance("Smith", of: [w.agency])
        expectEqual(w.verdict(ConnectionReading(from: ReadEnd(literal: bo, reading: .note(bo)), to: ReadEnd(literal: agent, reading: .note(agent)))).problems, [], "a subtype and an Agency")
    },
    test("a misfit is one error at its end, in the words of the drawing, and the end it quotes is named") {
        let w = try World()
        let verdict = w.verdict(w.ends(w.ann, w.foundation))
        expectEqual(verdict.problems.count, 1)
        let problem = try require(verdict.problems.first)
        expectEqual(problem.kind, .wrong)
        expectEqual(problem.locus, .end(.to))
        expectEqual(problem.keyword, "misfit")
        expectEqual(problem.place, [])
        expect(problem.path.isRoot)
        expectEqual(problem.message, "Employment runs to a Company or an Agency. “foundation” is a Layer.")
        expectEqual(verdict.quoted, [w.foundation])
        let from = w.verdict(w.ends(w.acme, w.acme))
        expectEqual(from.problems.map(\.message), ["Employment runs from a Person. “Acme” is a Company."])
        expectEqual(from.problems.map(\.locus), [.end(.from)])
    },
    test("both ends a misfit are two errors, from first; a misfit and an unread end are an error and a warning") {
        let w = try World()
        let both = w.verdict(w.ends(w.foundation, w.foundation))
        expectEqual(both.problems.map(\.locus), [.end(.from), .end(.to)])
        expectEqual(both.quoted, [w.foundation])
        let mixed = w.verdict(ConnectionReading(from: w.read(w.foundation), to: ReadEnd(literal: ShapeID(), reading: .empty)))
        expectEqual(mixed.problems.map(\.kind), [.wrong, .warning])
        expectEqual(mixed.problems.map(\.locus), [.end(.from), .end(.to)])
        expectEqual(mixed.problems.map(\.keyword), ["misfit", "unread"])
    },
    test("a type's own note, a note with no type and a shape of a kind that holds no type are each a misfit, said as what they are") {
        let w = try World()
        expectEqual(w.verdict(w.ends(w.ann, w.person)).problems.map(\.message), ["Employment runs to a Company or an Agency. “Person” is a type."])
        expectEqual(w.verdict(w.ends(w.plain, w.acme)).problems.map(\.message), ["Employment runs from a Person. “A note” has no type."])
        var naming = w.naming
        naming.kindName = { $0 == w.plain ? "pocket" : nil }
        expectEqual(w.verdict(w.ends(w.plain, w.acme), naming: naming).problems.map(\.message), ["Employment runs from a Person. “A note” is a pocket."])
        naming.kindName = { $0 == w.plain ? "gadget" : nil }
        expectEqual(w.verdict(w.ends(w.plain, w.acme), naming: naming).problems.map(\.message), ["Employment runs from a Person. “A note” is a gadget."])
        let both = w.editor.addInstance("Both", of: [w.layer, w.company])
        var named = w.naming
        named.label = { $0 == both ? "Both" : "?" }
        expectEqual(w.verdict(w.ends(both, w.acme), naming: named).problems.map(\.message), ["Employment runs from a Person. “Both” is a Layer and a Company."])
    },
    test("a side with no end drawn fits anything, and an arrow of a type that is gone or not marked is not judged") {
        let w = try World()
        let loose = w.editor.addRelationshipType("Loose", at: CGPoint(x: 800, y: 40))
        expectEqual(w.verdict(w.ends(w.foundation, w.foundation), types: [loose]), ArrowVerdict(), "no end drawn: both open")
        expectEqual(w.verdict(w.ends(w.foundation, w.foundation), types: [w.person]), ArrowVerdict(), "a plain type")
        expectEqual(w.verdict(w.ends(w.foundation, w.foundation), types: [ShapeID()]), ArrowVerdict(), "a type that is gone")
        expectEqual(w.verdict(nil, types: [w.person]), ArrowVerdict(), "a plain type: a free end is not flagged")
        expectEqual(w.verdict(w.ends(w.foundation, w.foundation), types: []), ArrowVerdict())
    },
    test("two marked types are each judged and an equal sentence is said once; an unmarked type beside a marked one says nothing") {
        let w = try World()
        let twin = w.editor.addRelationshipType("Employment", at: CGPoint(x: 800, y: 200))
        w.editor.addBond(w.person, twin)
        w.editor.addBond(twin, w.company)
        w.editor.addBond(twin, w.agency)
        expectEqual(w.verdict(w.ends(w.ann, w.foundation), types: [w.employment, twin]).problems.count, 1, "the same words once")
        let other = w.editor.addRelationshipType("Mentorship", at: CGPoint(x: 800, y: 400))
        w.editor.addBond(w.layer, other)
        let two = w.verdict(w.ends(w.ann, w.foundation), types: [w.person, w.employment, other])
        expectEqual(two.problems.map(\.message), ["Employment runs to a Company or an Agency. “foundation” is a Layer.", "Mentorship runs from a Layer. “Ann” is a Person."],
                    "each marked type judged alone, in list order, the plain type left out")
    },
    test("an arrow of a relationship type that is not bound at both ends is one orange line at no end, once for all its types") {
        let w = try World()
        let other = w.editor.addRelationshipType("Mentorship", at: CGPoint(x: 800, y: 400))
        let verdict = w.verdict(nil, types: [w.employment, other])
        expectEqual(verdict.problems.count, 1)
        let problem = try require(verdict.problems.first)
        expectEqual(problem.kind, .warning)
        expectEqual(problem.locus, .end(nil))
        expectEqual(problem.message, "Employment isn’t attached at both ends.")
        expectEqual(problem.placeName, nil)
        expectEqual(verdict.quoted, [])
    },
    test("an end that cannot be read is an orange line at that end, and one the app cannot show says nothing") {
        let w = try World()
        let pill = ShapeID()
        @MainActor func unread(_ reading: EndReading, side: RelationshipSide = .to) -> ArrowVerdict {
            let end = ReadEnd(literal: pill, reading: reading)
            return w.verdict(side == .to ? ConnectionReading(from: w.read(w.ann), to: end) : ConnectionReading(from: end, to: w.read(w.acme)))
        }
        expectEqual(unread(.gone(called: nil)).problems.map(\.message), ["Employment runs to a note that is gone."])
        expectEqual(unread(.gone(called: "Acme")).problems.map(\.message), ["Employment runs to “Acme”, which is gone."])
        expectEqual(unread(.notAdmitted(w.acme, needs: "open")).problems.map(\.message), ["Employment runs to “Acme”, which isn’t open."])
        expectEqual(unread(.notAdmitted(w.acme, needs: "open")).quoted, [w.acme])
        expectEqual(unread(.query(called: "Companies")).problems.map(\.message), ["Employment runs to a pill that stands for several notes."])
        expectEqual(unread(.empty, side: .from).problems.map(\.message), ["Employment runs from a pill that stands for nothing."])
        expectEqual(unread(.unavailable(called: "Acme")), ArrowVerdict())
        for reading in [EndReading.gone(called: nil), .query(called: nil), .empty] {
            let problem = try require(unread(reading).problems.first)
            expectEqual(problem.kind, .warning)
            expectEqual(problem.keyword, "unread")
            expectEqual(problem.locus, .end(.to))
        }
    },
    test("a check says where it is wrong at an end, and a field's reads ignore the ends") {
        let w = try World()
        let misfit = w.verdict(w.ends(w.ann, w.foundation)).problems
        let unread = w.verdict(ConnectionReading(from: w.read(w.ann), to: ReadEnd(literal: ShapeID(), reading: .empty))).problems
        let field = FieldProblem(path: FieldPath(field: "email"), kind: .wrong, keyword: "format", place: ["email"], message: "email is wrong")
        let check = FieldCheck(problems: [field] + misfit + unread)
        expectEqual(check.endMark(.to), .wrong, "the worst at the end")
        expectEqual(check.endMark(.from), nil)
        expectEqual(check.endMark(nil), nil)
        expectEqual(check.worstEnd, .wrong)
        expect(check.isMisfit)
        expect(!FieldCheck(problems: unread).isMisfit, "an unread end is no misfit")
        expectEqual(FieldCheck(problems: unread).worstEnd, .warning)
        expect(!FieldCheck(problems: [FieldProblem(path: FieldPath(), kind: .warning, keyword: "free", place: [], message: "m", locus: .end(nil))]).isMisfit)
        expectEqual(check.mark(at: FieldPath(field: "email")), .wrong)
        expectEqual(check.mark(at: FieldPath()), .wrong, "the root is above the field")
        expectEqual(check.problems(at: FieldPath()), [], "an end is at no path")
        expectEqual(check.removingRelations().problems, [field])
        expectEqual(check.leaving(out: FieldPath(field: "email")).problems, misfit + unread, "typing in a field leaves the ends")
        expectEqual(FieldCheck(problems: misfit).mark(at: FieldPath(field: "email")), nil)
    },
    test("Validation, draw and queries say where a problem is by one mapping: a field's name, from, to, or a row's name") {
        let field = FieldProblem(path: FieldPath(field: "email"), kind: .wrong, keyword: "format", place: ["email"], message: "m")
        expectEqual(field.placeName, "email")
        expectEqual(field.pointer, "/email")
        let root = FieldProblem(path: FieldPath(), kind: .wrong, keyword: "rule", place: [], message: "m")
        expectEqual(root.placeName, nil)
        expectEqual(root.pointer, nil)
        for (side, name) in [(RelationshipSide.from, "from"), (.to, "to")] {
            let end = FieldProblem(path: FieldPath(), kind: .wrong, keyword: "misfit", place: [], message: "m", locus: .end(side))
            expectEqual(end.placeName, name)
            expectEqual(end.pointer, nil)
        }
        expectEqual(FieldProblem(path: FieldPath(), kind: .warning, keyword: "free", place: [], message: "m", locus: .end(nil)).placeName, nil)
        let key = RelationshipRowKey(type: ShapeID(), label: .typed("layer"))
        let row = FieldProblem(path: FieldPath(), kind: .needed, keyword: "required", place: ["layer"], message: "layer is needed", locus: .row(key))
        expectEqual(row.placeName, "layer")
        expectEqual(row.pointer, nil)
        expectEqual(row.fieldPath, nil)
        expectEqual(FieldCheck(problems: [row]).mark(at: FieldPath(field: "layer")), nil, "a row named like a field marks no field")
    },
    test("an arrow its relationship type was taken from is a loose end when it is left at a type's note with a name or a rule, and says nothing with neither, at a note that is no type, or at both ends") {
        let w = try World()
        let checks = try require(w.editor.fieldChecks)
        let line = "This arrow isn’t attached at both ends."
        @MainActor func said(_ id: ShapeID) -> [FieldProblem] { checks.fullCheck(of: w.editor.file.record(id)!).problems }
        let named = w.editor.addBond(w.person, nil, name: "friends")
        let ruled = w.editor.addBond(nil, w.company, rule: EndRule(needed: true, onlyOne: false))
        let bare = w.editor.addBond(w.person, nil)
        let atNote = w.editor.addBond(w.ann, nil, name: "friends")
        let both = w.editor.addBond(w.person, w.company, name: "friends")
        let nowhere = w.editor.addBond(nil, nil, name: "friends")
        let bound = w.editor.addBond(w.employment, nil)
        expectEqual(said(named).map(\.message), [line], "a name")
        expectEqual(said(ruled).map(\.message), [line], "a rule")
        expectEqual(said(named).first?.kind, .warning)
        expectEqual(said(named).first?.locus, .end(nil))
        expectEqual(said(bare), [], "neither: a plain arrow that lost an end")
        expectEqual(said(atNote), [], "a note that is no type")
        expectEqual(said(both), [], "both ends bound")
        expectEqual(said(nowhere), [], "bound to nothing")
        expectEqual(said(bound).map(\.message), ["Employment isn’t attached at both ends."], "still bound to a relationship type: it is named")
        // The note stops being a type: no end of a relationship type.
        w.editor.removeType(w.person)
        expectEqual(said(named), [], "Person is no type")
        expectEqual(w.editor.issues(named).map(\.message), [], "and Validation holds none")
        w.editor.undo()
        expectEqual(said(named).map(\.message), [line], "a type again")
        expectEqual(w.editor.issues(named).map(\.message), [line], "and Validation holds the line")
        // And with no relationship type left in the file at all.
        w.editor.transact("Delete") { $0.delete([w.employment]) }
        expect(w.editor.relationships?.isActive == false)
        expectEqual(said(named).map(\.message), [line])
        expectEqual(w.editor.issues(named).map(\.message), [line])
        expectEqual(said(bare), [])
        expect(w.editor.file.record(bound) == nil, "bound to the relationship type alone, it went with it")
        let plain = try bondEditor()
        let note = plain.addInstance("A note", of: [])
        let lone = plain.addBond(note, nil, name: "friends")
        expectEqual(try require(plain.fieldChecks).fullCheck(of: try require(plain.file.record(lone))).problems, [], "a file with no type says nothing of a named arrow")
    },    test("a Needed row with no relationship is one needed problem at the row, and no other count is: no issue, only the check's") {
        let w = try World()
        let key = RelationshipRowKey(type: w.employment, label: .typed("employer"))
        let row = RelationshipRow(key: key, sides: [.from], others: [w.company], rule: EndRule(needed: true, onlyOne: false), carriers: [ShapeID()], source: w.person)
        for count in 1...3 { expectEqual(RelationChecks.note(rows: [row], count: { _ in count }, graph: w.graph), [], "\(count) relationships: nothing lacks") }
        let problems = RelationChecks.note(rows: [row], count: { _ in 0 }, graph: w.graph)
        expectEqual(problems.count, 1)
        let problem = try require(problems.first)
        expectEqual(problem.kind, .needed)
        expectEqual(problem.keyword, "required")
        expectEqual(problem.locus, .row(key))
        expectEqual(problem.place, ["employer"])
        expectEqual(problem.message, "employer is needed")
        expect(problem.path.isRoot)
        let check = FieldCheck(problems: problems)
        expect(check.isIncomplete && !check.isWrong && !check.hasWarnings)
        expectEqual(check.mark(at: key), .needed)
        expectEqual(check.mark(at: RelationshipRowKey(type: w.employment, label: .typed("other"))), nil, "another row")
        expectEqual(check.mark(at: FieldPath(field: "employer")), nil, "a field named like it")
        expectEqual(check.endMark(.to), nil)
        expectEqual(check.worstEnd, nil)
        expect(!check.isMisfit)
        expectEqual(check.removingRelations(), FieldCheck.clean, "a run's own answer strips it")
        expectEqual(check.leaving(out: FieldPath(field: "employer")), check, "a field being typed in leaves a row alone")
    },
    test("more than one relationship where the row allows one is one wrong problem at the row, in the validator's voice; Needed and Only one at once say what is true") {
        let w = try World()
        let key = RelationshipRowKey(type: w.employment, label: .typed("employer"))
        func row(_ rule: EndRule) -> RelationshipRow { RelationshipRow(key: key, sides: [.from], others: [w.company], rule: rule, carriers: [ShapeID()], source: w.person) }
        let only = row(EndRule(needed: false, onlyOne: true))
        expectEqual(RelationChecks.note(rows: [only], count: { _ in 0 }, graph: w.graph), [], "Only one alone asks for none")
        expectEqual(RelationChecks.note(rows: [only], count: { _ in 1 }, graph: w.graph), [])
        for count in 2...3 {
            let problems = RelationChecks.note(rows: [only], count: { _ in count }, graph: w.graph)
            expectEqual(problems.count, 1)
            let problem = try require(problems.first)
            expectEqual(problem.kind, .wrong)
            expectEqual(problem.keyword, "onlyOne")
            expectEqual(problem.locus, .row(key))
            expectEqual(problem.message, "employer has \(count) notes, and should have at most 1")
            expectEqual(problem.placeName, "employer", "the name Validation and an agent read")
            expectEqual(problem.pointer, nil)
            expectEqual(FieldCheck(problems: problems).mark(at: key), .wrong)
            expect(FieldCheck(problems: problems).isWrong && !FieldCheck(problems: problems).isMisfit, "a wrong row is no misfit")
        }
        let both = row(EndRule(needed: true, onlyOne: true))
        expectEqual(RelationChecks.note(rows: [both], count: { _ in 0 }, graph: w.graph).map(\.kind), [.needed])
        expectEqual(RelationChecks.note(rows: [both], count: { _ in 1 }, graph: w.graph), [])
        expectEqual(RelationChecks.note(rows: [both], count: { _ in 2 }, graph: w.graph).map(\.kind), [.wrong])
    },
    test("two ruled rows are two problems, in the rows' order, and a row with no rule gives none; a row with no name typed on a from end is called by its relationship type") {
        let w = try World()
        let first = RelationshipRow(key: RelationshipRowKey(type: w.employment, label: .unnamed(.from)), sides: [.from], others: [w.company],
                                    rule: EndRule(needed: true, onlyOne: false), carriers: [ShapeID()], source: w.person)
        let second = RelationshipRow(key: RelationshipRowKey(type: w.employment, label: .typed("mentor")), sides: [.from], others: [w.person],
                                     rule: EndRule(needed: true, onlyOne: false), carriers: [ShapeID()], source: w.person)
        let plain = RelationshipRow(key: RelationshipRowKey(type: w.employment, label: .typed("friend")), sides: [.from], others: [w.person],
                                    rule: EndRule(), carriers: [ShapeID()], source: w.person)
        let problems = RelationChecks.note(rows: [first, plain, second], count: { _ in 0 }, graph: w.graph)
        expectEqual(problems.map(\.message), ["employment is needed", "mentor is needed"])
        expectEqual(problems.map(\.locus), [.row(first.key), .row(second.key)])
        expect(RelationChecks.namesATitle(problems), "the first is named by a type's title")
        expect(!RelationChecks.namesATitle([problems[1]]), "the second by its end's own words")
        let check = FieldCheck(problems: problems)
        expectEqual(check.mark(at: first.key), .needed)
        expectEqual(check.mark(at: second.key), .needed)
        expectEqual(check.mark(at: plain.key), nil)
        expectEqual(RelationWords.onlyOne("layer", count: 2), "layer has 2 notes, and should have at most 1")
    },
])

@MainActor let relationWordsTests = Suite("The words of an arrow's check", [
    test("each sentence, exactly") {
        expectEqual(RelationWords.misfit(relation: "Employment", side: .to, allowed: ["Company"], end: "foundation", is: .types(["Layer"])),
                    "Employment runs to a Company. “foundation” is a Layer.")
        expectEqual(RelationWords.misfit(relation: "Employment", side: .from, allowed: ["Person"], end: "Acme", is: .types(["Company"])),
                    "Employment runs from a Person. “Acme” is a Company.")
        expectEqual(RelationWords.misfit(relation: "Employment", side: .to, allowed: ["Company", "Agency"], end: "foundation", is: .types(["Layer", "Feature"])),
                    "Employment runs to a Company or an Agency. “foundation” is a Layer and a Feature.")
        expectEqual(RelationWords.misfit(relation: "Employment", side: .to, allowed: ["Company"], end: "Person", is: .type), "Employment runs to a Company. “Person” is a type.")
        expectEqual(RelationWords.misfit(relation: "Employment", side: .to, allowed: ["Company"], end: "foundation", is: .untyped),
                    "Employment runs to a Company. “foundation” has no type.")
        expectEqual(RelationWords.misfit(relation: "Employment", side: .to, allowed: ["Company"], end: "Plans", is: .kind("pocket")),
                    "Employment runs to a Company. “Plans” is a pocket.")
        expectEqual(RelationWords.free(relation: "Employment"), "Employment isn’t attached at both ends.")
        let label: (ShapeID) -> String = { _ in "Acme" }
        expectEqual(RelationWords.unread(.gone(called: nil), relation: "Employment", side: .to, label: label), "Employment runs to a note that is gone.")
        expectEqual(RelationWords.unread(.notAdmitted(ShapeID(), needs: "open"), relation: "Employment", side: .to, label: label), "Employment runs to “Acme”, which isn’t open.")
        expectEqual(RelationWords.unread(.query(called: nil), relation: "Employment", side: .to, label: label), "Employment runs to a pill that stands for several notes.")
        expectEqual(RelationWords.unread(.empty, relation: "Employment", side: .to, label: label), "Employment runs to a pill that stands for nothing.")
    },
    test("an untitled relationship type is This arrow, and an untitled allowed type an untitled type") {
        expectEqual(RelationWords.misfit(relation: nil, side: .to, allowed: [nil], end: "x", is: .untyped), "This arrow runs to an untitled type. “x” has no type.")
        expectEqual(RelationWords.misfit(relation: "R", side: .to, allowed: ["Company"], end: "x", is: .types([nil])), "R runs to a Company. “x” is an untitled type.")
        expectEqual(RelationWords.free(relation: nil), "This arrow isn’t attached at both ends.")
        expectEqual(RelationWords.unread(.empty, relation: nil, side: .to, label: { _ in "" }), "This arrow runs to a pill that stands for nothing.")
    },
    test("more than four allowed types are the first four and a count; articles go by the first letter") {
        expectEqual(RelationWords.allowed(["Box", "Cat", "Dog", "Fox", "Gnu", "Hen"]), "a Box, a Cat, a Dog, a Fox or 2 more")
        expectEqual(RelationWords.allowed(["Person", "Agency", "Order"]), "a Person, an Agency or an Order")
        expectEqual(RelationWords.allowed(["Person", "Agency"]), "a Person or an Agency")
        expectEqual(RelationWords.allowed([]), "anything")
        expectEqual(RelationWords.withArticle("Employee"), "an Employee")
        expectEqual(RelationWords.withArticle("company"), "a company")
    },
    test("an end's name is cut at 40 characters, with an ellipsis, in curly quotes") {
        expectEqual(RelationWords.quoted("foundation"), "“foundation”")
        let exact = String(repeating: "x", count: 40)
        expectEqual(RelationWords.quoted(exact), "“" + exact + "”")
        expectEqual(RelationWords.quoted(exact + "y"), "“" + exact + "…”")
    },
    test("an unread end with no name quoted says what it is, and one the app cannot show says nothing") {
        expectEqual(RelationWords.unread(.unavailable(called: "Acme"), relation: "R", side: .to, label: { _ in "" }), nil)
        expectEqual(RelationWords.unread(.note(ShapeID()), relation: "R", side: .to, label: { _ in "" }), nil)
        expectEqual(RelationWords.unread(.free, relation: "R", side: .to, label: { _ in "" }), nil)
        expectEqual(RelationWords.unread(.notAdmitted(ShapeID(), needs: ""), relation: "R", side: .from, label: { _ in "Acme" }), "R runs from “Acme”, which isn’t available.")
    },
])
