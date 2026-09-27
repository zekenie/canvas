import Canvas
import CoreGraphics
import Geometry
import Observation
import Selection
import SwiftUI

/// One row of the table of contents, with the rows nested under it.
@MainActor
public struct ContentsEntry: Identifiable {
    public let id: ShapeID
    public let kind: ShapeKind
    /// The row, when it's a plain `ContentsLabel` (as most are); nil for any other view.
    public let label: ContentsLabel?
    /// The symbol of the tool that places the kind, which a `ContentsLabel` without its own shows.
    public let symbol: String
    /// The rows nested under this one, in document order; nil when there are none, so the list
    /// shows no disclosure triangle.
    public let children: [ContentsEntry]?
    let record: AnyShapeRecord
    let row: AnyView
}

/// Per editor (so per window): what the table of contents lists, and each shape's row, made again
/// only when that shape changes.
@MainActor
@Observable
public final class ContentsState {
    /// A shape's row, as its kind drew it for this version of the shape.
    private struct Cached {
        let record: AnyShapeRecord
        let isListed: Bool
        let parent: ShapeID?
        let row: ResolvedRow
    }

    /// What the table of contents listed when it last selected, and the selection it made then.
    private struct Pin {
        let scope: [ShapeID]?
        let selectionRevision: Int
    }

    @ObservationIgnored private unowned let editor: CanvasEditor
    /// Each kind's contribution, found once: the registry is frozen.
    @ObservationIgnored private var contributions: [ShapeKind: ContentsContribution?] = [:]
    @ObservationIgnored private var cache: [ShapeID: Cached] = [:]
    private var pin: Pin?

    init(editor: CanvasEditor) { self.editor = editor }

    // MARK: What's listed

    /// The shapes listed, nil for every shape. It follows the selection: select shapes (on the
    /// canvas, or anywhere but here) and just they are listed; select nothing and every shape is.
    /// Selecting rows (`select`) leaves it as it was, so a row of a long list can be picked without
    /// the rest going away, and `showAll` lists every shape without deselecting. Either holds until
    /// the selection next changes some other way.
    public var scope: [ShapeID]? {
        if let pin, pin.selectionRevision == editor.selectionRevision { return pin.scope }
        let selected = editor.selectedShapeIDs
        return selected.isEmpty ? nil : selected
    }

    public var isFiltered: Bool { scope != nil }

    /// The top-level rows in document order (back to front, as data-canvas's z-ordered outline),
    /// each with the rows nested under it. Only listed shapes in `scope` have rows. A row nests
    /// under the shape its kind names (`nestedUnder`) when that shape has a row too, unless that
    /// would make a loop: then the later shape stays at the top.
    public var entries: [ContentsEntry] {
        let shapes = editor.document.shapes
        let inScope = scope.map(Set.init)
        var rows: [ShapeID: Cached] = [:]
        var order: [ShapeID] = []
        for record in shapes where inScope?.contains(record.id) ?? true {
            let cached = resolve(record)
            rows[record.id] = cached
            if cached.isListed { order.append(record.id) }
        }
        // Keep only what's still there, so the cache doesn't grow with deleted shapes.
        if cache.count > shapes.count { cache = cache.filter { editor.document[$0.key] != nil } }

        var parents: [ShapeID: ShapeID] = [:]
        for id in order {
            guard let parent = rows[id]?.parent, parent != id, rows[parent]?.isListed == true else { continue }
            var ancestor: ShapeID? = parent
            while let next = ancestor, next != id { ancestor = parents[next] }
            if ancestor == nil { parents[id] = parent }
        }
        var children: [ShapeID: [ShapeID]] = [:]
        for id in order { if let parent = parents[id] { children[parent, default: []].append(id) } }

        func entry(_ id: ShapeID) -> ContentsEntry {
            let cached = rows[id]!
            let nested = children[id]?.map(entry)
            return ContentsEntry(id: id, kind: cached.record.kind, label: cached.row.label, symbol: symbol(of: cached.record.kind),
                                 children: nested, record: cached.record, row: cached.row.view)
        }
        return order.filter { parents[$0] == nil }.map(entry)
    }

