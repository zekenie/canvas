import Adornments
import AppKit
import Canvas
import Foundation
import Selection
import Titles

/// A shape's types, as chips in the row above its top-left corner, after its title's pill: one chip
/// for each type it is, in the order of its list, each light, in its type's color, with its type's
/// live title (gray and dimmed "Untitled" for a type with none; a dashed one, in italic, gray, for a
/// type that is gone, with the last title it was known by; a deleted type brought back by undo is
/// whole again), and the ones that don't fit whole folded into one "+N" chip. A type's note shows its
/// own pill (Titles', solid in its color) and then the chips of the types it builds on. A click on a
/// chip opens a small menu below it: for a type it is, Go to it and Remove it (Remove left out while
/// the shape can't change); for "+N", the same for every type it is. On the kinds that hold `is`; on
/// an arrow the row sits above its label (Adornments' anchor), and nothing is shown on a shape drawn
/// as a skeleton.
///
/// On an arrow of a relationship type the chip is the relationship's: it says after its name how many fields the type gives
/// the arrow (`friendship 2`, none for a type with none), whose values are never shown on the board; a click on the chip
/// of a relationship type that has fields opens the arrow's card (`RelationshipHooks.openCard`, Form's) with the arrow
/// selected, and the menu is for the rest; and while the check calls an end of the arrow a misfit
/// (`RelationshipHooks.tone`, the check's) the chip is red with a wave, and plain where there is no check.
public enum TypeChips {}

extension TypeChips: Adornment {
    public static var placement: AdornmentPlacement { .aboveTopLeft }
    /// Right after a title's pill: what a shape is called, then what it is.
    public static var order: Order<Self> { .after(TitlePill.self) }
}

extension TypeChips: ClickableAdornment {
    public static var partRole: PartRole { .menuButton }

    public static func click(_ click: AdornmentClick, in editor: CanvasEditor) {
        if opensCard(click, in: editor) { return }
        guard let menu = TypeChipMenus.menu(for: click, in: editor) else { return }
        editor.popUpMenu(menu, below: click.rect)
    }
}

extension TypeChips {
    /// Whether a click on a chip opens the arrow's card, which it did when it answers true: the chip of a relationship
    /// type, on a shape of a kind that relates (an arrow), and the card has fields to show.
    @MainActor
    static func opensCard(_ click: AdornmentClick, in editor: CanvasEditor) -> Bool {
        guard !click.isOverflow, let raw = click.tag.flatMap({ UUID(uuidString: $0.raw) }),
              let relationships = editor.relationships, relationships.graph.isRelationshipType(ShapeID(raw)),
              let record = editor.shape(inFile: click.shape), editor.registry.relates(record.kind),
              let hooks = editor.service(RelationshipHooks.self) else { return false }
        return hooks.openCard(click.shape)
    }

    /// How many fields a relationship type gives an arrow of it (its own and those of the types it builds on), nil for
    /// none: what its chip's number says. The values are in the arrow's card, which a click on the chip opens.
    @MainActor
    static func fieldCount(of type: ShapeID, in book: FieldBook) -> Int? {
        let count = book.fields(types: [type]).fields.count
        return count > 0 ? count : nil
    }

    /// The chip for one type a shape is.
    @MainActor
    static func label(for link: TypeLink, in types: TypeIndex) -> AdornmentLabel {
        let tag = AdornmentTag(link.shape)
        switch types.name(of: link) {
        case .live(let title?): return AdornmentLabel(title).tagged(tag).tinted(types.look(of: link.shape).light)
        case .live(nil): return AdornmentLabel(placeholder: TypesStyle.untitledType).tagged(tag)
        case .missing(let lastKnown): return AdornmentLabel(lastKnown ?? TypesStyle.deletedType).missing().tagged(tag)
        }
    }
}

@MainActor
func registerTypeChips(into registrar: inout PluginRegistrar) {
    registrar.forShapes(holding: IsAProperty.self) { typeable in
        typeable.adornments(TypeChips.self) { shape, context in
            guard let types = context.service(TypeIndex.self) else { return [] }
            // A relationship type is a pill, drawn alone: it shows no chip above it.
            if shape[RelationshipProperty.self] == true, shape[TypeSchemaProperty.self] != nil { return [] }
            let links = shape[IsAProperty.self] ?? []
            // On an arrow, a relationship type's chip says how many fields it gives the arrow, and turns red with a wave while an
            // end of it is a misfit; any other chip is as it was.
            let relates = !links.isEmpty && context.registry.relates(shape.kind)
            let relationships = relates ? context.service(RelationshipIndex.self) : nil
            let isWrong = relationships != nil && context.service(RelationshipHooks.self)?.tone(shape.id) == .wrong
            let book = relationships != nil ? context.service(FieldBook.self) : nil
            // The first relationship type of an arrow is its pill, in the lead of its label (`RelationshipPill`), not a chip.
            let leads = relationships.flatMap { _ in RelationshipPill.link(of: shape, in: context) }?.shape
            return links.filter { $0.shape != leads }.map { link in
                let label = TypeChips.label(for: link, in: types)
                guard let relationships, relationships.graph.isRelationshipType(link.shape) else { return label }
                let counted = label.counted(book.flatMap { TypeChips.fieldCount(of: link.shape, in: $0) })
                return isWrong ? counted.wrong() : counted
            }
        }
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
        func add(_ title: String, _ run: @escaping @MainActor () -> Void) { menu.addItem(NSMenuItem(title: title, run: run)) }
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
        } else if let raw = click.tag.flatMap({ UUID(uuidString: $0.raw) }) {
            items(for: TypeLink(ShapeID(raw)))
        }
        return menu.items.isEmpty ? nil : menu
    }
}
