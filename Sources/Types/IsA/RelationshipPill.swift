import Adornments
import AppKit
import Canvas
import Connections
import Foundation
import Selection

// The pill between two notes: where an arrow of a relationship type has its label, a pill in the type's color, tinted, in the
// line's cut, reads the type's name and the first value the arrow holds (`owner · 2021`), and the name alone when nothing is
// filled. It is the adornment at a label's lead (`AdornmentPlacement.inLabelLead`, Adornments'): the arrow's geometry leaves it
// room and the words, if it has any, come after it. A click on it opens the arrow's card, hung from the pill (a type with
// no fields: the chip's menu). Where the line is too short for the name and the value it says the name, then it is a dot. A
// misfit's is red with a wave, as the chip above was. A plain arrow between two notes that a relationship type fits, when it
// is the only shape selected, has the same place held by a dashed empty pill (`RelationshipOfferPill`): a click lists the types
// that fit, as a port's release lists them.

/// The pill that leads the label of an arrow of a relationship type.
public enum RelationshipPill {}

extension RelationshipPill: Adornment {
    public static var placement: AdornmentPlacement { .inLabelLead }
}

extension RelationshipPill: ClickableAdornment {
    public static var partRole: PartRole { .menuButton }

    public static func click(_ click: AdornmentClick, in editor: CanvasEditor) {
        if TypeChips.opensCard(click, in: editor) { return }
        guard let menu = TypeChipMenus.menu(for: click, in: editor) else { return }
        editor.popUpMenu(menu, below: click.rect)
    }
}

extension TypesStyle {
    /// The longest the value a pill reads is, in characters: past it, it ends in an ellipsis.
    static let pillValueLimit = 24
}

extension RelationshipPill {
    /// The relationship type an arrow's pill is: the first of its types that is one.
    @MainActor
    static func link(of shape: AnyShapeRecord, in context: AdornmentContext) -> TypeLink? {
        guard !(shape[IsAProperty.self] ?? []).isEmpty, context.registry.relates(shape.kind),
              let relationships = context.service(RelationshipIndex.self) else { return nil }
        return shape[IsAProperty.self]?.first { relationships.graph.isRelationshipType($0.shape) }
    }

    /// The pill an arrow has: its type's name in the type's tint, after it the first value the arrow holds for the
    /// fields of its types, in their order, as a row reads it; red with a wave while the check calls an end a misfit.
    /// The faces it may take instead, widest first: the name alone, then a dot.
    @MainActor
    static func label(of shape: AnyShapeRecord, in context: AdornmentContext) -> AdornmentLabel? {
        guard let link = link(of: shape, in: context), let types = context.service(TypeIndex.self) else { return nil }
        let tag = AdornmentTag(link.shape)
        let isWrong = context.service(RelationshipHooks.self)?.tone(shape.id) == .wrong
        let name = isWrong ? TypeChips.label(for: link, in: types).wrong() : TypeChips.label(for: link, in: types)
        var dot = AdornmentLabel.mark(.dot).tinted(types.look(of: link.shape).light).tagged(tag)
        if isWrong { dot = dot.wrong() }
        guard let value = context.service(FieldBook.self).flatMap({ firstValue(of: shape, in: $0) }) else {
            return name.narrowing(to: [dot])
        }
        return name.noted(value).narrowing(to: [name, dot])
    }

    /// The first value the arrow holds, as its row says it, for the fields its types give it in their order; nil when
    /// none is filled. Cut to `TypesStyle.pillValueLimit` characters.
    @MainActor
    static func firstValue(of shape: AnyShapeRecord, in book: FieldBook) -> String? {
        guard let values = shape[FieldValuesProperty.self], !values.isEmpty else { return nil }
        let types = shape[IsAProperty.self]?.map(\.shape) ?? []
        for field in book.fields(types: types).fields {
            guard let value = values[field.field.name] else { continue }
            let summary = FieldSummary.of(value, field: field, in: book, types: types)
            if case .empty = summary { continue }
            let text = summary.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !text.isEmpty else { continue }
            return text.count > TypesStyle.pillValueLimit ? String(text.prefix(TypesStyle.pillValueLimit - 1)) + "…" : text
        }
        return nil
    }
}

/// The dashed empty pill a selected plain arrow shows where a relationship type fits it.
public enum RelationshipOfferPill {}

