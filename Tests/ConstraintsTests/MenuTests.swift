@_spi(Host) import Canvas
import AppKit
import CanvasTesting
import CanvasUI
import Constraints
import CoreGraphics
import DetailPanel
import Selection
import TestKit
import Validation

// The menus that do what the panel's buttons do: a container's Constraints ▸ (each own constraint a submenu with its reach and
// Remove, then Remove All Constraints and Show Constraints), a breaker's Move Out of <place> and Show Constraint, the same
// from the Shape menu (the selection's context menu), each a step named as the writer names it.

private let penRect = CGRect(x: 100, y: 100, width: 400, height: 300)
private let inside = CGPoint(x: 400, y: 380)

@MainActor let menuTests = Suite("Constraints: the menus", [
    test("a container's Constraints ▸: each own constraint with its reach checked and Remove, Remove All Constraints, Show Constraints; none on a shape with no constraint") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [onlyTiles, Constraint(says: "no discs", query: ":not(disc)", reach: .descendants)])
        let bare = h.corral("Bare", CGRect(x: 600, y: 100, width: 150, height: 150))
        h.editor.selectedShapeIDs = [pen]
        let menu = try require(h.secondaryClick(at: inside))
        expectEqual(menu.outline.first, "Constraints ▸")
        expectEqual(Array(menu.outline.dropFirst().prefix(9)), ["  only tiles ▸", "    ✓ Directly Inside", "    Anywhere Inside", "    Remove",
                                                                "  no discs ▸", "    Directly Inside", "    ✓ Anywhere Inside", "    Remove",
                                                                "  Remove All Constraints"])
        h.editor.selectedShapeIDs = [bare]
        let none = try require(h.secondaryClick(at: CGPoint(x: 680, y: 220)))
        expect(!none.outline.contains("Constraints ▸"), "\(none.outline)")
        h.editor.selectedShapeIDs = [pen, bare]
        let two = try require(h.secondaryClick(at: inside))
        expect(!two.outline.contains("Constraints ▸"), "one container's list at a time")
    },
    test("a reach picked, Remove, and Remove All Constraints are one step each, named as the writer names them") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [onlyTiles, noDiscs])
        h.editor.selectedShapeIDs = [pen]
        var menu = try require(h.secondaryClick(at: inside))
        try menu.choose("Constraints", "only tiles", "Anywhere Inside")
        expectEqual(h.list(of: pen).first?.reach, .descendants)
        expectEqual(h.editor.undoHistory.undoName, "Change Constraint")
        menu = try require(h.secondaryClick(at: inside))
        try menu.choose("Constraints", "no discs", "Remove")
        expectEqual(h.list(of: pen), [Constraint(says: "only tiles", query: "tile", reach: .descendants)])
        expectEqual(h.editor.undoHistory.undoName, "Remove Constraint")
        menu = try require(h.secondaryClick(at: inside))
        try menu.choose("Constraints", "Remove All Constraints")
        expectEqual(h.list(of: pen), [])
        expectEqual(h.editor.undoHistory.undoName, "Remove All Constraints")
        h.editor.undo()
        expectEqual(h.list(of: pen).count, 1)
    },
    test("Show Constraints selects the container on its Rules tab; for a container that only has them from elsewhere there is no Remove All") {
        let given = Given()
        let h = try constraintHarness(given)
        let other = h.corral("Other", CGRect(x: 600, y: 100, width: 150, height: 150))
        let pen = h.corral("Pen", penRect)
        given.lists[pen] = [ConstraintSource(holder: other, constraints: [noDiscs])]
        h.index.inheritedConstraintsDidChange(of: [pen])
        h.wait(0)
        h.editor.selectedShapeIDs = [other]
        h.editor.selectedShapeIDs = [pen]
        let menu = try require(h.secondaryClick(at: inside))
        expectEqual(menu.outline.prefix(3), ["Constraints ▸", "  Go to Other", "  Show Constraints"])
        h.editor.selectedShapeIDs = [other]
        try menu.choose("Constraints", "Show Constraints")
        h.wait(0)
        expectEqual(h.editor.selectedShapeIDs, [pen])
        expectEqual(h.editor.detailPanel?.chosenTab(for: Corral.kind), .of(RulesTab.self))
    },
    test("a holder has Constraints ▸ too, with its own") {
        let h = try constraintHarness()
        let charter = h.add(Charter(CGRect(x: 600, y: 300, width: 100, height: 80), name: "Sprint"))
        h.writer.add(onlyTiles, to: .shape(charter))
        h.editor.selectedShapeIDs = [charter]
        let menu = try require(h.secondaryClick(at: CGPoint(x: 650, y: 340)))
        expectEqual(Array(menu.outline.prefix(6)), ["Constraints ▸", "  only tiles ▸", "    ✓ Directly Inside", "    Anywhere Inside", "    Remove", "  Remove All Constraints"])
        try menu.choose("Constraints", "Remove All Constraints")
        expectEqual(h.list(of: charter), [])
    },
    test("a holder's Constraints ▸ is there only when it has a list of its own or one from elsewhere, as a container's is: a bare type has none") {
        let given = Given()
        let h = try constraintHarness(given)
        let other = h.corral("Other", CGRect(x: 600, y: 100, width: 150, height: 150))
        let charter = h.add(Charter(CGRect(x: 600, y: 300, width: 100, height: 80), name: "Sprint"))
        let at = CGPoint(x: 650, y: 340)
        h.editor.selectedShapeIDs = [charter]
        var menu = try require(h.secondaryClick(at: at))
        expect(!menu.outline.contains("Constraints ▸"), "a bare holder has no submenu: \(menu.outline)")
        given.lists[charter] = [ConstraintSource(holder: other, constraints: [noDiscs])]
        menu = try require(h.secondaryClick(at: at))
        expect(menu.outline.contains("Constraints ▸"), "a list from elsewhere: \(menu.outline)")
        given.lists[charter] = []
        h.writer.add(onlyTiles, to: .shape(charter))
        menu = try require(h.secondaryClick(at: at))
        expect(menu.outline.contains("Constraints ▸"), "its own: \(menu.outline)")
        h.writer.removeAll(from: .shape(charter))
        menu = try require(h.secondaryClick(at: at))
        expect(!menu.outline.contains("Constraints ▸"), "and none again with the last gone: \(menu.outline)")
    },
    test("a holder is given lists from elsewhere through the one point, as a frame is: the index, its menu and its section read them") {
        let given = Given()
        let h = try constraintHarness(given)
        let other = h.corral("Other", CGRect(x: 600, y: 100, width: 150, height: 150))
        let charter = h.add(Charter(CGRect(x: 600, y: 300, width: 100, height: 80), name: "Sprint"))
        h.writer.add(onlyTiles, to: .shape(charter))
        expectEqual(h.index.sources(of: .shape(charter)), [])
        given.lists[charter] = [ConstraintSource(holder: other, constraints: [noDiscs])]
        expectEqual(h.index.sources(of: .shape(charter)).map(\.holder), [other], "asked of the holder as it is, no place kept")
        h.editor.selectedShapeIDs = [charter]
        let menu = try require(h.secondaryClick(at: CGPoint(x: 650, y: 340)))
        expect(menu.outline.contains("  Go to Other"), "\(menu.outline)")
    },
    test("a shape that breaks a constraint has Move Out of its place and Show Constraint, the actions its issue offers; one that doesn't has neither") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [noDiscs])
        let d = h.disc(at: CGPoint(x: 200, y: 200), in: pen), t = h.tile("T", at: CGPoint(x: 300, y: 150), in: pen)
        h.settle()
        h.editor.selectedShapeIDs = [d]
        var menu = try require(h.secondaryClick(at: CGPoint(x: 225, y: 225)))
        expectEqual(Array(menu.outline.prefix(2)), ["Move Out of Pen", "Show Constraint"])
        try menu.choose("Move Out of Pen")
        expectEqual(h.editor.holder(of: d), nil)
        expectEqual(h.editor.undoHistory.undoName, "Move Out")
        h.editor.undo()
        h.settle()
        h.editor.selectedShapeIDs = [d]
        menu = try require(h.secondaryClick(at: CGPoint(x: 225, y: 225)))
        h.editor.selectedShapeIDs = [pen]
        try menu.choose("Show Constraint")
        h.wait(0)
        expectEqual(h.editor.selectedShapeIDs, [pen])
        expectEqual(h.editor.detailPanel?.chosenTab(for: Corral.kind), .of(RulesTab.self))
        h.editor.selectedShapeIDs = [t]
        let fits = try require(h.secondaryClick(at: CGPoint(x: 340, y: 190)))
        expect(!fits.outline.contains { $0.hasPrefix("Move Out") || $0.hasPrefix("Show Constraint") }, "\(fits.outline)")
    },
    test("the same in the Shape menu, the selection's context menu") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [noDiscs])
        let d = h.disc(at: CGPoint(x: 200, y: 200), in: pen)
        h.settle()
        h.editor.selectedShapeIDs = [pen]
        let menus = BoardMenus.make(appName: "Infinite Canvas", registry: h.editor.registry, editor: { h.editor })
        @MainActor func shapeMenu() throws -> NSMenu {
            let shape = try require(menus.main.item(withTitle: "Shape")?.submenu)
            shape.delegate?.menuNeedsUpdate?(shape)
            return shape
        }
        expectEqual(try shapeMenu().outline.first, "Constraints ▸")
        h.editor.selectedShapeIDs = [d]
        let outline = try shapeMenu().outline
        expect(outline.contains("Move Out of Pen"), "\(outline)")
    },
])
