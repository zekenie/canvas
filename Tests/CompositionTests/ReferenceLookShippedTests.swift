import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import Foundation
import Geometry
import LanguageModels
import Queries
import References
import ShippedTesting
import StickyNotes
import TestKit

// What agents write and read of a reference's look: `look:` and `scale:` on a reference drawn by its query, read
// back by `canvas query` as attribute selectors; a direct pill takes them only through a query naming its shape.

@MainActor private func lookBoard(_ pasteboard: NSPasteboard) -> EditorHarness {
    EditorHarness { _ in ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: TaskScheduler(), pasteboard: pasteboard, model: ScriptedLanguageModel()) }
}

@MainActor private func references(_ h: EditorHarness) -> [ShapeRecord<Reference>] {
    h.editor.document.shapes.compactMap { $0.typed(as: Reference.self) }
}

@MainActor private func matches(_ query: String, on h: EditorHarness) throws -> [ShapeID] {
    let queries = try require(h.editor.queries)
    return try awaitResult { try await queries.run(QueryRequest(query, settle: QueryBudget.settleWait)) }.rows.map(\.id)
}

@MainActor let referenceLookShippedTests = Suite("Reference look, drawn and read", [
    test("a dynamic reference drawn with look: mirror and scale: keeps both, and a query finds it by them") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = lookBoard(pasteboard)
        _ = try drawnInProcess(#"sticky-note "Auth" text: "JWT""#, on: h.editor)
        let made = try drawnInProcess(#"reference right of "Auth" query: "sticky-note" look: mirror scale: 0.5"#, on: h.editor)
        let pill = try require(references(h).first)
        expectEqual(pill.props.look, .mirror)
        expectEqual(pill.props.scale, 0.5)
        expectEqual(made["changes"]?.arrayValue?.first?["id"], .string(pill.id.description))
        let plain = try drawnInProcess(#"reference right of "Auth" query: "sticky-note" all: true"#, on: h.editor)
        _ = plain
        expectEqual(references(h).count, 2)
        expectEqual(try matches(#"reference[look="mirror"]"#, on: h), [pill.id], "the mirror alone")
        expectEqual(try matches(#"reference[look="pill"]"#, on: h).count, 1)
        expectEqual(try matches("reference[scale<0.6]", on: h), [pill.id], "the other, at 1, isn't under 0.6")
        expectEqual(try matches("reference[scale>0.9]", on: h).count, 1)
        // Restated by its id: the scale changes, and it goes back to a pill.
        let restated = try drawnInProcess("reference #\(pill.id) scale: 2 look: pill", on: h.editor)
        expectEqual(restated["changes"]?.arrayValue?.first?["did"], "updated")
        expectEqual(h.editor.document[pill.id]?.typed(as: Reference.self)?.props.look, .pill)
        expectEqual(h.editor.document[pill.id]?.typed(as: Reference.self)?.props.scale, 2)
    },
    test("a direct pill an edge made takes no look by its id or on its edge; a query naming its shape draws a mirror of it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = lookBoard(pasteboard)
        _ = try drawnInProcess("""
        sticky-note "Auth" text: "JWT"
        sticky-note "Checkout" below "Auth"
        """, on: h.editor)
        _ = try drawnInProcess(#"edge "Checkout" -> "Auth" via: reference"#, on: h.editor)
        let direct = try require(references(h).first)
        expect(direct.props.target != nil, "a direct pill")
        expectEqual(try refusedInProcess("reference #\(direct.id) look: mirror", on: h.editor).reason, "invalid_value", "named by its shape, never its id")
        expectEqual(try refusedInProcess(#"edge "Checkout" -> "Auth" via: reference look: mirror"#, on: h.editor).reason, "unknown_attribute")
        expectEqual(direct.props.look, .pill)
        // The way in: a query that finds the one shape, by its id.
        let auth = try require(direct.props.target?.id)
        _ = try drawnInProcess("reference right of \"Checkout\" query: \"#\(auth)\" look: mirror scale: 0.75", on: h.editor)
        let mirror = try require(references(h).first { $0.props.look == .mirror })
        expectEqual(mirror.props.scale, 0.75)
        expectEqual(mirror.props.target, nil, "dynamic: it finds the shape by its query")
        expectEqual(try matches(#"reference[look="mirror"]"#, on: h), [mirror.id])
    },
    test("a look that is not pill or mirror is refused with draw's message; a scale past its bounds is drawn and warned about, as any bound is") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = lookBoard(pasteboard)
        let banana = try refusedInProcess(#"reference query: "sticky-note" look: banana"#, on: h.editor)
        expectEqual(banana.reason, "invalid_value", "\(banana)")
        expect(banana.message.contains("mirror") && banana.message.contains("pill"), "says what it takes: \(banana.message)")
        expect(references(h).isEmpty, "nothing was drawn")
        for scale in ["0.05", "4.5"] {
            let drawn = try drawnInProcess(#"reference query: "sticky-note" look: mirror scale: \#(scale)"#, on: h.editor)
            let warnings = drawn["warnings"]?.arrayValue ?? []
            expect(!warnings.isEmpty, "scale \(scale) says it's out of range: \(drawn)")
            _ = try drawnInProcess("delete #\(try require(references(h).first).id)", on: h.editor)
        }
        // A scale that isn't a number is refused.
        expectEqual(try refusedInProcess(#"reference query: "sticky-note" look: mirror scale: big"#, on: h.editor).reason, "invalid_value")
    },
])
