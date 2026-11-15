import Canvas
import ContextMenus
import CoreGraphics
import Keyboard
import Selection
import SlashCommands
import Transform

/// Create Frame's group in a context menu: right after a transform's, before Cut, Copy and Paste.
public enum FramesMenuGroup {}
extension FramesMenuGroup: MenuGroup {
    public static var order: Order<Self> { .after(TransformMenuGroup.self) }
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

extension PluginID {
    public static let frameSlash: PluginID = "frame-slash"
}

/// `/create-frame`: Create Frame for the shapes it's typed for, one frame around them all, in the
/// command bar (the shapes selected, or every shape on the board with none) or on a line of a shape's
/// text (that shape), on the kinds a frame holds (those with a box, `forShapes(adopting: .box)`), so a
/// selection's arrow isn't among them (`2 of 3`): it stays bound to them, and the frame is around them.
/// It runs `FramesPlugin`'s Create Frame and goes with it. A plugin value of its own so that it comes
/// after the plugins whose every-shape commands a note lists before it (Moving's): `FramesPlugin` is
/// among the kinds, before Titles, and a command of its plugin would head every shape's list, before
/// `title` and `lock`.
public struct FrameSlashPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .frameSlash }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.forShapes(adopting: .box) { boxes in
            boxes.slashCommands {
                // Run as the command, not typed as it (`SlashCommand(_:command:)`): its rule takes a locked
                // shape (the menu's item shakes it), so the bar would list a row that can only be refused
                // there. Offered as any command is, never on a read-only shape.
                // Typed in the text of the shape it frames, the core puts that shape down as it places the frame.
                SlashCommand.together("create-frame") { ids, _, editor in editor.perform(.createFrame, on: ids) }
            }
        }
    }
}
