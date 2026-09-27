import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TestKit

/// Kinds opting out of selection (`unselectable`, `selectable(when:)`), the commands the plugin
/// claims, and an editor without the plugin.
@MainActor let selectabilityTests = Suite("Selectability", [
    test("a press on an unselectable shape lands on the shape beneath it, and a drag moves that one") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), GhostsPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let ghost = h.add(Ghost(CGRect(x: 50, y: 0, width: 100, height: 100)))
        h.press(at: CGPoint(x: 75, y: 50))
        expectEqual(h.editor.selectedShapeIDs, [box])
        h.drag(to: CGPoint(x: 85, y: 50)); h.release()
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 10, y: 0))
        expectEqual(h.editor.document[ghost]?.box?.origin, CGPoint(x: 50, y: 0))
        expectEqual(h.editor.document.shapes.map(\.id), [box, ghost], "the box stays beneath the ghost")
    },
    test("a press on an unselectable shape with nothing beneath is a press on the canvas: it deselects, and a drag is a marquee") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), GhostsPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 40, height: 40)))
        h.add(Ghost(CGRect(x: 100, y: 0, width: 200, height: 200)))
        h.editor.selection = box
        h.press(at: CGPoint(x: 200, y: 100))
        expectEqual(h.editor.selection, nil)
        h.drag(to: CGPoint(x: 20, y: 20))
        expectEqual(h.editor.brush, CGRect(x: 20, y: 20, width: 180, height: 80))
        expectEqual(h.editor.selectedShapeIDs, [box], "the marquee passes the ghost by")
        h.release()
        h.press(at: CGPoint(x: 200, y: 100)); h.release()
        expectEqual(h.editor.selection, nil, "a click on it selects nothing")
    },
    test("the marquee, ⌘A, and setting the selection all pass an unselectable shape by; hover ignores it") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), GhostsPlugin()])
        let ghost = h.add(Ghost(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let box = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        expect(!h.editor.isSelectable(ghost)); expect(h.editor.isSelectable(box))
        h.press(at: CGPoint(x: 400, y: 200)); h.drag(to: CGPoint(x: -10, y: -10)); h.release()
        expectEqual(h.editor.selectedShapeIDs, [box])
        h.editor.selection = nil
        h.editor.selectAll()
        expectEqual(h.editor.selectedShapeIDs, [box])
        h.editor.selectedShapeIDs = [ghost, box]
        expectEqual(h.editor.selectedShapeIDs, [box])
        h.editor.selection = ghost
        expectEqual(h.editor.selectedShapeIDs, [])
        h.move(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.hovered, nil)
    },
    test("an unselectable shape still draws, and the core still hits it (for arrows, the eraser)") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), GhostsPlugin()])
        let size = CGSize(width: 100, height: 100)
        let empty = renderBitmap(h.editor, size: size)
        let ghost = h.add(Ghost(CGRect(x: 20, y: 20, width: 60, height: 60)))
        expect(changedPixels(empty, renderBitmap(h.editor, size: size), in: CGRect(origin: .zero, size: size)) > 0)
        expectEqual(h.editor.shape(at: CGPoint(x: 50, y: 50)), ghost)
    },
    test("selectable(when:) follows the shape: one that stops being selectable leaves the selection with the change") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), LockablesPlugin()])
        let lockable = h.add(Lockable(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.move(to: CGPoint(x: 50, y: 50))
        h.editor.selection = lockable
        expectEqual(h.editor.hovered, lockable)
        h.editor.transact { $0.update(lockable, as: Lockable.self) { $0.props.isLocked = true } }
        expectEqual(h.editor.selection, nil)
        expectEqual(h.editor.hovered, nil)
        h.press(at: CGPoint(x: 50, y: 50)); h.release()
        expectEqual(h.editor.selection, nil)
        h.editor.transact { $0.update(lockable, as: Lockable.self) { $0.props.isLocked = false } }
        h.press(at: CGPoint(x: 50, y: 50)); h.release()
        expectEqual(h.editor.selection, lockable)
    },
    test("a rule for every kind applies where a kind has none of its own") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), LockablesPlugin(), Contributor(id: "frozen") {
            $0.contribute({ _ in false }, to: ShapeSelectability.self)
        }])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let lockable = h.add(Lockable(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.editor.selectAll()
        expectEqual(h.editor.selectedShapeIDs, [lockable])
        expect(!h.editor.isSelectable(box))
    },
    test("a place tool puts an unselectable shape down and drags it; what was selected is let go, as with any placement") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), Contributor(id: "ghosts") { r in
            r.shape(GhostDefinition()) { ghost in
                ghost.tool(label: "Ghost", systemImage: "square.dashed", shortcut: "g", placing: ghost.placement(size: CGSize(width: 40, height: 40)) { Ghost(.zero) })
                ghost.unselectable()
            }
        }])
        h.editor.selection = h.add(Box(CGRect(x: 500, y: 500, width: 10, height: 10)))
        h.key("g")
        h.press(at: CGPoint(x: 100, y: 100))
        expectEqual(h.editor.currentToolID, .select)
        expectEqual(h.editor.selectedShapeIDs, [], "the new shape would be the only one selected, and it can't be")
        h.drag(to: CGPoint(x: 130, y: 110)); h.release()
        expectEqual(h.editor.document.shapes.last?.box?.origin, CGPoint(x: 110, y: 90))
    },
    test("a kind has at most one selectability rule") {
        expectThrows(RegistryError.conflict(point: "ShapeSelectability", key: "ghost", plugins: ["ghosts", "haunted"])) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), GhostsPlugin(), Contributor(id: "haunted") {
                $0.contribute({ _ in true }, to: ShapeSelectability.self, for: .kind(Ghost.kind))
            }])
        }
    },
    test("Delete, Return and ⌘A are the selection's keys, and Delete and Select All its commands, which the menus send") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), CardsPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let card = h.add(Card(CGRect(x: 200, y: 0, width: 100, height: 100)))
        let other = h.add(Box(CGRect(x: 400, y: 0, width: 100, height: 100)))
        h.hold(.command)
        expect(h.key("a"))
        h.hold([])
        expectEqual(h.editor.selectedShapeIDs, [box, card, other])
        h.editor.selection = nil
        expect(h.editor.perform(.selectAll))
        expectEqual(h.editor.selectedShapeIDs, [box, card, other])
        h.editor.selection = card
        expect(h.key("\r"))
        expectEqual(h.editor.editingShapeID, card)
        h.editor.endEditing()
        expect(h.key("\u{3}"), "Enter too")
        expectEqual(h.editor.editingShapeID, card)
        h.editor.endEditing()
        h.editor.selection = box
        expect(h.key("\u{7f}"))
        h.editor.selection = other
        expect(h.editor.perform(.delete))
        expectEqual(h.editor.document.shapes.map(\.id), [card])
        h.editor.selection = card
        expect(h.key("\u{F728}"), "Forward Delete too")
        expectEqual(h.editor.document.shapes.map(\.id), [])
    },
    test("without the Selection plugin, nothing is selected, selecting does nothing, and no one claims the commands") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.editor.selection = box
        expectEqual(h.editor.selection, nil)
        expectEqual(h.editor.selectedShapeIDs, [])
        expect(!h.editor.isSelectable(box))
        for command in [CanvasCommand.delete, .selectAll] { expect(!h.editor.perform(command), "\(command)") }
        expectEqual(h.editor.currentToolID, .hand)
        expectEqual(h.editor.registry.tools.map(\.id), [.hand])
    },
])

