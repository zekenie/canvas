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
    public var kind: ShapeKind { row.record.kind }
    /// The row, when it's a plain `ContentsLabel` (as most are); nil for any other view.
    public var label: ContentsLabel? { row.label }
    /// The symbol of the tool that places the kind, which a `ContentsLabel` without its own shows.
    public var symbol: String { row.symbol }
    /// The rows nested under this one, in document order; nil when there are none, so the list
    /// shows no disclosure triangle.
    public internal(set) var children: [ContentsEntry]?
    /// The shape's row, as its kind made it for the shape as listed: the same object until the
    /// shape changes.
    var row: ShapeRow

    init(row: ShapeRow, children: [ContentsEntry]?) {
        id = row.id
        self.row = row
        self.children = children
    }
}

/// A shape's row as its kind made it for one version of the shape, with what places it in the
/// list. Made again only when the shape changes, and shared by every scope that lists it.
@MainActor
final class ShapeRow {
    let record: AnyShapeRecord
    /// Whether the kind lists the shape (`when`).
    let isListed: Bool
    /// The shape the kind nests it under (`nestedUnder`), listed or not.
    let parent: ShapeID?
    let view: AnyView
    let label: ContentsLabel?
    let symbol: String
    /// Where the shape is in the stack, which orders rows among their siblings. Every shape in a
    /// document has a key.
    let key: StackingKey

    init(record: AnyShapeRecord, isListed: Bool, parent: ShapeID?, row: ResolvedRow, symbol: String) {
        self.record = record
        self.isListed = isListed
        self.parent = parent
        view = row.view
        label = row.label
        self.symbol = symbol
        key = record.stackingKey!
    }

    var id: ShapeID { record.id }
}

/// Per editor (so per window): what the table of contents lists, and each shape's row, made again
/// only when that shape changes. What a commit changed is all a read after it redoes: the rows of
/// the shapes its change set names, and where those nest.
@MainActor
@Observable
public final class ContentsState {
    /// What the table of contents listed when it last selected, and the selection it made then.
    private struct Pin {
        let scope: [ShapeID]?
        let selectionRevision: Int
    }

    /// How a kind's shapes get their rows.
    private struct KindRows {
        let contribution: ContentsContribution?
        /// What its rows are called (`ContentsTitles`): the kind's own name for them, else every kind's.
        let title: ContentsTitles.Contribution?
        /// The label and symbol of the tool that places the kind, else its name and a dashed square.
        let name: String
        let symbol: String
    }

    @ObservationIgnored private unowned let editor: CanvasEditor
    /// Each kind's, found once: the registry is frozen.
    @ObservationIgnored private var kinds: [ShapeKind: KindRows] = [:]
    /// Each shape's row, made when a scope first takes the shape in, and again after it changes.
    @ObservationIgnored private var rows: [ShapeID: ShapeRow] = [:]
    /// What's listed for the whole board, and for the last scope of some shapes: each kept, and
    /// brought up to date as it's read.
    @ObservationIgnored private var board: ContentsListing?
    @ObservationIgnored private var filtered: ContentsListing?
    /// The revision the rows and listings are up to date with. Read before this service hears of
    /// a commit (by a service that hears first), it keeps the rows whose shapes are as they were
    /// and lists them again.
    @ObservationIgnored private var heardRevision: Int
    private var pin: Pin?

    init(editor: CanvasEditor) {
        self.editor = editor
        heardRevision = editor.revision
    }

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
    /// would make a loop: then the later shape stays at the top. Kept from one read to the next,
    /// so a read after a commit costs what the commit changed.
    public var entries: [ContentsEntry] {
        catchUp()
        guard let scope else {
            if board == nil || !board!.update(row: row(of:)) { board = listing(of: nil) }
            return board!.entries
        }
        let ids = Set(scope)
        if filtered?.scope != ids || !filtered!.update(row: row(of:)) { filtered = listing(of: ids) }
        return filtered!.entries
    }

    /// Every row in scope (nil for every shape), listed from scratch, from the rows made already.
    private func listing(of scope: Set<ShapeID>?) -> ContentsListing {
        ContentsListing(scope: scope, shapes: inDocumentOrder(scope), row: row(of:))
    }

    /// Every shape, or the shapes of `ids` still in the document, back to front.
    private func inDocumentOrder(_ ids: Set<ShapeID>?) -> [ShapeID] {
        let document = editor.document
        guard let ids else { return document.shapes.map(\.id) }
        return ids.compactMap { id in document.index(of: id).map { (id, $0) } }.sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// After a commit this service hasn't heard of: keeps the rows whose shapes are as they were,
    /// and lists them again. Reading the revision also ties whoever reads `entries` to every
    /// commit, as reading the document would.
    private func catchUp() {
        guard heardRevision != editor.revision else { return }
        heardRevision = editor.revision
        let document = editor.document
        rows = rows.filter { document[$0.key] == $0.value.record }
        board = nil
        filtered = nil
    }

    // MARK: Selecting

    /// What selecting rows does (a click, ⌘- and ⇧-clicks, the arrow keys): selects their shapes,
    /// in document order, and brings them into view, zoomed to fit (no closer than 120%). What's
    /// listed stays as it was. Selecting what's already selected moves nothing.
    public func select(_ ids: Set<ShapeID>) {
        let listed = scope
        let ordered = inDocumentOrder(ids)
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

    /// The shape's row: its kind's, else its tool's label; called what `ContentsTitles` names it, if
    /// it's a `ContentsLabel`. Made again only after the shape changes; nil once it's gone. A shape
    /// the board keeps aside isn't listed, whatever its kind: nothing on the canvas sees it.
    private func row(of id: ShapeID) -> ShapeRow? {
        if let made = rows[id] { return made }
        guard let record = editor.document[id] else { return nil }
        let kind = kindRows(record.kind), contribution = kind.contribution
        var row = contribution?.row?(record) ?? ResolvedRow(ContentsLabel(kind.name))
        if let label = row.label, let title = kind.title?(record), !title.allSatisfy(\.isWhitespace) {
            row = ResolvedRow(label.retitled(title))
        }
        let made = ShapeRow(record: record, isListed: !record.isOpaque && (contribution?.isListed(record) ?? true),
                            parent: contribution?.parent?(record), row: row, symbol: kind.symbol)
        rows[id] = made
        return made
    }

    private func kindRows(_ kind: ShapeKind) -> KindRows {
        if let found = kinds[kind] { return found }
        let registry = editor.registry
        let tool = registry.tools.first { $0.id == ToolID(placing: kind) }
        let found = KindRows(contribution: registry.contributions(to: ContentsRows.self, for: kind).first,
                             title: registry.contributions(to: ContentsTitles.self, for: kind).first,
                             name: tool?.label ?? kind.rawValue, symbol: tool?.systemImage ?? ContentsSymbolKey.defaultValue)
        kinds[kind] = found
        return found
    }
}

extension ContentsState: EditorService {
    /// Forgets the rows of the shapes the commit touched, for the next read to make again and
    /// place: each scope's listing notes them.
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        guard heardRevision != editor.revision else { return }         // read since, and caught up
        heardRevision = editor.revision
        let touched = changes.shapeIDs
        for id in touched { rows[id] = nil }
        board?.pending.formUnion(touched)
        filtered?.pending.formUnion(touched)
    }
}

extension CanvasEditor {
    /// The table of contents' state; nil without TableOfContentsPlugin.
    public var tableOfContents: ContentsState? { service(ContentsState.self) }
}
