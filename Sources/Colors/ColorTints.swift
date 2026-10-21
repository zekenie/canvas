import AppKit
import Canvas
import Palette

/// The tint a listed shape's symbol has when the shape has a color of its own, or one it's given
/// (`InheritedColors`): its `solid`, a dynamic color that follows the appearance it's drawn in. A
/// shape drawn in its kind's default (and a shape whose name the file lacks) keeps its kind's tint,
/// so a default-yellow note is listed as it always was. Asked per row shown (`editor.tint(of:)`), so
/// it keeps nothing. The file's colors changing changes the tint of every shape that holds one of
/// them with no commit to say so, so the book's change tells the services
/// (`editor.shapeTintsDidChange()`), as a change to what's given does (`inheritedColorsDidChange()`).
@MainActor
func registerColorTints(into registrar: inout PluginRegistrar) {
    registrar.shapeTints { record, editor in editor.colors?.tint(of: record) }
}

extension ColorBook {
    /// Tells the editor's services when the file's colors change, so what lists a shape's symbol
    /// makes its tint again.
    func tellTintsOfChanges(in editor: CanvasEditor) {
        onChange { [unowned editor] in editor.shapeTintsDidChange() }
    }

    /// A listed shape's tint: its own color's `solid` where the file has it, else the given one's; nil
    /// for a shape drawn in its kind's default, or as its kind looks on its own, and for a kind with
    /// no colors.
    func tint(of record: AnyShapeRecord) -> NSColor? {
        guard editor.registry.isColorable(record.kind) else { return nil }
        if let own = record.ownColor, let tint = tint(for: own) { return tint }
        return inheritedColor(of: record.id, kind: record.kind).flatMap { tint(for: $0) }
    }
}
