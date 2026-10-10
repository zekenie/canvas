import Canvas

// The check's service. K0 holds only its shape: it answers clean, and keeps `typing`. The real one keeps
// the answer for each shape, from the schema and the values, and tells Validation.

@MainActor
public final class FieldChecks {
    private weak var editor: CanvasEditor?

    public init(editor: CanvasEditor) {
        self.editor = editor
    }

    /// The answer for a shape, with `typing` left out. Reading it from a view tracks `revision`.
    public func check(of record: AnyShapeRecord) -> FieldCheck { .clean }

    /// Set by whoever has the caret in a field (a row, a card's cell, a panel's box) when it gets it, and
    /// nil when it leaves: one at a time, and only whoever set it clears it. The field being typed in is
    /// left out of every read, so what is half typed is never red.
    public var typing: (shape: ShapeID, path: FieldPath)? {
        didSet {
            revision += 1
            editor?.setNeedsDisplay()
        }
    }

    /// Moves when any answer or `typing` changes.
    public private(set) var revision = 0
}

extension FieldChecks: EditorService {
    /// It keeps nothing per shape or per board, so a switch needs no change set (the default works one out).
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {}
}

extension CanvasEditor {
    /// What the check says of a shape's values (`FieldChecks`); nil without TypesPlugin.
    public var fieldChecks: FieldChecks? { service(FieldChecks.self) }
}
