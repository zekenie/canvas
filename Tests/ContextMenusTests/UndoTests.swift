@_spi(Host) import Canvas
import CanvasTesting
import ContextMenus
import CoreGraphics
import Selection
import TestKit

@MainActor let undoTests = Suite("Context menus and undo", [
    test("an item is one undo step, named by its title, however many shapes and transactions it takes") {
        let h = try harness([Contributor(id: "flicker") { r in
            r.contextMenu(Lamp.self) {
                MenuItem("Flicker") { ids, editor in
                    for id in ids {
                        editor.transact { $0.update(id, as: Lamp.self) { $0.props.isOn.toggle() } }
                        editor.transact { $0.update(id, as: Lamp.self) { $0.props.level = 3 } }
                    }
                }
            }
        }])
        let lamps = (0..<3).map { h.add(Lamp(slot($0))) }
        h.editor.replaceDocument(with: h.editor.document)
        let before = h.editor.document
        h.editor.selectedShapeIDs = lamps
        try require(h.secondaryClick(at: middle(1))).choose("Flicker")
        expectEqual(lamps.map { h.editor.lamp($0)?.level }, [3, 3, 3])
        expectEqual(h.editor.undoHistory.undoName, "Flicker")
        try require(h.secondaryClick(at: middle(1))).choose("Level", "2")
        expectEqual(h.editor.undoHistory.undoName, "2")
        h.editor.undo()
        expectEqual(h.editor.undoHistory.undoName, "Flicker")
        h.editor.undo()
        expectEqual(h.editor.document, before)
        expectEqual(h.editor.selectedShapeIDs, lamps)
        expect(!h.editor.canUndo)
    },
    test("an item for the canvas is one step, whatever it commits") {
        let h = try harness([Contributor(id: "tidy") { r in
            r.contextMenuForCanvas {
                MenuItem("Tidy Up") { ids, editor in
                    for (n, id) in ids.enumerated() {
                        editor.transact { $0.update(id) { $0.box?.origin.y = CGFloat(n) * 10 } }
                    }
                    editor.transact { $0.insert(ShapeRecord(Box(slot(3)))) }
                }
            }
        }])
        let a = h.add(Box(slot(0))), b = h.add(Box(slot(1)))
        h.editor.replaceDocument(with: h.editor.document)
        let before = h.editor.document
        h.editor.selectedShapeIDs = [a, b]
        try require(h.secondaryClick(at: middle(0))).choose("Tidy Up")
        expectEqual(h.editor.document.shapes.count, 3)
        expectEqual(h.editor.undoHistory.undoName, "Tidy Up")
        h.editor.undo()
        expectEqual(h.editor.document, before)
        expect(!h.editor.canUndo)
    },
])
