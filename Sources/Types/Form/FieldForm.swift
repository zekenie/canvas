import Canvas
import SwiftUI

// The form a card and the panel hold: a row for each field under the one it is for. `FieldFormView` is the form;
// `FieldForm` is its face in the panel.

/// What the form is for: a note's values, or a type's note: name and kind, read-only.
public enum FieldFormMode: Sendable {
    case values
    case kinds
}

@MainActor
public struct FieldFormContext {
    public enum Presentation {
        /// Under a row, over the note.
        case card
        /// In the panel: no fold, closed until opened, opens on a problem.
        case panel
    }

    public var editor: CanvasEditor
    public var shape: ShapeID
    /// The row the form is for; the form shows what is under it.
    public var path: FieldPath
    public var field: Resolved.Field
    public var kind: FieldKind
    public var mode: FieldFormMode
    public var isReadOnly: Bool
    public var presentation: Presentation
    /// `.card(key:)` in a card, `.ownRun` in the panel and the fold.
    public var step: FieldWriteStep

    public init(editor: CanvasEditor, shape: ShapeID, path: FieldPath, field: Resolved.Field, kind: FieldKind, mode: FieldFormMode,
                isReadOnly: Bool, presentation: Presentation, step: FieldWriteStep) {
        self.editor = editor
        self.shape = shape
        self.path = path
        self.field = field
        self.kind = kind
        self.mode = mode
        self.isReadOnly = isReadOnly
        self.presentation = presentation
        self.step = step
    }
}

/// The form in the panel, under a field's name, the section's full width: the SwiftUI face of `FieldFormView`
/// (AppKit, one view that draws its lines and owns its one text editor: the card hands the same view to the core).
/// It is as tall as what it holds, closed or open.
public struct FieldForm: View {
    private let context: FieldFormContext
    @State private var height: CGFloat = TypesStyle.formRowHeight

    public init(_ context: FieldFormContext) {
        self.context = context
    }

    private struct Identity: Hashable {
        var shape: ShapeID
        var path: FieldPath
        var mode: FieldFormMode
    }

    public var body: some View {
        // The form is for one note's field: another note, or another field, is a new view.
        FieldFormHost(context: context, height: $height)
            .id(Identity(shape: context.shape, path: context.path, mode: context.mode))
            .frame(height: height)
    }
}

/// Makes the form and tells it what the section hands it as that changes; the form says what height it needs a turn
/// after it changes (SwiftUI may not be told of a change in the middle of its own update).
struct FieldFormHost: NSViewRepresentable {
    let context: FieldFormContext
    @Binding var height: CGFloat

    func makeNSView(context swiftUI: Context) -> FieldFormView {
        let form = FieldFormView(context)
        listen(form)
        form.onResize?()
        return form
    }

    func updateNSView(_ form: FieldFormView, context swiftUI: Context) {
        listen(form)
        form.update(context)
    }

    private func listen(_ form: FieldFormView) {
        let height = $height
        form.onResize = { [weak form] in
            Task { @MainActor in
                guard let form, height.wrappedValue != form.contentHeight else { return }
                height.wrappedValue = form.contentHeight
            }
        }
    }
}
