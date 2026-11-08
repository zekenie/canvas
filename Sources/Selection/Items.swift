import AppKit
import Canvas
import CoreGraphics
import Geometry

/// What is selected inside a shape: its items (a table's rows), one level in from the shape, as a group's parts are one
/// level in from the group. With one shape selected, a click on one of its items selects that item (⇧ extends the run from
/// the anchor, ⌘ toggles one), a click on the only selected item opens it (a row is edited there), and a press anywhere
/// else drops them; the keys go to them while they're selected: ↑ ↓ the item above or below, ⇧↑ ⇧↓ the run extended, ⌥↑
/// ⌥↓ the items moved (the kind's step), ← → and Space open or close an item that hides others (a header, a fold's "+N ›"
/// line), ⌫ ⌦ delete them (the kind's counted step), Return opens the first, ⌘A selects every item, and Escape goes back to
/// the shape. Undo restores them with the selection. The shape stays selected (`selectedShapeIDs == [shape]`); its outline
/// gives way to theirs, drawn in the accent inside it, a run of items at a time, and not while it's edited. VoiceOver hears
/// them as rows of the shape, before its ⌥Tab parts, the selected ones said selected.
///
/// A plugin hands a kind's items in, with what each key does to them (`ShapeItemActions`), and writes no key code of its
/// own: LineRows lists the rows of every kind written as lines. Scoped as every face on other kinds' shapes is.
public enum ShapeItems {}

extension ShapeItems: ExtensionPoint {
    public typealias Contribution = ShapeItemSource
    public static var owner: PluginID { .selection }
    public static var scope: PointScope { .scoped }

    /// "items rows → table".
    public static func summary(of source: ShapeItemSource, for target: ShapeTarget) -> String {
        "items" + (source.name.map { " \($0)" } ?? "") + " → \(target)"
    }
}

/// Whether an item hides others behind it (a header, a fold's "+N ›" line), and which way it is now.
public enum ItemOutline: Hashable, Sendable {
    /// Its items show after it: ← closes it.
    case open
    /// Its items are hidden: → and Space open it.
    case closed
}

/// One item of a shape, as a plugin lists it, in the order the keys walk them (top to bottom).
@MainActor
public struct ShapeItem {
    /// Stable while it is the same item (a row's id): the selection holds it.
    public var id: AnyHashable
    /// What VoiceOver says of it: "customer_id, uuid, references accounts.id". Worked out when asked, so listing a shape's
    /// many items to find one costs their rects alone.
    public var title: String { titled() }
    private let titled: @MainActor () -> String
    /// Where it is drawn, world units: the outline goes inside it.
    public var rect: CGRect
    /// Nil for an item that hides nothing.
    public var outline: ItemOutline?
    /// The items it stands for while they're hidden (a fold's "+N ›" line, a closed header): a selected one of them shows
    /// as this one selected, and comes back as itself once it shows again.
    public var stands: [AnyHashable]

    public init<ID: Hashable & Sendable>(id: ID, title: @autoclosure @escaping @MainActor () -> String, rect: CGRect, outline: ItemOutline? = nil,
                                         stands: [AnyHashable] = []) {
        self.id = AnyHashable(id)
        titled = title
        self.rect = rect
        self.outline = outline
        self.stands = stands
    }
}

/// The items selected inside a shape (`editor.selectedItems`): the shape, the items in the order the shape lists them, and
/// the one a ⇧ click or ⇧↑ ⇧↓ extends from.
public struct ItemSelection: Equatable {
    public let shape: ShapeID
    public let ids: [AnyHashable]
    public let anchor: AnyHashable
    /// What the keys act on (delete, move, cut, copy): the items selected, and, for a line that stands for selected items a
    /// fold hides, those items themselves, never the line (a closed header, deleted, would take rows nobody selected).
    public let acting: [AnyHashable]

