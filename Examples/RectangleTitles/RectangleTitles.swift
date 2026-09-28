import Canvas
import DetailPanel
import Rectangles
import Titles

/// The smallest bridge: gives rectangles a title Titles keeps, as a note has, though neither
/// Rectangles nor Titles knows about the other. One line opts rectangles into `TitleProperty` and
/// titles them by it: a named rectangle shows its title in a pill and names its row in the table
/// of contents, and an unnamed one has none (a title derived from what the kind keeps is
/// EllipseTitles'). A second puts the title in the detail panel's header, where a person renames
/// or clears it, as a note's (Titles contributes no header: the kind's own is its to place, and
/// Rectangles has none).
public struct RectangleTitlesPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "rectangle-titles" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.title(Rectangle.self)
        registrar.details(Rectangle.self, header: Self.header) {}
    }

    /// The panel's header: the name, renamed in place.
    static func header(_ rectangle: ShapeBinding<Rectangle>) -> TitleHeader { TitleHeader(rectangle) }
}
