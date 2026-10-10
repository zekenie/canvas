import Canvas

/// What a palette tool offers and what was chosen from its menu: a list a test changes between
/// two opens of the menu.
@MainActor
public final class Palette {
    public var colors: [String]
    /// What was chosen, in order.
    public var chosen: [String] = []
    /// How many times the menu was asked for.
    public var asked = 0
    public nonisolated init(_ colors: [String] = ["Red", "Green"]) { self.colors = colors }
}

/// Two tools that make no shape: "palette", with a menu on its segment (a line a color in the
/// `Palette`, the last chosen checked, a separator and a dimmed line), and "stamp", registered with
/// `placesShapes`, so it is dimmed where a placing tool is. For tests of tool menus, with no vertical.
public struct PalettePlugin: CanvasPlugin {
    public static let palette: ToolID = "palette"
    public static let stamp: ToolID = "stamp"

    let colors: Palette
    public init(_ colors: Palette = Palette()) { self.colors = colors }
    public var id: PluginID { "palettes" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.tool(ToolDescriptor(id: Self.palette, label: "Palette", systemImage: "paintpalette")) { _ in PaletteTool() }
        registrar.tool(ToolDescriptor(id: Self.stamp, label: "Stamp", systemImage: "seal"), placesShapes: true) { _ in PaletteTool() }
        let colors = colors
        registrar.toolMenu(for: Self.palette) { _ in
            colors.asked += 1
            return colors.colors.map { color in
                ToolMenuEntry.item(ToolMenuItem(color, systemImage: "circle", isChecked: colors.chosen.last == color) { _ in colors.chosen.append(color) })
            } + [.separator, .item(ToolMenuItem("Unavailable", isEnabled: false) { _ in colors.chosen.append("Unavailable") })]
        }
    }
}

@MainActor
final class PaletteTool {}

extension PaletteTool: Tool {
    func pointerDown(_ pointer: Pointer, in editor: CanvasEditor) {}
}
