@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Mentions
import TestKit
import Titles
import Topology
import Types

// What a relationship type's ends are, and the fit of a note to a side, over bonds (arrows of the tests' own):
// Types names no kind, so none of it runs over an arrow.

/// Person, Company and a relationship type, Employment, each on the root of a bond editor.
@MainActor private struct World {
    let editor: CanvasEditor
    let person: ShapeID, company: ShapeID, employment: ShapeID

    init(file: CanvasFile? = nil) throws {
        editor = try bondEditor(file: file)
        person = editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 40, y: 40))
        company = editor.addType(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 40, y: 200))
        employment = editor.addRelationshipType("Employment")
    }

    var index: RelationshipIndex { editor.relationships! }
    var graph: RelationshipGraph { index.graph }
    func fitting(_ a: ShapeID, _ b: ShapeID) -> (taken: [ShapeID], open: [ShapeID]) { graph.fitting(from: .note(a), to: .note(b)) }

    /// Person → Employment → Company, as two bonds.
    func drawEnds(fromName: String = "", toName: String = "") {
        editor.addBond(person, employment, name: fromName)
        editor.addBond(employment, company, name: toName)
    }
}

@MainActor let relationshipEndsTests = Suite("The ends of a relationship type", [
    test("a bond from a type into a relationship type is a from end, out of it a to end; any other bond is plain") {
        let w = try World()
        expect(w.index.isActive)
        let toEmployment = w.editor.addBond(w.person, w.employment), fromEmployment = w.editor.addBond(w.employment, w.company)
        expectEqual(w.index.end(toEmployment)?.type, w.employment)
        expectEqual(w.index.end(toEmployment)?.side, .from)
        expectEqual(w.index.end(fromEmployment)?.side, .to)
        let sides = w.graph.sides(of: w.employment)
        expectEqual(sides.from.map(\.type), [w.person])
        expectEqual(sides.from.map(\.carrier), [toEmployment])
        expectEqual(sides.to.map(\.type), [w.company])
        // Between two relationship types, two unmarked types, a type and a note, a note and a relationship type, and with a free end.
        let mentor = w.editor.addRelationshipType("Mentor", at: CGPoint(x: 800, y: 40))
        let note = w.editor.addInstance("Ann", of: [w.person])
        let plain = [w.editor.addBond(w.employment, mentor), w.editor.addBond(w.person, w.company), w.editor.addBond(w.person, note),
                     w.editor.addBond(note, w.employment), w.editor.addBond(w.employment, nil), w.editor.addBond(note, w.person)]
        for bond in plain { expectEqual(w.index.end(bond) == nil, true, "a plain bond") }
        expectEqual(w.graph.sides(of: w.employment), sides, "the plain bonds changed no end")
        expect(w.graph.isRelationshipType(w.employment) && !w.graph.isRelationshipType(w.person))
    },
    test("an end is the type behind a pill that names one shape, whether or not the pill reads through; any other pill is no end") {
        let w = try World()
        let personPill = w.editor.addRelay(standingFor: [w.person], says: "Person")
        let end = w.editor.addBond(personPill, w.employment)
        expectEqual(w.index.end(end)?.type, w.employment, "a pill that is not admitted: the type behind it still counts")
        expectEqual(w.graph.sides(of: w.employment).from.map(\.type), [w.person])
        w.editor.open(w.person)
        expectEqual(w.graph.sides(of: w.employment).from.map(\.type), [w.person], "and the same once it is")
        // A pill for nothing, for two shapes, for a shape that is no type.
        let note = w.editor.addInstance("Ann", of: [w.person])
        for pill in [w.editor.addRelay(standingFor: []), w.editor.addRelay(standingFor: [w.person, w.company]), w.editor.addRelay(standingFor: [note])] {
            let bond = w.editor.addBond(pill, w.employment)
            expect(w.index.end(bond) == nil, "not an end")
        }
        expectEqual(w.graph.sides(of: w.employment).from.map(\.carrier), [end])
    },
    test("an end's name is its words' first line, trimmed; a line of mentions is none") {
        let w = try World()
        let named = w.editor.addBond(w.person, w.employment, name: "  employee \nsecond line")
        let blank = w.editor.addBond(w.employment, w.company, name: "  ")
        let ends = w.graph.sides(of: w.employment)
        expectEqual(ends.from.first?.name, "employee")
        expectEqual(ends.to.first?.name, nil)
        _ = (named, blank)
        w.editor.transact { $0.update(blank, as: Bond.self) { $0.props.text = MentionText(plain: "employer") } }
        expectEqual(w.graph.sides(of: w.employment).to.first?.name, "employer")
        let rule = w.editor.addBond(w.person, w.employment, rule: EndRule(needed: true, onlyOne: false))
        expectEqual(w.graph.sides(of: w.employment).from.first(where: { $0.carrier == rule })?.rule, EndRule(needed: true, onlyOne: false))
    },
    test("a side with no end fits anything; several on a side mean any of them; a type that builds on one fits; a type's own note never does") {
        let w = try World()
        let ann = w.editor.addInstance("Ann", of: [w.person]), acme = w.editor.addInstance("Acme", of: [w.company]), plain = w.editor.addInstance("A note", of: [])
        expectEqual(w.graph.side(.note(plain), at: .from, of: w.employment), .open, "no end drawn")
        expectEqual(w.graph.side(.note(w.person), at: .from, of: w.employment), .open, "open comes before a type's own note is judged")
        let agency = w.editor.addType(TypeSchemaProperty.starter, title: "Agency", at: CGPoint(x: 40, y: 600))
        let employee = w.editor.addType(TypeSchemaProperty.starter, title: "Employee", at: CGPoint(x: 400, y: 600))
        w.editor.addTypeLink(w.person, to: employee)
        w.editor.addBond(w.person, w.employment)
        w.editor.addBond(agency, w.employment)
        w.editor.addBond(w.employment, w.company)
        let bo = w.editor.addInstance("Bo", of: [employee])
        expectEqual(w.graph.side(.note(ann), at: .from, of: w.employment), .fits)
        expectEqual(w.graph.side(.note(bo), at: .from, of: w.employment), .fits, "an Employee is a Person")
        expectEqual(w.graph.side(.note(acme), at: .from, of: w.employment), .misfit(allowed: [w.person, agency]))
        expectEqual(w.graph.side(.note(plain), at: .from, of: w.employment), .misfit(allowed: [w.person, agency]), "a note of no type fits only an open side")
        expectEqual(w.graph.side(.note(w.person), at: .from, of: w.employment), .misfit(allowed: [w.person, agency]), "a type's own note is never an instance")
        expectEqual(w.graph.side(.note(employee), at: .from, of: w.employment), .misfit(allowed: [w.person, agency]), "a type that builds on an allowed one is still a type's note")
        expectEqual(w.graph.side(.note(acme), at: .to, of: w.employment), .fits)
        expectEqual(w.graph.side(.free, at: .to, of: w.employment), .unjudged(.free))
        expectEqual(w.graph.side(.empty, at: .to, of: w.employment), .unjudged(.empty))
        let fit = try require(w.graph.fit(of: w.employment, from: .note(ann), to: .note(plain)))
        expect(fit.isMisfit && !fit.holds)
        expectEqual(fit.from, .fits)
        expect(w.graph.fit(of: w.person, from: .note(ann), to: .note(acme)) == nil, "no relationship type, not judged")
        let ok = try require(w.graph.fit(of: w.employment, from: .note(bo), to: .note(acme)))
        expect(ok.holds && !ok.isMisfit)
    },
    test("an arrow between two notes may take the relationship types it fits by a drawn end; one with no ends is offered after and never taken") {
        let w = try World()
        let ann = w.editor.addInstance("Ann", of: [w.person]), acme = w.editor.addInstance("Acme", of: [w.company])
        w.drawEnds()
        let open = w.editor.addRelationshipType("Mentor", at: CGPoint(x: 800, y: 40))
        let wrong = w.editor.addRelationshipType("Founder", at: CGPoint(x: 800, y: 200))
        w.editor.addBond(w.company, wrong)
        w.editor.addBond(wrong, w.person)
        let found = w.fitting(ann, acme)
        expectEqual(found.taken, [w.employment], "Founder runs the other way: Company to Person")
        expectEqual(found.open, [open])
        expectEqual(w.fitting(acme, ann).taken, [wrong])
        expectEqual(w.fitting(w.person, acme).taken + w.fitting(w.person, acme).open, [], "an end that is a type's own note: nothing")
        let none = w.graph.fitting(from: .free, to: .note(acme))
        expect(none.taken.isEmpty && none.open.isEmpty, "a free end is not judged")
        expect(w.graph.fitting(from: .gone(called: "Ann"), to: .note(acme)).taken.isEmpty)
        // By name, an untitled one last.
        let aardvark = w.editor.addRelationshipType("Aardvark", at: CGPoint(x: 800, y: 400)), untitled = w.editor.addRelationshipType(nil, at: CGPoint(x: 800, y: 600))
        expectEqual(w.fitting(ann, acme).open, [aardvark, open, untitled])
    },
    test("a person's rows come from the ends at its type and at the types it builds on; a relationship type's own note has none") {
        let w = try World()
        w.drawEnds(fromName: "employer", toName: "")
        let employee = w.editor.addType(TypeSchemaProperty.starter, title: "Employee", at: CGPoint(x: 400, y: 600))
        w.editor.addTypeLink(w.person, to: employee)
        let personRows = w.graph.rows(for: [w.person], isType: false)
        expectEqual(personRows.map(\.key.label), [.typed("employer")])
        expectEqual(personRows.first?.sides, [.from])
        expectEqual(personRows.first?.others, [w.company])
        expectEqual(w.graph.rows(for: [w.company], isType: false).map(\.key.label), [.unnamed(.to)])
        expectEqual(w.graph.rows(for: [employee], isType: false).map(\.key.label), [.typed("employer")], "an Employee is a Person")
        expectEqual(w.graph.rows(for: [employee], isType: false).first?.source, w.person, "the end type that gives it")
        expectEqual(w.graph.rows(for: [w.person], isType: true).map(\.key.label), [.typed("employer")], "a type's own note lists them too")
        expectEqual(w.graph.rows(for: [w.employment], isType: true), [], "nothing for a relationship type's own note")
        expectEqual(w.graph.rows(for: [w.employment], isType: false), [], "nothing from a relationship type in the list")
        expectEqual(w.graph.rows(for: [], isType: false), [])
        expectEqual(w.index.rows(for: [w.person], isType: false), personRows, "the index memoises the same rows")
    },
    test("a row is named by its typed name, else the one other type's title, else the relationship type's, else untitled") {
        let w = try World()
        w.drawEnds(fromName: "employer")
        let types = w.graph.types
        expectEqual(w.graph.rows(for: [w.person], isType: false).first?.name(in: types), "employer")
        expectEqual(w.graph.rows(for: [w.company], isType: false).first?.name(in: types), "person", "the one other type's title, in lower case")
        let agency = w.editor.addType(TypeSchemaProperty.starter, title: "Agency", at: CGPoint(x: 40, y: 600))
        let ownership = w.editor.addRelationshipType("Ownership", at: CGPoint(x: 800, y: 300))
        w.editor.addBond(w.person, ownership)
        w.editor.addBond(ownership, w.company)
        w.editor.addBond(ownership, agency)
        let wide = w.graph.rows(for: [w.person], isType: false).first(where: { $0.key.type == ownership })
        expectEqual(wide?.name(in: w.graph.types), "ownership", "two other types: the relationship type's title")
        let blank = w.editor.addRelationshipType(nil, at: CGPoint(x: 800, y: 40)), friend = w.editor.addType(TypeSchemaProperty.starter, at: CGPoint(x: 800, y: 300))
        w.editor.addBond(friend, blank)
        expectEqual(w.graph.rows(for: [friend], isType: false).first?.name(in: w.graph.types), "untitled")
    },
    test("a note may sit at the other end of a row when it fits the row's other side, and a row on both sides takes either") {
        let w = try World()
        w.drawEnds()
        let ann = w.editor.addInstance("Ann", of: [w.person]), acme = w.editor.addInstance("Acme", of: [w.company])
        let personRow = try require(w.graph.rows(for: [w.person], isType: false).first)
        expect(w.graph.fits(acme, otherEndOf: personRow))
        expect(!w.graph.fits(ann, otherEndOf: personRow), "a person is no company")
        expect(!w.graph.fits(w.company, otherEndOf: personRow), "a type's own note is never an instance")
        // A relationship type that relates Person to itself, unnamed: one row on both sides.
        let friends = w.editor.addRelationshipType("Friends", at: CGPoint(x: 800, y: 40))
        w.editor.addBond(w.person, friends)
        w.editor.addBond(friends, w.person)
        let row = try require(w.graph.rows(for: [w.person], isType: false).first(where: { $0.key.type == friends }))
        expectEqual(row.sides, [.from, .to])
        expectEqual(row.key.label, .unnamed(nil))
        expect(w.graph.fits(ann, otherEndOf: row) && !w.graph.fits(acme, otherEndOf: row))
        // An open side fits any note.
        let open = w.editor.addRelationshipType("Mentor", at: CGPoint(x: 800, y: 300))
        w.editor.addBond(w.person, open)
        let openRow = try require(w.graph.rows(for: [w.person], isType: false).first(where: { $0.key.type == open }))
        expectEqual(openRow.others, [])
        expect(w.graph.fits(ann, otherEndOf: openRow) && w.graph.fits(acme, otherEndOf: openRow) && !w.graph.fits(w.person, otherEndOf: openRow))
    },
    test("the relationship types that join two types, either way round") {
        let w = try World()
        w.drawEnds()
        let founder = w.editor.addRelationshipType("Founder", at: CGPoint(x: 800, y: 40))
        w.editor.addBond(w.company, founder)
        w.editor.addBond(founder, w.person)
        expectEqual(w.graph.relationshipTypes(joining: w.person, and: w.company), [w.employment, founder])
        expectEqual(w.graph.relationshipTypes(joining: w.company, and: w.person), [w.employment, founder])
        expectEqual(w.graph.relationshipTypes(joining: w.person, and: w.person), [])
    },
    test("a note's relations are the arrows of relationship types at it, with the far end read; a plain arrow is none") {
        let w = try World()
        w.drawEnds()
        let ann = w.editor.addInstance("Ann", of: [w.person]), acme = w.editor.addInstance("Acme", of: [w.company])
        let job = w.editor.addBond(ann, acme, of: [w.employment])
        let mention = w.editor.addBond(acme, ann)
        let ofAnn = w.index.relations(of: ann)
        expectEqual(ofAnn, [Relation(arrow: job, type: w.employment, side: .from, far: ReadEnd(literal: acme, reading: .note(acme)))])
        expectEqual(w.index.relations(of: acme), [Relation(arrow: job, type: w.employment, side: .to, far: ReadEnd(literal: ann, reading: .note(ann)))])
        expect(w.index.relations(of: acme).contains { $0.arrow == mention } == false)
        let row = try require(w.graph.rows(for: [w.person], isType: false).first)
        expectEqual(w.index.relations(of: ann, in: row), ofAnn)
        // Unmarked, the arrow is a plain one.
        w.editor.transact { $0.update(w.employment) { $0[RelationshipProperty.self] = nil } }
        expectEqual(w.index.relations(of: ann), [])
        expect(!w.index.isActive)
        // The candidates for a row: the notes that fit the other end and are not there already.
        w.editor.undo()
        let globex = w.editor.addInstance("Globex", of: [w.company])
        expectEqual(w.index.candidates(for: row, of: ann), [globex], "Acme is related to Ann already; Ann and the types are not candidates")
        let open = w.editor.addRelationshipType("Mentor", at: CGPoint(x: 800, y: 300))
        w.editor.addBond(w.person, open)
        let openRow = try require(w.graph.rows(for: [w.person], isType: false).first(where: { $0.key.type == open }))
        expect(w.index.candidates(for: openRow, of: ann) == nil, "any shape of a kind that draws rows")
    },
    test("an arrow's ends are read by the connection, bound at both ends: the literal ends, each read") {
        let w = try World()
        let ann = w.editor.addInstance("Ann", of: [w.person]), acme = w.editor.addInstance("Acme", of: [w.company])
        let bond = w.editor.addBond(ann, acme, of: [w.employment])
        w.drawEnds()
        let reading = try require(w.index.subjects(of: bond))
        expectEqual(reading.from, ReadEnd(literal: ann, reading: .note(ann)))
        expectEqual(reading.to.reading, .note(acme))
        expectEqual(reading[.from], reading.from)
        let fits = w.index.fits(of: bond)
        expectEqual(fits.map(\.type), [w.employment])
        expect(fits.first?.fit.holds == true)
        expect(w.index.subjects(of: ann) == nil, "a note is no connection")
        expect(w.index.subjects(of: w.editor.addBond(ann, nil)) == nil, "a free end: not bound at both")
        // Misfit: Acme to Ann.
        let wrong = w.editor.addBond(acme, ann, of: [w.employment])
        expect(w.index.fits(of: wrong).first?.fit.isMisfit == true)
    },
])
