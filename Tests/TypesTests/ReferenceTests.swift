import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Foundation
import LanguageModels
import Mentions
import TestKit
import Titles
import Types

// A type's words mention another type, and its schema refers to that type's schema with a `$ref` to
// its URI (`urn:uuid:` and the type's id): the two kept in step through the model, which reads each
// type as `@` and a word of its name.

let addressSchema = """
{
  "title": "Address",
  "type": "object",
  "properties": {
    "street": { "type": "string" },
    "city": { "type": "string" }
  }
}
"""

/// A house whose `address` is `$ref`, and whose bedrooms are required; untitled, as a type keeps it
/// once the model's title is taken out.
func houseSchema(_ ref: String, titled: Bool = true) -> String {
    (titled ? "{\n  \"title\": \"House\",\n" : "{\n") + """
      "type": "object",
      "properties": {
        "address": { "$ref": "\(ref)" },
        "bedrooms": { "type": "integer" }
      },
      "required": ["bedrooms"]
    }
    """
}

private func uri(_ id: ShapeID) -> String { SchemaReferences.uri(of: id) }

/// Words: their runs, a mention of `card` called `name` where the text says `@`.
private func described(_ text: String, mentioning card: ShapeID, as name: String) -> MentionText {
    let parts = text.components(separatedBy: "@")
    var runs: [MentionRun] = []
    for (index, part) in parts.enumerated() {
        if index > 0 { runs.append(.mention(card, label: name)) }
        if !part.isEmpty { runs.append(.text(part)) }
    }
    return MentionText(runs)
}

extension CanvasEditor {
    /// A type of `schema`, titled as its root `"title"` says, somewhere out of the way.
    @discardableResult
    func addTitled(_ schema: String, at origin: CGPoint = CGPoint(x: 400, y: 0), width: CGFloat = 240) -> ShapeID {
        addType(schema, title: SchemaDocument(schema).title, at: origin, width: width)
    }

    /// The person writing words with mentions, the memo fitted to them.
    func write(_ id: ShapeID, _ words: MentionText) {
        transact { $0.update(id, as: Memo.self) { $0.props.text = words; MemoStyle.fit(&$0.props) } }
    }
}

extension SyncBench {
    /// A titled type of `schema`, somewhere out of the way.
    func add(_ schema: String, at origin: CGPoint = CGPoint(x: 400, y: 0)) -> ShapeID { editor.addTitled(schema, at: origin) }

    /// The person writing words with mentions.
    func write(_ id: ShapeID, _ words: MentionText) { editor.write(id, words) }
}

