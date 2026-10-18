@_spi(Host) import Canvas
import CanvasTesting
import ContextMenus
import CoreGraphics
import Grouping
import Keyboard
import Selection
import TestKit

/// An editor with keys, the selection, the fixtures, menus and Grouping, and `more`.
@MainActor func groupingHarness(_ more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), ContextMenusPlugin(), GroupingPlugin()] + more)
}

/// Three 100-point boxes in a row, 100 apart, their middles at x 50, 250 and 450.
@MainActor func threeBoxes(_ h: EditorHarness) -> (ShapeID, ShapeID, ShapeID) {
    (h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100))),
     h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100))),
     h.add(Box(CGRect(x: 400, y: 0, width: 100, height: 100))))
}

let first = CGPoint(x: 50, y: 50), second = CGPoint(x: 250, y: 50), third = CGPoint(x: 450, y: 50)

@MainActor let groupingTests = Suite("Grouping", [
    test("every kind holds the groups it's in, an added property no language lists") {
        let h = try groupingHarness()
        expect(h.editor.registry.properties(for: Box.kind).contains(GroupsProperty.key))
        let schema = KindSchema(try require(h.editor.registry.schema(for: Box.kind)))
        expect(schema.isUnlisted(GroupsProperty.key.rawValue))
        expect(h.editor.registry.report.contains("property groups → every shape"))
    },
    test("⌥⌘G groups the selection in one step, \"Group\", and a click then selects the group; undone, they're apart; redone, a group") {
        let h = try groupingHarness()
        let (a, b, c) = threeBoxes(h)
        h.editor.selectedShapeIDs = [a, b]
        h.hold([.command, .option])
        expect(h.key("g"))
        h.hold([])
        h.wait(200)                                  // a key let go in the last 150 ms still counts
        expectEqual(h.editor.undoHistory.undoName, "Group")
        let path = try require(h.editor.document[a]?[GroupsProperty.self])
        expectEqual(path.count, 1)
        expectEqual(h.editor.document[b]?[GroupsProperty.self], path)
        expectEqual(h.editor.document[c]?[GroupsProperty.self], nil)
        expectEqual(h.editor.selectedShapeIDs, [a, b], "still selected, as the group they are")
        h.click(at: third)
        h.click(at: first)
        expectEqual(h.editor.selectedShapeIDs, [a, b])
        h.editor.undo()
        h.click(at: third)
        h.click(at: first)
        expectEqual(h.editor.selectedShapeIDs, [a])
        h.editor.redo()
        h.click(at: third)
        h.click(at: first)
        expectEqual(h.editor.selectedShapeIDs, [a, b])
    },
    test("⇧⌥⌘G ungroups a group selected, a level; the keys pass while they can't run") {
        let h = try groupingHarness()
        let (a, b, c) = threeBoxes(h)
        @MainActor func chord(_ modifiers: Modifiers) -> Bool {
            h.hold(modifiers)
            defer {
                h.hold([])
                h.wait(200)                              // a key let go in the last 150 ms still counts
            }
            return h.key("g")
        }
        h.editor.selectedShapeIDs = [a]
        expect(!chord([.command, .option]), "one shape: nothing to group")
        h.editor.selectedShapeIDs = [a, b]
        expect(chord([.command, .option]))
        h.editor.selectedShapeIDs = [a, b, c]
        expect(chord([.command, .option]), "the group with c: a group in a group")
        h.click(at: CGPoint(x: 250, y: 300))
        h.click(at: first)
        expectEqual(h.editor.selectedShapeIDs, [a, b, c], "the outer group, whole")
        expect(chord([.command, .option, .shift]))
        expectEqual(h.editor.undoHistory.undoName, "Ungroup")
        h.click(at: third)
        expectEqual(h.editor.selectedShapeIDs, [c], "out of the outer group")
        h.click(at: first)
        expectEqual(h.editor.selectedShapeIDs, [a, b], "the inner one stays")
        expect(chord([.command, .option, .shift]))
        h.editor.selectedShapeIDs = [a]
        expect(!chord([.command, .option, .shift]), "no group to take apart")
        expectEqual(h.editor.document[a]?[GroupsProperty.self], nil)
    },
    test("the context menu offers Group for two or more, Ungroup for a group, both for a group and a shape, neither for a lone shape") {
        let h = try groupingHarness()
        let (a, b, c) = threeBoxes(h)
        h.editor.selectedShapeIDs = [a, b]
        let menu = try require(h.secondaryClick(at: first))
        expectEqual(menu.outline, ["Group", "—", "Delete"])
        try menu.choose("Group")
        expectEqual(h.editor.undoHistory.undoName, "Group")
        h.click(at: third)
        expectEqual(try require(h.secondaryClick(at: first)).outline, ["Ungroup", "—", "Delete"], "a right-click selects the group whole")
        expectEqual(h.editor.selectedShapeIDs, [a, b])
        h.hold(.shift)
        h.click(at: third)
        h.hold([])
        h.wait(200)
        expectEqual(try require(h.secondaryClick(at: third)).outline, ["Group", "Ungroup", "—", "Delete"])
        h.click(at: CGPoint(x: 450, y: 300))
        expectEqual(try require(h.secondaryClick(at: third)).outline, ["Delete"])
        try require(h.secondaryClick(at: first)).choose("Ungroup")
        expectEqual(h.editor.document[a]?[GroupsProperty.self], nil)
        expectEqual(h.editor.document[c]?[GroupsProperty.self], nil)
    },
    test("a read-only shape among them: nothing is grouped, no step, and it shakes") {
        let h = try groupingHarness([FreezingPlugin()])
        let (a, b, _) = threeBoxes(h)
        h.editor.freeze([b])
        let steps = h.editor.undoHistory.undoName
        expect(!h.editor.group([a, b]))
        expectEqual(h.editor.document[a]?[GroupsProperty.self], nil)
        expectEqual(h.editor.undoHistory.undoName, steps)
        h.wait(16)
        expect(h.editor.drawingOffset(of: b) != .zero, "it shakes")
        h.editor.freeze([b], false)
        expect(h.editor.group([a, b]))
        h.editor.freeze([a])
        expect(!h.editor.ungroup([a, b]))
        expect(h.editor.document[b]?[GroupsProperty.self] != nil)
    },
    test("a shape deleted from a group of two leaves the other in none: a click selects it alone, and nothing ungroups it") {
        let h = try groupingHarness()
        let (a, b, _) = threeBoxes(h)
        h.editor.group([a, b])
        h.editor.transact { $0.delete([b]) }
        h.click(at: third)
        h.click(at: first)
        expectEqual(h.editor.selectedShapeIDs, [a])
        expect(!h.editor.canUngroup([a]))
        expect(!h.editor.canGroup([a]))
    },
    test("Group and Ungroup wait while something's under way") {
        let h = try groupingHarness()
        let (a, b, _) = threeBoxes(h)
        h.editor.selectedShapeIDs = [a, b]
        expect(h.editor.canPerform(.group))
        h.press(at: CGPoint(x: 150, y: 300))
        h.drag(to: CGPoint(x: 160, y: 320))
        expect(!h.editor.canPerform(.group), "a marquee under way")
        h.release()
    },
    test("groups follow the board shown: another board's are its own, and coming back finds them") {
        let boards = GroupingPockets()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), ContextMenusPlugin(), PocketsPlugin(),
                                            GroupingPlugin()], file: boards.file)
        expect(h.editor.group([boards.a, boards.p]))
        expect(h.enter(boards.p))
        expectEqual(h.editor.boardGroups.shapes.count, 0, "nothing grouped on P's board")
        expect(h.editor.group([boards.b, boards.q]))
        expectEqual(h.editor.selectionUnit(of: boards.b), [boards.b, boards.q])
        let scanned = h.editor.boardsScannedForGroups
        expect(h.editor.showBoard(.root))
        expectEqual(h.editor.selectionUnit(of: boards.a), [boards.a, boards.p])
        expectEqual(h.editor.boardsScannedForGroups, scanned, "kept, not looked for again")
    },
])

/// A root holding box A and pocket P, and P's board box B and pocket Q.
struct GroupingPockets {
    let a = ShapeID(), p = ShapeID(), b = ShapeID(), q = ShapeID()

    var file: CanvasFile {
        func record<P: ShapeProps>(_ id: ShapeID, _ props: P) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, props)) }
        return CanvasFile(root: CanvasDocument(shapes: [record(a, Box(CGRect(x: 0, y: 0, width: 100, height: 100))),
                                                        record(p, Pocket(CGRect(x: 200, y: 0, width: 100, height: 100)))]),
                          children: [p: CanvasDocument(shapes: [record(b, Box(CGRect(x: 0, y: 0, width: 100, height: 100))),
                                                                record(q, Pocket(CGRect(x: 200, y: 0, width: 100, height: 100)))])])
    }
}
