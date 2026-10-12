import Automation
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Draw
import Foundation
import TestKit

// `canvas draw` with a property whose owner says how a value joins what a shape holds
// (`DrawValueWriters`): the statement writes only what it changes. These tests' property is a JSON
// object, `facts`, on tiles and links: a string `@Title` is written as `<id>` of the shape called so
// (the run's lookup, as a text format asks it), and a value joins what is held, member by member
// (a `null` member removing it), which a plugin of its own decides. No Types, no real kind.

/// A bag of facts by name.
struct Facts: Codable, Hashable, Sendable {
    var members: JSONObject
    init(_ members: JSONObject) { self.members = members }
    init(from decoder: any Decoder) throws { members = try decoder.singleValueContainer().decode(JSONObject.self) }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(members)
    }
}

extension Facts: SchemaDescribed {
    static func schema(in definitions: inout SchemaDefinitions) -> JSONObject { ["type": "object"] }
}

enum FactsProperty {}

extension FactsProperty: ShapeProperty {
    static let key: PropertyKey = "facts"
    static var defaultValue: Facts? { nil }
    static func isNone(_ value: Facts) -> Bool { value.members.isEmpty }
}

/// The merge a test's plugin gives `facts`: one level, `null` removing a member; nothing left is none.
func mergedFacts(_ written: JSONValue, _ held: JSONValue?) -> JSONValue {
    guard case .object(let members) = written else { return written }
    var result = held?.objectValue ?? [:]
    for (key, member) in members {
        if member == .null { result.removeValue(forKey: key) } else { result[key] = member }
    }
    return result.isEmpty ? .null : .object(result)
}

/// What each merge saw: the value as written and what the shape held.
@MainActor final class FactsLog {
    var merges: [(written: JSONValue, held: JSONValue?)] = []
}

/// `facts` on tiles and links, with a writer: `"@Title"` in a value becomes the shape's id.
@MainActor func factsPlugin(_ log: FactsLog = FactsLog(), writes: Bool = true) -> Contributor {
    Contributor(id: "facts") { registrar in
        registrar.declare(FactsProperty.self)
        registrar.optIn(Tile.self, to: FactsProperty.self)
        registrar.optIn(Link.self, to: FactsProperty.self)
        guard writes else { return }
        registrar.drawValueWriter(for: FactsProperty.key, write: { value, context throws(DrawError) in
            guard case .object(var members) = value else { return value }
            for (key, member) in members {
                guard case .string(let text) = member, text.hasPrefix("@") else { continue }
                let shape = try context.shape(called: String(text.dropFirst()))
                members[key] = .string("<\(shape.id)>")
            }
            return .object(members)
        }, merge: { written, held in
            log.merges.append((written, held))
            return mergedFacts(written, held)
        })
    }
}

@MainActor private func facts(_ title: String, in editor: CanvasEditor) -> JSONObject? {
    shape(title, in: editor)?[FactsProperty.self]?.members
}