    public init(shape: ShapeID, ids: [AnyHashable], anchor: AnyHashable, acting: [AnyHashable]? = nil) {
        self.shape = shape
        self.ids = ids
        self.anchor = anchor
        self.acting = acting ?? ids
    }
}

/// Where a press on a kind's item takes it before anything else (its lead: an endpoint's method chip), and what a click
/// there does, told whether the item's shape was the only one selected before the press (the press selects it, so a click
/// that goes a level at a time goes on to the item only then).
public struct ItemLead {
    public var item: AnyHashable
    public var click: @MainActor (CanvasEditor, _ wasSelected: Bool) -> Void

    public init<ID: Hashable & Sendable>(item: ID, click: @escaping @MainActor (CanvasEditor, _ wasSelected: Bool) -> Void) {
        self.item = AnyHashable(item)
        self.click = click
    }
}

/// What the keys and the pointer do to a kind's items: each is handed the shape and the items, as the shape lists them.
public struct ShapeItemActions {
    /// ⌫ ⌦ and Edit › Delete: the items deleted, in one step the kind names.
    public var delete: @MainActor (CanvasEditor, ShapeID, [AnyHashable]) -> Void
    /// ⌥↑ (-1) ⌥↓ (+1): the items moved a place, one step a held key.
    public var move: @MainActor (CanvasEditor, ShapeID, [AnyHashable], Int) -> Void
    /// Return, and a click on the only selected item: the item opened (a row edited), from a point if a click gave one.
    public var open: @MainActor (CanvasEditor, ShapeID, AnyHashable, CGPoint?) -> Void
    /// ← → and Space on an item that hides others: opened (true) or closed.
    public var setOpen: (@MainActor (CanvasEditor, ShapeID, AnyHashable, Bool) -> Void)?
    /// A press on a selected item dragged past the threshold: the session that drags the items, from a world point; nil, or
    /// none given, drags the shape.
    public var drag: (@MainActor (CanvasEditor, ShapeID, [AnyHashable], CGPoint) -> (any Session)?)?
    /// The item's lead under a world point, pressed before faces: a click runs its click, a drag drags that item.
    public var lead: (@MainActor (CanvasEditor, AnyShapeRecord, CGPoint) -> ItemLead?)?
    /// What VoiceOver hears as the run of selected items grows or shrinks by key or click, from how many there are now:
    /// "3 columns selected". Nil: nothing is said.
    public var selectedWords: (@MainActor (Int) -> String)?

    public init(delete: @escaping @MainActor (CanvasEditor, ShapeID, [AnyHashable]) -> Void,
                move: @escaping @MainActor (CanvasEditor, ShapeID, [AnyHashable], Int) -> Void,
                open: @escaping @MainActor (CanvasEditor, ShapeID, AnyHashable, CGPoint?) -> Void,
                setOpen: (@MainActor (CanvasEditor, ShapeID, AnyHashable, Bool) -> Void)? = nil,
                drag: (@MainActor (CanvasEditor, ShapeID, [AnyHashable], CGPoint) -> (any Session)?)? = nil,
                lead: (@MainActor (CanvasEditor, AnyShapeRecord, CGPoint) -> ItemLead?)? = nil,
                selectedWords: (@MainActor (Int) -> String)? = nil) {
        self.selectedWords = selectedWords
        self.delete = delete
        self.move = move
        self.open = open
        self.setOpen = setOpen
        self.drag = drag
        self.lead = lead
    }
}

/// One plugin's items of a kind's shapes. Only the sugar makes one.
@MainActor
public struct ShapeItemSource {
    let name: String?
    let items: @MainActor (CanvasEditor, AnyShapeRecord) -> [ShapeItem]
    let at: @MainActor (CanvasEditor, AnyShapeRecord, CGPoint) -> AnyHashable?
    let actions: ShapeItemActions
}

