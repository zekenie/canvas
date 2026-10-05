import Automation
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import Queries
import TestKit
import Topology

// What a schema says of a property, as `canvas draw` reads it: `readOnly` is no attribute a script
// writes, and a string with the format `x-canvas-query` is checked by the query engine, when the app
// has one. A fixture kind, a slip, holds one of each beside plain text; no real kind is named.

/// A box with a text, a memo no script writes, and a query.
struct Slip: BoxShapeProps {
    static let kind: ShapeKind = "slip"
    static let properties = Properties<Slip>(title: "Slip") {
        Property("frame", \.frame).required()
        Property("text", \.text)
        Property("memo", \.memo).readOnly()
        Property("query", \.query).maxLength(200).format("x-canvas-query")
        Property("lens", \.lens).format("x-canvas-query")
        Property("seal", \.seal).readOnly()
    }
    var frame: CGRect
    var text = ""
    var memo = ""
    var query = ""
    /// An optional query, as a kind that may have none holds it, and an optional memo.
    var lens: String?
    var seal: String?

    init(_ frame: CGRect) { self.frame = frame }
}

extension Slip {
    init() { self.init(.zero) }
}

struct SlipDefinition {}

extension SlipDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Slip>, in context: RenderContext) {}
}

let slips = Contributor(id: "slips") { registrar in
    registrar.shape(SlipDefinition()) { slip in
        slip.tool(label: "Slip", systemImage: "square", placing: slip.placement(size: CGSize(width: 100, height: 60)) { Slip() })
    }
}

/// An editor with the slip, and the query engine unless not.
@MainActor private func slipEditor(queries: Bool = true) throws -> CanvasEditor {
    try drawEditor([slips] + (queries ? [TopologyPlugin(), QueriesPlugin()] : []))
}

/// The slip on the board.
@MainActor private func slip(in editor: CanvasEditor) -> ShapeRecord<Slip>? {
    editor.document.shapes.compactMap { $0.typed(as: Slip.self) }.first
}

@MainActor let drawAttributeTests = Suite("draw: what a schema says of an attribute", [
    test("a readOnly property isn't an attribute: canvas kinds leaves it out, and writing it is unknown_attribute") {
        let editor = try slipEditor()
        let kinds = try run(["kinds"], on: editor).get().arrayValue ?? []
        let attributes = try require(kinds.first { $0["kind"] == "slip" }?["attributes"]?.objectValue)
        expectEqual(attributes.keys.sorted(), ["lens", "query", "text"])
        let error = try refused(#"slip memo: "from a script""#, on: editor)
        expectEqual(error.reason, "unknown_attribute")
        expectEqual(editor.document.shapes.count, 0, "nothing drawn")
        let ok = try drawn(#"slip text: "fine""#, on: editor)
        expectEqual(rows(ok).map { $0["did"] }, ["created"])
        expectEqual(slip(in: editor)?.props.text, "fine")
    },
    test("a string with format x-canvas-query is checked by the engine: a bad one is invalid_value with its message and hint, and draws nothing") {
        let editor = try slipEditor()
        let error = try refused(#"slip query: "note[""#, on: editor)
        expectEqual(error.reason, "invalid_value")
        expect(error.message.contains("query: "), error.message)
        expect(error.message.contains("isn't closed"), "the engine's message: \(error.message)")
        expectEqual(editor.document.shapes.count, 0, "nothing drawn")
        let unknown = try refused(#"slip query: "nothing-like-this""#, on: editor)
        expectEqual(unknown.reason, "invalid_value", "a word the language doesn't have")
        expect(unknown.hint != nil, "the engine's hint")
        let ok = try drawn(#"slip query: "slip""#, on: editor)
        expectEqual(rows(ok).map { $0["did"] }, ["created"])
        expectEqual(slip(in: editor)?.props.query, "slip")
        // An optional text holds a query as a plain one does, and an optional readOnly is no attribute.
        let optional = try refused(#"slip lens: "note[""#, on: editor)
        expectEqual(optional.reason, "invalid_value")
        expect(optional.message.contains("lens: "), optional.message)
        expectEqual(try refused(#"slip seal: "x""#, on: editor).reason, "unknown_attribute")
        let lens = try drawn(#"slip lens: "slip""#, on: editor)
        expectEqual(rows(lens).map { $0["did"] }, ["created"])
        expectEqual(editor.document.shapes.compactMap { $0.typed(as: Slip.self) }.last?.props.lens, "slip")
        // Text with no such format isn't read as a query.
        let plain = try drawn(#"slip text: "note[""#, on: editor)
        expectEqual(rows(plain).count, 1)
    },
    test("without the query engine, the value isn't checked") {
        let editor = try slipEditor(queries: false)
        let result = try drawn(#"slip query: "note[""#, on: editor)
        expectEqual(rows(result).map { $0["did"] }, ["created"])
        expectEqual(slip(in: editor)?.props.query, "note[")
    },
])
