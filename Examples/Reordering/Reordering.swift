import Canvas
import ContextMenus
import Keyboard
import Selection

/// Arrange, after every other item.
public enum ReorderMenuGroup {}
extension ReorderMenuGroup: MenuGroup {
    public static var order: Int { 200 }
}

/// An Arrange submenu in every shape's context menu, as in Keynote and tldraw: Bring to Front,
/// Bring Forward, Send Backward and Send to Back. The smallest plugin that adds items for every
/// kind, and one that picks kinds by capability: a kind painted by anchor (an arrow, just above the
/// shapes it joins) is left out, since document order doesn't decide where it's drawn.
///
/// Each is a command (the core names them: the menu bar's Arrange carries them too) with a key,
/// `]`, ⌥], ⌥[ and `[`, that the items run on the selection.
public struct ReorderingPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { "reordering" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.command(.bringToFront, "Bring to Front", shortcuts: [KeyChord("]")], isEnabled: { $0.canReorder }) { editor in
            editor.transact("Bring to Front") { $0.bringToFront(editor.selectedShapeIDs) }
        }
        registrar.command(.bringForward, "Bring Forward", shortcuts: [KeyChord("]", .option)], isEnabled: { $0.canReorder }) { editor in
            editor.transact("Bring Forward") { $0.bringForward(editor.selectedShapeIDs) }
        }
        registrar.command(.sendBackward, "Send Backward", shortcuts: [KeyChord("[", .option)], isEnabled: { $0.canReorder }) { editor in
            editor.transact("Send Backward") { $0.sendBackward(editor.selectedShapeIDs) }
        }
        registrar.command(.sendToBack, "Send to Back", shortcuts: [KeyChord("[")], isEnabled: { $0.canReorder }) { editor in
            editor.transact("Send to Back") { $0.sendToBack(editor.selectedShapeIDs) }
        }
        registrar.contextMenuForEveryShape(where: { !($0 is any PaintOrderAnchored) }) {
            Submenu("Arrange", in: ReorderMenuGroup.self) {
                MenuItem(command: .bringToFront)
                MenuItem(command: .bringForward)
                MenuItem(command: .sendBackward)
                MenuItem(command: .sendToBack)
            }
        }
    }
}

extension CanvasEditor {
    /// Whether the keys would restack anything: shapes are selected, none painted by anchor (the
    /// kinds Arrange leaves out), and nothing is under way or being edited.
    fileprivate var canReorder: Bool {
        guard session == nil, editingShapeID == nil, !selectedShapeIDs.isEmpty else { return false }
        let document = document
        return selectedShapeIDs.allSatisfy { id in
            document[id].flatMap { registry.definition(for: $0.kind) }.map { !($0 is any PaintOrderAnchored) } ?? false
        }
    }
}
