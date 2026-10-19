import Canvas
import CanvasTesting
import ContextMenus
import CoreGraphics
import Locking
import Selection
import TestKit

@MainActor let lockMenuTests = Suite("Locking from the context menu", [
    test("a shape's menu offers Lock, then Unlock, after every other group; a lock is `locked: true`, and unlocking takes it away") {
        let h = try lockingHarness([Contributor(id: "widening") { r in
            r.forEveryShape { $0.contextMenu { MenuItem("Widen") { $0.box?.size.width += 10 } } }
        }])
        let box = h.add(Box(CGRect(x: 100, y: 100, width: 100, height: 100)))
        let menu = try require(h.secondaryClick(at: CGPoint(x: 150, y: 150)))
        expectEqual(menu.outline, ["Widen", "—", "Lock", "—", "Delete"], "Delete last, after Lock")
        try menu.choose("Lock")
        expect(h.editor.isLocked(box))
        expectEqual(h.editor.document[box]?[LockedProperty.self], true)
        expectEqual(h.editor.selectedShapeIDs, [box], "still selected: a locked shape is selected as any other")
        expectEqual(try require(h.secondaryClick(at: CGPoint(x: 150, y: 150))).outline, ["Widen", "—", "Unlock", "—", "Delete"])
        try require(h.secondaryClick(at: CGPoint(x: 150, y: 150))).choose("Unlock")
        expect(!h.editor.isLocked(box))
        expectEqual(h.editor.document[box]?[LockedProperty.self], nil)
    },
    test("with several shapes: Lock while any is unlocked, which locks them all; Unlock once every one is") {
        let h = try lockingHarness()
        let a = h.add(Box(CGRect(x: 100, y: 100, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 300, y: 100, width: 100, height: 100)))
        h.editor.lock([a])
        h.editor.selectedShapeIDs = [a, b]
        let menu = try require(h.secondaryClick(at: CGPoint(x: 150, y: 150)))
        expectEqual(menu.outline, ["Lock", "—", "Delete"])
        try menu.choose("Lock")
        expect(h.editor.isLocked(a) && h.editor.isLocked(b))
        try require(h.secondaryClick(at: CGPoint(x: 350, y: 150))).choose("Unlock")
        expect(!h.editor.isLocked(a) && !h.editor.isLocked(b))
    },
    test("empty canvas offers neither") {
        let h = try lockingHarness()
        h.add(Box(CGRect(x: 100, y: 100, width: 100, height: 100)))
        expectEqual(try require(h.secondaryClick(at: CGPoint(x: 400, y: 400))).outline, ["Select All"])
    },
    test("the menu's Delete on a locked shape deletes nothing and shakes it, as the Delete key does; with an unlocked one, it takes that one") {
        let h = try lockingHarness()
        let locked = h.add(Box(CGRect(x: 100, y: 100, width: 100, height: 100)))
        let free = h.add(Box(CGRect(x: 300, y: 100, width: 100, height: 100)))
        h.editor.lock([locked])
        try require(h.secondaryClick(at: CGPoint(x: 150, y: 150))).choose("Delete")
        expectEqual(h.editor.document.shapes.map(\.id), [locked, free])
        h.wait(60)
        expect(h.editor.drawingOffset(of: locked) != .zero, "shaking")
        h.wait(1000)
        h.editor.selectedShapeIDs = [locked, free]
        try require(h.secondaryClick(at: CGPoint(x: 350, y: 150))).choose("Delete")
        expectEqual(h.editor.document.shapes.map(\.id), [locked])
    },
    test("every kind can be locked: each one's schema has `locked`, a boolean Locking owns") {
        let h = try lockingHarness()
        for kind in h.editor.registry.kinds {
            let properties = try require(h.editor.registry.schema(for: kind)?.json["properties"]?.objectValue)
            expectEqual(properties["locked"], ["type": "boolean", "x-canvas-owner": "locking"], "\(kind)")
        }
    },
    test("an item that edits a locked shape changes nothing, and shakes it") {
        let h = try lockingHarness([Contributor(id: "widening") { r in
            r.forEveryShape { $0.contextMenu { MenuItem("Widen") { $0.box?.size.width += 10 } } }
        }])
        let box = h.add(Box(CGRect(x: 100, y: 100, width: 100, height: 100)))
        h.editor.lock([box])
        try require(h.secondaryClick(at: CGPoint(x: 150, y: 150))).choose("Widen")
        expectEqual(h.editor.document[box]?.box, CGRect(x: 100, y: 100, width: 100, height: 100))
        h.wait(16)
        expect(h.editor.drawingOffset(of: box) != .zero, "shaking")
    },
])
