import Canvas
import ContextMenus

/// Arrange, after every other item.
public enum ReorderMenuGroup {}
extension ReorderMenuGroup: MenuGroup {
    public static var order: Int { 200 }
}

/// An Arrange submenu in every shape's context menu, as in Keynote and tldraw: Bring to Front,
/// Bring Forward, Send Backward and Send to Back. The smallest plugin that adds items for every
/// kind, and one that picks kinds by capability: a kind painted by anchor (an arrow, just above the
/// shapes it joins) is left out, since document order doesn't decide where it's drawn.
public struct ReorderingPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { "reordering" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.contextMenuForEveryShape(where: { !($0 is any PaintOrderAnchored) }) {
            Submenu("Arrange", in: ReorderMenuGroup.self) {
                MenuItem("Bring to Front") { ids, editor in editor.transact("Bring to Front") { $0.bringToFront(ids) } }
                MenuItem("Bring Forward") { ids, editor in editor.transact("Bring Forward") { $0.bringForward(ids) } }
                MenuItem("Send Backward") { ids, editor in editor.transact("Send Backward") { $0.sendBackward(ids) } }
                MenuItem("Send to Back") { ids, editor in editor.transact("Send to Back") { $0.sendToBack(ids) } }
            }
        }
    }
}
