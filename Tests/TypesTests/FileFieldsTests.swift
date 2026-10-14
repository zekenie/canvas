@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Mentions
import TestKit
import Titles
import Types

// What the file's types say of the members a note's values can hold (`FileFields`, kept by `FieldBook`): the
// first member of a path into `fieldValues` that no type has, and the members that could be there.

@MainActor private func unknown(_ editor: CanvasEditor, _ members: String...) throws -> String? {
    let fields = try require(editor.fileFields)
    return fields.unknown(members).map { "\($0.index): \($0.known.joined(separator: ", "))" }
}

@MainActor let fileFieldsTests = Suite("File fields", [
    test("a path no type has is unknown at its first such step, with the members that could be there; one a type gives is not") {
        let editor = try fieldEditor()
        expectEqual(try unknown(editor, "status"), nil)
        expectEqual(try unknown(editor, "stauts"),
                    "0: city, customer, email, gift, giftNote, lineItems, name, postcode, role, shippingAddress, startDate, status, street, tags",
                    "the union of every type's own fields, whichever type it is")
        expectEqual(try unknown(editor, "lineItems", "product"), nil, "through a list, to its items' members")
        expectEqual(try unknown(editor, "lineItems", "sku"), "1: price, product, quantity")
        expectEqual(try unknown(editor, "shippingAddress", "city"), nil, "through another type's fields")
        expectEqual(try unknown(editor, "shippingAddress", "zip"), "1: city, postcode, street")
        expectEqual(try unknown(editor, "role"), nil, "a type's own field, though it builds on another")
        expectEqual(try unknown(editor, "name"), nil, "and its parent's")
    },
    test("a step past a plain value or a choice is unknown, with nothing that could be there") {
        let editor = try fieldEditor()
        expectEqual(try unknown(editor, "customer", "name"), "1: ")
        expectEqual(try unknown(editor, "status", "x"), "1: ")
        expectEqual(try unknown(editor, "tags", "first"), "1: ")
        expectEqual(try unknown(editor, "lineItems", "product", "x"), "2: ")
    },
    test("nothing is said past pairs, Other or an either, nor under a reference to a type that is gone or to a part of one") {
        let editor = try fieldEditor()
        editor.addFieldTypes([FieldFixtures.everyKind.a, FieldFixtures.everyKind.b])
        expectEqual(try unknown(editor, "labels", "anything"), nil, "pairs")
        expectEqual(try unknown(editor, "anything", "x", "y"), nil, "Other")
        expectEqual(try unknown(editor, "payment", "bogus"), nil, "an either")
        expectEqual(try unknown(editor, "size", "x"), nil, "an either of plain kinds")
        expectEqual(try unknown(editor, "venue", "city"), nil)
        expectEqual(try unknown(editor, "venue", "street"), "1: city, name")
        expectEqual(try unknown(editor, "rooms", "street"), nil, "a list of another type's fields")
        let gone = ShapeID()
        _ = editor.addType(#"{"type": "object", "properties": {"x": {"$ref": "\#(FieldFixtures.uri(of: gone))"}, "y": {"$ref": "\#(FieldFixtures.uri(of: FieldFixtures.addressID))#/properties/city"}}}"#,
                           title: "Holder")
        expectEqual(try unknown(editor, "x", "n", "m"), nil, "a gone type")
        expectEqual(try unknown(editor, "y", "n"), nil, "a part of a type")
        expect(try unknown(editor, "z") != nil, "but a key at the top is still checked")
    },
    test("a $-key is a directive, never a field") {
        let editor = try fieldEditor()
        _ = editor.addType(#"{"type": "object", "properties": {"$title": {"const": "name"}, "nickname": {"type": "string"}}}"#, title: "Nicknamed")
        expectEqual(try unknown(editor, "nickname"), nil)
        expect(try unknown(editor, "$title") != nil, "never known")
        expect(try require(try require(editor.fileFields).unknown(["zzz"])).known.contains("$title") == false, "and never listed")
    },
    test("a file with no types knows no field, and a type that holds itself ends where it was read") {
        let none = try typeEditor()
        expectEqual(try unknown(none, "anything"), "0: ")
        let editor = try typeEditor()
        let id = ShapeID()
        let record = typeRecord(#"{"type": "object", "properties": {"label": {"type": "string"}, "child": {"$ref": "\#(FieldFixtures.uri(of: id))"}}}"#,
                                words: "", title: "Tree", at: CGPoint(x: 40, y: 40), id: id)
        editor.transact { $0.insert(record) }
        expectEqual(try unknown(editor, "child", "label"), nil)
        expectEqual(try unknown(editor, "child", "child", "nope"), "2: child, label", "read as far as it goes")
        expectEqual(try unknown(editor, "child", "child", "child", "child", "child", "child", "child", "nope"), nil, "then anything")
    },
    test("nothing is said while any note lists a type that is gone, and again once that is cleared") {
        let editor = try fieldEditor()
        expect(try unknown(editor, "stauts") != nil)
        let ghost = ShapeID()
        let note = editor.addInstance("", of: [ghost])
        expectEqual(try unknown(editor, "stauts"), nil, "its fields are unknown, and its values are kept")
        editor.transact { $0.delete([note]) }
        expect(try unknown(editor, "stauts") != nil)
    },
    test("it is kept until a type changes, then made again") {
        let editor = try fieldEditor()
        let before = try require(editor.fileFields)
        expect(before === (try require(editor.fileFields)), "kept")
        expectEqual(try unknown(editor, "nickname"), "0: " + (before.unknown(["nickname"])?.known.joined(separator: ", ") ?? ""))
        _ = editor.addType(#"{"type": "object", "properties": {"nickname": {"type": "string"}}}"#, title: "Nicknamed")
        expect(before !== (try require(editor.fileFields)), "made again")
        expectEqual(try unknown(editor, "nickname"), nil)
    },
    test("what --ask is told: a line for each titled type, key first, a differing title in quotes, every kind's word, builds on") {
        let editor = try fieldEditor()
        editor.addFieldTypes([FieldFixtures.everyKind.a, FieldFixtures.everyKind.b])
        _ = editor.addType(#"{"type": "object", "properties": {"dob": {"type": "string", "format": "date", "title": "birthday"}}}"#, title: "Born")
        _ = editor.addType(#"{"type": "object", "properties": {"ok": {"type": "string"}}}"#)
        _ = editor.addType(#"{"type": "object", "properties": {"x": {"$ref": "\#(FieldFixtures.uri(of: ShapeID()))"}, "y": {"type": "integer", "title": "why"}, "t": {"enum": [1, 2]}}}"#, title: "Holder")
        _ = editor.addType(#"{"type": "object", "properties": {}}"#, title: "Empty")
        expectEqual(try require(editor.fileFields).text(for: ""), """
            Person: name (text), email (text)
            Address: street (text), city (text), postcode (text)
            Born: dob "birthday" (date)
            Employee builds on Person: role (text), startDate (date)
            Empty: no fields
            Holder: x (fields of a gone type), y "why" (whole number), t (1|2)
            KindsA: name (text), price (number), due (date), done (yes/no), status (draft|paid|shipped), roles (any of engineer|designer|manager), tags (list of text), venue (group) {name (text), city (text)}, shippingAddress (fields of Address)
            KindsB: customer (text), guests (list of text), lineItems (list) {product (text), quantity (whole number)}, rooms (list of fields of Address), size (number or text), labels (pairs of text), anything (other), payment (group or text), count (whole number)
            Order: customer (text), shippingAddress (fields of Address), lineItems (list) {product (text), quantity (whole number), price (number)}, status (draft|paid|shipped), tags (list of text), gift (yes/no), giftNote (text)
            """, "an untitled type has no line, and a type's own fields only")
        let none = try typeEditor()
        expectEqual(try require(none.fileFields).text(for: "anything"), "", "no types")
        _ = none.addType(#"{"type": "object", "properties": {"ok": {"type": "string"}}}"#)
        expectEqual(try require(none.fileFields).text(for: "anything"), "", "none titled")
    },
    test("a type's fields past 60 end in how many more, and a group's members past twelve; choices past eight") {
        let editor = try typeEditor()
        editor.addFieldTypes([FieldFixtures.wide(70)])
        let members = (1...20).map { #""m\#($0)": {"type": "string"}"# }.joined(separator: ", ")
        let choices = (1...11).map { "\"c\($0)\"" }.joined(separator: ", ")
        _ = editor.addType(#"{"type": "object", "properties": {"g": {"type": "object", "properties": {\#(members)}}, "c": {"enum": [\#(choices)]}, "deep": {"type": "object", "properties": {"inner": {"type": "object", "properties": {"a": {"type": "string"}}}}}}}"#, title: "Big")
        let text = try require(editor.fileFields).text(for: "")
        let lines = text.split(separator: "\n").map(String.init)
        let wide = try require(lines.first { $0.hasPrefix("Wide:") })
        expect(wide.hasPrefix("Wide: f1 (text), f2 (text)"), wide)
        expect(wide.hasSuffix("f60 (text), +10 more"), wide)
        expect(!wide.contains("f61"), wide)
        let big = try require(lines.first { $0.hasPrefix("Big:") })
        expect(big.contains("g (group) {m1 (text), m2 (text)"), big)
        expect(big.contains("m12 (text), +8 more}"), big)
        expect(big.contains("c (c1|c2|c3|c4|c5|c6|c7|c8|+3)"), big)
        expect(big.contains("deep (group) {inner (group) {…}}"), big)
    },
    test("the block is at most 8,000 characters: whole types from the front while they fit, the rest named on a last line, then …") {
        let editor = try typeEditor()
        let properties = (1...40).map { #""field\#($0)": {"type": "string"}"# }.joined(separator: ", ")
        for number in 1...30 {
            _ = editor.addType(#"{"type": "object", "properties": {\#(properties)}}"#, title: "Type \(number < 10 ? "0" : "")\(number)")
        }
        let text = try require(editor.fileFields).text(for: "")
        expect(text.count <= 8_000, "\(text.count) characters")
        let lines = text.split(separator: "\n").map(String.init)
        let last = try require(lines.last)
        let kept = lines.count - 1
        expect(kept > 0 && kept < 30, "\(kept) types kept")
        expect(last.hasPrefix("and \(30 - kept) more types: Type "), last)
        expect(lines.dropLast().allSatisfy { $0.hasPrefix("Type ") && $0.hasSuffix("(text)") }, "whole lines")
        // Many types: the names that fit, then …
        let many = try typeEditor()
        for number in 1...600 { _ = many.addType(#"{"type": "object", "properties": {"id": {"type": "string"}}}"#, title: "Kind number \(number)") }
        let long = try require(many.fileFields).text(for: "")
        expect(long.count <= 8_000, "\(long.count) characters")
        let tail = try require(long.split(separator: "\n").last.map(String.init))
        expect(tail.hasPrefix("and ") && tail.contains(" more types: Kind number "), tail)
        expect(tail.hasSuffix(", …") || tail.hasSuffix("…"), tail)
    },
    test("types that share a word with the question come first, then by how many notes are one, then by title") {
        let editor = try typeEditor()
        let schema = #"{"type": "object", "properties": {"id": {"type": "string"}}}"#
        let apple = editor.addType(schema, title: "Apple"), pear = editor.addType(schema, title: "Pear")
        _ = editor.addType(schema, title: "Plum")
        let order = editor.addType(#"{"type": "object", "properties": {"shipTo": {"type": "string"}}}"#, title: "Order")
        editor.addInstance("", of: [pear])
        editor.addInstance("", of: [pear])
        editor.addInstance("", of: [apple])
        @MainActor func titles(_ question: String) throws -> [String] {
            try require(editor.fileFields).text(for: question).split(separator: "\n").map { String($0.prefix { $0 != ":" }) }
        }
        expectEqual(try titles(""), ["Pear", "Apple", "Order", "Plum"], "by notes, then title")
        expectEqual(try titles("which plums are there?"), ["Plum", "Pear", "Apple", "Order"], "a word of the question, a plural too")
        expectEqual(try titles("who ships to Oslo, shipping to"), ["Order", "Pear", "Apple", "Plum"], "a word of a field's name")
        _ = order
    },
    test("the lines are kept until a type changes, a field is added or a type is renamed") {
        let editor = try fieldEditor()
        let before = try require(editor.fileFields).text(for: "")
        expectEqual(try require(editor.fileFields).text(for: ""), before)
        editor.transact { $0.update(FieldFixtures.addressID) { $0[TitleProperty.self] = "Place" } }
        let renamed = try require(editor.fileFields).text(for: "")
        expect(renamed.contains("Place: street (text)") && renamed.contains("shippingAddress (fields of Place)"), renamed)
        editor.transact { $0.update(FieldFixtures.addressID) { $0[TypeSchemaProperty.self] = SchemaText(#"{"type": "object", "properties": {"street": {"type": "string"}, "zip": {"type": "string"}}}"#) } }
        expect(try require(editor.fileFields).text(for: "").contains("Place: street (text), zip (text)"))
    },
    test("a relationship type is told with the types it relates, its fields, and the names typed on its ends and their flags; no value is") {
        let w = try RelationshipWorld()
        expectEqual(try require(w.editor.fileFields).text(for: ""), """
            Company: name (text)
            Employment relates Person to Company: role (text), since (date); rows: Person "jobs" (only one), Company "staff" (needed)
            Person: name (text)
            """)
        let ann = w.editor.addInstance("Ann", of: [w.person], at: CGPoint(x: 500, y: 400))
        w.editor.transact { $0.update(ann) { $0[FieldValuesProperty.self] = FieldValues(["name": "Ann Lee"]) } }
        w.editor.addBond(ann, ann, name: "secret words", of: [w.employment])
        let said = try require(w.editor.fileFields).text(for: "")
        expect(!said.contains("Ann Lee") && !said.contains("secret"), "no note's values, and no arrow's text that is not on an end")
    },
    test("builds on comes before relates; a side with no end is anything, several types are joined by or; a name derived is not told, a flag alone is, and no clause when neither") {
        let w = try RelationshipWorld(named: false)
        let agency = w.editor.addType(#"{"type": "object", "properties": {"city": {"type": "string"}}}"#, title: "Agency", at: CGPoint(x: 40, y: 700))
        w.editor.addBond(w.employment, agency)
        let mentor = w.editor.addRelationshipType("Mentor", at: CGPoint(x: 400, y: 400))
        let strong = w.editor.addRelationshipType("Strong mentor", at: CGPoint(x: 400, y: 500))
        w.editor.addTypeLink(mentor, to: strong)
        let text = try require(w.editor.fileFields).text(for: "")
        expect(text.contains("Employment relates Person to Company or Agency: role (text), since (date)\n"), "no rows clause: \(text)")
        expect(text.contains("Mentor relates anything to anything: no fields"), text)
        expect(text.contains("Strong mentor builds on Mentor relates anything to anything: no fields"), "builds on first: \(text)")
        let flagged = w.editor.addBond(w.person, w.employment, rule: EndRule(needed: true, onlyOne: true))
        let flagText = try require(w.editor.fileFields).text(for: "")
        expect(flagText.contains("; rows: Person (needed, only one)\n"), "a flag alone: \(flagText)")
        _ = flagged
    },
    test("two ends of one name on a side are one row, and a type related to itself tells its row once") {
        let w = try RelationshipWorld(named: false)
        let friendship = w.editor.addRelationshipType("Friendship", at: CGPoint(x: 400, y: 400))
        w.editor.addBond(w.person, friendship, name: "friends")
        w.editor.addBond(friendship, w.person, name: "friends")
        let said = try require(w.editor.fileFields).text(for: "")
        expect(said.contains(#"Friendship relates Person to Person: no fields; rows: Person "friends""#), said)
    },
    test("an untitled relationship type is told by its id, an untitled plain type is left out") {
        let w = try RelationshipWorld()
        let record = { () -> AnyShapeRecord in
            var record = slipTypeRecord(TypeSchemaProperty.starter, title: nil, at: CGPoint(x: 700, y: 40))
            record[RelationshipProperty.self] = true
            return record
        }()
        w.editor.transact { $0.insert(record) }
        w.editor.addBond(w.person, record.id)
        _ = w.editor.addType(#"{"type": "object", "properties": {"z": {"type": "string"}}}"#, title: nil, at: CGPoint(x: 700, y: 400))
        let text = try require(w.editor.fileFields).text(for: "")
        expect(text.contains("#\(record.id.rawValue.uuidString) relates Person to anything: no fields"), text)
        expect(!text.contains("z (text)"), "a plain untitled type has no line")
    },
    test("the relationship lines are kept until an end changes: a name typed on an end, its flag, the mark") {
        let w = try RelationshipWorld()
        let before = try require(w.editor.fileFields).text(for: "")
        expectEqual(try require(w.editor.fileFields).text(for: ""), before)
        w.editor.transact { $0.update(w.fromEnd, as: Bond.self) { $0.props.text = MentionText(plain: "positions") } }
        let renamed = try require(w.editor.fileFields).text(for: "")
        expect(renamed.contains(#"Person "positions" (only one)"#) && !renamed.contains(#""jobs""#), "a name typed on an end: \(renamed)")
        w.editor.transact { $0.update(w.toEnd) { $0[RelationshipEndProperty.self] = nil } }
        let cleared = try require(w.editor.fileFields).text(for: "")
        expect(cleared.contains(#"; rows: Person "positions" (only one), Company "staff""#), "a flag taken off, the name stays: \(cleared)")
        w.editor.transact { $0.update(w.employment) { $0[RelationshipProperty.self] = nil } }
        let plain = try require(w.editor.fileFields).text(for: "")
        expect(plain.contains("Employment: role (text), since (date)") && !plain.contains("relates"), "unmarked, it is a type like another: \(plain)")
    },
    test("a question that names an end's type or a name typed on an end puts the relationship type first") {
        let w = try RelationshipWorld()
        let agency = w.editor.addType(#"{"type": "object", "properties": {"city": {"type": "string"}}}"#, title: "Agency", at: CGPoint(x: 40, y: 700))
        let first = try require(w.editor.fileFields).text(for: "who has the most jobs?").split(separator: "\n").first.map(String.init)
        expect(first?.hasPrefix("Employment relates") == true, "the typed name jobs: \(String(describing: first))")
        let other = try require(w.editor.fileFields).text(for: "which company?").split(separator: "\n").first.map(String.init)
        expect(other?.hasPrefix("Company") == true || other?.hasPrefix("Employment relates") == true, "an end's type: \(String(describing: other))")
        _ = agency
    },
    test("an end's type puts the relationship type among the types that share a word with the question, before types with more notes") {
        let w = try RelationshipWorld()
        let agency = w.editor.addType(#"{"type": "object", "properties": {"city": {"type": "string"}}}"#, title: "Agency", at: CGPoint(x: 40, y: 700))
        w.editor.addBond(w.employment, agency)
        for number in 1...3 { _ = w.editor.addInstance("P\(number)", of: [w.person], at: CGPoint(x: 500, y: 400 + 100 * Double(number))) }
        let lines = try require(w.editor.fileFields).text(for: "which agency?").split(separator: "\n").map(String.init)
        expect(lines[0].hasPrefix("Agency"), lines[0])
        expect(lines[1].hasPrefix("Employment relates"), "named by its end's type, ahead of Person's three notes: \(lines)")
        expect(lines[2].hasPrefix("Person"), lines[2])
    },
    test("an end at a type with no title is told as an untitled type") {
        let w = try RelationshipWorld(named: false)
        let blank = w.editor.addType(#"{"type": "object", "properties": {"z": {"type": "string"}}}"#, title: nil, at: CGPoint(x: 40, y: 700))
        w.editor.addBond(w.employment, blank)
        let text = try require(w.editor.fileFields).text(for: "")
        expect(text.contains("Employment relates Person to Company or an untitled type: role (text), since (date)"), text)
    },
    test("relationship lines count against the 8,000 characters, whole lines from the front and the rest named on a last line") {
        let w = try RelationshipWorld()
        let properties = (1...40).map { #""field\#($0)": {"type": "string"}"# }.joined(separator: ", ")
        for number in 1...30 {
            let type = w.editor.addRelationshipType("Relation \(number < 10 ? "0" : "")\(number)", at: CGPoint(x: 400, y: 400 + 40 * Double(number)))
            w.editor.transact { $0.update(type) { $0[TypeSchemaProperty.self] = SchemaText(#"{"type": "object", "properties": {\#(properties)}}"#) } }
            w.editor.addBond(w.person, type, name: "row \(number)")
        }
        let text = try require(w.editor.fileFields).text(for: "")
        expect(text.count <= 8_000, "\(text.count) characters")
        let lines = text.split(separator: "\n").map(String.init)
        expect(lines.last?.hasPrefix("and ") == true && lines.last?.contains(" more types: ") == true, "\(String(describing: lines.last))")
        expect(lines.dropLast().allSatisfy { $0.count <= 8_000 && ($0.hasSuffix(")") || $0.contains("(")) }, "whole lines")
        expect(lines.contains { $0.contains(" relates Person to anything") && $0.contains(#"rows: Person "row"#) }, "a relationship type's line is whole")
    },
    test("a type that comes to build on another changes the lines kept, so the relationship type's line says builds on") {
        let w = try RelationshipWorld(named: false)
        let before = try require(w.editor.fileFields).text(for: "")
        expect(!before.contains("builds on"), before)
        let parent = w.editor.addRelationshipType("Bond", at: CGPoint(x: 400, y: 500))
        w.editor.addTypeLink(parent, to: w.employment)
        let after = try require(w.editor.fileFields).text(for: "")
        expect(after.contains("Employment builds on Bond relates Person to Company"), after)
    },
])

/// Person, Company, and Employment from a Person to a Company (a role and a start date), its ends named `jobs`
/// (Only one) and `staff` (Needed) unless `named` is false.
@MainActor private struct RelationshipWorld {
    let editor: CanvasEditor
    let person: ShapeID, company: ShapeID, employment: ShapeID, fromEnd: ShapeID, toEnd: ShapeID

    init(named: Bool = true) throws {
        editor = try bondEditor()
        person = editor.addType(#"{"type": "object", "properties": {"name": {"type": "string"}}}"#, title: "Person", at: CGPoint(x: 40, y: 40))
        company = editor.addType(#"{"type": "object", "properties": {"name": {"type": "string"}}}"#, title: "Company", at: CGPoint(x: 40, y: 200))
        var record = slipTypeRecord(#"{"type": "object", "properties": {"role": {"type": "string"}, "since": {"type": "string", "format": "date"}}}"#, title: "Employment",
                                    at: CGPoint(x: 400, y: 40))
        record[RelationshipProperty.self] = true
        editor.transact { $0.insert(record) }
        employment = record.id
        fromEnd = editor.addBond(person, employment, name: named ? "jobs" : "", rule: named ? EndRule(needed: false, onlyOne: true) : nil)
        toEnd = editor.addBond(employment, company, name: named ? "staff" : "", rule: named ? EndRule(needed: true, onlyOne: false) : nil)
    }
}
