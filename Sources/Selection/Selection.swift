import Canvas
import CoreGraphics
import Geometry
import Keyboard

/// Selecting shapes, as a plugin: the selection itself (`editor.selection`,
/// `editor.selectedShapeIDs`) and the way back through it (`editor.goBack()`), the Select tool and
/// its marquee, the handles of the one selected shape (its kind's own, and a resizable kind's eight:
/// `ShapeResizing`, `x.resizable(minimumSize:)`), what Delete, Return, ⌘A and Back do (their
/// keys are registered with Keyboard), what opening a shape does (`ShapeOpening`: a double-click,
/// Return, ⌘↓), and what a double-click on empty canvas places. Every kind is
/// selectable unless it opts out (`shape.unselectable()`). The core never learns what a selection
/// is: it outlines what this plugin asks, and tells it about Escape, commands, placed shapes and
/// document changes.
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

/// Something a plugin draws for a shape outside it (Adornments' pills and chips) that counts as the
/// shape: `selectableShape(at:)`, and so the select tool's press, hover and release and the context
/// menu, take a point on it as a point on its shape. Asked before shapes, since such drawing is
/// above every shape, the last plugin's first. Each finds the front-most shape, of those `include`
/// accepts, with its drawing under a world point. A canvas button is still asked first.
public enum DecorationHits {}

extension DecorationHits: ExtensionPoint {
    public typealias Contribution = @MainActor (CanvasEditor, CGPoint, (AnyShapeRecord) -> Bool) -> ShapeID?
    public static var owner: PluginID { .selection }
}

/// What dragging the selection with ⌥ held moves: copies of it, put down in place when the drag
/// begins (tldraw's), in the step of the drag. A plugin that can copy shapes returns the copies, selected
/// by the plugin or not; none claiming it (or an answer of none) leaves the drag moving the shapes
/// themselves. At most one plugin answers; the first wins.
public enum DragCopies {}

extension DragCopies: ExtensionPoint {
    public typealias Contribution = @MainActor (CanvasEditor, [ShapeID]) -> [ShapeID]
    public static var owner: PluginID { .selection }
}

/// What a plugin does when the selection changes, told as it has (after the change, the shapes it left and the shapes it
/// holds now, in order): the arrow that offers a relationship type's pill while it is the only shape selected
/// (Types'). Every plugin's is told, each time the selection changes, including when it is cleared by showing another
/// board; keep it cheap.
public enum SelectionObservers {}

extension SelectionObservers: ExtensionPoint {
    public typealias Contribution = @MainActor (CanvasEditor, _ left: [ShapeID], _ now: [ShapeID]) -> Void
    public static var owner: PluginID { .selection }
}

extension PluginRegistrar {
    /// This plugin is told each time the selection changes (see `SelectionObservers`).
    public mutating func selectionChanged(_ observe: @escaping @MainActor (CanvasEditor, _ left: [ShapeID], _ now: [ShapeID]) -> Void) {
        contribute(observe, to: SelectionObservers.self)
    }
}

// Sugar, so opting in or out is one line.
extension ShapeRegistrar {
    /// The select tool sees through this kind's shapes: a press lands on what's beneath them (or
    /// on the canvas, where a drag is a marquee), and the marquee and ⌘A pass them by, so they're
    /// never selected or outlined on hover. They still draw, and everything else treats them as
    /// usual: arrows bind to them, code moves them.
    public mutating func unselectable() {
        contribute({ _ in false }, to: ShapeSelectability.self)
    }

    /// Selectable only while `isSelectable` says so (a shape that's hidden, say; a locked one is
    /// selectable, and only refuses changes). A shape that stops being selectable leaves the
    /// selection with the change that did it.
    public mutating func selectable(when isSelectable: @escaping @MainActor (ShapeRecord<Definition.Props>) -> Bool) {
        contribute({ $0.typed(as: Definition.Props.self).map(isSelectable) ?? false }, to: ShapeSelectability.self)
    }

    /// Double-clicking empty canvas with the select tool places this. At most one kind may claim it.
    public mutating func createOnDoubleClick(_ placement: Placement) {
        precondition(placement.kind == kind, "\(kind) can't claim double-click for \(placement.kind)")
        contribute(placement, to: DoubleClickPlacement.self)
    }
}

extension PluginRegistrar {
    /// What this plugin draws for shapes outside them, as those shapes (see `DecorationHits`): `find`
    /// returns the front-most shape `include` accepts whose drawing is under a world point, or nil.
    /// The select tool asks it as the pointer moves, so keep it cheap.
    public mutating func decorationHits(_ find: @escaping @MainActor (CanvasEditor, CGPoint, (AnyShapeRecord) -> Bool) -> ShapeID?) {
        contribute(find, to: DecorationHits.self)
    }
}

extension PluginRegistrar {
    /// What this plugin carries in place of the selection when it is dragged with ⌥ held: copies of the
    /// shapes, in place (see `DragCopies`), which the drag then moves. Nothing for what can't be copied.
    public mutating func copiesOnDrag(_ copy: @escaping @MainActor (CanvasEditor, [ShapeID]) -> [ShapeID]) {
        contribute(copy, to: DragCopies.self)
    }
}

extension CanvasEditor {
    /// Whether some plugin copies shapes for a drag with ⌥ (`registrar.copiesOnDrag`).
    var copiesOnDrag: Bool { !registry.contributions(to: DragCopies.self).isEmpty }

