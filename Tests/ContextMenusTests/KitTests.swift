@_spi(Host) import Canvas
import CanvasTesting
import ContextMenus
import CoreGraphics
import Selection
import TestKit

// A kit's menu items (Kits.swift): while the kit a plugin joined is off in the file, its items for a kind and for
// the canvas are in no menu, the selection's included, and an item of no kit's that runs the kit's command is
// left out, never dimmed; turned on, each is back.

/// The workshop's items, from a plugin in the kit: Plane on boxes, and Sweep in every menu.
@MainActor private func workshopItems() -> Contributor {
    Contributor(id: "workshop-items") { r in
        r.join(Workshop.self)
        r.contextMenu(Box.self) { MenuItem("Plane") { $0.frame.size.width += 10 } }
        r.contextMenuForCanvas { MenuItem("Sweep") { _, _ in } }
    }
}

/// An item of no kit's that runs the workshop's Carve, shown dimmed where it can't act.
@MainActor private let carveItem = Contributor(id: "carve-item") { r in
    r.contextMenuForCanvas { MenuItem(command: .carve, dims: true) }
}

@MainActor let menuKitTests = Suite("A kit's menu items", [
    test("while the kit is off, its items and an item that runs its command are in no menu; on, they're back and run") {
        let h = try harness([WorkshopPlugin(), workshopItems(), carveItem])
        let box = h.add(Box(slot(0)))
        let kits = ["Plane", "Sweep", "Carve"]
        expectEqual(try require(h.secondaryClick(at: middle(0))).outline.filter(kits.contains), [], "a box's menu")
        expectEqual(h.secondaryClick(at: emptyCanvas)?.outline.filter(kits.contains) ?? [], [], "the canvas's")
        h.editor.selectedShapeIDs = [box]
        expectEqual(h.editor.menuForSelection(omitting: [])?.outline.filter(kits.contains) ?? [], [], "the selection's")
        h.editor.turn(Workshop.self, on: true)
        let menu = try require(h.secondaryClick(at: middle(0)))
        expectEqual(menu.outline.filter(kits.contains), ["Plane", "Sweep", "Carve"])
        try menu.choose("Plane")
        expectEqual(h.editor.document[box]?.box?.width, 110)
        expectEqual(try require(h.editor.menuForSelection(omitting: [])).outline.filter(kits.contains), ["Plane", "Sweep", "Carve"])
        h.editor.turn(Workshop.self, on: false)
        expectEqual(try require(h.secondaryClick(at: middle(0))).outline.filter(kits.contains), [], "off again")
    },
])
