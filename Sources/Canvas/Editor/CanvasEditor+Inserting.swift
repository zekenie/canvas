import CoreGraphics
import Geometry

// Insert: a shape of what a placing tool places, put down with no pointer and no tool picked, beside
// the selection or somewhere clear in the middle of the view. Every tool that places a shape has its
// item in the Insert menu (`ShapeRegistrar.tool(placing:)` declares it), so a new kind is put down from
// the menu bar and by its key with no code of its own; where it lands is the insertion spot's to say
// (`registrar.insertionSpot`, Draw's in the shipped app), the middle of the view otherwise.

extension CanvasCommand {
    /// Insert › the tool's label: what `tool` places, put down beside the selection, or in the middle of
    /// the view with none (`editor.insert(_:beside:)`). The core declares one for each placing tool.
    public static func insert(_ tool: ToolID) -> CanvasCommand { CanvasCommand("insert:\(tool.rawValue)") }
}

extension CanvasEditor {
    /// Whether Insert can put down what `tool` places: a tool that places a shape, which the board shown
    /// takes (`isToolEnabled`), with no shapes waiting to be placed (`isPlacingLater`), which putting one
    /// down would let go: ⇧↩ then goes on to Return, which puts them down.
    public func canInsert(_ tool: ToolID) -> Bool {
        registry.placement(forTool: tool) != nil && isToolEnabled(tool) && !isPlacingLater
    }

    /// Puts down what `tool` places (its placement, `registry.placement(forTool:)`) without the pointer,
    /// as Insert does: beside `shapes` (the selection, on the board shown), or with none somewhere clear in
    /// the middle of the view, in the frame the insertion spot gives (`registrar.insertionSpot`), else
    /// centered in the view's clear part (`unobscuredViewport`). Beside one shape it's made as its kind
    /// says one beside a shape is (`ShapeRegistrar.madeBeside`). A shape being edited stops being edited
    /// once that's known (a note's ⇧↩), so beside a note left empty, which ending its edit takes away, is
    /// where that note was. Then as `place(_:in:)` puts it: settled, the default tool back unless the tool
    /// is locked, services told (`didPlace`: the selection selects it) and an editing placement's shape
    /// edited, in one step named as the tool's placing is ("Add Note"), which what's typed into it joins.
    /// False, and nothing done, for a tool that places nothing, a board that takes nothing, shapes waiting
    /// to be placed, a press under way, or nowhere to put it (no view, and no spot given).
    @discardableResult
    public func insert(_ tool: ToolID, beside shapes: [ShapeID]) -> Bool {
        guard session == nil, canInsert(tool), var placement = registry.placement(forTool: tool) else { return false }
        let view = unobscuredViewport
        guard let frame = registry.insertionSpot?(self, placement.size, shapes)
                ?? (view.isEmpty ? nil : CGRect(center: CGPoint(x: view.midX, y: view.midY), size: placement.size)) else { return false }
        if shapes.count == 1, let neighbor = document[shapes[0]], let made = registry.madeBeside(placement.kind) {
            placement = placement.mapping { made($0, neighbor) }
        }
        endEditing()
        // A group, as a press is for a placing tool: the step stays open while the new shape is edited,
        // so what is typed into it is the one step.
        undoHistory.group("Add \(registry.tools.first { $0.id == tool }?.label ?? "Shape")") {
            place(placement, in: frame)
        }
        return true
    }
}
