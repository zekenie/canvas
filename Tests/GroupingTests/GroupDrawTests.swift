@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Draw
import Foundation
import Grouping
import Selection
import TestKit

// `canvas draw`'s `group` and `ungroup`, through Draw's entry points (`draw(script:…)`), as Grouping's plugin value
// `GroupDrawPlugin` writes them: the groups of the shapes a statement names, as the app's Group writes them (a group is its
// shapes' `groups`, outermost first), but flat, and judged by `BoardGroups`' counting, never by what a shape holds: an id no
// group needs any more is no group. Titles are the fixture's (a tile is called by its label): Grouping doesn't know Titles.

/// Names tiles by their labels, and a script may make one.
let tileNames = Contributor(id: "tile-names") { registrar in
    let fold: @Sendable (String) -> String? = { title in
        let folded = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return folded.isEmpty ? nil : folded
    }
    registrar.drawNames(name: { record, _ in record.typed(as: Tile.self).flatMap { fold($0.props.label) } },
                        namingProperty: { kind, _ in kind == Tile.kind ? "label" : nil },
                        isDerived: { _, _ in false }, fold: fold)
}

/// An editor with Grouping and what draws groups, the draw engine, tiles and their names, and `more`; tiles A, B, C, D and E
/// in a row on its board, 100 apart.
@MainActor func drawingHarness(_ more: [any CanvasPlugin] = []) throws -> (h: EditorHarness, ids: [String: ShapeID]) {
    let h = try groupingHarness([DrawPlugin(), TilesPlugin(), tileNames, GroupDrawPlugin()] + more)
    h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
    var ids: [String: ShapeID] = [:]
    for (index, label) in ["A", "B", "C", "D", "E"].enumerated() {
        ids[label] = h.add(Tile(CGRect(x: CGFloat(index) * 200, y: 0, width: 100, height: 60), label: label))
    }
    return (h, ids)
}

/// What a draw says, as the wire carries it.
@MainActor func drawn(_ script: String, in h: EditorHarness, dryRun: Bool = false) throws -> JSON {
    try JSON(encoding: draw(script: script, dryRun: dryRun, reveal: false, program: "canvas", in: h.editor))
}

/// Why a draw is refused: its error's reason, message and hint.
@MainActor func refused(_ script: String, in h: EditorHarness) throws -> DrawError {
    do throws(DrawError) {
        _ = try draw(script: script, dryRun: false, reveal: false, program: "canvas", in: h.editor)
    } catch {
        return error
    }
    throw Unexpected()
}

struct Unexpected: Error {}

/// What the rows of a result say a statement did.
func dids(_ result: JSON) -> [String] { (result["changes"]?.arrayValue ?? []).compactMap { $0["did"]?.stringValue } }

/// The groups a shape holds, as it stores them.
@MainActor func stored(_ id: ShapeID?, in h: EditorHarness) -> [String]? { id.flatMap { h.editor.document[$0]?[GroupsProperty.self] } }

/// The groups a shape is in that count, outermost first.
@MainActor func counting(_ id: ShapeID?, in h: EditorHarness) -> [String] { id.map { h.editor.boardGroups.path(of: $0) } ?? [] }

