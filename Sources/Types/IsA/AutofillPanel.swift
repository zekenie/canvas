import Canvas
import DetailPanel
import LanguageModels
import SwiftUI

// Whether a shape fills its fields from its words (`FieldFill`), in the panel: one box at the foot of a shape of a
// type's Types tab, after its Fields, with where its fill is under it; and the same box at the foot of a type's
// Schema tab, after its JSON, saying what its shapes do unless they say otherwise (its `$autofill`).

extension TypePanelText {
    static let fillFromWords = "Fill fields from words"
    /// A type's box: what its notes do, the type itself filling nothing.
    static let notesFillFromWords = "Notes fill fields from words"
    static let filling = "Filling fields…"
}

@MainActor
func registerAutofillPanel(into registrar: inout PluginRegistrar) {
    // A shape of a type, while its types give it fields; a type's own note fills nothing.
    registrar.forShapes(holding: AutofillProperty.self) { autofilling in
        autofilling.details {
            DetailSection<AnyShapeRecord>(in: TypesTab.self, id: "autofill") { shape in
                AutofillBox(record: shape.wrappedValue, id: shape.shapeID, fill: shape.service(FieldFill.self), index: shape.service(TypeIndex.self))
            }
            .shownWhile { shape, context in
                shape[TypeSchemaProperty.self] == nil && context.service(FieldBook.self)?.fields(of: shape).fields.isEmpty == false
            }
        }
    }
    // A type: what its shapes do, written in its JSON as it's written in the shape.
    registrar.forShapes(holding: TypeSchemaProperty.self) { types in
        types.details {
            DetailSection<AnyShapeRecord>(in: TypeSchemaTab.self, id: "type-autofill") { shape in
                AutofillBox(record: shape.wrappedValue, id: shape.shapeID, fill: shape.service(FieldFill.self), index: shape.service(TypeIndex.self))
            }
            .shownWhile { shape, context in
                shape[TypeSchemaProperty.self] != nil && context.service(FieldFill.self)?.holdsAutofill(shape) == true
            }
        }
    }
}

/// The box: what holds for the shape (its own say, else its types', else on), checked or not; a click says the other
/// (`FieldFill.setAutofill`, which keeps the shape's own say only where it differs from its types'). Drawn again when a
/// type says otherwise (`observeAutofills`), which is no commit to this shape. Under it, on a shape of a type, where its
/// fill is.
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
        if !isType, let fill {
            FillLine(status: fill.status(of: id), fill: fill, id: id)
        }
    }
}

/// Where a shape's fill is, under the box: filling, with a spinner, or why it failed, with what can be done: Retry, or
/// for want of a key Open Settings… (saving one tries again by itself); nothing for Claude declining, as it would again.
struct FillLine: View {
    let status: FieldFillStatus
    weak var fill: FieldFill?
    let id: ShapeID

    var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case .filling:
            DetailStatusLine(DetailStatus(TypePanelText.filling), isBusy: true)
        case let .failed(failure):
            DetailStatusLine(DetailStatus(failure.message, tone: .warning), actions: actions(for: failure.remedy))
        }
    }

    private func actions(for remedy: TypeSyncFailure.Remedy) -> [DetailStatusAction] {
        let id = id
        switch remedy {
        case .retry: return [DetailStatusAction(TypePanelText.retry) { [weak fill] in fill?.retry(id) }]
        case .key: return [DetailStatusAction(TypePanelText.openSettings) { AnthropicSettingsView.showSettings() }]
        case .editByHand: return []
        }
    }
}