@MainActor let referenceTests = Suite("Type references", [
    test("a type's URI is urn:uuid: and its id, lowercase; a $ref to one reads in any case, whole or with a fragment, and nothing else does") {
        let id = ShapeID(UUID(uuidString: "5B0E7C1A-3D2F-4E6B-8A9C-1F2E3D4C5B6A")!)
        expectEqual(uri(id), "urn:uuid:5b0e7c1a-3d2f-4e6b-8a9c-1f2e3d4c5b6a")
        expectEqual(SchemaReferences.target(of: "urn:uuid:5b0e7c1a-3d2f-4e6b-8a9c-1f2e3d4c5b6a")?.shape, id)
        expectEqual(SchemaReferences.target(of: "urn:uuid:5b0e7c1a-3d2f-4e6b-8a9c-1f2e3d4c5b6a")?.fragment, "")
        expectEqual(SchemaReferences.target(of: "URN:UUID:5B0E7C1A-3D2F-4E6B-8A9C-1F2E3D4C5B6A")?.shape, id)
        let part = SchemaReferences.target(of: "urn:uuid:5b0e7c1a-3d2f-4e6b-8a9c-1f2e3d4c5b6a#/$defs/money")
        expectEqual(part?.shape, id)
        expectEqual(part?.fragment, "#/$defs/money")
        for other in ["#/$defs/money", "#", "https://example.com/address.json", "urn:uuid:5b0e7c1a", "urn:uuid:5b0e7c1a-3d2f-4e6b-8a9c-1f2e3d4c5b6ax",
                      "urn:isbn:5b0e7c1a-3d2f-4e6b-8a9c-1f2e3d4c5b6a", "urn:uuid:5b0e7c1a-3d2f-4e6b-8a9c-1f2e3d4c5b6é", ""] {
            expect(SchemaReferences.target(of: other) == nil, other)
        }
    },
    test("a schema's $refs to types are found at any depth, in its order, with where their values are; none in text that isn't JSON or never says urn:uuid:") {
        let a = ShapeID(), b = ShapeID()
        let text = ##"{"properties": {"home": {"$ref": "\##(uri(a))"}, "stops": {"type": "array", "items": {"$ref": "\##(uri(b))#/$defs/stop"}}, "##
            + ##""near": {"$ref": "#/$defs/x"}}, "anyOf": [{"$ref": "\##(uri(a).uppercased())"}], "é": {"$ref": "\##(uri(b))"}}"##
        let refs = SchemaReferences.refs(in: text)
        expectEqual(refs.map(\.shape), [a, b, a, b])
        expectEqual(refs.map(\.fragment), ["", "#/$defs/stop", "", ""])
        let bytes = Array(text.utf8)
        expectEqual(refs.map { String(decoding: bytes[$0.range], as: UTF8.self) },
                    ["\"\(uri(a))\"", "\"\(uri(b))#/$defs/stop\"", "\"\(uri(a).uppercased())\"", "\"\(uri(b))\""], "each value, its quotes and all")
        expectEqual(SchemaReferences.refs(in: String(text.dropLast())), [], "not JSON")
        expectEqual(SchemaReferences.refs(in: ##"{"$ref": "#/$defs/x", "properties": {"a": {"$ref": "urn:isbn:1"}}}"##), [])
    },
    test("a schema names the types it refers to; a copy renames those copied with it, keeps the rest, and changes nothing else, byte for byte") {
        let a = ShapeID(), b = ShapeID(), copy = ShapeID()
        let schema = SchemaText("""
        {
          "properties": {
            "home": { "$ref": "\(uri(a))" },
            "work": { "$ref": "\(uri(b))#/$defs/office" },
            "again": { "$ref": "\(uri(a).uppercased())" }
          }
        }
        """)
        var named: [ShapeID] = []
        schema.forEachNamedShape { named.append($0) }
        expectEqual(named, [a, b, a])
        let renamed = schema.renamingShapes { $0 == a ? copy : nil }
        expectEqual(renamed.text, schema.text.replacingOccurrences(of: uri(a).uppercased(), with: uri(copy)).replacingOccurrences(of: uri(a), with: uri(copy)))
        expectEqual(schema.renamingShapes { _ in nil }, schema)
        expectEqual(SchemaText("not JSON \(uri(a))").renamingShapes { _ in copy }.text, "not JSON \(uri(a))")
    },
    test("a type copied with the type it refers to refers to the copy, in its schema and its words alike; copied alone, to the original") {
        let b = try SyncBench()
        let address = b.add(addressSchema)
        let house = b.editor.addType(houseSchema(uri(address)), at: .zero)
        b.write(house, described("A house: its @, and bedrooms", mentioning: address, as: "Address"))
        let record = try require(b.editor.document[house])
        expect(b.editor.registry.namingKinds.contains(Memo.kind), "the schema names shapes, as the words do")
        let copyOfAddress = ShapeID()
        let both = try require(record.remappingReferences({ $0 == address ? copyOfAddress : nil }, in: b.editor.shapeContext))
        expectEqual(both[TypeSchemaProperty.self]?.text, houseSchema(uri(copyOfAddress)))
        expectEqual(both.typed(as: Memo.self)?.props.text.mentioned, [copyOfAddress])
        let alone = try require(record.remappingReferences({ _ in nil }, in: b.editor.shapeContext))
        expectEqual(alone[TypeSchemaProperty.self]?.text, houseSchema(uri(address)))
        expectEqual(alone.typed(as: Memo.self)?.props.text.mentioned, [address])
    },
])

@MainActor let referenceNameTests = Suite("Type reference words", [
    test("a type's word is its name run together, each word after the first capitalized, only letters, digits and _; a second type of one word is numbered") {
        expectEqual(SchemaReferenceNames.word(for: "Line Item"), "LineItem")
        expectEqual(SchemaReferenceNames.word(for: "line item"), "lineItem")
        expectEqual(SchemaReferenceNames.word(for: "Q&A log"), "QALog")
        expectEqual(SchemaReferenceNames.word(for: "dirección postal"), "direcciónPostal")
        expectEqual(SchemaReferenceNames.word(for: "住所"), "住所")
        expectEqual(SchemaReferenceNames.word(for: "C# class"), "CClass")
        expectEqual(SchemaReferenceNames.word(for: "!!!"), "Schema")
        let a = ShapeID(), b = ShapeID(), c = ShapeID()
        let names = SchemaReferenceNames(words: [described("@ and @", mentioning: a, as: "Address")],
                                         schemas: [houseSchema(uri(b)), houseSchema(uri(c))]) { id in
            [a: "Address", b: "address", c: nil][id] ?? nil
        }
        expectEqual(names.named.map(\.word), ["Address", "address2"], "a type named, then a type referred to; one referred to with no name isn't")
        expectEqual(names.list, "@Address\n@address2")
        expectEqual(names.shape(forWord: "ADDRESS2"), b)
    },
    test("the model reads each mention as @ and its word; a word, or any of it, is its pill in the text as drawn") {
        let a = ShapeID()
        let prompt = described("Its @ and its bedrooms", mentioning: a, as: "Line Item")
        let names = SchemaReferenceNames(words: [prompt], schemas: [], name: { _ in nil })
        let read = names.modelText(of: prompt)
        expectEqual(read.text, "Its @LineItem and its bedrooms")
        let text = read.text as NSString
        expectEqual(read.drawnRange(of: text.range(of: "@LineItem")), NSRange(location: 4, length: 1), "the pill")
        expectEqual(read.drawnRange(of: text.range(of: "Item")), NSRange(location: 4, length: 1))
        expectEqual(read.drawnRange(of: text.range(of: "bedrooms")), NSRange(location: 14, length: 8), "after the pill, shifted")
        expectEqual(read.drawnRange(of: text.range(of: "Its @Line")), NSRange(location: 0, length: 5))
    },
    test("a $ref to a named type reads as its word, a fragment kept; the model's words read back as URIs, any case; anything else stays as written") {
        let a = ShapeID(), other = ShapeID()
        let names = SchemaReferenceNames(words: [described("@", mentioning: a, as: "Address")], schemas: [], name: { _ in nil })
        let schema = #"{"properties": {"home": {"$ref": "\#(uri(a))"}, "part": {"$ref": "\#(uri(a))#/$defs/zip"}, "other": {"$ref": "\#(uri(other))"}}}"#
        let modeled = names.modelSchema(schema)
        expectEqual(modeled, #"{"properties": {"home": {"$ref": "@Address"}, "part": {"$ref": "@Address#/$defs/zip"}, "other": {"$ref": "\#(uri(other))"}}}"#)
        expectEqual(names.schema(fromModel: modeled), schema)
        expectEqual(names.schema(fromModel: #"{"a": {"$ref": "@address"}, "b": {"$ref": "@Nowhere"}, "c": "@Address"}"#),
                    #"{"a": {"$ref": "\#(uri(a))"}, "b": {"$ref": "@Nowhere"}, "c": "@Address"}"#)
        expectEqual(names.schema(fromModel: #"{"a": {"$ref": "@Address"}"#), #"{"a": {"$ref": "@Address"}"#, "not JSON: as written")
    },
    test("the model's words read each @ and word as a mention of its type, named as it is: the longest word, not inside one, not after a letter") {
        let a = ShapeID(), b = ShapeID()
        let names = SchemaReferenceNames(words: [described("@", mentioning: a, as: "Line Item")], schemas: [houseSchema(uri(b))]) { id in
            id == b ? "Line Item" : nil
        }
        expectEqual(names.named.map(\.word), ["LineItem", "LineItem2"])
        let prompt = names.words(fromModel: "Some @LineItem2 rows, a @lineitem, not @LineItems, me@LineItem or @Nowhere; \\@[x](shape:1) (@LineItem).")
        expectEqual(prompt.runs, [.text("Some "), .mention(b, label: "Line Item"), .text(" rows, a "), .mention(a, label: "Line Item"),
                                  .text(", not @LineItems, me@LineItem or @Nowhere; \\@[x](shape:1) ("), .mention(a, label: "Line Item"), .text(").")])
        expectEqual(prompt.lookalikes, [], "text that looks like a mention stays text")
        expectEqual(SchemaReferenceNames(words: [], schemas: [], name: { _ in nil }).words(fromModel: "a @House").runs, [.text("a @House")])
    },
    test("a mention of a shape that isn't a type is words the model reads, its label as it is, not a type it may point to") {
        let note = ShapeID(), card = ShapeID()
        let prompt = MentionText([.text("See "), .mention(note, label: "Groceries"), .text(" and "), .mention(card, label: "Address")])
        let names = SchemaReferenceNames(words: [prompt], schemas: [], name: { _ in nil }, isType: { $0 == card })
        expectEqual(names.list, "@Address")
        let read = names.modelText(of: prompt)
        expectEqual(read.text, "See Groceries and @Address")
        expectEqual(read.drawnRange(of: (read.text as NSString).range(of: "Groceries")), NSRange(location: 4, length: 1), "its pill")
    },
])

@MainActor let referenceSyncTests = Suite("Type references synced", [
    test("words that mention a type have its schema point to it: the model reads the type as @ and a word, and its $ref to the word is the type's URI") {
        let b = try SyncBench()
        let address = b.add(addressSchema)
        let house = b.place()
        b.write(house, described("A house: its @, and how many bedrooms (required)", mentioning: address, as: "Address"))
        b.sync(house, answer: houseSchema("@Address"))
        let message = try require(b.message(0))
        expect(message.hasPrefix("<schemas>\n@Address\n</schemas>\n\n<prompt>\nA house: its @Address, and how many bedrooms (required)\n</prompt>"), message)
        expectEqual(b.schema(house), houseSchema(uri(address), titled: false))
        expectEqual(b.title(house), "House")
        expectEqual(b.status(house), .idle)
        expect(b.sync.isInStep(house))
    },
    test("a $ref typed by hand has the words mention the type: the model's @ and word is a mention of it, named as the type is") {
        let b = try SyncBench()
        let address = b.add(addressSchema)
        let house = b.place()
        b.typeSchema(house, houseSchema(uri(address)))
        b.sync(house, answer: "A house with an @Address, and bedrooms (required).")
        let message = try require(b.message(0))
        expect(message.contains(#""$ref": "@Address""#), message)
        expect(message.hasPrefix("<schemas>\n@Address\n</schemas>"), message)
        expect(!message.contains("urn:uuid:"), "never an id")
        expectEqual(b.words(house)?.runs, [.text("A house with an "), .mention(address, label: "Address"), .text(", and bedrooms (required).")])
    },
    test("the model reads each type as it's called now: renamed since it was mentioned, a type with another's name, and one deleted, by the name its mention holds") {
        let b = try SyncBench()
        let address = b.add(addressSchema)
        let other = b.add(addressSchema.replacingOccurrences(of: "\"street\"", with: "\"line\""), at: CGPoint(x: 700, y: 0))
        let gone = ShapeID()
        let house = b.place()
        b.write(house, MentionText([.text("A house: its "), .mention(address, label: "Old name"), .text(", a "), .mention(other, label: "Address"),
                                         .text(" for mail, and a "), .mention(gone, label: "Garden"), .text(".")]))
        b.editor.transact { $0.update(address) { $0[TitleProperty.self] = "Mailing Address" } }
        b.sync(house, answer: "NO_CHANGE")
        let message = try require(b.message(0))
        expect(message.contains("<schemas>\n@MailingAddress\n@Address\n@Garden\n</schemas>"), message)
        expect(message.contains("A house: its @MailingAddress, a @Address for mail, and a @Garden."), message)
    },
    test("a type on another board of the file is read as any other: its name, and its $ref") {
        let pocket = ShapeID(), address = ShapeID(), house = ShapeID()
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 600, y: 0, width: 100, height: 100)))),
                                                            typeRecord(TypeSchemaProperty.starter, at: .zero, id: house)]),
                              children: [pocket: CanvasDocument(shapes: [typeRecord(addressSchema, title: "Address", id: address)])])
        let b = try SyncBench(file: file, more: [PocketsPlugin()])
        b.write(house, described("A house: its @", mentioning: address, as: "Address"))
        b.sync(house, answer: houseSchema("@Address"))
        expectEqual(b.schema(house), houseSchema(uri(address), titled: false))
        expect(b.editor.types?.isType(address) == true, "a type on a board not shown")
        expectEqual(b.editor.types?.name(of: address), "Address")
    },
])

@MainActor let referenceShownTests = Suite("Type references shown", [
    test("a type is mentioned as its shape is, by its title; what mentions a type is listed") {
        let b = try SyncBench()
        let address = b.add(addressSchema)
        let house = b.add(houseSchema(uri(address)), at: CGPoint(x: 0, y: 300))
        let appearance = try require(b.editor.registry.mentionAppearance(of: try require(b.editor.document[address])))
        expectEqual(appearance.label, "Address")
        b.write(house, described("A house: its @", mentioning: address, as: "Address"))
        expect(b.editor.mentions?.isMentioned(address) == true)
        expectEqual(b.editor.mentions?.backlinks(of: address).map(\.id), [house])
    },
    test("a type draws its words' mentions as pills, live, inside its text") {
        let b = try SyncBench()
        let address = b.add(addressSchema)
        let house = b.place()
        b.write(house, described("A house: its @, and how many bedrooms (required) it has, counted", mentioning: address, as: "Address"))
        let frame = try require(b.editor.document[house]?.box)
        let pills = b.editor.mentionPills(of: house)
        expectEqual(pills.map(\.target), [address])
        expectEqual(pills.map(\.isLive), [true])
        expect(frame.insetBy(dx: MemoStyle.padding - 0.5, dy: MemoStyle.padding - 0.5).contains(try require(pills.first).frame))
    },
    test("words the model writes with mentions are written through the kind's words, which fit the shape to them") {
        let b = try SyncBench()
        let zip = b.add(#"{"title": "Zip", "type": "object"}"#)
        let house = b.place()
        b.typeSchema(house, houseSchema(uri(zip)))
        b.sync(house, answer: "A house at " + String(repeating: "@Zip ", count: 12) + "and bedrooms (required).")
        let memo = try require(b.memo(house))
        expectEqual(memo.text.runs.filter { if case .mention = $0 { true } else { false } }.count, 12)
        var fitted = memo
        MemoStyle.fit(&fitted)
        expect(memo.frame.height > MemoStyle.emptyHeight, "\(memo.frame.height)")
        expectEqual(memo.frame, fitted.frame, "as the kind fits it")
        expectEqual(b.editor.undoHistory.undoName, "Update Text")
    },
    test("a highlight on a mention is its pill: the model's words are found in the words as it read them, and the words after it are where they're drawn") {
        let b = try HighlightBench()
        let address = b.editor.addTitled(addressSchema, at: CGPoint(x: 500, y: 100))
        b.answer = .success(ModelResponse(text: #"[{"text": "house", "address": ""}, {"text": "@Address", "address": "/properties/address"}, "#
                                            + #"{"text": "bedrooms", "address": "/properties/bedrooms"}, {"text": "required", "address": "/required"}]"#))
        let house = b.editor.addType(houseSchema(uri(address)), words: described("A house: its @, and how many bedrooms (required)", mentioning: address, as: "Address"),
                                     at: CGPoint(x: 100, y: 100), width: 320)
        b.frame()
        b.settle()
        let asked = try require(b.asked.last?.messages.first?.text)
        expect(asked.contains("A house: its @Address, and how many bedrooms (required)"), asked)
        expect(asked.contains(#""$ref": "@Address""#), asked)
        expect(b.asked.last?.system?.hasSuffix("\n" + SchemaPrompts.highlightsReferences) == true, "told how an @ word links, after the guide")
        let placed = b.placed(house)
        expectEqual(placed.map(\.range), [NSRange(location: 2, length: 5), NSRange(location: 13, length: 1), NSRange(location: 29, length: 8),
                                          NSRange(location: 39, length: 8)])
        let lines = b.lines(house)
        let pill = try require(b.editor.mentionPills(of: house).first).frame
        let line = try require(lines[1].first)
        expect(line.minX <= pill.minX + 0.5 && line.maxX >= pill.maxX - 0.5 && line.minY <= pill.minY && line.maxY >= pill.maxY,
               "the pill's highlight is around it: \(line) \(pill)")
    },
    test("resting the pointer on a mention's highlight shows the schema it refers to, the whole of it") {
        let b = try HighlightBench()
        let address = b.editor.addTitled(addressSchema, at: CGPoint(x: 500, y: 100))
        b.answer = .success(ModelResponse(text: #"[{"text": "@Address", "address": "/properties/address"}]"#))
        let house = b.editor.addType(houseSchema(uri(address)), words: described("A house: its @, and bedrooms", mentioning: address, as: "Address"),
                                     at: CGPoint(x: 100, y: 100), width: 320)
        b.frame()
        b.settle()
        let lines = b.lines(house)
        let line = try require(lines.first?.first)
        b.move(to: CGPoint(x: line.midX, y: line.midY))
        expectEqual(b.popoverAfterDelay(), addressSchema)
    },
    test("resting the pointer on a mention's highlight whose $ref has a fragment shows that part of the schema it refers to, percent-encoded or not") {
        let moneySchema = #"{"title": "Money", "type": "object", "$defs": {"Unit Price": {"type": "number", "minimum": 0}}}"#
        for fragment in ["#/$defs/Unit%20Price", "#/$defs/Unit Price"] {
            let b = try HighlightBench()
            let money = b.editor.addTitled(moneySchema, at: CGPoint(x: 500, y: 100))
            b.answer = .success(ModelResponse(text: #"[{"text": "@Money", "address": "/properties/address"}]"#))
            let house = b.editor.addType(houseSchema(uri(money) + fragment), words: described("A house: its @, and bedrooms", mentioning: money, as: "Money"),
                                         at: CGPoint(x: 100, y: 100), width: 320)
            b.frame()
            b.settle()
            let line = try require(b.lines(house).first?.first)
            b.move(to: CGPoint(x: line.midX, y: line.midY))
            expectEqual(b.popoverAfterDelay(), #""Unit Price": {"type": "number", "minimum": 0}"#, fragment)
        }
    },
    test("a $ref's completions list the file's other titled types by their names, each written as its URI; a type's own list leaves it out") {
        let b = try SyncBench()
        let address = b.add(addressSchema)
        let zone = b.add(#"{"title": "Zone", "type": "object", "properties": {}}"#, at: CGPoint(x: 700, y: 0))
        _ = b.add(#"{"type": "object"}"#, at: CGPoint(x: 1000, y: 0))
        let house = b.place()
        let types = try require(b.editor.types)
        let targets = types.referenceTargets(from: house)
        expectEqual(targets.map(\.label), ["Address", "Zone"])
        expectEqual(targets.map(\.json), ["\"\(uri(address))\"", "\"\(uri(zone))\""])
        expectEqual(targets.map(\.detail), ["2 fields", ""])
        expectEqual(types.referenceTargets(from: address).map(\.label), ["Zone"])
        let text = #"{"properties": {"home": {"$ref": ""}}}"#
        let caret = (text as NSString).range(of: #""$ref": ""#).location + 9
        let listed = try require(TypeCompletions.completions(in: text, at: caret, types: { targets }))
        expectEqual(listed.items.map(\.label), ["#", "Address", "Zone"])
        expectEqual(listed.items.last?.insert, "\"\(uri(zone))\"", "the value, quotes and all, in place of the one there")
        let asked = Counter()
        _ = TypeCompletions.completions(in: text, at: 1, types: { asked.count += 1; return targets })
        expectEqual(asked.count, 0, "asked only where a $ref's value goes")
    },
])
