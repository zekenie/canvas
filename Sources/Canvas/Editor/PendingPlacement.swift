import CoreGraphics

/// Shapes about to be placed together (`editor.placeLater(_:)`): records on no board yet, and where each
/// goes for the keys held. Until a press puts them down, the editor draws them faint where it would put
/// them: at the pointer while it's over the canvas, else with their bounds in the middle of the view's
/// clear part, where Return puts them (`placeAtKeyboard`).
public struct PendingPlacement {
    /// What is put down, in this order: records of box kinds, their ids new to the file.
    public let records: [AnyShapeRecord]
    /// The step putting them down makes ("Add Notes").
    public let stepName: String
    /// Where each record's box goes for the keys held: its top-left corner from the point they're put down
    /// at, one a record, in order.
    let arrange: @MainActor (Modifiers) -> [CGPoint]

    /// `arrange` says, for the keys held (⌥ may lay them out another way), where each record's box goes:
    /// its top-left corner from the point they're put down at (the pointer, or the press), one a record.
    public init(_ records: [AnyShapeRecord], stepName: String, arrange: @escaping @MainActor (Modifiers) -> [CGPoint]) {
        self.records = records
        self.stepName = stepName
        self.arrange = arrange
    }

    /// The records with their boxes where they go for `modifiers`, put down at `point` (world units).
    @MainActor func records(at point: CGPoint, for modifiers: Modifiers) -> [AnyShapeRecord] {
        let corners = arrange(modifiers)
        assert(corners.count == records.count, "a pending placement says where each of its records goes")
        return zip(records, corners).map { record, corner in
            var placed = record
            if let box = record.box { placed.box = CGRect(origin: CGPoint(x: point.x + corner.x, y: point.y + corner.y), size: box.size) }
            return placed
        }
    }

    /// The box around them all for `modifiers`, put down at the origin; null for none with a box.
    @MainActor func bounds(for modifiers: Modifiers) -> CGRect {
        records(at: .zero, for: modifiers).compactMap(\.box).reduce(CGRect.null) { $0.union($1) }
    }
}

/// The core's tool while shapes wait to be placed (`ToolID.pendingPlacement`): no toolbar lists it, so
/// none is shown picked. The pointer moving and the keys held draw them again where they would land; a
/// press puts them down there (`putPending`); Escape leaves it, as it leaves any tool, and they go.
@MainActor
final class PendingPlacementTool {}

extension PendingPlacementTool: Tool {
    func pointerDown(_ pointer: Pointer, in editor: CanvasEditor) { editor.putPending(pressedAt: pointer.world) }
    func pointerMoved(_ pointer: Pointer, in editor: CanvasEditor) { editor.setNeedsDisplay() }
    func pointerExited(in editor: CanvasEditor) { editor.setNeedsDisplay() }
    func modifiersChanged(_ modifiers: Modifiers, in editor: CanvasEditor) { editor.setNeedsDisplay() }
}