extension ScopedRegistrar {
    /// Items of the shapes of every kind the scope reaches (see `ShapeItems`): `items` lists one shape's, top to bottom, as
    /// laid out now; `at` is the item under a world point; `actions` what the keys and the pointer do to them. The first
    /// plugin's for a kind is the kind's.
    public mutating func shapeItems(named name: String? = nil, _ items: @escaping @MainActor (CanvasEditor, AnyShapeRecord) -> [ShapeItem],
                                    at: @escaping @MainActor (CanvasEditor, AnyShapeRecord, CGPoint) -> AnyHashable?,
                                    actions: ShapeItemActions) {
        contribute(ShapeItemSource(name: name, items: items, at: at, actions: actions), to: ShapeItems.self)
    }
}

extension ShapeRegistrar {
    /// Items of this kind's shapes (see `ShapeItems`), as `shapeItems` in a scope lists them.
    public mutating func shapeItems(named name: String? = nil, _ items: @escaping @MainActor (CanvasEditor, AnyShapeRecord) -> [ShapeItem],
                                    at: @escaping @MainActor (CanvasEditor, AnyShapeRecord, CGPoint) -> AnyHashable?,
                                    actions: ShapeItemActions) {
        contribute(ShapeItemSource(name: name, items: items, at: at, actions: actions), to: ShapeItems.self)
    }
}

// MARK: Reading them

extension CanvasEditor {
    /// What lists a kind's items, if anything does.
    func itemSource(of kind: ShapeKind) -> ShapeItemSource? { registry.contributions(to: ShapeItems.self, for: kind).first }

    /// A shape's items, top to bottom, as laid out now (`ShapeItems`); none for a kind with none, a shape not on the board shown,
    /// and the shape being edited.
    public func shapeItems(of id: ShapeID) -> [ShapeItem] {
        guard editingShapeID != id, let record = document[id], let source = itemSource(of: record.kind) else { return [] }
        return source.items(self, record)
    }

    /// The item of `id` under a world point; nil off its items, or for a kind with none.
    public func item(at point: CGPoint, of id: ShapeID) -> AnyHashable? {
        guard editingShapeID != id, let record = document[id], let source = itemSource(of: record.kind) else { return nil }
        return source.at(self, record, point)
    }

    /// The items selected inside the only selected shape (`ShapeItems`), as its items show now: one hidden by a fold since it
    /// was selected is the item standing for it. Nil with none. Without the Selection plugin, nil.
    public var selectedItems: ItemSelection? {
        guard let state = selectionState, let held = state.items else { return nil }
        return state.shown(held)
    }

    /// Selects `ids` of `shape`, its items: the shape alone selected (if it can be), its part's focus let go, `anchor` (the
    /// first of `ids` by default) where ⇧ extends from. None of `ids` among its items: none selected, the shape still is.
    public func selectItems(_ ids: [AnyHashable], of shape: ShapeID, anchor: AnyHashable? = nil) {
        guard let state = selectionState else { return }
        if selectedShapeIDs != [shape] { selectedShapeIDs = [shape] }
        guard selectedShapeIDs == [shape] else { return }
        // What's selected already: nothing to list (a shape of many rows lists them all to check).
        if let held = state.items, held.shape == shape, held.ids == ids, anchor == nil || anchor == held.anchor { return }
        state.setItems(ids, of: shape, anchor: anchor)
    }

    /// Whether the keys go to selected items: there are some, and nothing's under way or edited.
    public var canStepItems: Bool { session == nil && editingShapeID == nil && selectedItems != nil }

    /// Says how many items are selected now (the kind's words) when a key or click changed a run of them: more than one now,
    /// or fewer than before. VoiceOver's focus change says a single item moved to; a run has no one element to say it.
    func announceItems(from before: Int) {
        guard let selection = selectedItems, selection.ids.count > 1 || before > 1, let record = document[selection.shape],
              let words = itemSource(of: record.kind)?.actions.selectedWords else { return }
        announce(words(selection.ids.count))
    }
}

