import Canvas
import CoreGraphics

/// A box kind whose shapes are as wide as what they hold reads whole at rest (a table's columns, an enum's values, each its
/// line's width): one `canvas draw` writes (made, or a value of it set) at no size the statement gives is made that wide where
/// it is narrower, never narrower, as a commit of its rows makes it (LineRows' `widening`), so what an agent draws reads as what a
/// person types. Conform in an extension.
public protocol DrawnWhole: ShapeDefinition {
    /// How wide `shape` is for what it holds to read whole, over `context` (the board as the run leaves it); nil for no width of
    /// its own.
    func wholeWidth(of shape: ShapeRecord<Props>, in context: ShapeContext) -> CGFloat?
}

extension DrawnWhole {
    func erasedWholeWidth(of record: AnyShapeRecord, in context: ShapeContext) -> CGFloat? {
        record.typed(as: Props.self).flatMap { wholeWidth(of: $0, in: context) }
    }
}

extension Registry {
    /// `record` as wide as its kind says what it holds reads whole (`DrawnWhole`), where it's narrower; as it is otherwise.
    @MainActor func drawnWhole(_ record: AnyShapeRecord, in context: ShapeContext) -> AnyShapeRecord {
        guard let kind = definition(for: record.kind) as? any DrawnWhole, var box = record.box,
              let width = kind.erasedWholeWidth(of: record, in: context)?.rounded(.up), width > box.width else { return record }
        box.size.width = width
        var wider = record
        wider.box = box
        return wider
    }
}
