import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Foundation
import LanguageModels
import Mentions
import TestKit
import Titles
import Types

// What a mention can mean (`TypeIndex.canBeEmbedded`): a type, and no relationship type. A relationship type's fields
// belong to its arrows, so a mention of one in another type's words is plain words to the model (the sync's
// `<schemas>`, the request for highlights) and the `$ref` completion leaves it out, while a `$ref` to one written by
// hand still reads as its word. A relationship type's own words, naming its ends, are synced as any type's.

/// A relationship type: a memo with the starter schema and the mark, titled.
@MainActor private func relationshipType(_ title: String, in editor: CanvasEditor, at origin: CGPoint = CGPoint(x: 800, y: 0)) -> ShapeID {
    var record = typeRecord(TypeSchemaProperty.starter, title: title, at: origin)
    record[RelationshipProperty.self] = true
    editor.transact { $0.insert(record) }
    return record.id
}

private let personSchema = """
{
  "type": "object",
  "properties": {
    "name": { "type": "string" }
  }
}
"""

@MainActor let mentionedTypeTests = Suite("What a mention can mean", [
    test("a type is embeddable, a relationship type is not, and unmarking it makes it so") {
        let b = try SyncBench()
        let address = b.add(addressSchema)
        let employment = relationshipType("Employment", in: b.editor)
        let types = try require(b.editor.types)
        expect(types.canBeEmbedded(address))
        expect(!types.canBeEmbedded(employment), "its fields belong to its arrows")
        b.editor.transact { $0.update(employment) { $0[RelationshipProperty.self] = nil } }
        expect(types.canBeEmbedded(employment), "unmarked, it is a type like any")
    },
    test("the sync reads a mention of a relationship type as the words it holds: it is not in <schemas>, and a plain type's is") {
        let b = try SyncBench()
        let address = b.add(addressSchema)
        let employment = relationshipType("Employment", in: b.editor)
        let house = b.place()
        b.write(house, MentionText([.text("A house: its "), .mention(address, label: "Address"), .text(", and an "), .mention(employment, label: "Employment"), .text(".")]))
        b.sync(house, answer: "NO_CHANGE")
        let message = try require(b.message(0))
        expect(message.hasPrefix("<schemas>\n@Address\n</schemas>"), message)
        expect(message.contains("A house: its @Address, and an Employment."), message)
        expect(!message.contains("@Employment"), message)
    },
    test("only a relationship type mentioned: no <schemas> block at all, and the words as they are") {
        let b = try SyncBench()
        let employment = relationshipType("Employment", in: b.editor)
        let house = b.place()
        b.write(house, MentionText([.text("A house, "), .mention(employment, label: "Employment")]))
        b.sync(house, answer: "NO_CHANGE")
        let message = try require(b.message(0))
        expect(!message.contains("<schemas>"), message)
        expect(message.contains("A house, Employment"), message)
    },
    test("a relationship type's own words, naming its ends, write only its own fields: the ends are in <schemas>, the answer is written as given and the mark stays") {
        let b = try SyncBench()
        let person = b.add(personSchema.replacingOccurrences(of: "{\n", with: "{\n  \"title\": \"Person\",\n"), at: CGPoint(x: 400, y: 0))
        let company = b.add(addressSchema.replacingOccurrences(of: "Address", with: "Company"), at: CGPoint(x: 400, y: 300))
        let employment = relationshipType("Employment", in: b.editor)
        b.write(employment, MentionText([.text("A job a "), .mention(person, label: "Person"), .text(" holds at a "), .mention(company, label: "Company"), .text(": a role and a start date")]))
        let answer = #"{"type": "object", "properties": {"role": {"type": "string"}, "since": {"type": "string", "format": "date"}}}"#
        b.sync(employment, answer: answer)
        let message = try require(b.message(0))
        expect(message.hasPrefix("<schemas>\n@Person\n@Company\n</schemas>"), message)
        let schema = try require(b.schema(employment))
        expect(!schema.contains("$ref") && !schema.contains("urn:uuid:"), "no end is written: \(schema)")
        expect(schema.contains("\"role\"") && schema.contains("\"since\""), schema)
        expectEqual(b.editor.document[employment]?[RelationshipProperty.self], true, "the mark is neither side's")
        expectEqual(b.words(employment)?.runs.filter { if case .mention = $0 { true } else { false } }.count, 2, "the mentions stay")
        expect(b.sync.isInStep(employment))
    },
    test("a $ref to a relationship type written by hand still round-trips: the model reads it as its word and the words get its mention") {
        let b = try SyncBench()
        let employment = relationshipType("Employment", in: b.editor)
        let house = b.place()
        b.typeSchema(house, houseSchema(SchemaReferences.uri(of: employment)))
        b.sync(house, answer: "A house with an @Employment, and bedrooms (required).")
        let message = try require(b.message(0))
        expect(message.contains(#""$ref": "@Employment""#), message)
        expect(!message.contains("urn:uuid:"), "never an id")
        expectEqual(b.words(house)?.runs, [.text("A house with an "), .mention(employment, label: "Employment"), .text(", and bedrooms (required).")])
    },
    test("the $ref completion offers the plain types and leaves a relationship type out") {
        let b = try SyncBench()
        let address = b.add(addressSchema)
        let employment = relationshipType("Employment", in: b.editor)
        let house = b.place()
        let offered = try require(b.editor.types).referenceTargets(from: house)
        expectEqual(offered.map(\.label), ["Address"])
        expectEqual(offered.map(\.json), [JSONReader.literal(SchemaReferences.uri(of: address))])
        b.editor.transact { $0.update(employment) { $0[RelationshipProperty.self] = nil } }
        expectEqual(try require(b.editor.types).referenceTargets(from: house).map(\.label), ["Address", "Employment"])
    },
    test("the request for highlights reads a mention of a relationship type as its label and a plain type's as its word") {
        let b = try HighlightBench()
        let address = b.editor.addType(addressSchema, title: "Address", at: CGPoint(x: 400, y: 40))
        let employment = relationshipType("Employment", in: b.editor)
        let house = b.editor.addType(jiraSchema, words: MentionText([.text("a ticket in an "), .mention(address, label: "Address"), .text(" with an "),
                                                                   .mention(employment, label: "Employment"), .text(": its key")]))
        _ = house
        b.frame()
        b.settle()
        let request = try require(b.asked.first)
        let message = try require(request.messages.first?.text)
        expect(message.contains("a ticket in an @Address with an Employment: its key"), message)
        expect(!message.contains("@Employment"), message)
    },
])
