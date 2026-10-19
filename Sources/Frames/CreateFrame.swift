import Canvas
import ContextMenus
import CoreGraphics
import Keyboard
import Selection

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

extension CanvasCommand {
    /// Create Frame, ⇧⌘F: a frame around the selection (tldraw's ⌥⌘G is Group's here).
    public static let createFrame: CanvasCommand = "createFrame"
}

extension CanvasEditor {
    /// Puts a frame down around these shapes (see `createFrameItem`), in one step named "Create Frame".
    func createFrame(around ids: [ShapeID]) {
        undoHistory.group("Create Frame") {
            place(ShapeRecord(Frame()), around: ids, padding: FrameStyle.padding,
                  minimumSize: registry.placement(for: Frame.kind)?.minimumSize ?? .zero)
        }
    }
}

extension PluginRegistrar {
    /// Create Frame, in the menu of any shapes a frame can hold (those with a box: an arrow alone has
    /// none) and on ⇧⌘F, one command (`.createFrame`) that both run on their shapes: a frame around
    /// them, holding them, put down by the core (`place(_:around:)`), reaching
    /// `FrameStyle.padding` past them and never under its placement's `minimumSize` where the frame they're all in
    /// has room, in that frame, just below the lowest of them; what it mostly covers comes in, what it
    /// barely reaches is nudged out. Selected, one step, named as the item is. A locked one among them
    /// leaves it all as it was, and shakes. An item for the canvas, as Turn into Subboard is: it's for
    /// the menu's shapes together, whatever their kinds. Never mid-press or while a shape is edited.
    mutating func createFrameItem() {
        command(.createFrame, title: "Create Frame", shortcut: KeyChord("f", [.command, .shift]), runs: .whenIdle,
                isEnabled: { subject in
                    let document = subject.editor.document
                    return subject.shapes.contains { document[$0]?.box != nil }
                }) { $0.editor.createFrame(around: $0.shapes) }
        contextMenuForCanvas {
            MenuItem(command: .createFrame, in: FramesMenuGroup.self)
        }
    }
}
