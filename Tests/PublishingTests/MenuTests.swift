@_spi(Host) import Canvas
import CanvasTesting
import ContextMenus
import CoreGraphics
import Publishing
import Selection
import TestKit

// Make Public and Make Private in the context menu, one item for the menu's shapes as a lock's:
// Make Public while any of them is private, else Make Private, so a shape as it starts offers Make
// Private.

private let spot = CGPoint(x: 150, y: 150)

@MainActor let menuTests = Suite("Publishing from the context menu", [
    test("a shape's menu offers Make Private, then Make Public, after every other group and before Delete; a private shape is `private: true`, and going public takes it away") {
        let h = try publishingHarness([Contributor(id: "widening") { r in
            r.forEveryShape { $0.contextMenu { MenuItem("Widen") { $0.box?.size.width += 10 } } }
        }])
        let plaque = h.add(Plaque(plaqueFrame))
        let menu = try require(h.secondaryClick(at: spot))
        expectEqual(menu.outline, ["Widen", "—", "Make Private", "—", "Delete"], "public, as every shape starts")
        try menu.choose("Make Private")
        expectEqual(h.editor.document[plaque]?[PrivateProperty.self], true)
        expectEqual(h.editor.undoHistory.undoName, "Make Private")
        expectEqual(h.editor.selectedShapeIDs, [plaque], "still selected")
        expectEqual(try require(h.secondaryClick(at: spot)).outline, ["Widen", "—", "Make Public", "—", "Delete"])
        try require(h.secondaryClick(at: spot)).choose("Make Public")
        expectEqual(h.editor.document[plaque]?[PrivateProperty.self], nil)
        expectEqual(h.editor.undoHistory.undoName, "Make Public")
    },
    test("with several shapes: Make Public while any is private, which makes those public in one step; Make Private once every one is public") {
        let h = try publishingHarness()
        let a = h.add(Plaque(plaqueFrame)), b = h.add(Plaque(CGRect(x: 300, y: 100, width: 100, height: 100)))
        h.conceal(b)
        h.editor.selectedShapeIDs = [a, b]
        let menu = try require(h.secondaryClick(at: spot))
        expectEqual(menu.outline, ["Make Public", "—", "Delete"])
        try menu.choose("Make Public")
        expectEqual([a, b].map { h.editor.document[$0]?[PrivateProperty.self] }, [nil, nil])
        expectEqual(h.editor.undoHistory.undoName, "Make Public")
        h.editor.undo()
        expectEqual([a, b].map { h.editor.document[$0]?[PrivateProperty.self] }, [nil, true], "one step: only b goes back")
        h.editor.redo()
        try require(h.secondaryClick(at: CGPoint(x: 350, y: 150))).choose("Make Private")
        expectEqual([a, b].map { h.editor.document[$0]?[PrivateProperty.self] }, [true, true])
        h.editor.undo()
        expectEqual([a, b].map { h.editor.document[$0]?[PrivateProperty.self] }, [nil, nil], "in one step")
    },
    test("a seal (always public), a draft (never) and a stand-in have no item; a mix makes private only what can be") {
        let h = try publishingHarness()
        let seal = h.add(Seal(plaqueFrame)), draft = h.add(Draft(CGRect(x: 300, y: 100, width: 100, height: 100)))
        let holder = h.hold([seal], at: CGRect(x: 500, y: 100, width: 100, height: 100))
        for (shape, point) in [(seal, spot), (draft, CGPoint(x: 350, y: 150)), (holder, CGPoint(x: 550, y: 150))] {
            h.editor.selectedShapeIDs = [shape]
            expectEqual(try require(h.secondaryClick(at: point)).outline, ["Delete"], "\(shape)")
        }
        let plaque = h.add(Plaque(CGRect(x: 100, y: 300, width: 100, height: 100)))
        h.editor.selectedShapeIDs = [seal, draft, plaque]
        let menu = try require(h.secondaryClick(at: CGPoint(x: 150, y: 350)))
        expectEqual(menu.outline, ["Make Private", "—", "Delete"])
        try menu.choose("Make Private")
        expectEqual(h.editor.document[plaque]?[PrivateProperty.self], true)
        expectEqual(h.editor.document[seal]?[PrivateProperty.self], nil, "nothing is written to a seal")
        expectEqual(h.editor.document[draft]?[PrivateProperty.self], nil)
        expectEqual(h.editor.undoHistory.undoName, "Make Private")
    },
    test("Make Private on held shapes is enabled; choosing it changes nothing, shakes them and shows Connections") {
        let log = RefusalLog()
        let h = try publishingHarness([FreezingPlugin(log: log)])
        let a = h.add(Plaque(plaqueFrame)), b = h.add(Plaque(CGRect(x: 300, y: 100, width: 100, height: 100)))
        h.hold([a, b])
        h.editor.selectedShapeIDs = [a, b]
        expectEqual(try require(h.secondaryClick(at: spot)).outline, ["Make Private", "—", "Delete"])
        h.editor.selectedShapeIDs = [a]
        let menu = try require(h.secondaryClick(at: spot))
        expectEqual(menu.outline, ["Make Private", "—", "Delete"])
        let before = h.editor.undoHistory.undoName
        try menu.choose("Make Private")
        expectEqual(h.editor.document[a]?[PrivateProperty.self], nil, "stays public")
        expectEqual(h.editor.undoHistory.undoName, before, "no step")
        expectEqual(log.refusals, [[a]])
        h.wait(16)
        expect(h.editor.drawingOffset(of: a) != .zero, "shaking")
    },
    test("Make Private on a shape nothing stands for makes it private") {
        let h = try publishingHarness()
        let a = h.add(Plaque(plaqueFrame))
        try require(h.secondaryClick(at: spot)).choose("Make Private")
        expectEqual(h.editor.document[a]?[PrivateProperty.self], true)
    },
    test("a mix of held and free shapes: the free ones go private in one step, and the held one shakes") {
        let log = RefusalLog()
        let h = try publishingHarness([FreezingPlugin(log: log)])
        let held = h.add(Plaque(plaqueFrame)), free = h.add(Plaque(CGRect(x: 300, y: 100, width: 100, height: 100)))
        h.hold([held])
        h.editor.selectedShapeIDs = [held, free]
        let menu = try require(h.secondaryClick(at: spot))
        expectEqual(menu.outline, ["Make Private", "—", "Delete"])
        try menu.choose("Make Private")
        expectEqual([held, free].map { h.editor.document[$0]?[PrivateProperty.self] }, [nil, true])
        expectEqual(h.editor.undoHistory.undoName, "Make Private")
        expectEqual(log.refusals, [[held]], "the held shape is refused, once")
        h.wait(16)
        expect(h.editor.drawingOffset(of: held) != .zero, "shaking")
        expectEqual(h.editor.drawingOffset(of: free), .zero)
        h.editor.undo()
        expectEqual([held, free].map { h.editor.document[$0]?[PrivateProperty.self] }, [nil, nil], "one step")
    },
    test("locked shapes: each item is dimmed when every shape it would change is read-only, and a mix changes the others") {
        let log = RefusalLog()
        let h = try publishingHarness([FreezingPlugin(log: log)])
        let a = h.add(Plaque(plaqueFrame)), b = h.add(Plaque(CGRect(x: 300, y: 100, width: 100, height: 100)))
        h.editor.freeze([a])
        h.editor.selectedShapeIDs = [a]
        expectEqual(try require(h.secondaryClick(at: spot)).outline, ["(Make Private)", "—", "Delete"], "a locked public shape")
        h.editor.freeze([a], false)
        h.conceal(a, b)
        h.editor.freeze([a])
        expectEqual(try require(h.secondaryClick(at: spot)).outline, ["(Make Public)", "—", "Delete"], "a locked private shape")
        h.editor.selectedShapeIDs = [a, b]
        let menu = try require(h.secondaryClick(at: CGPoint(x: 350, y: 150)))
        expectEqual(menu.outline, ["Make Public", "—", "Delete"], "with one that isn't locked: the item works")
        try menu.choose("Make Public")
        expectEqual([a, b].map { h.editor.document[$0]?[PrivateProperty.self] }, [true, nil], "the locked one stays")
        h.editor.freeze([b])
        h.editor.selectedShapeIDs = [a, b]
        expectEqual(try require(h.secondaryClick(at: spot)).outline, ["(Make Public)", "—", "Delete"], "a is private and locked, b public and locked: nothing to change")
        h.editor.freeze([a, b], false)
        h.publish(a)
        h.editor.freeze([a, b])
        expectEqual(try require(h.secondaryClick(at: spot)).outline, ["(Make Private)", "—", "Delete"], "every shape public, and locked")
    },
    test("empty canvas offers neither") {
        let h = try publishingHarness()
        h.add(Plaque(plaqueFrame))
        expectEqual(try require(h.secondaryClick(at: CGPoint(x: 500, y: 500))).outline, ["Select All"])
    },
])
