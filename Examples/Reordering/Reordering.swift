import Canvas
import ContextMenus
import CoreGraphics

/// Arrange, after every other item.
public enum ReorderMenuGroup {}
extension ReorderMenuGroup: MenuGroup {
    public static var order: Int { 200 }
}

/// An Arrange submenu in every shape's context menu, as in Keynote and tldraw: Bring to Front,
/// Bring Forward, Send Backward and Send to Back. The smallest plugin that adds items for every
/// kind, and one that picks kinds by capability: a kind painted by anchor (an arrow, just above the
/// shapes it joins) is left out, since document order doesn't decide where it's drawn.
public struct ReorderingPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "reordering" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.contextMenuForEveryShape(where: { !($0 is any PaintOrderAnchored) }) {
            Submenu("Arrange", in: ReorderMenuGroup.self) {
                MenuItem("Bring to Front") { ids, editor in
                    let ordered = backToFront(ids, in: editor.document)
                    editor.transact("Bring to Front") { transaction in
                        for id in ordered { transaction.bringToFront(id) }
                    }
                }
                MenuItem("Bring Forward") { ids, editor in step(ids, forward: true, in: editor) }
                MenuItem("Send Backward") { ids, editor in step(ids, forward: false, in: editor) }
                MenuItem("Send to Back") { ids, editor in
                    let ordered = backToFront(ids, in: editor.document)
                    editor.transact("Send to Back") { transaction in
                        for id in ordered.reversed() { transaction.sendToBack(id) }
                    }
                }
            }
        }
    }
}

/// So the shapes keep their order among themselves.
private func backToFront(_ ids: [ShapeID], in document: CanvasDocument) -> [ShapeID] {
    ids.sorted { (document.index(of: $0) ?? 0) < (document.index(of: $1) ?? 0) }
}

/// tldraw's Bring Forward and Send Backward: each shape moves just past the nearest shape that
/// overlaps it, in that direction, which isn't moving too, nor held in it (a frame's contents go
/// with it); past a shape it doesn't overlap, a move would change nothing to see. The leading shape
/// moves first, so the shapes keep their order among themselves. A shape with nothing to pass
/// stays. Shapes painted by anchor don't count.
@MainActor
private func step(_ ids: [ShapeID], forward: Bool, in editor: CanvasEditor) {
    let context = editor.shapeContext
    let moving = Set(ids)
    func bounds(_ id: ShapeID) -> CGRect? { context.geometry(of: id)?.bounds }
    editor.transact(forward ? "Bring Forward" : "Send Backward") { transaction in
        let ordered = backToFront(ids, in: transaction.document)
        for id in forward ? ordered.reversed() : ordered {
            guard let index = transaction.document.index(of: id), let mine = bounds(id) else { continue }
            let shapes = transaction.document.shapes
            let passing = forward ? Array(shapes[(index + 1)...]) : shapes[..<index].reversed()
            // What a container holds goes with it, so it's never the shape it steps past.
            let held = Set(transaction.document.descendants(of: id, containingKinds: editor.registry.containingKinds))
            let next = passing.first { other in
                !moving.contains(other.id) && !held.contains(other.id) && !(editor.registry.definition(for: other.kind) is any PaintOrderAnchored)
                    && bounds(other.id).map { $0.intersects(mine) } == true
            }
            guard let next else { continue }
            if forward { transaction.move(id, above: next.id) } else { transaction.move(id, below: next.id) }
        }
    }
}
