import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import DetailPanel
import Foundation
import LanguageModels
import Mentions
import Schemas
import Selection
import TestKit
import TextEditing

// A card's description mentions another schema card, and its schema refers to that card's schema
// with a `$ref` to its URI (`urn:uuid:` and the card's id): the two kept in step through the model,
// which reads each card as `@` and a word of its name.

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

/// A house whose `address` is `$ref`, and whose bedrooms are required.
func houseSchema(_ ref: String) -> String {
    """
    {
      "title": "House",
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

/// A description: its runs, a mention of `card` called `name` where the text says `@`.
private func described(_ text: String, mentioning card: ShapeID, as name: String) -> SchemaPromptText {
    let parts = text.components(separatedBy: "@")
    var runs: [MentionRun] = []
    for (index, part) in parts.enumerated() {
        if index > 0 { runs.append(.mention(card, label: name)) }
        if !part.isEmpty { runs.append(.text(part)) }
    }
    return SchemaPromptText(runs)
}

extension SyncBench {
    /// A titled card of `schema`, somewhere out of the way.
    func add(_ schema: String, at origin: CGPoint = CGPoint(x: 400, y: 0)) -> ShapeID {
        editor.add(SchemasTests.card(schema, at: origin))
    }

    /// The person writing a description with mentions.
    func write(_ id: ShapeID, _ prompt: SchemaPromptText) {
        editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.setPrompt(prompt) } }
    }
}

@MainActor let referenceTests = Suite("Schema references", [
    test("a card's URI is urn:uuid: and its id, lowercase; a $ref to one reads in any case, whole or with a fragment, and nothing else does") {
        let id = ShapeID(UUID(uuidString: "5B0E7C1A-3D2F-4E6B-8A9C-1F2E3D4C5B6A")!)
        expectEqual(uri(id), "urn:uuid:5b0e7c1a-3d2f-4e6b-8a9c-1f2e3d4c5b6a")
        expectEqual(SchemaReferences.target(of: "urn:uuid:5b0e7c1a-3d2f-4e6b-8a9c-1f2e3d4c5b6a")?.card, id)
        expectEqual(SchemaReferences.target(of: "urn:uuid:5b0e7c1a-3d2f-4e6b-8a9c-1f2e3d4c5b6a")?.fragment, "")
        expectEqual(SchemaReferences.target(of: "URN:UUID:5B0E7C1A-3D2F-4E6B-8A9C-1F2E3D4C5B6A")?.card, id)
        let part = SchemaReferences.target(of: "urn:uuid:5b0e7c1a-3d2f-4e6b-8a9c-1f2e3d4c5b6a#/$defs/money")
        expectEqual(part?.card, id)
        expectEqual(part?.fragment, "#/$defs/money")
        for other in ["#/$defs/money", "#", "https://example.com/address.json", "urn:uuid:5b0e7c1a", "urn:uuid:5b0e7c1a-3d2f-4e6b-8a9c-1f2e3d4c5b6ax",
                      "urn:isbn:5b0e7c1a-3d2f-4e6b-8a9c-1f2e3d4c5b6a", "urn:uuid:5b0e7c1a-3d2f-4e6b-8a9c-1f2e3d4c5b6é", ""] {
            expect(SchemaReferences.target(of: other) == nil, other)
        }
    },
    test("a schema's $refs to cards are found at any depth, in its order, with where their values are; none in text that isn't JSON or never says urn:uuid:") {
        let a = ShapeID(), b = ShapeID()
        let text = ##"{"properties": {"home": {"$ref": "\##(uri(a))"}, "stops": {"type": "array", "items": {"$ref": "\##(uri(b))#/$defs/stop"}}, "##
            + ##""near": {"$ref": "#/$defs/x"}}, "anyOf": [{"$ref": "\##(uri(a).uppercased())"}], "é": {"$ref": "\##(uri(b))"}}"##
        let refs = SchemaReferences.refs(in: text)
        expectEqual(refs.map(\.card), [a, b, a, b])
        expectEqual(refs.map(\.fragment), ["", "#/$defs/stop", "", ""])
        let bytes = Array(text.utf8)
        expectEqual(refs.map { String(decoding: bytes[$0.range], as: UTF8.self) },
                    ["\"\(uri(a))\"", "\"\(uri(b))#/$defs/stop\"", "\"\(uri(a).uppercased())\"", "\"\(uri(b))\""], "each value, its quotes and all")
        expectEqual(SchemaReferences.refs(in: String(text.dropLast())), [], "not JSON")
        expectEqual(SchemaReferences.refs(in: ##"{"$ref": "#/$defs/x", "properties": {"a": {"$ref": "urn:isbn:1"}}}"##), [])
    },
    test("a schema names the cards it refers to; a copy renames those copied with it, keeps the rest, and changes nothing else, byte for byte") {
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
    test("a card copied with the card it refers to refers to the copy, in its schema and its description alike; copied alone, to the original") {
        let b = try SyncBench()
        let address = b.add(addressSchema)
        let house = b.editor.add(SchemaCard(frame: CGRect(x: 0, y: 0, width: 240, height: 89), schema: SchemaText(houseSchema(uri(address)))))
        b.write(house, described("A house: its @, and bedrooms", mentioning: address, as: "Address"))
        let record = try require(b.editor.document[house])
        expect(b.editor.registry.namingKinds.contains(SchemaCard.kind))
        let copyOfAddress = ShapeID()
        let both = try require(record.remappingReferences({ $0 == address ? copyOfAddress : nil }, in: b.editor.shapeContext)?.typed(as: SchemaCard.self))
        expectEqual(both.props.schema.text, houseSchema(uri(copyOfAddress)))
        expectEqual(both.props.prompt.mentioned, [copyOfAddress])
        let alone = try require(record.remappingReferences({ _ in nil }, in: b.editor.shapeContext)?.typed(as: SchemaCard.self))
        expectEqual(alone.props.schema.text, houseSchema(uri(address)))
        expectEqual(alone.props.prompt.mentioned, [address])
    },
])

@MainActor let referenceNameTests = Suite("Schema reference words", [
    test("a card's word is its name run together, each word after the first capitalized, only letters, digits and _; a second card of one word is numbered") {
        expectEqual(SchemaReferenceNames.word(for: "Line Item"), "LineItem")
        expectEqual(SchemaReferenceNames.word(for: "line item"), "lineItem")
        expectEqual(SchemaReferenceNames.word(for: "Q&A log"), "QALog")
        expectEqual(SchemaReferenceNames.word(for: "dirección postal"), "direcciónPostal")
        expectEqual(SchemaReferenceNames.word(for: "住所"), "住所")
        expectEqual(SchemaReferenceNames.word(for: "C# class"), "CClass")
        expectEqual(SchemaReferenceNames.word(for: "!!!"), "Schema")
        let a = ShapeID(), b = ShapeID(), c = ShapeID()
        let names = SchemaReferenceNames(prompts: [described("@ and @", mentioning: a, as: "Address")],
                                         schemas: [houseSchema(uri(b)), houseSchema(uri(c))]) { id in
            [a: "Address", b: "address", c: nil][id] ?? nil
        }
        expectEqual(names.named.map(\.word), ["Address", "address2"], "a card named, then a card referred to; one referred to with no name isn't")
        expectEqual(names.list, "@Address\n@address2")
        expectEqual(names.card(forWord: "ADDRESS2"), b)
    },
    test("the model reads each mention as @ and its word; a word, or any of it, is its pill in the text as drawn") {
        let a = ShapeID()
        let prompt = described("Its @ and its bedrooms", mentioning: a, as: "Line Item")
        let names = SchemaReferenceNames(prompts: [prompt], schemas: [], name: { _ in nil })
        let read = names.modelText(of: prompt)
        expectEqual(read.text, "Its @LineItem and its bedrooms")
        let text = read.text as NSString
        expectEqual(read.shownRange(of: text.range(of: "@LineItem")), NSRange(location: 4, length: 1), "the pill")
        expectEqual(read.shownRange(of: text.range(of: "Item")), NSRange(location: 4, length: 1))
        expectEqual(read.shownRange(of: text.range(of: "bedrooms")), NSRange(location: 14, length: 8), "after the pill, shifted")
        expectEqual(read.shownRange(of: text.range(of: "Its @Line")), NSRange(location: 0, length: 5))
    },
    test("a $ref to a named card reads as its word, a fragment kept; the model's words read back as URIs, any case; anything else stays as written") {
        let a = ShapeID(), other = ShapeID()
        let names = SchemaReferenceNames(prompts: [described("@", mentioning: a, as: "Address")], schemas: [], name: { _ in nil })
        let schema = #"{"properties": {"home": {"$ref": "\#(uri(a))"}, "part": {"$ref": "\#(uri(a))#/$defs/zip"}, "other": {"$ref": "\#(uri(other))"}}}"#
        let modeled = names.modelSchema(schema)
        expectEqual(modeled, #"{"properties": {"home": {"$ref": "@Address"}, "part": {"$ref": "@Address#/$defs/zip"}, "other": {"$ref": "\#(uri(other))"}}}"#)
        expectEqual(names.schema(fromModel: modeled), schema)
        expectEqual(names.schema(fromModel: #"{"a": {"$ref": "@address"}, "b": {"$ref": "@Nowhere"}, "c": "@Address"}"#),
                    #"{"a": {"$ref": "\#(uri(a))"}, "b": {"$ref": "@Nowhere"}, "c": "@Address"}"#)
        expectEqual(names.schema(fromModel: #"{"a": {"$ref": "@Address"}"#), #"{"a": {"$ref": "@Address"}"#, "not JSON: as written")
    },
    test("the model's description reads each @ and word as a mention of its card, named as it is: the longest word, not inside one, not after a letter") {
        let a = ShapeID(), b = ShapeID()
        let names = SchemaReferenceNames(prompts: [described("@", mentioning: a, as: "Line Item")], schemas: [houseSchema(uri(b))]) { id in
            id == b ? "Line Item" : nil
        }
        expectEqual(names.named.map(\.word), ["LineItem", "LineItem2"])
        let prompt = names.prompt(fromModel: "Some @LineItem2 rows, a @lineitem, not @LineItems, me@LineItem or @Nowhere; \\@[x](shape:1) (@LineItem).")
        expectEqual(prompt.runs, [.text("Some "), .mention(b, label: "Line Item"), .text(" rows, a "), .mention(a, label: "Line Item"),
                                  .text(", not @LineItems, me@LineItem or @Nowhere; \\@[x](shape:1) ("), .mention(a, label: "Line Item"), .text(").")])
        expectEqual(prompt.lookalikes, [], "text that looks like a mention stays text")
        expectEqual(SchemaReferenceNames(prompts: [], schemas: [], name: { _ in nil }).prompt(fromModel: "a @House").runs, [.text("a @House")])
    },
    test("a mention of a shape that isn't a schema card is words the model reads, not a card it may point to") {
        let note = ShapeID(), card = ShapeID()
        let prompt = SchemaPromptText([.text("See "), .mention(note, label: "Groceries"), .text(" and "), .mention(card, label: "Address")])
        let names = SchemaReferenceNames(prompts: [prompt], schemas: [], name: { _ in nil }, isSchema: { $0 == card })
        expectEqual(names.list, "@Address")
        expectEqual(names.modelText(of: prompt).text, "See @Groceries and @Address")
    },
])

@MainActor let referenceSyncTests = Suite("Schema references synced", [
    test("a description that mentions a card has its schema point to it: the model reads the card as @ and a word, and its $ref to the word is the card's URI") {
        let b = try SyncBench()
        let address = b.add(addressSchema)
        let house = b.place()
        b.write(house, described("A house: its @, and how many bedrooms (required)", mentioning: address, as: "Address"))
        b.sync(house, answer: houseSchema("@Address"))
        let message = try require(b.message(0))
        expect(message.hasPrefix("<schemas>\n@Address\n</schemas>\n\n<prompt>\nA house: its @Address, and how many bedrooms (required)\n</prompt>"), message)
        expectEqual(b.card(house)?.schema.text, houseSchema(uri(address)))
        expectEqual(b.status(house), .idle)
        expect(b.sync.isInStep(house))
    },
    test("a $ref typed by hand has the description mention the card: the model's @ and word is a mention of it, named as the card is") {
        let b = try SyncBench()
        let address = b.add(addressSchema)
        let house = b.place()
        b.typeSchema(house, houseSchema(uri(address)))
        b.sync(house, answer: "A house with an @Address, and bedrooms (required).")
        let message = try require(b.message(0))
        expect(message.contains(#""$ref": "@Address""#), message)
        expect(message.hasPrefix("<schemas>\n@Address\n</schemas>"), message)
        expect(!message.contains("urn:uuid:"), "never an id")
        expectEqual(b.card(house)?.prompt.runs, [.text("A house with an "), .mention(address, label: "Address"), .text(", and bedrooms (required).")])
    },
    test("the model reads each card as it's called now: renamed since it was mentioned, a card with another's name, and one deleted, by the name its mention holds") {
        let b = try SyncBench()
        let address = b.add(addressSchema)
        let other = b.add(addressSchema.replacingOccurrences(of: "\"street\"", with: "\"line\""), at: CGPoint(x: 700, y: 0))
        let gone = ShapeID()
        let house = b.place()
        b.write(house, SchemaPromptText([.text("A house: its "), .mention(address, label: "Old name"), .text(", a "), .mention(other, label: "Address"),
                                         .text(" for mail, and a "), .mention(gone, label: "Garden"), .text(".")]))
        b.editor.transact { $0.update(address, as: SchemaCard.self) { $0.props.setTitle("Mailing Address") } }
        b.sync(house, answer: "NO_CHANGE")
        let message = try require(b.message(0))
        expect(message.contains("<schemas>\n@MailingAddress\n@Address\n@Garden\n</schemas>"), message)
        expect(message.contains("A house: its @MailingAddress, a @Address for mail, and a @Garden."), message)
    },
    test("a card on another board of the file is read as any other: its name, and its $ref") {
        let pocket = ShapeID(), address = ShapeID(), house = ShapeID()
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 600, y: 0, width: 100, height: 100)))),
                                                            AnyShapeRecord(ShapeRecord(id: house, SchemaCard(frame: CGRect(x: 0, y: 0, width: 240, height: 89))))]),
                              children: [pocket: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: address, SchemasTests.card(addressSchema)))])])
        let b = try SyncBench(file: file, more: [PocketsPlugin()])
        b.write(house, described("A house: its @", mentioning: address, as: "Address"))
        b.sync(house, answer: houseSchema("@Address"))
        expectEqual(b.card(house)?.schema.text, houseSchema(uri(address)))
        expectEqual(b.editor.mentions?.candidates(matching: "Addr", in: Only<SchemaCard>.self, for: house).matches.map(\.id), [address],
                    "the picker offers it, from inside its pocket")
    },
])

@MainActor let referenceShownTests = Suite("Schema references shown", [
    test("a card can be mentioned by its title, in its magenta; the picker offers only titled schema cards, the card itself among them; what mentions a card is listed") {
        let b = try SyncBench()
        let address = b.add(addressSchema)
        let untitled = b.add(#"{"type": "object", "properties": {"a": {"type": "string"}}}"#, at: CGPoint(x: 700, y: 0))
        let house = b.add(houseSchema(uri(address)), at: CGPoint(x: 0, y: 300))
        let appearance = try require(b.editor.registry.mentionAppearance(of: try require(b.editor.document[address])))
        expectEqual(appearance.label, "Address")
        expectEqual(appearance.systemImage, "curlybraces")
        let offered = try require(b.editor.mentions).candidates(matching: "", in: Only<SchemaCard>.self, for: house).all.map(\.id)
        expect(offered.contains(address), "\(offered)")
        expect(!offered.contains(untitled), "\(offered)")
        b.write(house, described("A house: its @", mentioning: address, as: "Address"))
        expect(b.editor.mentions?.isMentioned(address) == true)
        expectEqual(b.editor.mentions?.backlinks(of: address).map(\.id), [house])
    },
    test("the card draws its description's mentions as pills, live, inside its text; one fitted from properties is as tall as its text with them") {
        let b = try SyncBench()
        let address = b.add(addressSchema)
        let house = b.place()
        b.write(house, described("A house: its @, and how many bedrooms (required) it has, counted", mentioning: address, as: "Address"))
        let frame = try require(b.editor.document[house]?.box)
        let pills = b.editor.mentionPills(of: house)
        expectEqual(pills.map(\.target), [address])
        expectEqual(pills.map(\.isLive), [true])
        expect(frame.insetBy(dx: SchemaCardMetrics.padding - 0.5, dy: SchemaCardMetrics.padding - 0.5).contains(try require(pills.first).frame))
        let made = try b.editor.registry.shape(SchemaCard.kind, properties: [
            "frame": [[0, 0], [240, 52]], "prompt": .string(described("A house: its @, and how many bedrooms (required) it has, counted",
                                                                    mentioning: address, as: "Address").stored),
        ])
        expectEqual(made.box?.height, frame.height, "fitted, the pill measured by the name it holds")
    },
    test("a highlight on a mention is its pill: the model's words are found in the description as it read it, and the words after it are where they're drawn") {
        let b = try HighlightBench()
        let address = b.editor.add(SchemasTests.card(addressSchema, at: CGPoint(x: 500, y: 100)))
        b.answer = .success(ModelResponse(text: #"[{"text": "house", "pointer": ""}, {"text": "@Address", "pointer": "/properties/address"}, "#
                                            + #"{"text": "bedrooms", "pointer": "/properties/bedrooms"}, {"text": "required", "pointer": "/required"}]"#))
        var props = SchemaCard(frame: CGRect(x: 100, y: 100, width: 320, height: 52), schema: SchemaText(houseSchema(uri(address))))
        props.setPrompt(described("A house: its @, and how many bedrooms (required)", mentioning: address, as: "Address"))
        let house = b.editor.add(props)
        b.frame()
        b.settle()
        let asked = try require(b.asked.last?.messages.first?.text)
        expect(asked.contains("A house: its @Address, and how many bedrooms (required)"), asked)
        expect(asked.contains(#""$ref": "@Address""#), asked)
        let card = try require(b.card(house))
        let placed = SchemaHighlightAnswers.placed(for: card)
        expectEqual(placed.map(\.range), [NSRange(location: 2, length: 5), NSRange(location: 13, length: 1), NSRange(location: 29, length: 8),
                                          NSRange(location: 39, length: 8)])
        let lines = SchemaHighlightAnswers.lines(of: card) { b.editor.registry.mentionResolution(of: $0, lookup: { b.editor.shape(inFile: $0) }) }
        let pill = try require(b.editor.mentionPills(of: house).first).frame
        let line = try require(lines[1].first)
        expect(line.minX <= pill.minX + 0.5 && line.maxX >= pill.maxX - 0.5 && line.minY <= pill.minY && line.maxY >= pill.maxY,
               "the pill's highlight is around it: \(line) \(pill)")
    },
    test("resting the pointer on a mention's highlight shows the schema it refers to, the whole of it") {
        let b = try HighlightBench()
        let address = b.editor.add(SchemasTests.card(addressSchema, at: CGPoint(x: 500, y: 100)))
        b.answer = .success(ModelResponse(text: #"[{"text": "@Address", "pointer": "/properties/address"}]"#))
        var props = SchemaCard(frame: CGRect(x: 100, y: 100, width: 320, height: 52), schema: SchemaText(houseSchema(uri(address))))
        props.setPrompt(described("A house: its @, and bedrooms", mentioning: address, as: "Address"))
        let house = b.editor.add(props)
        b.frame()
        b.settle()
        let card = try require(b.card(house))
        let lines = SchemaHighlightAnswers.lines(of: card) { b.editor.registry.mentionResolution(of: $0, lookup: { b.editor.shape(inFile: $0) }) }
        let line = try require(lines.first?.first)
        b.move(to: CGPoint(x: line.midX, y: line.midY))
        expectEqual(b.popoverAfterDelay(), addressSchema)
    },
    test("a $ref's completions list the file's other titled cards by their names, each written as its URI; a card's own list leaves it out") {
        let b = try SyncBench()
        let address = b.add(addressSchema)
        let zone = b.add(#"{"title": "Zone", "type": "object", "properties": {}}"#, at: CGPoint(x: 700, y: 0))
        _ = b.add(#"{"type": "object"}"#, at: CGPoint(x: 1000, y: 0))
        let house = b.place()
        let targets = b.sync.referenceTargets(from: house)
        expectEqual(targets.map(\.label), ["Address", "Zone"])
        expectEqual(targets.map(\.json), ["\"\(uri(address))\"", "\"\(uri(zone))\""])
        expectEqual(targets.map(\.detail), ["2 fields", ""])
        expectEqual(b.sync.referenceTargets(from: address).map(\.label), ["Zone"])
        let text = #"{"properties": {"home": {"$ref": ""}}}"#
        let caret = (text as NSString).range(of: #""$ref": ""#).location + 9
        let listed = try require(SchemaCompletions.completions(in: text, at: caret) { targets })
        expectEqual(listed.items.map(\.label), ["#", "Address", "Zone"])
        expectEqual(listed.items.last?.insert, "\"\(uri(zone))\"", "the value, quotes and all, in place of the one there")
        var asked = 0
        _ = SchemaCompletions.completions(in: text, at: 1) { asked += 1; return targets }
        expectEqual(asked, 0, "asked only where a $ref's value goes")
    },
])

/// A card being edited: its editing view (a `MentionTextView`) in an unshown window, where the
/// canvas would put it, the keyboard in its text, beside a titled card, Address.
@MainActor
private final class EditedCard {
    let b: SyncBench
    let address: ShapeID
    let house: ShapeID
    let window: NSWindow
    let textView: MentionTextView<Only<SchemaCard>>

    init() throws {
        b = try SyncBench()
        address = b.add(addressSchema)
        house = b.place()
        b.editor.selection = house
        expect(b.editor.beginEditing(house))
        let view = try require(b.editor.makeEditingView())
        window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = FlippedView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
        window.contentView = canvas
        view.view.frame = CGRect(x: 100, y: 100, width: 240, height: 89)
        canvas.addSubview(view.view)
        textView = try require(view.firstResponder as? MentionTextView<Only<SchemaCard>>)
        window.makeFirstResponder(textView)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor let referenceEditorTests = Suite("Schema references typed", [
    test("@ in a card's description lists the other schema cards, and a pick is a mention of one, which the card's description holds") {
        let edited = try EditedCard()
        defer { edited.window.close() }
        edited.window.type("A house: its @Addr")
        expectEqual(edited.textView.picker?.rows.compactMap(\.candidate?.id), [edited.address])
        edited.window.pressReturn()
        expectEqual(edited.b.card(edited.house)?.prompt.runs, [.text("A house: its "), .mention(edited.address, label: "Address"), .text(" ")])
        edited.textView.onCommit?()
        expectEqual(edited.b.editor.editingShapeID, nil, "⌘↩'s commit ends editing")
        expectEqual(edited.b.editor.mentionPills(of: edited.house).map(\.target), [edited.address])
    },
    test("⌘↩ ends editing while the model writes the description, as Escape does: nothing's typed to commit") {
        let edited = try EditedCard()
        defer { edited.window.close() }
        edited.textView.isEditable = false
        pressReturn(edited.textView, .command)
        expectEqual(edited.b.editor.editingShapeID, nil)
    },
])
