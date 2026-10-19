import Canvas
import CanvasTesting
import ContextMenus
import CoreGraphics
import Selection
import TestKit
import Transform

// Turn into … in the context menu: where it shows and what it's called, and choosing it: the shape
// under its own id as the other kind, what it held moved onto its board, one undo step.

/// A group of the canvas's, after Transform's.
private enum PastingGroup {}
extension PastingGroup: MenuGroup {
    static var order: Int { 100 }
}

/// A corral K that holds a box A and a corral L holding a box B, a box C beside it, a link between A and
/// B and one from A to C, and a box Z far off.
private struct Sprint {
    let z = ShapeID(), k = ShapeID(), a = ShapeID(), l = ShapeID(), b = ShapeID(), c = ShapeID(), i = ShapeID(), o = ShapeID()

    var file: CanvasFile {
        CanvasFile(root: board(box(z, x: 900), corral(k, CGRect(x: 100, y: 100, width: 400, height: 300)), box(a, x: 120, y: 120, in: k),
                               corral(l, CGRect(x: 200, y: 200, width: 200, height: 150), in: k), box(b, x: 220, y: 220, in: l),
                               box(c, x: 600), link(i, a, b), link(o, a, c)))
    }

    /// Where K shows, not under A or L.
    let click = CGPoint(x: 450, y: 380)
}

