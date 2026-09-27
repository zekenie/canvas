import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import LanguageModels
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
            editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.prompt = prompt } }
            return id
        }

        let pet = place("a pet in my household")
        let petCard = try require(commit(pet, "“a pet in my household” → schema"))
        print(petCard.schema)
        expect(petCard.schema != SchemaCard.starter)

        let contact = place("email required, phone required, description")
        let contactCard = try require(commit(contact, "“email required, phone required, description” → schema"))
        print(contactCard.schema)
        let root = try JSONReader.read(contactCard.schema)
        expectEqual(root["required"]?.elements?.compactMap(\.string).sorted(), ["email", "phone"])

        // By hand: phone optional, and a company.
        let required = try require(root["required"]), last = try require(root["properties"]?.members?.last)
        guard required.range.lowerBound > last.value.range.upperBound else { return expect(false, "required before properties") }
        var edited = Array(contactCard.schema.utf8)      // the later edit first, so the earlier range holds
        edited.replaceSubrange(required.range, with: Array(#"["email"]"#.utf8))
        edited.replaceSubrange(last.value.range.upperBound..<last.value.range.upperBound,
                               with: Array(",\n    \"company\": {\n      \"type\": \"string\"\n    }".utf8))
        let handEdited = String(decoding: edited, as: UTF8.self)
        editor.transact { $0.update(contact, as: SchemaCard.self) { $0.props.setSchema(handEdited) } }
        print("── the schema edited by hand\n\(handEdited)")
        let described = try require(commit(contact, "the hand edit → description"))
        print(described.prompt)
        expect(described.prompt.lowercased().contains("company"))
        expect(!described.prompt.lowercased().contains("phone required"), "phone is optional now")
        expectEqual(described.schema, handEdited)
    },
])