    /// The session that drags the selection from `origin` (world units): moving it, or, with ⌥ held where a
    /// plugin copies shapes (`registrar.copiesOnDrag`) and none of it is read-only (a drag then refuses to
    /// move it, as ever), moving copies of it, put down in place now, in the press's step, and selected;
    /// Escape takes them away again.
    func translationSession(from origin: CGPoint, pointer: Pointer) -> any Session {
        let ids = selectedShapeIDs
        guard pointer.modifiers.contains(.option), !ids.isEmpty, !isBoardReadOnly, !ids.contains(where: { isReadOnly($0) }),
              let copy = registry.contributions(to: DragCopies.self).first?.value else {
            return TranslatingSession(ids: ids, from: origin, in: self)
        }
        let copies = copy(self, ids)
        guard !copies.isEmpty else { return TranslatingSession(ids: ids, from: origin, in: self) }
        selectedShapeIDs = copies
        return CopyDraggingSession(moving: TranslatingSession(ids: copies, from: origin, in: self), copies: copies, from: ids)
    }
}

/// A drag with ⌥ held that carries copies (`translationSession`): the copies follow the pointer as a drag of
/// them does, and Escape puts them back and takes them away, the selection as it was, so the press comes to
/// nothing (the step it opened ends where it began and is dropped).
@MainActor
final class CopyDraggingSession {
    private let move: TranslatingSession
    private let copies: [ShapeID]
    private let originals: [ShapeID]

    init(moving move: TranslatingSession, copies: [ShapeID], from originals: [ShapeID]) {
        self.move = move
        self.copies = copies
        self.originals = originals
    }
}

extension CopyDraggingSession: Session {
    var scrollsAtEdges: Bool { move.scrollsAtEdges }
    func drag(_ pointer: Pointer, in editor: CanvasEditor) { move.drag(pointer, in: editor) }
    func modifiersChanged(_ modifiers: Modifiers, in editor: CanvasEditor) { move.modifiersChanged(modifiers, in: editor) }
    func end(_ pointer: Pointer, in editor: CanvasEditor) { move.end(pointer, in: editor) }
    func draw(in context: OverlayContext) { move.draw(in: context) }

    func cancel(in editor: CanvasEditor) -> Bool {
        _ = move.cancel(in: editor)
        // A container deleted lets go of what it holds, so the copies of what a copied container holds go with it.
        let kinds = editor.registry.containingKinds, document = editor.document
        var gone = Set(copies)
        if !kinds.isEmpty { for id in copies { gone.formUnion(document.descendants(of: id, containingKinds: kinds)) } }
        editor.transact { $0.delete(gone) }
        editor.selectedShapeIDs = originals.filter { editor.document[$0] != nil }
        return true
    }
}

public struct SelectionPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .selection }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { SelectionState(editor: $0) }
        registrar.service { RefusalShake(editor: $0) }
        registrar.tool(ToolDescriptor(id: .select, label: "Select", systemImage: "cursorarrow"), shortcut: "v") { _ in SelectTool() }
        registrar.defaultTool(.select)
        registrar.outlines { $0.selectionOutlines }
        registrar.overlay(GroupFocusOverlay())
        registrar.overlay(HandlesOverlay())
        // Delete and Forward Delete, and Edit › Delete, delete the selection, while there is one (a
        // locked one too, which shakes); ⌘A and Edit › Select All select everything, while the
        // board has shapes; ⌘[ and Go › Back go back to what was selected before, when there's
        // somewhere to go; ⌘↓ opens the only selected shape, when it can be opened and isn't being
        // edited (⌘↓ is then the text's), and Return (and Enter) does too, but always takes the
        // key, as it did when it only edited; ⇧2 and View › Zoom to Selection bring the selection
        // into view (tldraw's key), and a trackpad's smart zoom the shape under the pointer.
        registrar.command(.delete, shortcuts: [.delete, .deleteForward], isEnabled: { !$0.selectedShapeIDs.isEmpty }) { $0.deleteSelection() }
        registrar.command(.selectAll, shortcuts: [KeyChord("a", .command)], isEnabled: { !$0.document.shapes.isEmpty }) { $0.selectAll() }
        registrar.command(.goBack, shortcuts: [KeyChord("[", .command)], isEnabled: { $0.canGoBack && $0.session == nil }) { $0.goBack() }
        registrar.command(.openSelection, shortcuts: [KeyChord(KeyChord.downArrow.key, .command)],
                          isEnabled: { editor in
                              editor.session == nil && editor.editingShapeID == nil && (editor.selection.map(editor.canOpen) ?? false)
                          }) { $0.openSelection() }
        registrar.shortcut(.return, "Open Selection") { $0.perform(.openSelection) }
        registrar.shortcut(.enter, "Open Selection") { $0.perform(.openSelection) }
        registrar.command(.zoomToSelection, shortcuts: [KeyChord("2", .shift)],
                          isEnabled: { !$0.selectedShapeIDs.isEmpty && !$0.unobscuredViewport.isEmpty }) { $0.reveal($0.selectedShapeIDs) }
        registrar.command(.smartMagnify) { $0.smartMagnify() }
        // ← → ↑ ↓ nudge the selection a world unit, and ten with ⇧, again and again while held (one
        // undo step), while nothing's under way or being edited; with nothing selected they pass.
        for (arrow, direction) in SelectionStyle.nudges {
            registrar.shortcut(arrow, "Nudge", when: { $0.canNudge }, repeats: true) { $0.nudgeSelection(by: direction * SelectionStyle.nudge) }
            registrar.shortcut(KeyChord(arrow.key, .shift), "Nudge", when: { $0.canNudge }, repeats: true) {
                $0.nudgeSelection(by: direction * SelectionStyle.shiftNudge)
            }
        }
    }
}
