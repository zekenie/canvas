import Canvas
import ContextMenus

// Open Fields: the cards a click opens on a relationship, by keys. On an arrow of a relationship type that has fields it opens
// the arrow's card (what a click on its chip opens); on a relationship type's pill, the card that defines it, at its name (what a
// click on the pill opens), and nothing where that card is open already. One command, so the selection's menu (the Shape menu) has it and every surface runs the same thing.
// It names no kind: an arrow is a shape of a kind that relates (`registry.relates`), a pill a shape holding the mark.

extension CanvasCommand {
    /// Open Fields: the only selected shape's relationship card.
    public static let openFields: CanvasCommand = "openFields"
}

extension TypesStyle {
    /// The command's title.
    public static let openFields = "Open Fields"
}

/// What Open Fields opens for a shape: nil where it opens nothing.
enum FieldsTarget: Equatable {
    /// An arrow whose relationship types give it fields.
    case arrow(ShapeID)
    /// A relationship type drawn as a pill.
    case definition(ShapeID)

    @MainActor
    static func of(_ shapes: [ShapeID], in editor: CanvasEditor) -> FieldsTarget? {
        guard shapes.count == 1, let id = shapes.first, let record = editor.document[id], let relationships = editor.relationships else { return nil }
        if editor.registry.relates(record.kind) {
            let types = (record[IsAProperty.self] ?? []).map(\.shape).filter { relationships.graph.isRelationshipType($0) }
            guard !types.isEmpty, editor.fieldBook?.fields(types: types).fields.isEmpty == false else { return nil }
            return .arrow(id)
        }
        if record[TypeSchemaProperty.self] != nil, record[RelationshipProperty.self] == true, editor.rowBook?.pill(of: id) != nil {
            return .definition(id)
        }
        return nil
    }

    /// Whether the card is showing already: the command opens it, and a card opened asks to be closed (a click on the row of
    /// an open card), so the command leaves it be.
    @MainActor
    func isOpen(in editor: CanvasEditor) -> Bool {
        switch self {
        case .arrow(let id): editor.fieldCards?.openTarget.map { $0.shape == id && $0.target == .shape } ?? false
        case .definition(let id): editor.definitionCards?.openType == id
        }
    }
}

@MainActor
func registerFieldsCommand(into registrar: inout PluginRegistrar) {
    registrar.command(.openFields, title: TypesStyle.openFields, runs: .whenIdle,
                      isEnabled: { subject in
                          guard let target = FieldsTarget.of(subject.shapes, in: subject.editor) else { return false }
                          return !target.isOpen(in: subject.editor)
                      }) { subject in
        switch FieldsTarget.of(subject.shapes, in: subject.editor) {
        case .arrow(let arrow)?: subject.editor.openRelationshipCard(for: arrow)
        case .definition(let type)?: subject.editor.definitionCards?.open(type, focus: .title)
        case nil: break
        }
    }
    registrar.contextMenuForCanvas { MenuItem(command: .openFields) }
}