// MARK: The state

/// The items selected, as the selection holds them: the ids as they were selected (a row a fold hides since is kept, and
/// shows as the line standing for it), so an unfold gives it back.
struct HeldItems: Equatable {
    let shape: ShapeID
    var ids: [AnyHashable]
    var anchor: AnyHashable
}

extension SelectionState {
    /// The items `held` is, as the shape lists them now: each item selected or standing for one selected, in the shape's order;
    /// nil when none is left. Kept while the board, its layout and what's held stay as they were, so the keys, the outline
    /// and VoiceOver read it once between changes.
    func shown(_ held: HeldItems) -> ItemSelection? {
        let revision = editor.revision, layout = editor.layoutRevision, editing = editor.editingShapeID
        if let kept = keptItems, kept.held == held, kept.revision == revision, kept.layout == layout, kept.editing == editing { return kept.shown }
        let shown = listedShown(held)
        keptItems = KeptItems(held: held, revision: revision, layout: layout, editing: editing, shown: shown)
        return shown
    }

    private func listedShown(_ held: HeldItems) -> ItemSelection? {
        let listed = editor.shapeItems(of: held.shape)
        let wanted = Set(held.ids)
        let ids = listed.filter { wanted.contains($0.id) || $0.stands.contains(where: wanted.contains) }.map(\.id)
        guard !ids.isEmpty else { return nil }
        let anchor = listed.first { $0.id == held.anchor || $0.stands.contains(held.anchor) }?.id ?? ids[0]
        // A line standing for items held is not what the keys act on: those items are.
        var acting: [AnyHashable] = []
        for item in listed where wanted.contains(item.id) || item.stands.contains(where: wanted.contains) {
            if wanted.contains(item.id) { acting.append(item.id) }
            acting += item.stands.filter(wanted.contains)
        }
        return ItemSelection(shape: held.shape, ids: ids, anchor: ids.contains(anchor) ? anchor : ids[0], acting: acting)
    }

    /// Selects items of the only selected shape: those of `ids` it lists (or that one it lists stands for), in its order.
    func setItems(_ ids: [AnyHashable], of shape: ShapeID, anchor: AnyHashable?) {
        let listed = editor.shapeItems(of: shape)
        let wanted = Set(ids)
        let known = listed.flatMap { [$0.id] + $0.stands }
        let kept = known.filter(wanted.contains)
        guard !kept.isEmpty else {
            items = nil
            return
        }
        clearPartFocus()
        trail = StepTrail()
        let held = HeldItems(shape: shape, ids: kept, anchor: anchor.flatMap { wanted.contains($0) ? $0 : nil } ?? ids.first(where: kept.contains) ?? kept[0])
        if held != items { items = held }
    }

    /// Drops the items: whether there were any.
    @discardableResult
    func clearItems() -> Bool {
        guard items != nil else { return false }
        items = nil
        return true
    }

    /// A commit took the items' shape away, or it's no longer the only one selected: the items go. One that took some items
    /// away (a row deleted by another writer) leaves them held, as a fold leaves a hidden one: what shows is what the shape
    /// lists (`shown`), and none listed is none selected.
    func pruneItems() {
        guard let held = items else { return }
        if selectedIDs != [held.shape] || editor.document[held.shape] == nil { items = nil }
    }
}

/// The items selected as the shape lists them, as last worked out, and what from.
struct KeptItems {
    let held: HeldItems
    let revision: Int
    let layout: Int
    let editing: ShapeID?
    let shown: ItemSelection?
}

// MARK: The keys

extension CanvasEditor {
    /// The source of the selected items' shape, with the items and the shape's list.
    private func itemContext() -> (selection: ItemSelection, source: ShapeItemSource, listed: [ShapeItem])? {
        guard canStepItems, let selection = selectedItems, let record = document[selection.shape], let source = itemSource(of: record.kind) else { return nil }
        return (selection, source, source.items(self, record))
    }

