import Canvas
import CoreGraphics
import Foundation
import LanguageModels
import Mentions
import TestKit
import Types

// Three syncs against Claude itself, through the app's path (`AnthropicModel`, with the key Settings
// saves, and `TypeSync`'s requests, parse and writes), printing what came back. Only with
// SCHEMA_LIVE=1, which test.sh never sets: no other test reaches the network.

@MainActor let liveTests = Suite("Type sync, live", [
    test("with SCHEMA_LIVE=1: vague words, precise ones, and a hand edit back to the words; an untitled type named by the model") {
        guard ProcessInfo.processInfo.environment["SCHEMA_LIVE"] == "1" else { return }
        expect(AnthropicKeyStore.standard.hasKey, "no key: add one in Settings")
        let editor = try typeEditor(model: AnthropicModel())
        let sync = try require(editor.typeSync)

        /// Commits the type and waits (up to a minute) for the model's answer to land.
        @MainActor func commit(_ id: ShapeID, _ what: String) {
            let started = Date()
            sync.commit(id)
            spinRunLoop(until: { if case .updating = sync.status(of: id) { false } else { true } }, timeout: 60)
            print("── \(what) (\(Int(Date().timeIntervalSince(started) * 1000)) ms, \(sync.status(of: id)))")
            expectEqual(sync.status(of: id), .idle, what)
        }

        @MainActor func place(_ words: String) -> ShapeID {
            editor.addType(TypeSchemaProperty.starter, words: words, at: .zero)
        }

        let pet = place("a pet in my household")
        commit(pet, "“a pet in my household” → schema")
        let petSchema = try require(editor.schema(pet))
        print("\(editor.title(pet) ?? "untitled"): \(petSchema)")
        expect(petSchema != TypeSchemaProperty.starter)
        expect(editor.title(pet) != nil, "named by the model")

        let contact = place("email required, phone required, description")
        commit(contact, "“email required, phone required, description” → schema")
        let contactSchema = try require(editor.schema(contact))
        print(contactSchema)
        let root = try JSONReader.read(contactSchema)
        expectEqual(root["required"]?.elements?.compactMap(\.string).sorted(), ["email", "phone"])

        // By hand: phone optional, and a company.
        let required = try require(root["required"]), last = try require(root["properties"]?.members?.last)
        guard required.range.lowerBound > last.value.range.upperBound else { return expect(false, "required before properties") }
        var edited = Array(contactSchema.utf8)      // the later edit first, so the earlier range holds
        edited.replaceSubrange(required.range, with: Array(#"["email"]"#.utf8))
        edited.replaceSubrange(last.value.range.upperBound..<last.value.range.upperBound,
                               with: Array(",\n    \"company\": {\n      \"type\": \"string\"\n    }".utf8))
        let handEdited = String(decoding: edited, as: UTF8.self)
        editor.transact { $0.update(contact) { $0[TypeSchemaProperty.self] = SchemaText(handEdited) } }
        print("── the schema edited by hand\n\(handEdited)")
        commit(contact, "the hand edit → words")
        let described = try require(editor.words(contact))
        print(described)
        expect(described.stored.lowercased().contains("company"))
        expect(!described.stored.lowercased().contains("phone required"), "phone is optional now")
        expectEqual(editor.schema(contact), handEdited)
    },
    test("with SCHEMA_LIVE=1: words that mention another type, and a $ref to it written back as a mention") {
        guard ProcessInfo.processInfo.environment["SCHEMA_LIVE"] == "1" else { return }
        expect(AnthropicKeyStore.standard.hasKey, "no key: add one in Settings")
        let editor = try typeEditor(model: AnthropicModel())
        let sync = try require(editor.typeSync)
        @MainActor func commit(_ id: ShapeID, _ what: String) {
            let started = Date()
            sync.commit(id)
            spinRunLoop(until: { if case .updating = sync.status(of: id) { false } else { true } }, timeout: 60)
            print("── \(what) (\(Int(Date().timeIntervalSince(started) * 1000)) ms, \(sync.status(of: id)))")
            expectEqual(sync.status(of: id), .idle, what)
        }
        let address = editor.addType(addressSchema, title: "Address", at: CGPoint(x: 400, y: 0))
        let house = editor.addType(TypeSchemaProperty.starter, at: .zero)
        editor.transact { $0.update(house, as: Memo.self) {
            $0.props.text = MentionText([.text("A house: its "), .mention(address, label: "Address"), .text(", and how many bedrooms (required)")])
        } }
        commit(house, "“A house: its @Address, and how many bedrooms (required)” → schema")
        let written = try require(editor.schema(house))
        print(written)
        expectEqual(SchemaReferences.refs(in: written).map(\.shape), [address], "the mention is a $ref to the type")

        // A second type referred to by hand: the words name it.
        let room = editor.addType(#"{"type": "object", "properties": {"name": {"type": "string"}}}"#, title: "Room", at: CGPoint(x: 700, y: 0))
        let root = try JSONReader.read(written)
        let last = try require(root["properties"]?.members?.last)
        var edited = Array(written.utf8)
        edited.replaceSubrange(last.value.range.upperBound..<last.value.range.upperBound,
                               with: Array(",\n    \"rooms\": {\n      \"type\": \"array\",\n      \"items\": { \"$ref\": \"\(SchemaReferences.uri(of: room))\" }\n    }".utf8))
        editor.transact { $0.update(house) { $0[TypeSchemaProperty.self] = SchemaText(String(decoding: edited, as: UTF8.self)) } }
        commit(house, "a $ref to Room by hand → words")
        let described = try require(editor.words(house))
        print(described)
        expectEqual(described.mentioned, [address, room], "each type a mention")
    },
])
