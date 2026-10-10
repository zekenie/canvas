import Canvas
import SwiftUI

// The form a card and the panel hold: a row for each field under the one it is for. K0 holds only its
// shape: the summary of the row and `›`, read-only.

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

public struct FieldForm: View {
    private let context: FieldFormContext

    public init(_ context: FieldFormContext) {
        self.context = context
    }

    public var body: some View {
        Text(line)
    }

    private var line: String {
        let editor = context.editor
        guard let book = editor.fieldBook, let writer = editor.fieldWriter else { return "" }
        let types = editor.document[context.shape]?[IsAProperty.self]?.map(\.shape) ?? []
        let summary = FieldSummary.of(writer.values(of: context.shape).value(at: context.path), field: context.field, in: book, types: types)
        return summary.text + " ›"
    }
}
