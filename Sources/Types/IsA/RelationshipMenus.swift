import AppKit
import Canvas
import Foundation

/// The list at an arrow a port's release opened: the relationship types that fit it, the taken ones first and the
/// open ones after, a rule, and a gray `Plain arrow` that leaves it as drawn. A pick is `setRelationshipType`, its own
/// undo step ("Add Type"), a step after the press's "Add Arrow": one Undo returns to the plain arrow.
@MainActor
enum RelationshipMenus {
    /// The menu for `connection`, nil with nothing to list. Each type is its name (`Untitled` for one with none) after
    /// a small arrow in its color. What a row does is asked again when it is picked: an arrow deleted, or typed some other
    /// way, in the meantime, is left alone.
    static func menu(taken: [ShapeID], open: [ShapeID], for connection: ShapeID, in editor: CanvasEditor) -> NSMenu? {
        guard let types = editor.types, !(taken + open).isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ title: String, image: NSImage? = nil, color: NSColor? = nil, _ run: @escaping @MainActor () -> Void) {
            let action = TypeMenuAction(run)
            let item = NSMenuItem(title: title, action: #selector(TypeMenuAction.fire), keyEquivalent: "")
            item.target = action
            item.representedObject = action          // the item holds its target weakly
            item.image = image
            if let color { item.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: color]) }
            menu.addItem(item)
        }
        func symbol(for type: ShapeID) -> NSImage? {
            let image = NSImage(systemSymbolName: TypesStyle.relationshipTypeSymbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [types.look(of: type).row]))
            return image
        }
        func add(_ type: ShapeID) {
            item(TypesStyle.menuName(types.name(of: TypeLink(type))), image: symbol(for: type)) { [weak editor] in
                guard let editor, (editor.shape(inFile: connection)?[IsAProperty.self] ?? []).isEmpty else { return }
                editor.setRelationshipType(type, of: [connection])
            }
        }
        for type in taken { add(type) }
        if !taken.isEmpty, !open.isEmpty { menu.addItem(.separator()) }
        for type in open { add(type) }
        menu.addItem(.separator())
        item(TypesStyle.plainArrow, color: .secondaryLabelColor) {}
        return menu
    }
}
