import Canvas
import ContextMenus

/// The built-in colors in Color ▸, then a line, the file's, a line, and `None`, in the order the
/// submenu lists them.
enum ColorBuiltInMenuGroup {}
extension ColorBuiltInMenuGroup: MenuGroup {}
enum ColorFileMenuGroup {}
extension ColorFileMenuGroup: MenuGroup {}
enum ColorNoneMenuGroup {}
extension ColorNoneMenuGroup: MenuGroup {}

/// The color every shape has as its own: `.some(nil)` when none has one, nil when they differ.
private func agreed(_ owns: [ShapeColor?]) -> ShapeColor?? {
    if owns.dropFirst().allSatisfy({ $0 == owns[0] }) { return .some(owns[0]) }
    return nil
}

/// Color ▸ in the menu of every selection whose shapes all have colors (`scope`), beside Lock (`StateMenuGroup`):
/// the built-in colors by name, a line, the file's, a line, and None; a check by the color every
/// selected shape has as its own (none, when they differ; None, when no shape has one). Choosing
/// one colors the whole selection in one step ("Change Color"). Never dimmed: a read-only shape is
/// refused by the core and shakes, while the rest of the selection changes. Items are plain titles:
/// `MenuItem` shows no image.
@MainActor
func registerColorMenu(into scope: inout ScopedRegistrar) {
    scope.contextMenuForCanvas {
        MenuItems(in: StateMenuGroup.self, id: "color") { subject in
            let editor = subject.editor
            let records = subject.shapes.compactMap { editor.document[$0] }
            if let book = editor.colors, !records.isEmpty, records.count == subject.shapes.count {
                let owns = records.map { $0.ownColor.map { book.canonical($0) ?? $0 } }
                let common = agreed(owns)
                Submenu(ColorsStyle.color, in: StateMenuGroup.self, id: "color") {
                    for named in book.names {
                        let color = named.color
                        let title = named.title
                        if named.isBuiltIn {
                            MenuItem(title, in: ColorBuiltInMenuGroup.self, id: named.name, isChecked: { _ in common == .some(color) },
                                     stepName: ColorsStyle.changeColor) { ids, editor in editor.setColor(color, of: ids) }
                        } else {
                            MenuItem(title, in: ColorFileMenuGroup.self, id: named.name, isChecked: { _ in common == .some(color) },
                                     stepName: ColorsStyle.changeColor) { ids, editor in editor.setColor(color, of: ids) }
                        }
                    }
                    MenuItem(ColorsStyle.none, in: ColorNoneMenuGroup.self, id: "none", isChecked: { _ in common == .some(nil) },
                             stepName: ColorsStyle.changeColor) { ids, editor in editor.setColor(nil, of: ids) }
                }
            }
        }
    }
}
