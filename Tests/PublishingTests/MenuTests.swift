@_spi(Host) import Canvas
import CanvasTesting
import ContextMenus
import CoreGraphics
import Publishing
import Selection
import TestKit

// Make Public and Make Private in the context menu, one item for the menu's shapes as a lock's:
// Make Public while any shape that can be public isn't, else Make Private.

private let spot = CGPoint(x: 150, y: 150)

@MainActor let menuTests = Suite("Publishing from the context menu", [
    test("a shape's menu offers Make Public, then Make Private, after every other group and before Delete; a public shape is `public: true`, and going private takes it away") {
        let h = try publishingHarness([Contributor(id: "widening") { r in
            r.forEveryShape { $0.contextMenu { MenuItem("Widen") { $0.box?.size.width += 10 } } }
        }])
        let plaque = h.add(Plaque(plaqueFrame))
        let menu = try require(h.secondaryClick(at: spot))
        expectEqual(menu.outline, ["Widen", "—", "Make Public", "—", "Delete"])
        try menu.choose("Make Public")
        expectEqual(h.editor.document[plaque]?[PublicProperty.self], true)
        expectEqual(h.editor.undoHistory.undoName, "Make Public")
        expectEqual(h.editor.selectedShapeIDs, [plaque], "still selected")
        expectEqual(try require(h.secondaryClick(at: spot)).outline, ["Widen", "—", "Make Private", "—", "Delete"])
        try require(h.secondaryClick(at: spot)).choose("Make Private")
        expectEqual(h.editor.document[plaque]?[PublicProperty.self], nil)
        expectEqual(h.editor.undoHistory.undoName, "Make Private")
    },
    test("with several shapes: Make Public while any is private, which makes them all public in one step; Make Private once every one is") {
        let h = try publishingHarness()
        let a = h.add(Plaque(plaqueFrame)), b = h.add(Plaque(CGRect(x: 300, y: 100, width: 100, height: 100)))
        h.publish(a)
        h.editor.selectedShapeIDs = [a, b]
        let menu = try require(h.secondaryClick(at: spot))
        expectEqual(menu.outline, ["Make Public", "—", "Delete"])
        try menu.choose("Make Public")
        expectEqual([a, b].map { h.editor.document[$0]?[PublicProperty.self] }, [true, true])
        let steps = h.editor.undoHistory.undoName
        expectEqual(steps, "Make Public")
        h.editor.undo()
        expectEqual([a, b].map { h.editor.document[$0]?[PublicProperty.self] }, [true, nil], "one step: only b goes back")
        h.editor.redo()
        try require(h.secondaryClick(at: CGPoint(x: 350, y: 150))).choose("Make Private")
        expectEqual([a, b].map { h.editor.document[$0]?[PublicProperty.self] }, [nil, nil])
        h.editor.undo()
        expectEqual([a, b].map { h.editor.document[$0]?[PublicProperty.self] }, [true, true], "in one step")
    },
    test("a seal (always public), a draft (never) and a stand-in have no item; a mix makes public only what can be") {
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
        expectEqual(menu.outline, ["Make Public", "—", "Delete"])
        try menu.choose("Make Public")
        expectEqual(h.editor.document[plaque]?[PublicProperty.self], true)
        expectEqual(h.editor.document[seal]?[PublicProperty.self], nil, "nothing is written to a seal")
        expectEqual(h.editor.document[draft]?[PublicProperty.self], nil)
        expectEqual(h.editor.undoHistory.undoName, "Make Public")
    },
    test("Make Private on held public shapes is enabled; choosing it changes nothing, shakes them and shows Connections") {
        let log = RefusalLog()
        let h = try publishingHarness([FreezingPlugin(log: log)])
        let a = h.add(Plaque(plaqueFrame)), b = h.add(Plaque(CGRect(x: 300, y: 100, width: 100, height: 100)))
        h.publish(a, b)
        h.hold([a, b])
        h.editor.selectedShapeIDs = [a, b]
        expectEqual(try require(h.secondaryClick(at: spot)).outline, ["Make Private", "—", "Delete"])
        h.editor.selectedShapeIDs = [a]
        let menu = try require(h.secondaryClick(at: spot))
        expectEqual(menu.outline, ["Make Private", "—", "Delete"])
        let before = h.editor.undoHistory.undoName
        try menu.choose("Make Private")
        expectEqual(h.editor.document[a]?[PublicProperty.self], true, "stays public")
        expectEqual(h.editor.undoHistory.undoName, before, "no step")
        expectEqual(log.refusals, [[a]])
        h.wait(16)
        expect(h.editor.drawingOffset(of: a) != .zero, "shaking")
    },
    test("Make Private on an unheld public shape makes it private") {
        let h = try publishingHarness()
        let a = h.add(Plaque(plaqueFrame))
        h.publish(a)
        try require(h.secondaryClick(at: spot)).choose("Make Private")
        expectEqual(h.editor.document[a]?[PublicProperty.self], nil)
    },
    test("a mix of held and free public shapes: the free ones go private in one step, and the held one shakes") {
        let log = RefusalLog()
        let h = try publishingHarness([FreezingPlugin(log: log)])
        let held = h.add(Plaque(plaqueFrame)), free = h.add(Plaque(CGRect(x: 300, y: 100, width: 100, height: 100)))
        h.publish(held, free)
        h.hold([held])
        h.editor.selectedShapeIDs = [held, free]
        let menu = try require(h.secondaryClick(at: spot))
        expectEqual(menu.outline, ["Make Private", "—", "Delete"])
        try menu.choose("Make Private")
        expectEqual([held, free].map { h.editor.document[$0]?[PublicProperty.self] }, [true, nil])
        expectEqual(h.editor.undoHistory.undoName, "Make Private")
        expectEqual(log.refusals, [[held]], "the held shape is refused, once")
        h.wait(16)
        expect(h.editor.drawingOffset(of: held) != .zero, "shaking")
        expectEqual(h.editor.drawingOffset(of: free), .zero)
        h.editor.undo()
        expectEqual([held, free].map { h.editor.document[$0]?[PublicProperty.self] }, [true, true], "one step")
    },
    test("locked shapes: each item is dimmed when every shape it would change is read-only, and a mix changes the others") {
        let log = RefusalLog()
        let h = try publishingHarness([FreezingPlugin(log: log)])
        let a = h.add(Plaque(plaqueFrame)), b = h.add(Plaque(CGRect(x: 300, y: 100, width: 100, height: 100)))
        h.editor.freeze([a])
        h.editor.selectedShapeIDs = [a]
        expectEqual(try require(h.secondaryClick(at: spot)).outline, ["(Make Public)", "—", "Delete"], "a locked private shape")
        h.editor.freeze([a], false)
        h.publish(a, b)
        h.editor.freeze([a])
        expectEqual(try require(h.secondaryClick(at: spot)).outline, ["(Make Private)", "—", "Delete"], "a locked public shape")
        h.editor.selectedShapeIDs = [a, b]
        let menu = try require(h.secondaryClick(at: CGPoint(x: 350, y: 150)))
        expectEqual(menu.outline, ["Make Private", "—", "Delete"], "with one that isn't locked: the item works")
        try menu.choose("Make Private")
        expectEqual([a, b].map { h.editor.document[$0]?[PublicProperty.self] }, [true, nil], "the locked one stays")
        h.editor.freeze([b])
        h.editor.selectedShapeIDs = [a, b]
        expectEqual(try require(h.secondaryClick(at: spot)).outline, ["(Make Public)", "—", "Delete"], "b is private and locked now: nothing to change")
        h.editor.freeze([b], false)
        h.publish(b)
        h.editor.freeze([b])
        expectEqual(try require(h.secondaryClick(at: spot)).outline, ["(Make Private)", "—", "Delete"], "every public shape locked")
    },
    test("empty canvas offers neither") {
        let h = try publishingHarness()
        h.add(Plaque(plaqueFrame))
        expectEqual(try require(h.secondaryClick(at: CGPoint(x: 500, y: 500))).outline, ["Select All"])
    },
])