    /// The source of the selected items' shape and the selection, without listing the shape's items (a table of 500 rows lists
    /// them all): for the keys that act on the items selected and need none of the others.
    private func itemActionContext() -> (selection: ItemSelection, source: ShapeItemSource)? {
        guard canStepItems, let selection = selectedItems, let record = document[selection.shape], let source = itemSource(of: record.kind) else { return nil }
        return (selection, source)
    }

    /// An arrow key with items selected: ↑ ↓ the item above or below (with ⇧, the run from the anchor extended or drawn back),
    /// stopping at the ends; → and ← open and close an item that hides others. Whether there were items (the key is theirs
    /// then, whatever it did).
    func arrowOnItems(_ direction: CGPoint, extending: Bool) -> Bool {
        guard let (selection, source, listed) = itemContext() else { return false }
        if direction.y == 0 {
            guard selection.ids.count == 1, let item = listed.first(where: { $0.id == selection.ids[0] }), let outline = item.outline,
                  let setOpen = source.actions.setOpen else { return true }
            let open = direction.x > 0
            if (outline == .open) != open { setOpen(self, selection.shape, item.id, open) }
            return true
        }
        let order = listed.map(\.id)
        let step = direction.y < 0 ? -1 : 1
        guard let state = selectionState else { return true }
        if extending {
            // The run from the anchor to the end the key moves: past the anchor it grows, back toward it it shrinks.
            guard let anchor = order.firstIndex(of: selection.anchor) else { return true }
            let indices = selection.ids.compactMap { order.firstIndex(of: $0) }
            let head = (indices.min() ?? anchor) == anchor ? (indices.max() ?? anchor) : (indices.min() ?? anchor)
            let next = head + step
            guard order.indices.contains(next) else { return true }
            let range = min(anchor, next)...max(anchor, next)
            state.setItems(range.map { order[$0] }, of: selection.shape, anchor: selection.anchor)
            announceItems(from: selection.ids.count)
        } else {
            let indices = selection.ids.compactMap { order.firstIndex(of: $0) }
            // Finder's: the item past the run's end that way; at the end of the shape, the run comes down to that end.
            guard let edge = step < 0 ? indices.min() : indices.max() else { return true }
            let next = order.indices.contains(edge + step) ? edge + step : edge
            guard next != edge || indices.count > 1 else { return true }
            state.setItems([order[next]], of: selection.shape, anchor: nil)
            announceItems(from: selection.ids.count)
        }
        if let rect = listed.first(where: { selectedItems?.ids.last == $0.id })?.rect { revealIfOffscreen(rect: rect) }
        return true
    }

    /// ⌥↑ ⌥↓ with items selected: the kind moves them a place (one step a held key). Whether there were items.
    func moveItems(_ direction: CGPoint) -> Bool {
        guard let (selection, source) = itemActionContext() else { return false }
        guard direction.x == 0 else { return true }
        source.actions.move(self, selection.shape, selection.acting, direction.y < 0 ? -1 : 1)
        return true
    }

    /// ⌫ ⌦ (and Edit › Delete, and the selection's menu's Delete) on the selected items: the kind deletes them. Whether there
    /// were items to take the key, where `subject` asks: a key, the menu bar or a right-click, on the items' shape (the shape's
    /// own outline is hidden while its items are the selection, so the menu means them as the keys do).
    func deleteItems(for subject: CommandSubject) -> Bool {
        guard let selection = selectedItems, subject.shapes == [selection.shape],
              let (_, source) = itemActionContext() else { return false }
        revealIfOffscreen([selection.shape])
        source.actions.delete(self, selection.shape, selection.acting)
        return true
    }

    /// Return with items selected: the first opened (a row edited). Whether there were items.
    func openSelectedItem() -> Bool {
        guard let (selection, source) = itemActionContext() else { return false }
        source.actions.open(self, selection.shape, selection.ids[0], nil)
        return true
    }

