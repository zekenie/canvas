@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import Constraints
import CoreGraphics
import Foundation
import Queries
import TestKit
import Topology

// A list of constraints as boards keep it: read leniently (a member that isn't a constraint, has no words or comes
// twice is dropped, never the list; `reach` missing reads `children`; an empty query is words not interpreted),
// written in order with each member's keys sorted; a container's own as an added property the kinds that hold shapes
// or own a board opt into, the root's as a file value, and the fixtures that hold both.

private func decoded(_ json: String) throws -> ConstraintList {
    try JSONDecoder().decode(ConstraintList.self, from: Data(json.utf8))
}

@MainActor let codecTests = Suite("Constraints: the codec, the property and the file value", [
    test("a list reads leniently: a member with no words, one that isn't a constraint and one met before are dropped, never the list") {
        let list = try decoded("""
            [{"says": "only tasks", "query": ":is-a(\\"Task\\")", "reach": "children"},
             {"query": "tile"},
             {"says": "   "},
             {"says": "no bugs", "reach": "everywhere"},
             17,
             {"says": "only  tasks", "query": " :is-a(\\"Task\\") "},
             {"says": "anything inside", "query": "tile", "reach": "descendants"}]
            """)
        expectEqual(list.constraints, [Constraint(says: "only tasks", query: #":is-a("Task")"#),
                                       Constraint(says: "anything inside", query: "tile", reach: .descendants)])
    },
    test("reach missing reads children; a missing or empty query is words not interpreted; words are one line") {
        let list = try decoded(#"[{"says": "only\n tiles"}, {"says": "no discs", "query": "  "}]"#)
        expectEqual(list.constraints.map(\.says), ["only tiles", "no discs"])
        expectEqual(list.constraints.map(\.reach), [.children, .children])
        expectEqual(list.constraints.map(\.query), [nil, nil])
        expectEqual(list.constraints.map(\.isInterpreted), [false, false])
        expect(!(try decoded("[]")).constraints.contains(where: \.isInterpreted))
    },
    test("a list is written in order, each member's keys sorted, a query left out while there is none") {
        let list = ConstraintList([Constraint(says: "only tiles", query: "tile", reach: .descendants), Constraint(says: "no discs")])
        let json = try JSONValue(encoding: list)
        expectEqual(json.compactText, #"[{"query":"tile","reach":"descendants","says":"only tiles"},{"reach":"children","says":"no discs"}]"#)
        let again = try JSONDecoder().decode(ConstraintList.self, from: try JSONEncoder().encode(list))
        expectEqual(again, list)
    },
    test("a list as text a person reads in a schema is the codec's value: every member round-trips, its layout fixed, the one writer of the members") {
        let task = ShapeID(), other = ShapeID()
        let list = ConstraintList([
            Constraint(says: "only tasks", query: #":is-a("Task")"#),
            Constraint(says: "no bugs / chores", query: #":not(:is-a("Bug", "Chore")[title*="a\\b"])"#, reach: .descendants, names: ["Bug": other, "Task": task]),
            Constraint(says: "café, said \"so\"", query: nil),
            Constraint(says: "titled", query: "[title]", reach: .children, names: ["Zed": other]),
        ])
        let text = list.jsonText
        expectEqual(try JSONDecoder().decode(ConstraintList.self, from: Data(text.utf8)), list, "every member: words, query, reach, names")
        expect(!text.contains("\\/"), "slashes as they are: \(text)")
        expect(text.hasPrefix(#"[{"says": "only tasks", "query": ":is-a(\"Task\")", "reach": "children"}, {"says": "no bugs / chores", "query": "#), "the layout: \(text)")
        expect(text.contains(#""names": {"Bug": "\#(other)", "Task": "\#(task)"}"#), "names' keys sorted: \(text)")
        expect(text.contains(#"{"says": "café, said \"so\"", "reach": "children"}"#), "a query left out while there is none: \(text)")
        // The codec reads what it writes, member for member: the same keys, the same values.
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(list)) as? [[String: Any]]
        let written = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]]
        expectEqual(written?.map { NSDictionary(dictionary: $0) }, encoded?.map { NSDictionary(dictionary: $0) }, "the codec's JSON and the text, one value")
        expectEqual(ConstraintList().jsonText, "[]")
    },
    test("a corral's own list is an added property, unlisted, which a commit writes and an undo takes back") {
        let h = try constraintHarness()
        let registry = h.editor.registry
        expect(registry.isConstrainable(Corral.kind) && registry.isConstrainable(Pocket.kind))
        expect(!registry.isConstrainable(Tile.kind), "a tile holds no shapes")
        let schema = try require(registry.schema(for: Corral.kind)?.json["properties"]?["constraints"])
        expectEqual(schema["x-canvas-unlisted"], true)
        let pen = h.corral("Pen", CGRect(x: 100, y: 100, width: 400, height: 300))
        expectEqual(h.editor.document[pen]?.ownConstraints, [])
        h.editor.transact("Constrain") { $0.update(pen) { $0[ConstraintsProperty.self] = [onlyTiles] } }
        expectEqual(h.editor.document[pen]?.ownConstraints, [onlyTiles])
        h.editor.transact { $0.update(pen) { $0[ConstraintsProperty.self] = ConstraintList() } }
        expectEqual(h.editor.document[pen]?[ConstraintsProperty.self], nil, "an empty list is none")
        h.editor.undo()
        expectEqual(h.editor.document[pen]?.ownConstraints, [onlyTiles])
    },
    test("the root's list is a file value, none until set, read through the file") {
        let h = try constraintHarness()
        expectEqual(h.file[RootConstraintsProperty.self], ConstraintList())
        h.editor.transact("Constrain") { $0.setFileValue(RootConstraintsProperty.self, to: [noDiscs]) }
        expectEqual(h.file[RootConstraintsProperty.self].constraints, [noDiscs])
        expect(h.file.fileValueKeys.contains(RootConstraintsProperty.key))
    },
    test("only a kind that holds shapes or owns a board can opt in: the registry refuses another, and its report names those that did") {
        let refusing = Contributor(id: "constrained-boxes") { $0.constrainable(Box.self) }
        do {
            _ = try Registry(plugins: [FixturesPlugin(), CorralsPlugin(), TopologyPlugin(), QueriesPlugin(), ConstraintsPlugin(), refusing])
            expect(false, "a box is refused")
        } catch let error as RegistryError {
            expect("\(error)".contains("box holds no shapes and owns no board"), "\(error)")
        }
        let h = try constraintHarness()
        let report = h.editor.registry.report
        expect(report.contains("constrainable → corral") && report.contains("constrainable → pocket"), report)
    },
    test("the fixtures: an added property's value and the file's at every version, today's written back byte for byte") {
        let h = try constraintHarness()
        expectPropertyFixtures([ConstraintsProperty.key], in: h.editor.registry, directory: "Tests/CompositionTests/Fixtures/added")
        expectFilePropertyFixtures([RootConstraintsProperty.key], in: h.editor.registry, directory: "Tests/CompositionTests/Fixtures/file")
    },
])
