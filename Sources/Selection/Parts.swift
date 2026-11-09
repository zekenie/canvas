import AppKit
import Canvas
import CoreGraphics
import Geometry

/// What a shape draws that a click acts on, as the keys reach it: its chips and pills, buttons, handles
/// and arrows, one level in from the shape (keyboard navigation's principles 1 and 3). With one shape
/// selected, ⌥Tab focuses its first part in reading order and ⌥⇧Tab its last, and again steps to the
/// next or previous, wrapping inside the shape; Return or Space presses the focused part (the click it
/// stands for), an arrow key adjusts a part that has a way to (a handle) and otherwise nudges the shape
/// (⌥⌘ and an arrow too, which otherwise steps to the nearest shape: `PartStep.toNearest`), and Escape
/// goes back to the shape, still selected. The focused part draws an accent ring and comes into view.
/// Its focus goes with any other change of the selection, a commit that takes the part away, another
/// tool or board, and editing: a shape being edited lists none.
///
/// A plugin hands its parts in, and writes no key code of its own: Adornments lists every clickable
/// adornment by itself, so a chip a plugin puts on a shape is reachable with no more than the chip.
/// Scoped as every face on other kinds' shapes is (`registrar.forShapes(holding:)`, `forShapes(adopting:)`,
/// `forEveryShape`): the registry refuses a list for every shape with no scope, and names each scope in
/// its report. Listed only when a key asks, and for the ring when something its place is worked out from
/// changes (a commit, a layout, the zoom: while a zoom runs, the focused shape's alone each frame). A list:
/// every plugin's, in plugin order.
public enum ShapeParts {}

extension ShapeParts: ExtensionPoint {
    public typealias Contribution = ShapePartSource
    public static var owner: PluginID { .selection }
    /// Parts of other kinds' shapes say which kinds.
    public static var scope: PointScope { .scoped }

    /// "parts LockChip → every shape holding locked".
    public static func summary(of source: ShapePartSource, for target: ShapeTarget) -> String {
        "parts" + (source.name.map { " \($0)" } ?? "") + " → \(target)"
    }
}

/// What a part is to VoiceOver, and so what Return and Space do with it.
public enum PartRole: Hashable, Sendable {
    /// Does something when pressed (the lock chip unlocks).
    case button
    /// Pops a menu when pressed (a type chip's).
    case menuButton
    /// Goes somewhere (a reference's go button).
    case link
    /// Toggles (a checkbox drawn on a card).
    case checkbox
    /// Moved with the arrow keys (an arrow's end, a resize handle).
    case handle
    /// Another shape this one is connected to (an arrow at it).
    case connection
}

/// An arrow key pressed on a focused part that adjusts (`ShapePart.adjust`): which way, one step or,
/// with ⇧, a large one; or, with ⌥⌘, as far as the nearest shape that way.
public struct PartStep: Hashable, Sendable {
    /// The way, a unit along one axis: (1, 0) is →, (0, -1) is ↑ (y grows down).
    public let direction: CGPoint
    /// ⇧ is held.
    public let isLarge: Bool
    /// ⌥⌘ is held: to the nearest shape that way (`editor.nearestShape(to:toward:among:)`), as ⌥⌘ and an
    /// arrow select it when no part takes the key (an arrow's end binds to it).
    public let toNearest: Bool

    public init(direction: CGPoint, isLarge: Bool = false, toNearest: Bool = false) {
        self.direction = direction
        self.isLarge = isLarge
        self.toNearest = toNearest
    }

    /// The way, as stepping between shapes names it (`AdjacentDirection`): left, right, up or down.
    public var adjacentDirection: AdjacentDirection {
        abs(direction.x) >= abs(direction.y) ? (direction.x < 0 ? .left : .right) : (direction.y < 0 ? .up : .down)
    }

    /// The step in world units, as far as a nudge goes: 1, or 10 with ⇧.
    @MainActor public var offset: CGPoint {
        let distance = isLarge ? SelectionStyle.shiftNudge : SelectionStyle.nudge
        return CGPoint(x: direction.x * distance, y: direction.y * distance)
    }
}