/// A box the select tool sees through.
struct Ghost: BoxShapeProps {
    static let kind: ShapeKind = "ghost"
    static let properties = Properties<Ghost> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
}
extension Ghost {
    init() { self.init(.zero) }
}

struct GhostDefinition {}

extension GhostDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Ghost>, in context: RenderContext) {
        context.fillWithShadow(CGPath(rect: shape.frame, transform: nil), .systemGray)
    }
}

struct GhostsPlugin: CanvasPlugin {
    var id: PluginID { "ghosts" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(GhostDefinition()) { ghost in ghost.unselectable() }
    }
}

/// A box that can't be selected while it's locked.
struct Lockable: BoxShapeProps {
    static let kind: ShapeKind = "lockable"
    static let properties = Properties<Lockable> {
        Property("frame", \.frame).required()
        Property("isLocked", \.isLocked)
    }
    var frame: CGRect
    var isLocked = false
    init(_ frame: CGRect) { self.frame = frame }
}
extension Lockable {
    init() { self.init(.zero) }
}

struct LockableDefinition {}

extension LockableDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Lockable>, in context: RenderContext) {}
}

struct LockablesPlugin: CanvasPlugin {
    var id: PluginID { "lockables" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(LockableDefinition()) { lockable in lockable.selectable { !$0.props.isLocked } }
    }
}
