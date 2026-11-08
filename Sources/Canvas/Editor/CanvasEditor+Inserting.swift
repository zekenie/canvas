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

    /// Insert › New (the kind) Beside, first in Insert, and ⇧↩ (Keyboard's): a shape of the selection's kind put down
    /// beside it, whichever kind that is (`editor.toolBeside`): the placing tool of the one kind the selected shapes
    /// are, else the tool a plugin claimed for it (`registrar.insertsBesideByDefault`, StickyNotes' Note). The core
    /// declares it, run when nothing is being edited.
    public static let insertBeside: CanvasCommand = "insertBeside"
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
        guard canInsert(tool), let placement = registry.placement(forTool: tool) else { return false }
        return insert(placement, named: "Add \(registry.tools.first { $0.id == tool }?.label ?? "Shape")", beside: shapes) != nil
    }

    /// Puts down a shape of `placement`, as `insert(_:beside:)` puts down what a tool places, in one step named
    /// `step` ("Add Table"): beside `shapes`, or with none somewhere clear in the middle of the view, in the frame
    /// the insertion spot gives, made as its kind says one beside a shape is, when it's beside one (`madeBeside`),
    /// settled, the default tool back unless the tool is locked, services told (`didPlace`) and an editing
    /// placement's shape edited. The step stays open while the new shape is edited, so what is typed into it is
    /// the one step. The one insertion spot: a tool's insert calls it. Returns the shape's id; nil, and nothing
    /// done, for shapes waiting to be placed, a press under way, nowhere to put it (no view, and no spot given), or
    /// a board or container that takes nothing (heard refused, so it shakes).
    @discardableResult
    public func insert(_ placement: Placement, named step: String, beside shapes: [ShapeID]) -> ShapeID? {
        guard session == nil, !isPlacingLater else { return nil }
        var placement = placement
        guard let frame = insertionFrame(of: placement.size, beside: shapes) else { return nil }
        if shapes.count == 1, let neighbor = document[shapes[0]], let made = registry.madeBeside(placement.kind) {
            placement = placement.mapping { made($0, neighbor) }
        }
        endEditing()
        // A group, as a press is for a placing tool: the step stays open while the new shape is edited,
        // so what is typed into it is the one step.
        var placed: ShapeID?
        undoHistory.group(step) {
            placed = place(placement, in: frame)
        }
        return placed
    }

    /// Where Insert puts a shape of `size` beside `shapes` (world units): the frame the insertion spot gives
    /// (`registrar.insertionSpot`), else, with none, one centered in the view's clear part (`unobscuredViewport`). Nil for
    /// nowhere (no view, and no spot given). For a plugin that puts its own shape down where Insert would (rows taken out
    /// into a new table).
    public func insertionFrame(of size: CGSize, beside shapes: [ShapeID]) -> CGRect? {
        let view = unobscuredViewport
        return registry.insertionSpot?(self, size, shapes) ?? (view.isEmpty ? nil : CGRect(center: CGPoint(x: view.midX, y: view.midY), size: size))
    }

    /// The tool ⇧↩ puts a shape down with, beside these shapes: the placing tool of the kind they all are (the
    /// first that places it), else the tool a plugin claimed for any other selection (`registrar.insertsBesideByDefault`:
    /// nothing selected, an arrow, which no tool places, or shapes of several kinds). A tool this file doesn't have
    /// on (a kit that's off here) or the board can't use isn't picked, so a kind of an off kit gets the claim's.
    /// Nil when neither is available.
    public func toolBeside(_ shapes: [ShapeID]) -> ToolID? {
        var kinds: Set<ShapeKind> = []
        for id in shapes { if let record = document[id] { kinds.insert(record.kind) } }
        if kinds.count == 1, let kind = kinds.first, let tool = registry.placingTool(for: kind), canInsert(tool) { return tool }
        return registry.insertsBesideByDefault.flatMap { canInsert($0) ? $0 : nil }
    }

    /// Whether ⇧↩ can put a shape down beside these shapes (`toolBeside`).
    public func canInsertBeside(_ shapes: [ShapeID]) -> Bool { toolBeside(shapes) != nil }

    /// Insert › New (the kind) Beside: what the item is called now, for the tool it would use: "New Table Beside"
    /// with a selection, "New Note" with none (nothing to be beside); "New Shape Beside" when none is available.
    public func insertBesideTitle(_ shapes: [ShapeID]) -> String {
        guard let tool = toolBeside(shapes), let label = registry.tools.first(where: { $0.id == tool })?.label else { return "New Shape Beside" }
        return shapes.isEmpty ? "New \(label)" : "New \(label) Beside"
    }
}
