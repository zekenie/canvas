import Adornments
import AppKit
import Canvas
import Foundation
import Selection

/// A shape's types, as chips in the row above its top-left corner, after its title's pill: "Type" on
/// a type, and one chip for each type it is, in the order of its list, each its type's live title (a
/// dashed one, in italic, for a type that is gone, with the last title it was known by; a deleted
/// type brought back by undo is whole again), and the ones that don't fit whole folded into one "+N"
/// chip. A click on a chip opens a small menu below it: for a type it is, Go to it and Remove it
/// (Remove left out while the shape can't change); for the Type chip, Remove Type; for "+N", the
/// same for every type it is. On the kinds that hold `is` or a schema; on an arrow the row sits above
/// its label (Adornments' anchor), and nothing is shown on a shape drawn as a skeleton.
public enum TypeChips {}

extension TypeChips: Adornment {
    public static var placement: AdornmentPlacement { .aboveTopLeft }
    /// After a title's pill (a horizontal's feature, 50), before the states that come and go (300).
    public static var order: Int { 100 }
}

extension TypeChips: ClickableAdornment {
    public static func click(_ click: AdornmentClick, in editor: CanvasEditor) {
        guard let menu = TypeChipMenus.menu(for: click, in: editor) else { return }
        editor.popUpMenu(menu, below: click.rect)
    }
}

extension TypeChips {
    /// The tag of the Type chip: no shape's id is this.
    static let typeMark = AdornmentTag("type")

    /// The chip for one type a shape is.
    @MainActor
    static func label(for link: TypeLink, in types: TypeIndex) -> AdornmentLabel {
        let tag = AdornmentTag(link.shape)
        switch types.name(of: link) {
        case .live(let title?): return AdornmentLabel(title).tagged(tag)
        case .live(nil): return AdornmentLabel(placeholder: TypesStyle.untitledType).tagged(tag)
        case .missing(let lastKnown): return AdornmentLabel(lastKnown ?? TypesStyle.deletedType).missing().tagged(tag)
        }
    }
}

@MainActor
func registerTypeChips(into registrar: inout PluginRegistrar) {
    registrar.adornmentsForEveryShape(TypeChips.self, where: { $0.holds(IsAProperty.self) || $0.holds(TypeSchemaProperty.self) }) { shape, context in
        guard let types = context.service(TypeIndex.self) else { return [] }
        var labels: [AdornmentLabel] = []
        if shape[TypeSchemaProperty.self] != nil { labels.append(AdornmentLabel(TypesStyle.typeChip).tagged(TypeChips.typeMark)) }
        for link in shape[IsAProperty.self] ?? [] { labels.append(TypeChips.label(for: link, in: types)) }
        return labels
    }
}

// MARK: The menus

/// What a click on a chip opens, built as it's asked: each item runs one editor call.
@MainActor
enum TypeChipMenus {
    /// The menu for a click on one of `click.shape`'s chips, nil when there's nothing to offer.
    static func menu(for click: AdornmentClick, in editor: CanvasEditor) -> NSMenu? {
        guard let types = editor.types, let record = editor.shape(inFile: click.shape) else { return nil }
        let owner = click.shape, readOnly = editor.isReadOnly(inFile: owner)
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ run: @escaping @MainActor () -> Void) {
            let action = TypeMenuAction(run)
            let item = NSMenuItem(title: title, action: #selector(TypeMenuAction.fire), keyEquivalent: "")
            item.target = action
            item.representedObject = action          // the item holds its target weakly
            menu.addItem(item)
        }
        func items(for link: TypeLink) {
            let name = TypesStyle.menuName(types.name(of: link))
            let type = link.shape
            if editor.file.record(type) != nil { add(TypesStyle.goTo(name)) { [weak editor] in editor?.goTo([type]) } }
            if !readOnly { add(TypesStyle.remove(name)) { [weak editor] in editor?.removeTypeLink(type, from: owner) } }
        }
        if click.isOverflow {
            for link in record[IsAProperty.self] ?? [] {
                if !menu.items.isEmpty { menu.addItem(.separator()) }
                items(for: link)
            }
        } else if click.tag == TypeChips.typeMark {
            if !readOnly { add(TypesStyle.removeType) { [weak editor] in editor?.removeType(owner) } }
        } else if let raw = click.tag.flatMap({ UUID(uuidString: $0.raw) }) {
            items(for: TypeLink(ShapeID(raw)))
        }
        return menu.items.isEmpty ? nil : menu
    }
}

/// What a menu item runs: its target, kept alive as its `representedObject`. The item stays a plain
/// NSMenuItem, since AppKit may copy one through initializers a subclass wouldn't inherit.
final class TypeMenuAction: NSObject {
    private let run: @MainActor () -> Void

    init(_ run: @escaping @MainActor () -> Void) { self.run = run }

    /// AppKit sends menu actions on the main thread.
    @MainActor @objc func fire() { run() }
}
