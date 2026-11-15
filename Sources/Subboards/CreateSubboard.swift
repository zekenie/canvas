import Canvas
import CoreGraphics
import SlashCommands

extension CanvasEditor {
    /// Puts an untitled subboard down where these shapes are, taking them onto its board (the core's
    /// `place(_:taking:)`), in one step named "Create Subboard": a subboard's size, its top-left corner at
    /// theirs, as Turn into Subboard puts one at a frame's, in the frame they're all in, where the lowest
    /// of them was in the stack; they go onto its board where they are, with what they hold and the arrows
    /// between them. Selected; the board shown stays. A locked one that would move leaves it all as it
    /// was, and shakes.
    func createSubboard(for ids: [ShapeID]) {
        undoHistory.group("Create Subboard") {
            place(ShapeRecord(Subboard(frame: CGRect(origin: .zero, size: Subboard.defaultSize))), taking: ids)
        }
    }
}

extension PluginID {
    public static let subboardSlash: PluginID = "subboard-slash"
}

/// `/create-subboard`: a subboard made for the shapes it's typed for, holding them on its board
/// (`createSubboard(for:)`), in the command bar (the shapes selected, or every shape on the board with
/// none) or on a line of a shape's text (that shape), on the kinds whose shapes a board takes (those with a
/// box, `forShapes(adopting: .box)`), so a selection's arrow isn't among them (`2 of 3`), though one between
/// two of them goes along. It makes `SubboardsPlugin`'s kind and goes with it. A plugin value of its own so
/// that it comes after the plugins whose every-shape commands a note lists before it (Moving's):
/// `SubboardsPlugin` is among the kinds, before Titles, and a command of its plugin would head every
/// shape's list, before `title` and `lock`.
public struct SubboardSlashPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .subboardSlash }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.forShapes(adopting: .box) { boxes in
            boxes.slashCommands {
                // Never on a read-only shape, as any command that isn't a declared one: the bar lists no row
                // that can only be refused.
                SlashCommand.together("create-subboard") { ids, _, editor in editor.createSubboard(for: ids) }
            }
        }
    }
}