/// One part of a shape, as a plugin lists it (`registrar.forShapes(…) { $0.shapeParts { … } }`).
public struct ShapePart {
    /// Stable from one listing to the next while it is the same part (an adornment's button, a handle,
    /// an edge): the focus follows it.
    public var id: AnyHashable
    /// What VoiceOver says of it: "Locked", "Person", "Go to Original".
    public var title: String
    public var role: PartRole
    /// Where it is drawn, in world units: the ring goes around it, and it is brought into view.
    public var rect: CGRect
    /// What a click on it does: Return and Space run it. A press that pops a menu or opens a card leaves the
    /// focus on the part, so Escape out of the menu lands back on it.
    public var press: @MainActor (CanvasEditor) -> Void
    /// What an arrow key does to it, for a part that is moved (a handle): whether it took the step. Nil, or a
    /// step it doesn't take, nudges the shape as the arrow keys do.
    public var adjust: (@MainActor (CanvasEditor, PartStep) -> Bool)?
    /// Shapes the part stands for, outlined as the selection is while it has the focus, besides its ring (a connection's
    /// arrow, drawn whole in the focus color, so the ring at its end is read as the arrow's).
    public var lights: [ShapeID]

    public init<ID: Hashable & Sendable>(id: ID, title: String, role: PartRole = .button, rect: CGRect, lights: [ShapeID] = [],
                                         press: @escaping @MainActor (CanvasEditor) -> Void,
                                         adjust: (@MainActor (CanvasEditor, PartStep) -> Bool)? = nil) {
        self.id = AnyHashable(id)
        self.title = title
        self.role = role
        self.rect = rect
        self.lights = lights
        self.press = press
        self.adjust = adjust
    }
}

extension ShapePart: Identifiable {}

/// One plugin's parts of a shape. Only the sugar makes one.
@MainActor
public struct ShapePartSource {
    let order: Int
    /// What the registry's report calls them, after "parts".
    let name: String?
    let parts: @MainActor (CanvasEditor, AnyShapeRecord) -> [ShapePart]
}

extension ScopedRegistrar {
    /// Parts of the shapes of every kind the scope reaches (see `ShapeParts`): `parts` lists those of one
    /// shape, given the editor; empty for none. Listed only when a key asks, so it may lay out what it
    /// needs. Where two parts are level, `order` puts them (lower first), then plugin order. `name` is what
    /// the registry's report says they are.
    ///
    ///     registrar.forShapes(holding: LinkProperty.self) { link in
    ///         link.shapeParts { editor, shape in
    ///             editor.goButtonRect(of: shape.id).map { [ShapePart(id: "go", title: "Go to Original", role: .link, rect: $0) { $0.follow(shape.id) }] } ?? []
    ///         }
    ///     }
    public mutating func shapeParts(order: Int = 0, named name: String? = nil,
                                    _ parts: @escaping @MainActor (CanvasEditor, AnyShapeRecord) -> [ShapePart]) {
        contribute(ShapePartSource(order: order, name: name, parts: parts), to: ShapeParts.self)
    }
}

extension ShapeRegistrar {
    /// Parts of this kind's shapes (see `ShapeParts`), as `shapeParts` in a scope lists them.
    public mutating func shapeParts(order: Int = 0, named name: String? = nil,
                                    _ parts: @escaping @MainActor (CanvasEditor, ShapeRecord<Definition.Props>) -> [ShapePart]) {
        contribute(ShapePartSource(order: order, name: name) { editor, shape in shape.typed(as: Definition.Props.self).map { parts(editor, $0) } ?? [] },
                   to: ShapeParts.self)
    }
}

extension PluginRegistrar {
    /// Parts of the shapes of a kind another plugin registers, as a kind's own registrar lists them.
    public mutating func shapeParts<P: ShapeProps>(on _: P.Type, order: Int = 0, named name: String? = nil,
                                                   _ parts: @escaping @MainActor (CanvasEditor, ShapeRecord<P>) -> [ShapePart]) {
        contribute(ShapePartSource(order: order, name: name) { editor, shape in shape.typed(as: P.self).map { parts(editor, $0) } ?? [] },
                   to: ShapeParts.self, for: .kind(P.kind))
    }
}