    /// Space with one item selected that hides others: opened or closed. Whether it took the key.
    func toggleSelectedItem() -> Bool {
        guard let (selection, source, listed) = itemContext(), selection.ids.count == 1,
              let item = listed.first(where: { $0.id == selection.ids[0] }), let outline = item.outline, let setOpen = source.actions.setOpen else { return false }
        setOpen(self, selection.shape, item.id, outline == .closed)
        return true
    }

    /// ⌘A with items selected: every item of the shape. Whether there were items.
    func selectAllItems() -> Bool {
        guard let (selection, _, listed) = itemContext(), let state = selectionState else { return false }
        state.setItems(listed.map(\.id), of: selection.shape, anchor: listed.first?.id)
        announceItems(from: selection.ids.count)
        return true
    }
}

// MARK: The pointer

/// A press on an item of the only selected shape: past the drag threshold, the selected items dragged (the kind's `drag`) when
/// it's on one of them, else the shape moved; released, the item selected (⇧ the run from the anchor to it, ⌘ it toggled), or,
/// the only one selected already, opened from where it was released. A press on an item not selected while others are selects
/// it at once.
@MainActor
final class PointingItemSession {
    let shape: ShapeID
    let item: AnyHashable
    let press: CGPoint
    let modifiers: Modifiers
    let didSelectOnPress: Bool

    init(shape: ShapeID, item: AnyHashable, press: CGPoint, modifiers: Modifiers, in editor: CanvasEditor) {
        self.shape = shape
        self.item = item
        self.press = press
        self.modifiers = modifiers
        let selected = editor.selectedItems?.ids ?? []
        if !selected.isEmpty, !selected.contains(item), modifiers.isDisjoint(with: [.shift, .command]) {
            editor.selectItems([item], of: shape)
            didSelectOnPress = true
        } else {
            didSelectOnPress = false
        }
    }
}

extension PointingItemSession: Session {
    func drag(_ pointer: Pointer, in editor: CanvasEditor) {
        guard pointer.view.distance(to: press) > Style.dragThreshold else { return }
        let origin = editor.camera.toWorld(press)
        // ⌘ held is the brush from anywhere on a shape (the key hint "⌘ Drag: Select Shapes Wholly in the Box"), a row too.
        if modifiers.contains(.command) {
            let brush = BrushingSession(origin: origin, in: editor)
            editor.session = brush
            brush.drag(pointer, in: editor)
            return
        }
        var next: (any Session)?
        if let selection = editor.selectedItems, selection.ids.contains(item), let record = editor.document[shape],
           let drag = editor.itemSource(of: record.kind)?.actions.drag {
            next = drag(editor, shape, selection.ids, origin)
        }
        let session = next ?? editor.translationSession(from: origin, pointer: pointer)
        editor.session = session
        session.drag(pointer, in: editor)
    }

    func end(_ pointer: Pointer, in editor: CanvasEditor) {
        guard !didSelectOnPress, let state = editor.selectionState else { return }
        let selected = editor.selectedItems
        if modifiers.contains(.shift), let selected {
            let order = editor.shapeItems(of: shape).map(\.id)
            guard let from = order.firstIndex(of: selected.anchor), let to = order.firstIndex(of: item) else { return }
            state.setItems((min(from, to)...max(from, to)).map { order[$0] }, of: shape, anchor: selected.anchor)
            editor.announceItems(from: selected.ids.count)
        } else if modifiers.contains(.command), let selected {
            let ids = selected.ids.contains(item) ? selected.ids.filter { $0 != item } : selected.ids + [item]
            if ids.isEmpty { state.clearItems() } else { state.setItems(ids, of: shape, anchor: selected.anchor) }
            editor.announceItems(from: selected.ids.count)
        } else if selected?.ids == [item] {
            // A click on the only selected item opens it there (a row edited from the click), as a click on the only
            // selected note edits it; a locked shape's is only selected, as a click on a locked note isn't a try.
            guard !editor.isReadOnly(shape), let record = editor.document[shape], let source = editor.itemSource(of: record.kind) else { return }
            editor.session = nil
            source.actions.open(editor, shape, item, pointer.world)
        } else {
            state.setItems([item], of: shape, anchor: nil)
        }
    }

