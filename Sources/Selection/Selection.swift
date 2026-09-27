import Canvas

/// Selecting shapes, as a plugin: the selection itself (`editor.selection`,
/// `editor.selectedShapeIDs`), the Select tool and its marquee, the handles of the one selected
/// shape, what Delete, Return and ⌘A do, and what a double-click on empty canvas places. Every
/// kind is selectable unless it opts out (`shape.unselectable()`). The core never learns what a
/// selection is: it outlines what this plugin asks, and tells it about Escape, commands, placed
/// shapes and document changes.
extension PluginID {
    public static let selection: PluginID = "selection"
}

extension ToolID {
    public static let select: ToolID = "select"
}

/// Whether a kind's shapes can be selected. At most one rule per kind, plus one for every kind
/// (`.any`), which a kind's own overrides; a kind with neither is always selectable.
public enum ShapeSelectability: KeyedExtensionPoint {
    public typealias Contribution = @MainActor (AnyShapeRecord) -> Bool
    public static var owner: PluginID { .selection }
    public static func uniqueKeys(of _: Contribution, for target: ShapeTarget) -> [AnyHashable] { [target] }
}

/// What a double-click on empty canvas with the select tool places. At most one kind may claim it.
public enum DoubleClickPlacement: KeyedExtensionPoint {
    public typealias Contribution = Placement
    public static var owner: PluginID { .selection }
    public static func uniqueKeys(of _: Placement, for _: ShapeTarget) -> [AnyHashable] { ["double-click on empty canvas"] }
}

// Sugar, so opting in or out is one line.
extension ShapeRegistrar {
    /// The select tool sees through this kind's shapes: a press lands on what's beneath them (or
    /// on the canvas, where a drag is a marquee), and the marquee and ⌘A pass them by, so they're
    /// never selected or outlined on hover. They still draw, and everything else treats them as
    /// usual: arrows bind to them, the eraser erases them, code moves them.
    public mutating func unselectable() {
        contribute({ _ in false }, to: ShapeSelectability.self)
    }

    /// Selectable only while `isSelectable` says so (a lock, say). A shape that stops being
    /// selectable leaves the selection with the change that did it.
    public mutating func selectable(when isSelectable: @escaping @MainActor (ShapeRecord<Definition.Props>) -> Bool) {
        contribute({ $0.typed(as: Definition.Props.self).map(isSelectable) ?? false }, to: ShapeSelectability.self)
    }

    /// Double-clicking empty canvas with the select tool places this. At most one kind may claim it.
    public mutating func createOnDoubleClick(_ placement: Placement) {
        precondition(placement.kind == kind, "\(kind) can't claim double-click for \(placement.kind)")
        contribute(placement, to: DoubleClickPlacement.self)
    }
}

public struct SelectionPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .selection }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { SelectionState(editor: $0) }
        registrar.tool(ToolDescriptor(id: .select, label: "Select", systemImage: "cursorarrow", shortcut: "v")) { _ in SelectTool() }
        registrar.defaultTool(.select)
        registrar.outlines { $0.selectionOutlines }
        registrar.overlay(HandlesOverlay())
        registrar.command(.delete) { $0.deleteSelection() }
        registrar.command(.insertNewline) { $0.editSelection() }
        registrar.command(.selectAll) { $0.selectAll() }
    }
}
