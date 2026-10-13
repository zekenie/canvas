import AppKit
import Canvas
import Palette

/// The tint a listed shape's symbol has when the shape has a color of its own: its `solid`, a
/// dynamic color that follows the appearance it's drawn in. A shape with no color of its own (and
/// a shape whose name the file lacks) keeps its kind's tint, so a default-yellow note is listed as
/// it always was. Asked per row shown (`editor.tint(of:)`), so it keeps nothing. The file's colors
/// changing changes the tint of every shape that holds one of them with no commit to say so, so
/// the book's change tells the services (`editor.shapeTintsDidChange()`).
@MainActor
func registerColorTints(into registrar: inout PluginRegistrar) {
    registrar.shapeTints { record, editor in
        guard let own = record.ownColor, editor.registry.isColorable(record.kind) else { return nil }
        return editor.colors?.tint(for: own)
    }
}

extension ColorBook {
    /// Tells the editor's services when the file's colors change, so what lists a shape's symbol
    /// makes its tint again.
    func tellTintsOfChanges(in editor: CanvasEditor) {
        onChange { [unowned editor] in editor.shapeTintsDidChange() }
    }
}