    func cancel(in editor: CanvasEditor) -> Bool { true }
}

/// A press on an item's lead (`ShapeItemActions.lead`): released, its click; past the threshold, that item dragged at once,
/// selected or not.
@MainActor
final class PointingLeadSession {
    let shape: ShapeID
    let lead: ItemLead
    let press: CGPoint
    /// Whether the shape was the only one selected before the press.
    let wasSelected: Bool

    init(shape: ShapeID, lead: ItemLead, press: CGPoint, wasSelected: Bool) {
        self.shape = shape
        self.lead = lead
        self.press = press
        self.wasSelected = wasSelected
    }
}

extension PointingLeadSession: Session {
    func drag(_ pointer: Pointer, in editor: CanvasEditor) {
        guard pointer.view.distance(to: press) > Style.dragThreshold, let record = editor.document[shape],
              let drag = editor.itemSource(of: record.kind)?.actions.drag else { return }
        editor.selectItems([lead.item], of: shape)
        guard let session = drag(editor, shape, [lead.item], editor.camera.toWorld(press)) else { return }
        editor.session = session
        session.drag(pointer, in: editor)
    }

    func end(_ pointer: Pointer, in editor: CanvasEditor) {
        editor.session = nil
        lead.click(editor, wasSelected)
    }

    func cancel(in editor: CanvasEditor) -> Bool { true }
}

extension CanvasEditor {
    /// The lead of an item of `id` under a world point (`ShapeItemActions.lead`), for a kind with one.
    func itemLead(on id: ShapeID, at point: CGPoint) -> ItemLead? {
        guard editingShapeID != id, let record = document[id], let lead = itemSource(of: record.kind)?.actions.lead else { return nil }
        return lead(self, record, point)
    }
}

// MARK: Drawing

/// The selected items' outline: in the selection's color, inside its shape, around each run of items selected one after
/// another; not while the shape is edited, and carried with the shape's drawing offset (a shake).
struct ItemsOverlay: CanvasOverlay {
    var space: OverlaySpace { .world }

    func draw(in overlay: OverlayContext) {
        let editor = overlay.editor
        guard let selection = editor.selectedItems, editor.editingShapeID != selection.shape else { return }
        let listed = editor.shapeItems(of: selection.shape)
        let selected = Set(selection.ids)
        var runs: [CGRect] = [], run: CGRect?
        for item in listed {
            if selected.contains(item.id) {
                run = run.map { $0.union(item.rect) } ?? item.rect
            } else if let done = run {
                runs.append(done)
                run = nil
            }
        }
        if let run { runs.append(run) }
        let zoom = overlay.zoom, offset = overlay.worldDrawingOffset(of: selection.shape)
        let inset = SelectionStyle.itemInset / zoom, radius = SelectionStyle.itemRadius / zoom
        let cg = overlay.cg
        cg.saveGState()
        cg.setStrokeColor((editor.selectionOutlineColor ?? SelectionStyle.accent).cgColor)
        cg.setLineWidth(SelectionStyle.itemOutlineWidth / zoom)
        for rect in runs {
            let ring = rect.insetBy(dx: inset, dy: SelectionStyle.itemOutlineWidth / zoom / 2).offsetBy(dx: offset.x, dy: offset.y)
            guard ring.intersects(overlay.visibleRect) else { continue }
            cg.addPath(CGPath(roundedRect: ring, cornerWidth: radius, cornerHeight: radius, transform: nil))
        }
        cg.strokePath()
        cg.restoreGState()
    }
}
