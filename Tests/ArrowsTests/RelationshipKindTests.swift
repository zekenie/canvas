import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import DetailPanel
import Foundation
import TestKit
import Types

// The arrow is a relating kind (`relating()`, beside `typeable()`): the arrows between types and a relationship
// type are its ends, whatever heads they have. Types knows no arrow; this is the one place the two meet.

@MainActor let endsKindTests = Suite("An arrow relates", [
    test("the arrow holds endRule, so it relates; a box and a type's gloss do not; the registry says so") {
        let h = try EditorHarness(plugins: arrowsPlugins(more: [PortsPlugin(), ArrowPortsPlugin(), DetailPanelPlugin(), LabelFixturesPlugin()]))
        let registry = h.editor.registry
        expect(registry.relates(Arrow.kind))
        expect(!registry.relates(Box.kind) && !registry.relates(Gloss.kind))
        expect(registry.canBeRelationshipType(Gloss.kind) && !registry.canBeRelationshipType(Arrow.kind))
        expect(registry.report.contains("property endRule → arrow"), registry.report)
        expect(registry.properties(for: Arrow.kind).contains(IsAProperty.key) && registry.properties(for: Arrow.kind).contains(FieldValuesProperty.key))
    },
    test("an arrow from a type into a relationship type is an end, and out of it too, whatever its heads; between two types it is plain whatever its heads") {
        let h = try EditorHarness(plugins: arrowsPlugins(more: [PortsPlugin(), ArrowPortsPlugin(), DetailPanelPlugin(), LabelFixturesPlugin()]))
        let editor = h.editor
        let person = editor.addType("Person", at: CGRect(x: 0, y: 0, width: 200, height: 60))
        let company = editor.addType("Company", at: CGRect(x: 0, y: 200, width: 200, height: 60))
        let employment = editor.addType("Employment", at: CGRect(x: 400, y: 100, width: 200, height: 60))
        editor.transact { $0.update(employment) { $0[RelationshipProperty.self] = true } }
        @MainActor func arrow(_ from: ShapeID, _ to: ShapeID, start: Bool, end: Bool) -> ShapeID {
            func bound(_ id: ShapeID) -> ArrowTerminal {
                .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
            }
            return h.add(Arrow(start: bound(from), end: bound(to), startArrowhead: start, endArrowhead: end))
        }
        let relationships = try require(editor.relationships)
        var ends: [ShapeID] = []
        for (start, end) in [(false, true), (true, true), (true, false), (false, false)] {
            let into = arrow(person, employment, start: start, end: end), out = arrow(employment, company, start: start, end: end)
            expectEqual(relationships.end(into)?.side, .from, "heads \(start) \(end)")
            expectEqual(relationships.end(out)?.side, .to, "heads \(start) \(end)")
            ends += [into, out]
        }
        let sides = relationships.graph.sides(of: employment)
        expectEqual(sides.from.count, 4)
        expectEqual(sides.to.count, 4)
        for (start, end) in [(false, true), (true, true), (true, false), (false, false)] {
            let between = arrow(person, company, start: start, end: end)
            expect(relationships.end(between) == nil, "two types: a plain arrow, heads \(start) \(end)")
        }
        expectEqual(relationships.graph.sides(of: employment), sides, "no plain arrow changed an end")
        // A type related to itself is two arrows, one head each; a two-headed arrow is read from its start to its end.
        let friends = editor.addType("Friends", at: CGRect(x: 400, y: 300, width: 200, height: 60))
        editor.transact { $0.update(friends) { $0[RelationshipProperty.self] = true } }
        let there = arrow(person, friends, start: true, end: true), back = arrow(friends, person, start: false, end: true)
        expectEqual(relationships.end(there)?.side, .from, "read start to end")
        expectEqual(relationships.end(back)?.side, .to)
        // The role of two end records is the same whatever the arrow's heads.
        let records = [person, friends].compactMap { editor.document[$0] }
        expectEqual(ArrowRole.of(from: records[0], to: records[1], registry: editor.registry), .end(type: friends, side: .from))
    },
])
