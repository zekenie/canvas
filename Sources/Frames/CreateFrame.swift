import Canvas
import ContextMenus
import CoreGraphics

/// Create Frame's band in a context menu: after a transform's (60), before Cut, Copy and Paste (100).
public enum FramesMenuGroup {}
extension FramesMenuGroup: MenuGroup {
    public static var order: Int { 70 }
}

extension FrameStyle {
    /// How far a frame made around shapes reaches past them on every side, in world units, as the model
    /// is: a frame made zoomed out reaches no further over its neighbors than one made at 100%.
    static let padding: CGFloat = 32
}

extension PluginRegistrar {
    /// Create Frame, in the menu of any shapes a frame can hold (those with a box: an arrow alone has
    /// none): a frame around them, holding them, put down by the core (`place(_:around:)`), reaching
    /// `FrameStyle.padding` past them and never under its placement's `minimumSize` where the frame they're all in
    /// has room, in that frame, just below the lowest of them; what it mostly covers comes in, what it
    /// barely reaches is nudged out. Selected, one step, named as the item is. A locked one among them
    /// leaves it all as it was, and shakes. An item for the canvas, as Turn into Subboard is: it's for
    /// the menu's shapes together, whatever their kinds.
    mutating func createFrameItem() {
        contextMenuForCanvas {
            MenuItem("Create Frame", in: FramesMenuGroup.self, when: { subject in
                let document = subject.editor.document
                return subject.shapes.contains { document[$0]?.box != nil }
            }) { ids, editor in
                editor.place(ShapeRecord(Frame()), around: ids, padding: FrameStyle.padding,
                             minimumSize: editor.registry.placement(for: Frame.kind)?.minimumSize ?? .zero)
            }
        }
    }
}