@MainActor let drawValueWriterTests = Suite("draw: values a plugin joins", [
    test("a value joins what the shape holds: a statement sets what it names; null removes a member; a list or scalar replaces") {
        let editor = try drawEditor([factsPlugin()])
        _ = try drawn(#"tile "A" facts: {"x": 1, "y": 2}"#, on: editor)
        expectEqual(facts("A", in: editor), ["x": 1, "y": 2])
        let second = try drawn(#"tile "A" facts: {"y": 3, "z": 4}"#, on: editor)
        expectEqual(rows(second).map { $0["did"] }, ["updated"])
        expectEqual(facts("A", in: editor), ["x": 1, "y": 3, "z": 4], "x is kept")
        _ = try drawn(#"tile "A" facts: {"x": null}"#, on: editor)
        expectEqual(facts("A", in: editor), ["y": 3, "z": 4], "null removes the member")
        _ = try drawn(#"tile "A" facts: null"#, on: editor)
        expectEqual(facts("A", in: editor), nil, "null alone takes the whole property off")
        _ = try drawn(#"tile "A" facts: {"y": 1}"#, on: editor)
        _ = try drawn(#"tile "A" facts: {"y": 1}"# + "\n" + #"tile "B" facts: {"q": 1}"# + #" right of "A""#, on: editor)
        expectEqual(facts("B", in: editor), ["q": 1], "a new shape's is joined with nothing")
    },

    test("a script run again says unchanged, in a run and a dry run; one whose join comes to nothing over nothing is no change") {
        let editor = try drawEditor([factsPlugin()])
        _ = try drawn(#"tile "A" facts: {"x": 1}"#, on: editor)
        let again = try drawn(#"tile "A" facts: {"x": 1}"#, on: editor)
        expectEqual(rows(again).map { $0["did"] }, ["unchanged"])
        let dry = try drawn(#"tile "A" facts: {"x": 2}"#, on: editor, ["--dry-run"])
        expectEqual(rows(dry).map { $0["did"] }, ["updated"])
        expectEqual(facts("A", in: editor), ["x": 1], "a dry run writes nothing")
        // A removal of the last member leaves none; asked again, there is nothing to take.
        let removed = try drawn(#"tile "A" facts: {"x": null}"#, on: editor)
        expectEqual(rows(removed).map { $0["did"] }, ["updated"])
        expectEqual(facts("A", in: editor), nil)
        let twice = try drawn(#"tile "A" facts: {"x": null}"#, on: editor)
        expectEqual(rows(twice).map { $0["did"] }, ["unchanged"])
    },

    test("write gets the run's lookup, a shape drawn further down found, and merge gets what the shape holds, nil for a new one") {
        let log = FactsLog()
        let editor = try drawEditor([factsPlugin(log)])
        _ = try drawn("tile \"A\" facts: {\"with\": \"@B\"}\ntile \"B\" right of \"A\"", on: editor)
        let b = try require(shape("B", in: editor)).id
        expectEqual(facts("A", in: editor), ["with": .string("<\(b)>")])
        expectEqual(log.merges.count, 1)
        expect(try require(log.merges.first).held == nil, "a new shape holds nothing")
        _ = try drawn(#"tile "A" facts: {"n": 1}"#, on: editor)
        let last = try require(log.merges.last)
        expectEqual(last.held, .object(["with": .string("<\(b)>")]), "what the shape holds, as stored")
        expectEqual(last.written, .object(["n": 1]))
    },

    test("a refusal of the writer is said on the statement's line with the property's prefix, and nothing is drawn") {
        let editor = try drawEditor([factsPlugin()])
        let refusal = try refused("tile \"A\"\ntile \"B\" right of \"A\" facts: {\"with\": \"@Nobody\"}", on: editor)
        expectEqual(refusal.reason, "unknown_title")
        expect(refusal.message.hasPrefix(#""B": facts: "#), refusal.message)
        expectEqual(refusal.data?["line"], 2)
        expectEqual(editor.document.shapes.count, 0, "nothing was drawn")
    },

    test("an edge's value joins what the arrow it restates holds, written by the same writer") {
        let editor = try drawEditor([factsPlugin()])
        _ = try drawn("tile \"A\"\ntile \"B\" right of \"A\"\ntile \"C\" below \"A\"\nedge \"A\" -> \"B\" facts: {\"x\": 1, \"to\": \"@C\"}", on: editor)
        let c = try require(shape("C", in: editor)).id
        let link = try require(editor.document.shapes.first { $0.kind == Link.kind })
        expectEqual(link[FactsProperty.self]?.members, ["x": 1, "to": .string("<\(c)>")])
        let again = try drawn(#"edge "A" -> "B" facts: {"y": 2}"#, on: editor)
        expectEqual(rows(again).map { $0["did"] }, ["reconnected"], "an arrow restated with a change")
        expectEqual(try require(editor.document[link.id])[FactsProperty.self]?.members, ["x": 1, "to": .string("<\(c)>"), "y": 2])
        let same = try drawn(#"edge "A" -> "B" facts: {"y": 2}"#, on: editor)
        expectEqual(rows(same).map { $0["did"] }, ["unchanged"])
        _ = try drawn(#"edge "A" -> "B" facts: null"#, on: editor)
        expectEqual(try require(editor.document[link.id])[FactsProperty.self], nil)
    },

    test("without a writer a value replaces what the shape holds") {
        let editor = try drawEditor([factsPlugin(writes: false)])
        _ = try drawn(#"tile "A" facts: {"x": 1, "y": 2}"#, on: editor)
        _ = try drawn(#"tile "A" facts: {"y": 3}"#, on: editor)
        expectEqual(facts("A", in: editor), ["y": 3])
    },

    test("two plugins writing one property's values refuse the plugin list, and the report names the property") {
        let twice = { (id: PluginID) in Contributor(id: id) { $0.drawValueWriter(for: FactsProperty.key) { written, _ in written } } }
        expectThrows(RegistryError.conflict(point: "DrawValueWriters", key: "draw value facts", plugins: ["a", "b"])) {
            _ = try Registry(plugins: [DrawPlugin(), AutomationPlugin(), twice("a"), twice("b")])
        }
    },
])
