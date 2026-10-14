@_spi(Host) import Canvas
import CanvasTesting
import Foundation
import TestKit
import Types

// The values of relationships that need no file: the rows a relationship type's ends give the types at
// them (the merge, held on hand-made sides), the role an arrow has by its two end records, and the rule an
// end holds. The fit is held over a file, with the index, in `RelationshipEndsTests`.

private func end(_ type: ShapeID, _ carrier: ShapeID, _ name: String? = nil, needed: Bool = false, onlyOne: Bool = false) -> RelationshipEnd {
    RelationshipEnd(type: type, carrier: carrier, name: name, rule: EndRule(needed: needed, onlyOne: onlyOne))
}

@MainActor let relationshipRowsTests = Suite("The rows a relationship type's ends give", [
    test("a side is the other side's other; a rule joins either's") {
        expectEqual(RelationshipSide.from.other, .to)
        expectEqual(RelationshipSide.to.other, .from)
        expectEqual(RelationshipSide.allCases, [.from, .to])
        expect(EndRule().isNone && !EndRule(needed: true, onlyOne: false).isNone && !EndRule(needed: false, onlyOne: true).isNone)
    },
    test("ends of one name on one type are one row, on every side that has one: Ann → Bo and Cy → Ann are one `friends` row on Ann") {
        let person = ShapeID(), r = ShapeID(), a = ShapeID(), b = ShapeID()
        let rows = RelationshipEnds.rows(of: r, sides: RelationshipSides(from: [end(person, a, "friends")], to: [end(person, b, "friends")]))
        expectEqual(rows.keys.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }, [person])
        let row = try require(rows[person]?.first)
        expectEqual(rows[person]?.count, 1)
        expectEqual(row.key, RelationshipRowKey(type: r, label: .typed("friends")))
        expectEqual(row.sides, [.from, .to])
        expectEqual(row.carriers, [a, b])
        expectEqual(row.others, [person])
        expectEqual(row.source, person)
        expectEqual(row.drawSide, .from)
    },
    test("`friends` and `friend of` are two rows, and each is on its own side") {
        let person = ShapeID(), r = ShapeID(), a = ShapeID(), b = ShapeID()
        let rows = try require(RelationshipEnds.rows(of: r, sides: RelationshipSides(from: [end(person, a, "friends")], to: [end(person, b, "friend of")]))[person])
        expectEqual(rows.map(\.key.label), [.typed("friends"), .typed("friend of")])
        expectEqual(rows.map(\.sides), [[.from], [.to]])
        expectEqual(rows[1].drawSide, .to)
    },
    test("unnamed ends on both sides with the same types are one row; with other types, a row a side") {
        let person = ShapeID(), company = ShapeID(), r = ShapeID(), a = ShapeID(), b = ShapeID()
        let same = try require(RelationshipEnds.rows(of: r, sides: RelationshipSides(from: [end(person, a)], to: [end(person, b)]))[person])
        expectEqual(same.map(\.key.label), [.unnamed(nil)])
        expectEqual(same[0].sides, [.from, .to])
        let sides = RelationshipSides(from: [end(person, a)], to: [end(company, b)])
        let rows = RelationshipEnds.rows(of: r, sides: sides)
        expectEqual(rows[person]?.map(\.key.label), [.unnamed(.from)])
        expectEqual(rows[company]?.map(\.key.label), [.unnamed(.to)])
        expectEqual(rows[person]?.first?.others, [company], "the other side's types")
        expectEqual(rows[company]?.first?.others, [person])
        // The same type at both ends of a relationship type that also relates others: not equal sets.
        let mixed = RelationshipSides(from: [end(person, a)], to: [end(person, b), end(company, ShapeID())])
        expectEqual(RelationshipEnds.rows(of: r, sides: mixed)[person]?.map(\.key.label), [.unnamed(.from), .unnamed(.to)])
    },
    test("a typed name merges across sides with unequal types; the unnamed rows come after, and a name is the exact text") {
        let person = ShapeID(), company = ShapeID(), r = ShapeID()
        let sides = RelationshipSides(from: [end(person, ShapeID(), "boss"), end(person, ShapeID())], to: [end(person, ShapeID(), "boss"), end(company, ShapeID())])
        let rows = try require(RelationshipEnds.rows(of: r, sides: sides)[person])
        expectEqual(rows.map(\.key.label), [.typed("boss"), .unnamed(.from)], "Person has no unnamed end on its to side")
        expectEqual(rows[0].sides, [.from, .to])
        expectEqual(rows[0].others, [person, company], "the types on the opposite side or sides, once each, in order")
        // Case counts.
        let apart = try require(RelationshipEnds.rows(of: r, sides: RelationshipSides(from: [end(person, ShapeID(), "Boss")], to: [end(person, ShapeID(), "boss")]))[person])
        expectEqual(apart.count, 2)
    },
    test("a row's rule is the union of the rules of the ends it merges") {
        let person = ShapeID(), r = ShapeID()
        let rows = try require(RelationshipEnds.rows(of: r, sides: RelationshipSides(from: [end(person, ShapeID(), "friends", needed: true)], to: [end(person, ShapeID(), "friends", onlyOne: true)]))[person])
        expectEqual(rows[0].rule, EndRule(needed: true, onlyOne: true))
        let alone = try require(RelationshipEnds.rows(of: r, sides: RelationshipSides(to: [end(person, ShapeID(), nil, onlyOne: true)]))[person])
        expectEqual(alone[0].rule, EndRule(needed: false, onlyOne: true))
        expectEqual(alone[0].others, [], "no end on the other side: anything")
    },
    test("an arrow is an end by its two end records alone: a relationship type at one end, an unmarked type at the other") {
        let editor = try typeEditor()
        let registry = editor.registry
        let plain = typeRecord(TypeSchemaProperty.starter, title: "Layer"), other = typeRecord(TypeSchemaProperty.starter, title: "Feature")
        var marked = typeRecord(TypeSchemaProperty.starter, title: "Placement"), another = typeRecord(TypeSchemaProperty.starter, title: "Mentor")
        marked[RelationshipProperty.self] = true
        another[RelationshipProperty.self] = true
        let note = instanceRecord("a note", of: [plain.id])
        expectEqual(ArrowRole.of(from: plain, to: marked, registry: registry), .end(type: marked.id, side: .from))
        expectEqual(ArrowRole.of(from: marked, to: plain, registry: registry), .end(type: marked.id, side: .to))
        expectEqual(ArrowRole.of(from: plain, to: other, registry: registry), .betweenTypes)
        expectEqual(ArrowRole.of(from: marked, to: another, registry: registry), .betweenRelationshipTypes)
        expectEqual(ArrowRole.of(from: marked, to: note, registry: registry), .endAtNonType(type: marked.id))
        expectEqual(ArrowRole.of(from: note, to: marked, registry: registry), .endAtNonType(type: marked.id))
        expectEqual(ArrowRole.of(from: plain, to: note, registry: registry), .notes, "a type and a note")
        expectEqual(ArrowRole.of(from: note, to: instanceRecord("another", of: []), registry: registry), .notes)
        expectEqual(ArrowRole.of(from: nil, to: marked, registry: registry), .notes, "an end that is not there")
        expectEqual(ArrowRole.of(from: nil, to: nil, registry: registry), .notes)
        // The mark with no schema is none.
        var inert = instanceRecord("not a type", of: [])
        inert[RelationshipProperty.self] = true
        expectEqual(ArrowRole.of(from: plain, to: inert, registry: registry), .notes)
    },
])
