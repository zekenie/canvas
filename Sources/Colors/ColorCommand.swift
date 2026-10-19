import AppKit
import Canvas
import Palette
import SlashCommands

/// `/color`'s rows: the named colors, each a chip in its color, and what is typed as a hex value.
@MainActor
enum ColorCommandRows {
    /// The row of `None`: no name or value reads as an empty text.
    static let noneID = ""

    /// A color's chip: its line color, following the appearance it's drawn in.
    static func chip(_ swatch: Swatch) -> NSColor { NSColor(swatch.solid) }
    /// What reads on its chip: white on most, black on a yellow.
    static func chipInk(_ swatch: Swatch) -> NSColor { NSColor(swatch.onSolid) }

    /// The built-in colors in one group, the file's in the next, then `None` while the shape has a
    /// color of its own.
    static func rows(for owner: ShapeID, in editor: CanvasEditor) -> [SlashChoice] {
        guard let book = editor.colors else { return [] }
        var rows = book.names.map { named in
            SlashChoice(named.name, title: named.name, group: named.isBuiltIn ? 0 : 1, chip: chip(named.swatch), chipInk: chipInk(named.swatch))
        }
        if editor.document[owner]?.ownColor != nil {
            rows.append(SlashChoice(noneID, title: ColorsStyle.none, group: 2))
        }
        return rows
    }

    /// For text that reads as a hex value, a row titled with the value as it is stored.
    static func valueRow(typed: String, in editor: CanvasEditor) -> SlashChoice? {
        guard case .value(let value)? = ShapeColor(typed), let book = editor.colors,
              let swatch = book.swatch(for: .value(value)) else { return nil }
        let text = ShapeColor.value(value).text
        return SlashChoice(text, title: text, chip: chip(swatch), chipInk: chipInk(swatch))
    }
}

/// `/color`, on the kinds that have colors (`scope`): a list of the named colors, each row a chip in
/// its color, and a typed hex value as a row of its own. `None` is in the list while the shape has a
/// color of its own. A pick runs at once ("Change Color"). A read-only shape is offered nothing.
@MainActor
func registerColorCommand(into scope: inout ScopedRegistrar) {
    scope.slashCommands {
        SlashCommand("color", argument: ColorsStyle.colorArgument,
                     choices: { owner, editor in ColorCommandRows.rows(for: owner, in: editor) },
                     otherwise: { typed, _, editor in ColorCommandRows.valueRow(typed: typed, in: editor) },
                     step: ColorsStyle.changeColor) { owner, choice, editor in
            editor.setColor(ShapeColor(choice.id), of: [owner])
        }
    }
}