extension RelationshipOfferPill: Adornment {
    public static var placement: AdornmentPlacement { .inLabelLead }
    /// After the pill of a relationship type, which takes the lead where both would show.
    public static var order: Order<Self> { .after(RelationshipPill.self) }
}

extension RelationshipOfferPill: ClickableAdornment {
    public static var partRole: PartRole { .menuButton }

    /// A click lists the types that fit, as a port's release lists them, under the pill: a pick types the arrow.
    public static func click(_ click: AdornmentClick, in editor: CanvasEditor) {
        guard let offers = editor.service(RelationshipOffers.self), let (taken, open) = offers.fitting(click.shape) else { return }
        let choices = RelationshipMenus.choices(taken: taken, open: open, for: click.shape, in: editor)
        guard !choices.isEmpty else { return }
        editor.presentConnectionChoices([choices], for: click.shape, below: click.rect)
    }
}

/// Which arrow, if any, is the only shape selected, so the offer's pill is where it is asked for: Selection tells it when
/// the selection changes (`registrar.selectionChanged`), and it tells Adornments for the shape that left and the shape that
/// came; and it says which types fit an arrow now.
@MainActor
final class RelationshipOffers {
    private unowned let editor: CanvasEditor
    /// The only selected shape.
    private(set) var subject: ShapeID?

    init(editor: CanvasEditor) {
        self.editor = editor
        subject = editor.selection
        // What fits the arrow changes with the file's relationship types (one made, renamed, deleted, an end drawn), with no
        // commit to the arrow: its pill is made again.
        editor.relationships?.onChange { [weak self] _ in self?.relationshipsChanged() }
    }

    /// The relationship types changed: the selected arrow's offer is asked again.
    private func relationshipsChanged() {
        guard let subject, editor.document[subject].map({ editor.registry.relates($0.kind) }) == true else { return }
        editor.adornmentsDidChange(for: [subject])
    }

    /// The selection changed: the arrows it left and took are made again.
    func selectionChanged() {
        let next = editor.selection
        guard next != subject else { return }
        let changed = Set([subject, next].compactMap { $0 }.filter { editor.document[$0].map { editor.registry.relates($0.kind) } ?? false })
        subject = next
        if !changed.isEmpty { editor.adornmentsDidChange(for: changed) }
    }

    /// The types that fit an arrow, the taken ones and the open ones, when it is a plain arrow of a kind that relates, bound at
    /// both ends to notes (neither a type, nor a relationship type) and a type fits; nil otherwise.
    func fitting(_ id: ShapeID) -> (taken: [ShapeID], open: [ShapeID])? {
        guard let relationships = editor.relationships, let record = editor.shape(inFile: id), editor.registry.relates(record.kind),
              (record[IsAProperty.self] ?? []).isEmpty, let subjects = relationships.subjects(of: id) else { return nil }
        let from = subjects.from.literal.flatMap { editor.shape(inFile: $0) }, to = subjects.to.literal.flatMap { editor.shape(inFile: $0) }
        guard case .notes = ArrowRole.of(from: from, to: to, registry: editor.registry), from != nil, to != nil else { return nil }
        let (taken, open) = relationships.graph.fitting(from: subjects.from.reading, to: subjects.to.reading)
        return taken.isEmpty && open.isEmpty ? nil : (taken, open)
    }

    /// Whether the offer's pill is shown on this arrow now: it is the only selected shape and a type fits it.
    func offers(_ id: ShapeID) -> Bool { subject == id && fitting(id) != nil }
}

extension RelationshipOffers: EditorService {}

@MainActor
func registerRelationshipPills(into registrar: inout PluginRegistrar) {
    registrar.service { RelationshipOffers(editor: $0) }
    registrar.selectionChanged { editor, _, _ in editor.service(RelationshipOffers.self)?.selectionChanged() }
    registrar.forShapes(holding: IsAProperty.self) { typeable in
        typeable.adornment(RelationshipPill.self) { shape, context in
            RelationshipPill.label(of: shape, in: context)
        }
        typeable.adornment(RelationshipOfferPill.self) { shape, context in
            guard let offers = context.service(RelationshipOffers.self), offers.offers(shape.id) else { return nil }
            return AdornmentLabel.mark(.ghost).tagged(AdornmentTag(shape.id))
        }
    }
}