    // MARK: Selecting

    /// What selecting rows does (a click, ⌘- and ⇧-clicks, the arrow keys): selects their shapes,
    /// in document order, and brings them into view, zoomed to fit (no closer than 120%). What's
    /// listed stays as it was. Selecting what's already selected moves nothing.
    public func select(_ ids: Set<ShapeID>) {
        let listed = scope
        let ordered = editor.document.shapes.map(\.id).filter(ids.contains)
        let isNew = Set(ordered) != Set(editor.selectedShapeIDs)
        editor.selectedShapeIDs = ordered
        pin = Pin(scope: listed, selectionRevision: editor.selectionRevision)
        if isNew { reveal(editor.selectedShapeIDs) }
    }

    /// Lists every shape, keeping the selection, until the selection next changes.
    public func showAll() {
        pin = Pin(scope: nil, selectionRevision: editor.selectionRevision)
    }

    /// Centers the shapes' bounds in the view, zoomed to fit with a margin but no closer than 120%,
    /// animated (data-canvas's click-to-zoom). Does nothing before the view has a size.
    func reveal(_ ids: [ShapeID]) {
        let size = editor.viewportSize
        let context = editor.shapeContext
        let rects = ids.compactMap { context.geometry(of: $0) }.filter { !$0.outline.isEmpty && !$0.bounds.isNull }.map(\.bounds)
        guard let first = rects.first, size.width > 0, size.height > 0 else { return }
        let bounds = rects.dropFirst().reduce(first) { $0.union($1) }
        editor.animateCamera(to: Camera(fitting: bounds, in: size, inset: ContentsStyle.zoomInset, maxZoom: ContentsStyle.maxZoom),
                             duration: ContentsStyle.zoomDuration)
    }

    // MARK: Hovering

    /// The pointer is on the shape's row (and, called again as it moves there, still is): the
    /// shape is hovered (`editor.hovered`), as though the pointer were on it on the canvas.
    public func hover(_ id: ShapeID) { editor.hovered = id }

    /// The pointer left the shape's row, or the row went away: the shape isn't hovered any more.
    /// Leaves any other shape's hover, which the canvas or another row may have set since.
    public func endHover(_ id: ShapeID) {
        if editor.hovered == id { editor.hovered = nil }
    }

    /// Whether the shape's row shows as hovered: its shape is hovered, whether the pointer is on the
    /// row or on the shape on the canvas, and isn't selected (as the canvas outlines the hover only
    /// on an unselected shape).
    public func isHovered(_ id: ShapeID) -> Bool { editor.hovered == id && !editor.isSelected(id) }

    // MARK: Rows

    /// The shape's row: its kind's, else its tool's label. Made again only when the shape changes.
    private func resolve(_ record: AnyShapeRecord) -> Cached {
        if let cached = cache[record.id], cached.record == record { return cached }
        let contribution = contribution(for: record.kind)
        let cached = Cached(record: record, isListed: contribution?.isListed(record) ?? true, parent: contribution?.parent?(record),
                            row: contribution?.row?(record) ?? ResolvedRow(ContentsLabel(name(of: record.kind))))
        cache[record.id] = cached
        return cached
    }

    private func contribution(for kind: ShapeKind) -> ContentsContribution? {
        if let found = contributions[kind] { return found }
        let found = editor.registry.contributions(to: ContentsRows.self, for: kind).first
        contributions[kind] = found
        return found
    }

    private func placingTool(of kind: ShapeKind) -> ToolDescriptor? {
        editor.registry.tools.first { $0.id == ToolID(placing: kind) }
    }

    /// The label of the tool that places the kind, else the kind.
    func name(of kind: ShapeKind) -> String { placingTool(of: kind)?.label ?? kind.rawValue }

    /// The symbol of the tool that places the kind, else a dashed square.
    func symbol(of kind: ShapeKind) -> String { placingTool(of: kind)?.systemImage ?? ContentsSymbolKey.defaultValue }
}

extension ContentsState: EditorService {}

extension CanvasEditor {
    /// The table of contents' state; nil without TableOfContentsPlugin.
    public var tableOfContents: ContentsState? { service(ContentsState.self) }
}