@MainActor let transformMenuTests = Suite("Turning from the context menu", [
    test("a corral's menu has Turn into Pocket, in a group of its own after the shape's items and before the rest; choosing it turns the corral and everything it held, in one undo step") {
        let s = Sprint()
        let h = try transformHarness([plugin("around") { r in
            r.forEveryShape { $0.contextMenu { MenuItem("Widen") { $0.box?.size.width += 10 } } }
            r.contextMenuForCanvas { MenuItem("Paste Here", in: PastingGroup.self) { _, _ in } }
        }], file: s.file)
        h.editor.transact { $0.update(s.k) { $0[Tagline.self] = "Sprint" } }
        let before = h.file
        let menu = try require(h.secondaryClick(at: s.click))
        expectEqual(menu.outline, ["Widen", "—", "Turn into Pocket", "—", "Paste Here", "—", "Delete"])
        expectEqual(h.editor.selectedShapeIDs, [s.k], "the right-click selected it")
        try menu.choose("Turn into Pocket")

        let pocket = try require(h.file.record(s.k))
        expectEqual(pocket.kind, Pocket.kind, "under its own id")
        expectEqual(pocket.box, CGRect(x: 100, y: 100, width: pocketSize.width, height: pocketSize.height), "a pocket's size at the corral's corner")
        expectEqual(pocket[Tagline.self], "Sprint", "its tagline, which both kinds hold")
        expectEqual(ids(h.editor.document), [s.z, s.k, s.c, s.o], "what it held is off this board; the rest stays, the pocket where the corral was")
        expectEqual(ids(h.contents(of: s.k)), [s.a, s.l, s.b, s.i], "on its board, in the order they were, where they were")
        expectEqual(h.contents(of: s.k).shapes.map(\.container), [nil, nil, s.l, nil], "the corral inside is still one, holding its box")
        expectEqual(h.file.record(s.b)?.box, before.record(s.b)?.box)
        expectEqual(h.props(s.i, as: Link.self), Link(from: s.a, to: s.b), "a link between what moved rode along")
        expectEqual(h.props(s.o, as: Link.self), Link(from: nil, to: s.c), "one to a shape that stays let go of its end")
        expectEqual(h.editor.selectedShapeIDs, [s.k], "still selected")
        expectEqual(h.editor.undoHistory.undoName, "Turn into Pocket")
        let after = h.file

        h.editor.undo()
        try expectFile(h, before, "the corral, and everything in it")
        expectEqual(h.editor.document[s.k]?.kind, Corral.kind)
        expectEqual(h.editor.holder(of: s.b), s.l)
        h.editor.redo()
        try expectFile(h, after, "and the pocket again")
        expect(h.enter(s.k), "it opens onto the board it holds")
        expectEqual(ids(h.editor.document), [s.a, s.l, s.b, s.i])
    },

    test("corrals selected together turn together, innermost first, in one step: the pocket the inner one made goes onto the outer one's board") {
        let z = ShapeID(), o = ShapeID(), a = ShapeID(), i = ShapeID(), b = ShapeID(), c = ShapeID()
        let file = CanvasFile(root: board(box(z, x: 900), corral(o, CGRect(x: 0, y: 0, width: 600, height: 400)), box(a, x: 20, y: 20, in: o),
                                          corral(i, CGRect(x: 100, y: 100, width: 300, height: 200), in: o), box(b, x: 120, y: 120, in: i),
                                          box(c, x: 200, y: 120, in: i)))
        let h = try transformHarness(file: file)
        let before = h.file
        h.editor.selectedShapeIDs = [o, i]
        let menu = try require(h.secondaryClick(at: CGPoint(x: 500, y: 350)))
        expectEqual(menu.outline, ["Turn into Pocket", "—", "Delete"])
        try menu.choose("Turn into Pocket")
        expectEqual(ids(h.editor.document), [z, o])
        expectEqual(ids(h.contents(of: o)), [a, i])
        expectEqual(ids(h.contents(of: i)), [b, c])
        expectEqual(h.file.record(o)?.kind, Pocket.kind)
        expectEqual(h.file.record(i)?.kind, Pocket.kind)
        expectEqual(h.file.record(i)?.box, CGRect(x: 100, y: 100, width: pocketSize.width, height: pocketSize.height), "where it was")
        expectEqual(h.file.path(to: BoardID(owner: i)), [.root, BoardID(owner: o), BoardID(owner: i)], "its board went with it")
        expectEqual(h.contents(of: o).shapes.map(\.container), [nil, nil], "the pocket isn't in the pocket it moved onto")
        expectEqual(h.editor.undoHistory.undoName, "Turn into Pocket")
        let after = h.file

        h.editor.undo()
        try expectFile(h, before, "both corrals, and everything in them: one step")
        h.editor.redo()
        try expectFile(h, after, "both pockets")

        // The order they're given in changes nothing: the deepest turns first.
        for order in [[o, i], [i, o]] {
            let again = try transformHarness(file: file)
            expect(again.editor.transforms?.turn(order, into: Pocket.kind) == true)
            expectEqual(ids(again.editor.document), [z, o])
            expectEqual(ids(again.contents(of: o)), [a, i], "\(order)")
            expectEqual(ids(again.contents(of: i)), [b, c], "\(order)")
        }
    },

    test("the item shows only when every shape of the menu can turn into the kind: not with a box among them, nor a pocket, and not for a box or a pocket alone") {
        let k = ShapeID(), a = ShapeID(), p = ShapeID(), l = ShapeID()
        let h = try transformHarness(file: CanvasFile(root: board(corral(k, CGRect(x: 0, y: 0, width: 150, height: 100)), box(a, x: 200),
                                                                  corral(l, CGRect(x: 400, y: 0, width: 150, height: 100)))))
        h.editor.transact { $0.insert(AnyShapeRecord(ShapeRecord(id: p, Pocket(CGRect(x: 600, y: 0, width: 100, height: 100))))) }
        expectEqual(try require(h.secondaryClick(at: CGPoint(x: 75, y: 50))).outline, ["Turn into Pocket", "—", "Delete"])
        h.editor.selectedShapeIDs = [k, l]
        expectEqual(try require(h.secondaryClick(at: CGPoint(x: 75, y: 50))).outline, ["Turn into Pocket", "—", "Delete"], "two corrals")
        h.editor.selectedShapeIDs = [k, a]
        expectEqual(try require(h.secondaryClick(at: CGPoint(x: 75, y: 50))).outline, ["Delete"], "a corral and a box")
        h.editor.selectedShapeIDs = [k, p]
        expectEqual(try require(h.secondaryClick(at: CGPoint(x: 75, y: 50))).outline, ["Delete"], "a corral and a pocket")
        expectEqual(try require(h.secondaryClick(at: CGPoint(x: 220, y: 15))).outline, ["Delete"], "a box")
        expectEqual(try require(h.secondaryClick(at: CGPoint(x: 650, y: 50))).outline, ["Delete"], "a pocket: nothing for it to turn into")
        expectEqual(try require(h.secondaryClick(at: CGPoint(x: 300, y: 300))).outline, ["Select All"], "empty canvas")
    },

    test("the item is called for what the target's schema is titled, else its id, unless the target says otherwise; one item for each kind a shape turns into") {
        let h = try EditorHarness(plugins: transformBase() + [ChoresPlugin(), plugin("labels") { r in
            r.turnable(Box.self, through: LooseChannel.self)
            r.turnable(into: Chore.self, through: LooseChannel.self) { _, _ in }
            r.turnable(into: Tag.self, through: LooseChannel.self) { _, _ in }
            r.turnable(into: Pocket.self, through: LooseChannel.self, label: "Cell") { _, _ in }
        }])
        h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let menu = try require(h.secondaryClick(at: CGPoint(x: 50, y: 50)))
        expectEqual(menu.outline, ["Turn into Chore", "Turn into tag", "Turn into Cell", "—", "Delete"],
                    "the chore's schema is titled Chore, though its kind is called a Task; the tag's is untitled; a label is taken as it's given")
    },

    test("a target whose source says no leaves the shape as it was: the item shows, choosing it changes nothing and makes no step") {
        let h = try transformHarness([boxesTurnIntoDiscs()])
        let narrow = h.add(Box(CGRect(x: 0, y: 0, width: 50, height: 50)))
        let wide = h.add(Box(CGRect(x: 200, y: 0, width: 150, height: 50)))
        let before = h.file
        var menu = try require(h.secondaryClick(at: CGPoint(x: 275, y: 25)))
        expectEqual(menu.outline, ["Turn into Disc", "—", "Delete"])
        let revision = h.editor.revision
        try menu.choose("Turn into Disc")
        expectEqual(h.file, before)
        expectEqual(h.editor.revision, revision, "nothing committed")
        menu = try require(h.secondaryClick(at: CGPoint(x: 25, y: 25)))
        try menu.choose("Turn into Disc")
        expectEqual(h.editor.document[narrow]?.kind, Disc.kind, "the box that has a source turns, on its own frame")
        expectEqual(h.editor.document[narrow]?.box, CGRect(x: 0, y: 0, width: 50, height: 50))
        expectEqual(h.editor.document[wide]?.kind, Box.kind)
        expectEqual(h.editor.undoHistory.undoName, "Turn into Disc")
        h.editor.undo()
        try expectFile(h, before, "the box again")
    },
])