// MARK: Reading them

extension CanvasEditor {
    /// A shape's parts (`ShapeParts`): its own (chips, pills, buttons, handles) and then its arrows (`.connection`), each in
    /// reading order of their rects' middles (`StopOrder.reading`, as Tab reads shapes, a row being parts level within half
    /// the shortest one's height, so a note's rows are read top to bottom), parts whose middles are level in `order`, then
    /// plugin order; a part two plugins list (the same id) once. None for a shape not on the board shown, nor for the shape being edited,
    /// whose parts are its editor's.
    public func shapeParts(of id: ShapeID) -> [ShapePart] {
        guard editingShapeID != id, let record = document[id] else { return [] }
        let sources = registry.contributions(to: ShapeParts.self, for: record.kind)
        guard !sources.isEmpty else { return [] }
        var seen = Set<AnyHashable>()
        let listed = sources.enumerated()
            .sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
            .flatMap { $0.element.parts(self, record) }
            .filter { !$0.rect.isNull && seen.insert($0.id).inserted }
        // The shape's own parts first (chips, pills, buttons, handles), then its arrows (keyboard navigation's principle 3),
        // each in reading order: ⌥⇧Tab from the shape reaches its last arrow at once, and ⌥Tab still starts at its first chip.
        // A row of parts is level within half the shortest one's height: a note's rows, a field's height apart, are rows of their own.
        func reading(_ parts: [ShapePart]) -> [ShapePart] {
            let range = max(1, (parts.map(\.rect.height).min() ?? 0) / 2)
            return StopOrder.reading(parts, rowRange: range) { CGPoint(x: $0.rect.midX, y: $0.rect.midY) }
        }
        return reading(listed.filter { $0.role != .connection }) + reading(listed.filter { $0.role == .connection })
    }

    /// The focused part of the only selected shape (⌥Tab), as listed now; nil when none is.
    public var focusedPart: ShapePart? {
        guard let focus = selectionState?.partFocus, editingShapeID == nil else { return nil }
        return shapeParts(of: focus.shape).first { $0.id == focus.part }
    }

    /// Whether a part of the selected shape has the keyboard (⌥Tab): one is focused and still listed. A part
    /// gone with no commit (a handle or a chip left out as the zoom changed) has none: it draws no ring, and keys
    /// go on as with no part focused.
    public var hasFocusedPart: Bool { focusedPart != nil }

    /// Whether a focused part has the keyboard where `subject` was asked for: a key or the menu bar (no point),
    /// acting on the shape the part is on, which the part stands in front of (Delete there deletes nothing). A
    /// surface that brings its own shapes and click (a context menu) acts on them whatever part is focused.
    public func hasFocusedPart(for subject: CommandSubject) -> Bool {
        guard subject.point == nil, subject.shapes.count == 1, selectionState?.partFocus?.shape == subject.shapes[0] else { return false }
        return hasFocusedPart
    }

    /// Whether ⌥Tab and ⌥⇧Tab go into the selected shape's parts: one shape is selected, and nothing is
    /// under way or being edited.
    public var canFocusParts: Bool { session == nil && editingShapeID == nil && selection != nil }

