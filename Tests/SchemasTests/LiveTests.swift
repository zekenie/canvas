import Canvas
import CoreGraphics
import Foundation
import LanguageModels
import Mentions
import Schemas
import TestKit

// Three syncs against Claude itself, through the app's path (`AnthropicModel`, with the key Settings
// saves, and `SchemaSync`'s requests, parse and writes), printing what came back. Only with
// SCHEMA_LIVE=1, which test.sh never sets: no other test reaches the network.

@MainActor let liveTests = Suite("Schema sync, live", [
    test("with SCHEMA_LIVE=1: a vague prompt, a precise one, and a hand edit back to the prompt") {
        guard ProcessInfo.processInfo.environment["SCHEMA_LIVE"] == "1" else { return }
        expect(AnthropicKeyStore.standard.hasKey, "no key: add one in Settings")
        let editor = try schemaEditor(model: AnthropicModel())
        let sync = try require(editor.schemaSync)

        /// Commits the card and waits (up to a minute) for the model's answer to land.
        @MainActor func commit(_ id: ShapeID, _ what: String) -> SchemaCard? {
            let started = Date()
            sync.commit(id)
            spinRunLoop(until: { if case .updating = sync.status(of: id) { false } else { true } }, timeout: 60)
            let card = editor.schemaCard(id)
            print("── \(what) (\(Int(Date().timeIntervalSince(started) * 1000)) ms, \(sync.status(of: id)))")
            expectEqual(sync.status(of: id), .idle, what)
            return card
        }

        @MainActor func place(_ prompt: String) -> ShapeID {
            let id = editor.add(SchemaCard(frame: CGRect(x: 0, y: 0, width: 240, height: 89)))
            editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.setPrompt(SchemaPromptText(plain: prompt)) } }
            return id
        }

        let pet = place("a pet in my household")
        let petCard = try require(commit(pet, "“a pet in my household” → schema"))
        print(petCard.schema)
        expect(petCard.schema.text != SchemaCard.starter)

        let contact = place("email required, phone required, description")
        let contactCard = try require(commit(contact, "“email required, phone required, description” → schema"))
        print(contactCard.schema)
        let root = try JSONReader.read(contactCard.schema.text)
        expectEqual(root["required"]?.elements?.compactMap(\.string).sorted(), ["email", "phone"])

        // By hand: phone optional, and a company.
        let required = try require(root["required"]), last = try require(root["properties"]?.members?.last)
        guard required.range.lowerBound > last.value.range.upperBound else { return expect(false, "required before properties") }
        var edited = Array(contactCard.schema.text.utf8)      // the later edit first, so the earlier range holds
        edited.replaceSubrange(required.range, with: Array(#"["email"]"#.utf8))
        edited.replaceSubrange(last.value.range.upperBound..<last.value.range.upperBound,
                               with: Array(",\n    \"company\": {\n      \"type\": \"string\"\n    }".utf8))
        let handEdited = String(decoding: edited, as: UTF8.self)
        editor.transact { $0.update(contact, as: SchemaCard.self) { $0.props.schema.text = handEdited } }
        print("── the schema edited by hand\n\(handEdited)")
        let described = try require(commit(contact, "the hand edit → description"))
        print(described.prompt)
        expect(described.prompt.stored.lowercased().contains("company"))
        expect(!described.prompt.stored.lowercased().contains("phone required"), "phone is optional now")
        expectEqual(described.schema.text, handEdited)
    },
    test("with SCHEMA_LIVE=1: a description that mentions another card, and a $ref to it written back as a mention") {
        guard ProcessInfo.processInfo.environment["SCHEMA_LIVE"] == "1" else { return }
        expect(AnthropicKeyStore.standard.hasKey, "no key: add one in Settings")
        let editor = try schemaEditor(model: AnthropicModel())
        let sync = try require(editor.schemaSync)
        @MainActor func commit(_ id: ShapeID, _ what: String) -> SchemaCard? {
            let started = Date()
            sync.commit(id)
            spinRunLoop(until: { if case .updating = sync.status(of: id) { false } else { true } }, timeout: 60)
            print("── \(what) (\(Int(Date().timeIntervalSince(started) * 1000)) ms, \(sync.status(of: id)))")
            expectEqual(sync.status(of: id), .idle, what)
            return editor.schemaCard(id)
        }
        let address = editor.add(SchemasTests.card(addressSchema, at: CGPoint(x: 400, y: 0)))
        let house = editor.add(SchemaCard(frame: CGRect(x: 0, y: 0, width: 240, height: 89)))
        editor.transact { $0.update(house, as: SchemaCard.self) {
            $0.props.setPrompt(SchemaPromptText([.text("A house: its "), .mention(address, label: "Address"), .text(", and how many bedrooms (required)")]))
        } }
        let written = try require(commit(house, "“A house: its @Address, and how many bedrooms (required)” → schema"))
        print(written.schema)
        expectEqual(SchemaReferences.refs(in: written.schema.text).map(\.card), [address], "the mention is a $ref to the card")

        // A second card referred to by hand: the description names it.
        let room = editor.add(SchemasTests.card(#"{"title": "Room", "type": "object", "properties": {"name": {"type": "string"}}}"#, at: CGPoint(x: 700, y: 0)))
        let root = try JSONReader.read(written.schema.text)
        let last = try require(root["properties"]?.members?.last)
        var edited = Array(written.schema.text.utf8)
        edited.replaceSubrange(last.value.range.upperBound..<last.value.range.upperBound,
                               with: Array(",\n    \"rooms\": {\n      \"type\": \"array\",\n      \"items\": { \"$ref\": \"\(SchemaReferences.uri(of: room))\" }\n    }".utf8))
        editor.transact { $0.update(house, as: SchemaCard.self) { $0.props.schema.text = String(decoding: edited, as: UTF8.self) } }
        let described = try require(commit(house, "a $ref to Room by hand → description"))
        print(described.prompt)
        expectEqual(described.prompt.mentioned, [address, room], "each card a mention")
    },
])
