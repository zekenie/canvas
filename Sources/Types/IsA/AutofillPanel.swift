import Canvas
import DetailPanel
import SwiftUI

// Whether a shape fills its fields from its words (`FieldFill`), in the panel, kept out of the way: one box in a section
// called Advanced, collapsed until the person opens it, at the foot of a shape of a type's Types tab, after its Fields;
// and the same at the foot of a type's Schema tab, after its JSON, saying what its shapes do unless they say otherwise
// (its `$autofill`). Where a fill is (filling, or why it failed) is the Fields' to say (`FillLine`), so folding the box
// away hides nothing that happens.

extension TypePanelText {
    /// The section the box is in, and anything else few will change.
    static let advanced = "Advanced"
    static let fillFromWords = "Fill fields from words"
    /// A type's box: what its notes do, the type itself filling nothing.
    static let notesFillFromWords = "Notes fill fields from words"
}

@MainActor
func registerAutofillPanel(into registrar: inout PluginRegistrar) {
    // A shape of a type, while its types give it fields; a type's own note fills nothing.
    registrar.forShapes(holding: AutofillProperty.self) { autofilling in
        autofilling.details {
            DetailSection<AnyShapeRecord>(TypePanelText.advanced, in: TypesTab.self, id: "autofill") { shape in
                AutofillBox(record: shape.wrappedValue, id: shape.shapeID, fill: shape.service(FieldFill.self), index: shape.service(TypeIndex.self))
            }
            .collapsedUntilOpened()
            .shownWhile { shape, context in
                shape[TypeSchemaProperty.self] == nil && context.service(FieldBook.self)?.fields(of: shape).fields.isEmpty == false
            }
        }
    }
    // A type: what its shapes do, written in its JSON as it's written in the shape.
    registrar.forShapes(holding: TypeSchemaProperty.self) { types in
        types.details {
            DetailSection<AnyShapeRecord>(TypePanelText.advanced, in: TypeSchemaTab.self, id: "type-autofill") { shape in
                AutofillBox(record: shape.wrappedValue, id: shape.shapeID, fill: shape.service(FieldFill.self), index: shape.service(TypeIndex.self))
            }
            .collapsedUntilOpened()
            .shownWhile { shape, context in
                shape[TypeSchemaProperty.self] != nil && context.service(FieldFill.self)?.holdsAutofill(shape) == true
            }
        }
    }
}

/// The box: what holds for the shape (its own say, else its types', else on), checked or not; a click says the other
/// (`FieldFill.setAutofill`, which keeps the shape's own say only where it differs from its types'). Drawn again when a
/// type says otherwise (`observeAutofills`), which is no commit to this shape.
struct AutofillBox: View {
    let record: AnyShapeRecord
    let id: ShapeID
    weak var fill: FieldFill?
    let index: TypeIndex?

    var body: some View {
        let _ = index?.observeAutofills()
        let isOn = index?.autofills(record) ?? true, isType = record[TypeSchemaProperty.self] != nil
        DetailCheckbox(isType ? TypePanelText.notesFillFromWords : TypePanelText.fillFromWords,
                       isOn: Binding(get: { isOn }, set: { [fill, id] in fill?.setAutofill($0, of: id) }))
    }
}