@MainActor let groupDrawTests = Suite("Grouping: canvas draw's group and ungroup", [
    test("group puts exactly the shapes it names in one group of their own, flat; its row says grouped, and the registry reports the plugin") {
        let (h, id) = try drawingHarness()
        expect(h.editor.registry.report.contains("group-draw"), h.editor.registry.report)
        expect(h.editor.registry.report.contains("draw groups"), h.editor.registry.report)
        let result = try drawn(#"group "A" and "B""#, in: h)
        expectEqual(result["changes"], [["line": 1, "did": "grouped", "shapes": ["A", "B"]]])
        let group = try require(stored(id["A"], in: h))
        expectEqual(group.count, 1, "one group")
        expectEqual(stored(id["B"], in: h), group, "the same one")
        expectEqual(stored(id["C"], in: h), nil)
        expectEqual(counting(id["A"], in: h), group)
        expectEqual(h.editor.boardGroups.shapes[group[0]], [id["A"], id["B"]].compactMap { $0 }, "the group is its shapes, back to front")
        expectEqual(h.editor.undoHistory.undoName, "Draw")
        // Selected as one in the app, as the plugin's Group writes them.
        h.click(at: CGPoint(x: 450, y: 30))
        h.click(at: CGPoint(x: 50, y: 30))
        expectEqual(h.editor.selectedShapeIDs, [id["A"], id["B"]].compactMap { $0 }, "a click on one selects both")
    },
    test("a shape leaves the groups it was in: the others stay a group when two parts remain, and are not one when one is left") {
        let (h, id) = try drawingHarness()
        _ = try drawn(#"group "A" and "B" and "C""#, in: h)
        let first = try require(stored(id["A"], in: h))
        _ = try drawn(#"group "A" and "D""#, in: h)
        let second = try require(stored(id["A"], in: h))
        expect(second != first, "a new group")
        expectEqual(stored(id["A"], in: h)?.count, 1, "flat: A holds just the new one, not the old as well")
        expectEqual(stored(id["D"], in: h), second)
        expectEqual(counting(id["B"], in: h), first, "B and C are still a group")
        expectEqual(counting(id["C"], in: h), first)
        expectEqual(h.editor.boardGroups.shapes[first[0]], [id["B"], id["C"]].compactMap { $0 })
        // Another leaves: one is left, which is no group, though it still holds the id.
        _ = try drawn(#"group "B" and "E""#, in: h)
        expectEqual(counting(id["C"], in: h), [], "C alone is in no group")
        expectEqual(stored(id["C"], in: h), first, "it still holds the id of the group it was in: nothing wrote it")
        expectEqual(h.editor.boardGroups.shapes[first[0]], nil)
    },
    test("a group inside groups is made flat: the shapes named leave every group they were in, the inner and the outer") {
        let (h, id) = try drawingHarness()
        let a = try require(id["A"]), b = try require(id["B"]), c = try require(id["C"])
        expect(h.editor.group([a, b]))
        expect(h.editor.group([a, b, c]))
        expectEqual(counting(a, in: h).count, 2, "A is in a group in a group")
        expectEqual(counting(c, in: h).count, 1)
        let result = try drawn(#"group "A" and "B""#, in: h)
        expectEqual(dids(result), ["grouped"])
        expectEqual(stored(a, in: h)?.count, 1, "flat")
        expectEqual(stored(a, in: h), stored(b, in: h))
        expectEqual(counting(c, in: h), [], "C is left alone in the outer group: no group")
        expectEqual(h.editor.boardGroups.shapes.count, 1, "the one group, A and B")
        // All three, made flat over the nest that is left.
        _ = try drawn(#"group "A" and "B" and "C""#, in: h)
        expectEqual(counting(a, in: h).count, 1)
        expectEqual(counting(a, in: h), counting(c, in: h))
        expectEqual(h.editor.boardGroups.shapes.count, 1)
    },
    test("shapes that already are one group, alone, are unchanged: nothing is written, whatever order they are named in, and no step opens; more or fewer do change it") {
        let (h, id) = try drawingHarness()
        _ = try drawn(#"group "A" and "B" and "C""#, in: h)
        let document = h.editor.document
        var events: [UndoEvent] = []
        h.editor.undoHistory.didChange = { events.append($0) }
        let again = try drawn(#"group "C" and "A" and "B""#, in: h)
        expectEqual(again["changes"], [["line": 1, "did": "unchanged", "shapes": ["C", "A", "B"]]])
        expectEqual(h.editor.document, document)
        expectEqual(events, [], "no step")
        let fewer = try drawn(#"group "A" and "B""#, in: h)
        expectEqual(dids(fewer), ["grouped"], "two of three are a group of their own")
        expectEqual(counting(id["C"], in: h), [])
        let more = try drawn(#"group "A" and "B" and "D""#, in: h)
        expectEqual(dids(more), ["grouped"])
        expect(!events.isEmpty, "steps")
    },
    test("ungroup leaves each shape in no group, at every level: its groups cleared; the others stay a group while two parts remain") {
        let (h, id) = try drawingHarness()
        let b = try require(id["B"]), c = try require(id["C"]), d = try require(id["D"])
        _ = try drawn(#"group "A" and "B" and "C""#, in: h)
        let group = try require(stored(id["A"], in: h))
        let result = try drawn(#"ungroup "A""#, in: h)
        expectEqual(result["changes"], [["line": 1, "did": "ungrouped", "shapes": ["A"]]])
        expectEqual(stored(id["A"], in: h), nil, "cleared")
        expectEqual(counting(b, in: h), group, "B and C stay a group")
        expectEqual(counting(c, in: h), group)
        // B and C, a group, and D with them: B is in a group in a group.
        expect(h.editor.group([b, c, d]))
        expectEqual(counting(b, in: h).count, 2)
        let nested = try drawn(#"ungroup "B""#, in: h)
        expectEqual(dids(nested), ["ungrouped"])
        expectEqual(stored(b, in: h), nil, "out of both")
        expectEqual(counting(c, in: h).count, 1, "C and D are still a group, outside the one that held B and C")
        expectEqual(counting(c, in: h), counting(d, in: h))
        // Several at once, one of them in none.
        let several = try drawn(#"ungroup "C" and "D" and "E""#, in: h)
        expectEqual(several["changes"], [["line": 1, "did": "ungrouped", "shapes": ["C", "D", "E"]]])
        expectEqual(h.editor.boardGroups.shapes.count, 0)
        expectEqual([stored(c, in: h), stored(d, in: h), stored(id["E"], in: h)], [nil, nil, nil])
    },
    test("a stale id is no group: ungrouping a shape that holds one, or grouping it, is judged by the groups that count") {
        let (h, id) = try drawingHarness()
        let b = try require(id["B"]), c = try require(id["C"])
        // B holds an id of a group nobody else is in: no group.
        h.editor.transact { $0.update(b) { $0[GroupsProperty.self] = ["stale"] } }
        expectEqual(counting(b, in: h), [])
        let document = h.editor.document
        var events: [UndoEvent] = []
        h.editor.undoHistory.didChange = { events.append($0) }
        let ungrouped = try drawn(#"ungroup "B""#, in: h)
        expectEqual(dids(ungrouped), ["unchanged"], "in no group that counts: nothing to take it out of")
        expectEqual(h.editor.document, document)
        expectEqual(stored(b, in: h), ["stale"], "and nothing is written")
        expectEqual(events, [])
        // Grouped, it leaves the stale id with the rest.
        let grouped = try drawn(#"group "B" and "C""#, in: h)
        expectEqual(dids(grouped), ["grouped"])
        expectEqual(stored(b, in: h)?.count, 1)
        expectEqual(stored(b, in: h), stored(c, in: h))
        expect(stored(b, in: h) != ["stale"])
        // Two shapes that hold one group and a stale id are that group alone: grouped again, unchanged.
        let group = try require(stored(b, in: h)?.first)
        h.editor.transact {
            $0.update(b) { $0[GroupsProperty.self] = ["old", group] }
            $0.update(c) { $0[GroupsProperty.self] = [group] }
        }
        expectEqual(counting(b, in: h), [group])
        expectEqual(dids(try drawn(#"group "B" and "C""#, in: h)), ["unchanged"])
        expectEqual(stored(b, in: h), ["old", group], "left as it is")
    },
    test("shapes the same script draws can be named, and a run with groups is one undo step: Draw") {
        let (h, id) = try drawingHarness()
        let before = h.editor.document
        let result = try drawn("""
            tile "F" right of "E"
            group "F" and "E" and "A"
            ungroup "B"
            """, in: h)
        expectEqual(dids(result), ["created", "grouped", "unchanged"])
        let f = try require(h.editor.document.shapes.first { $0.typed(as: Tile.self)?.props.label == "F" }?.id)
        let group = try require(stored(f, in: h))
        expectEqual(stored(id["E"], in: h), group)
        expectEqual(stored(id["A"], in: h), group)
        expectEqual(h.editor.undoHistory.undoName, "Draw")
        h.editor.undo()
        expectEqual(h.editor.document, before)
        h.editor.redo()
        expectEqual(stored(f, in: h), group)
    },
    test("a dry run says the same rows and writes nothing") {
        let (h, id) = try drawingHarness()
        let before = h.editor.document, step = h.editor.undoHistory.undoName
        let dry = try drawn(#"group "A" and "B""#, in: h, dryRun: true)
        expectEqual(dry["dryRun"], true)
        expectEqual(dids(dry), ["grouped"])
        expectEqual(h.editor.document, before)
        expectEqual(stored(id["A"], in: h), nil)
        expectEqual(h.editor.undoHistory.undoName, step)
    },
    test("a read-only shape among them: read_only, nothing is grouped and no step opens; a statement that writes nothing goes through") {
        let (h, id) = try drawingHarness([FreezingPlugin()])
        let a = try require(id["A"]), b = try require(id["B"])
        h.editor.freeze([b])
        let before = h.editor.document, step = h.editor.undoHistory.undoName
        let error = try refused(#"group "A" and "B""#, in: h)
        expectEqual(error.reason, "read_only")
        expectEqual(error.message, #""B" is read-only (locked, say), so it can't be grouped"#)
        expectEqual(error.line, 1)
        expectEqual(h.editor.document, before)
        expectEqual(h.editor.undoHistory.undoName, step)
        expectEqual(stored(a, in: h), nil)
        expectEqual(dids(try drawn(#"ungroup "B" and "A""#, in: h)), ["unchanged"], "in no group: nothing to write")
        h.editor.freeze([b], false)
        _ = try drawn(#"group "A" and "B""#, in: h)
        h.editor.freeze([b])
        expectEqual(try refused(#"ungroup "B""#, in: h).message, #""B" is read-only (locked, say), so it can't be ungrouped"#)
        expectEqual(dids(try drawn(#"group "B" and "A""#, in: h)), ["unchanged"], "already as asked")
    },
    test("an agent groups shapes only through the statements: groups is no attribute of any kind, listed nowhere") {
        let (h, id) = try drawingHarness()
        let error = try refused(#"tile "A" groups: ["made-up"]"#, in: h)
        expectEqual(error.reason, "unknown_attribute")
        expectEqual(stored(id["A"], in: h), nil, "nothing was written")
        let kind = try require(try JSON(encoding: kinds(named: Tile.kind.rawValue, in: h.editor.registry)).arrayValue?.first)
        expectEqual(kind["attributes"]?["groups"], nil)
    },
    test("without Grouping's plugin value, a script with either statement is no_groups") {
        let h = try groupingHarness([DrawPlugin(), TilesPlugin(), tileNames])
        h.add(Tile(CGRect(x: 0, y: 0, width: 100, height: 60), label: "A"))
        let error = try refused(#"group "A" and "B""#, in: h)
        expectEqual(error.reason, "no_groups")
        expectEqual(try refused(#"ungroup "A""#, in: h).reason, "no_groups")
    },
])