    /// ⌥Tab (`.next`) and ⌥⇧Tab (`.previous`): with no part focused, the only selected shape's first or
    /// last stop; with one, the next or previous, round from the last to the first. A shape with items (`ShapeItems`: a
    /// table's rows) has them as its first stop, one stop whose items ↑ ↓ walk, as a list is one stop of a panel's loop:
    /// ⌥Tab from the shape selects its first item, and from the items goes on to its first part; coming back to the items
    /// (⌥⇧Tab from the first part, ⌥Tab round from the last) selects the items that were left, so each key's opposite lands
    /// where it was. Brought into view if it is not (`revealIfOffscreen`). A shape with no parts and no items focuses none.
    /// Any other direction does nothing.
    public func focusAdjacentPart(_ direction: AdjacentDirection) {
        guard canFocusParts, let id = selection, let state = selectionState, direction == .next || direction == .previous else { return }
        let parts = shapeParts(of: id)
        let items = shapeItems(of: id)
        // The ring: the items as one stop (0) where the shape lists any, then each part.
        let first = items.isEmpty ? 0 : 1, count = first + parts.count
        guard count > 0 else { return }
        let forward = direction == .next
        let at: Int?
        if !items.isEmpty, let held = state.items, held.shape == id {
            at = 0
        } else if let focus = state.partFocus, focus.shape == id, let part = parts.firstIndex(where: { $0.id == focus.part }) {
            at = first + part
        } else {
            at = nil
        }
        let index = at.map { ($0 + (forward ? 1 : count - 1)) % count } ?? (forward ? 0 : count - 1)
        guard index != at else { return }
        if index < first {
            // Back to the items: those left by ⌥Tab, while the shape still lists one of them; else its first.
            let left = state.itemsLeft.flatMap { $0.shape == id ? $0 : nil }
            state.setItems(left?.ids ?? [items[0].id], of: id, anchor: left?.anchor)
            if selectedItems == nil { state.setItems([items[0].id], of: id, anchor: nil) }
            if let rect = items.first(where: { selectedItems?.ids.first == $0.id })?.rect { revealIfOffscreen(rect: rect) }
            return
        }
        if at == 0, first == 1 { state.itemsLeft = state.items }
        let part = parts[index - first]
        state.focusPart(part, of: id)
        revealIfOffscreen(rect: part.rect)
    }

    /// Presses the focused part, as a click on it does: whether there was one to press. The focus stays on
    /// it (a menu it pops comes back to it); a commit that takes it away lets it go.
    @discardableResult
    public func pressFocusedPart() -> Bool {
        guard session == nil, let part = focusedPart else { return false }
        part.press(self)
        return true
    }

    /// An arrow key on the focused part: its `adjust`, if it has one and takes the step. False when there is
    /// none to take it (the arrow then nudges; with ⌥⌘, steps to the nearest shape).
    func adjustFocusedPart(_ step: PartStep) -> Bool {
        guard let adjust = focusedPart?.adjust else { return false }
        return adjust(self, step)
    }

    /// An arrow key with the selection: the focused part adjusted, else the selection nudged. A held key keeps what
    /// its press did: once it has adjusted a part in the step it holds open, its repeats adjust or do nothing, never
    /// nudge, so a handle the key shrinks the box past (no longer shown, its focus gone) leaves the shape where it is.
    func arrow(_ direction: CGPoint, large: Bool) {
        let step = PartStep(direction: direction, isLarge: large)
        if adjustFocusedPart(step) {
            undoHistory.finishing(HeldPartAdjust()) {}
            return
        }
        guard !undoHistory.willFinish(HeldPartAdjust()) else { return }
        nudgeSelection(by: step.offset)
    }

    /// Whether an arrow key with nothing selected pans: nothing's under way or edited, and the view has a size.
    var canPanByKeys: Bool { session == nil && editingShapeID == nil && selectedShapeIDs.isEmpty && canPan }

    /// An arrow key on the canvas: with a selection, `arrow`; with none, the view panned that way a step, a page
    /// with ⇧ (`pan`).
    func arrowKey(_ direction: CGPoint, large: Bool) {
        if arrowOnItems(direction, extending: large) { return }
        if canNudge { return arrow(direction, large: large) }
        guard canPanByKeys else { return }
        pan(direction.x < 0 ? .left : direction.x > 0 ? .right : direction.y < 0 ? .up : .down, far: large)
    }

    /// Return and Enter on the canvas: the focused part pressed (⌥Tab), else the placing tool's shape put down and
    /// edited (`placeAtKeyboard`), else the first selected item opened (a row edited), else the selection opened
    /// (`.openSelection`).
    func returnKey() {
        if pressFocusedPart() || placeAtKeyboard() || openSelectedItem() { return }
        perform(.openSelection)
    }
}

// MARK: The focus

