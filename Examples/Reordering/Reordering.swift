import Canvas
import ContextMenus

/// Bring to Front and Send to Back, after every other item.
public enum ReorderMenuGroup {}
extension ReorderMenuGroup: MenuGroup {
    public static var order: Int { 200 }
}

/// Bring to Front and Send to Back in the context menu of every shape with a frame: the smallest
/// plugin that adds items for every kind. Not shipped, so a right-click on a shape with no items of
/// its own still does nothing; add it to `ShippedPlugins.all` to give every box a menu.
public struct ReorderingPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "reordering" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.contextMenuForEveryShape {
            MenuItem("Bring to Front", in: ReorderMenuGroup.self, when: { $0.box != nil }) { ids, editor in
                let ordered = backToFront(ids, in: editor.document)
                editor.transact { transaction in
                    for id in ordered { transaction.bringToFront(id) }
                }
            }
            MenuItem("Send to Back", in: ReorderMenuGroup.self, when: { $0.box != nil }) { ids, editor in
                let ordered = backToFront(ids, in: editor.document)
                editor.transact { transaction in
                    for id in ordered.reversed() { transaction.sendToBack(id) }
                }
            }
        }
    }
}

/// So the shapes keep their order among themselves.
private func backToFront(_ ids: [ShapeID], in document: CanvasDocument) -> [ShapeID] {
    ids.sorted { (document.index(of: $0) ?? 0) < (document.index(of: $1) ?? 0) }
}