extension SelectionState {
    /// The focus moves to `part` of `shape`; the ring is drawn there.
    func focusPart(_ part: ShapePart, of shape: ShapeID) {
        items = nil
        partFocus = PartFocus(shape: shape, part: part.id)
        focusedPartRing = PartRing(rect: part.rect, lights: part.lights, revision: editor.revision, layout: editor.layoutRevision, zoom: editor.camera.zoom)
        editor.setNeedsDisplay()
    }

    /// The focus goes back to its shape: whether a part had it.
    @discardableResult
    func clearPartFocus() -> Bool {
        guard partFocus != nil else { return false }
        partFocus = nil
        focusedPartRing = nil
        editor.setNeedsDisplay()
        return true
    }

    /// Where the focused part is drawn, in world units: kept from the last listing until the board, the layout
    /// or the zoom changes (an adornment's size is in view points), then listed again. Nil with none focused, one
    /// that is gone, and while the shape is edited.
    var focusedPartRect: CGRect? { focusedRing?.rect }

    /// What the focused part lights besides its ring (`ShapePart.lights`), outlined with the selection. Empty with none.
    var focusedPartLights: [ShapeID] { focusedRing?.lights ?? [] }

    private var focusedRing: PartRing? {
        guard let focus = partFocus, editor.editingShapeID == nil else { return nil }
        let revision = editor.revision, layout = editor.layoutRevision, zoom = editor.camera.zoom
        if let ring = focusedPartRing, ring.revision == revision, ring.layout == layout, ring.zoom == zoom { return ring }
        let part = editor.shapeParts(of: focus.shape).first { $0.id == focus.part }
        focusedPartRing = part.map { PartRing(rect: $0.rect, lights: $0.lights, revision: revision, layout: layout, zoom: zoom) }
        return focusedPartRing
    }

    /// A commit has been taken in by every service: a focused part it took away (a lock chip whose shape was
    /// unlocked) lets its focus go back to the shape.
    func partFocusDidSettle() {
        guard let focus = partFocus else { return }
        if !editor.shapeParts(of: focus.shape).contains(where: { $0.id == focus.part }) { clearPartFocus() }
    }
}

/// The open step's arrow keys adjusted a part (`arrow`): its repeats are the part's.
private struct HeldPartAdjust: Hashable {}

/// Which part of which shape has the keyboard.
struct PartFocus: Equatable {
    let shape: ShapeID
    let part: AnyHashable
}

/// Where the focused part's ring was drawn, and what that was worked out from.
struct PartRing {
    let rect: CGRect
    let lights: [ShapeID]
    let revision: Int
    let layout: Int
    let zoom: CGFloat
}

/// The focused part's ring (⌥Tab): an accent outline stood off its rect, its corners as round as a chip's, in
/// view points over the zoom. It goes where its shape is drawn (`worldDrawingOffset`), as the part does: a refused
/// key's shake and a settle's glide carry it with the chip.
struct PartFocusOverlay: CanvasOverlay {
    var space: OverlaySpace { .world }

    func draw(in overlay: OverlayContext) {
        guard let state = overlay.editor.selectionState, let shape = state.partFocus?.shape, let rect = state.focusedPartRect else { return }
        let zoom = overlay.zoom, standoff = SelectionStyle.partRingStandoff / zoom, offset = overlay.worldDrawingOffset(of: shape)
        let ring = rect.insetBy(dx: -standoff, dy: -standoff).offsetBy(dx: offset.x, dy: offset.y)
        guard ring.intersects(overlay.visibleRect.insetBy(dx: -overlay.worldDrawingReach, dy: -overlay.worldDrawingReach)) else { return }
        let radius = min(ring.height, ring.width) / 2
        let cg = overlay.cg
        cg.saveGState()
        cg.setStrokeColor(SelectionStyle.accent.cgColor)
        cg.setLineWidth(SelectionStyle.partRingWidth / zoom)
        cg.addPath(CGPath(roundedRect: ring, cornerWidth: radius, cornerHeight: radius, transform: nil))
        cg.strokePath()
        cg.restoreGState()
    }
}
