import Canvas
import CoreGraphics
import Geometry
import Keyboard

/// Selecting shapes, as a plugin: the selection itself (`editor.selection`,
/// `editor.selectedShapeIDs`) and the way back through the places it was (`editor.goBack()`), the Select tool and
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

extension CanvasCommand {
    /// Delete (⌫, ⌦; Edit › Delete): the shapes deleted, a locked one refused and shaking.
    public static let delete: CanvasCommand = "delete"
    /// Select All (⌘A; Edit › Select All): every shape of the board shown.
    public static let selectAll: CanvasCommand = "selectAll"
    /// Go › Back (⌘[, and ⌃- as VS Code has it): the last place gone from, its board, selection and camera,
    /// whatever has the keyboard.
    public static let goBack: CanvasCommand = "goBack"
    /// Go › Forward (⌘], and ⌃⇧-): where Back left, again.
    public static let goForward: CanvasCommand = "goForward"
    /// Go › Open Selection (⌘↓): a shape alone opened (its board shown, or edited), or a group whole or
    /// a container alone gone into; the selection, or a context menu's shapes.
    public static let openSelection: CanvasCommand = "openSelection"
    /// View › Zoom to Selection (⇧2): the shapes brought into view.
    public static let zoomToSelection: CanvasCommand = "zoomToSelection"
    /// A trackpad's smart zoom (a two-finger double-tap): the shape under the pointer brought into
    /// view, and again back.
    public static let smartMagnify: CanvasCommand = "smartMagnify"
}

/// Go's section of moving between shapes and boards: Back, Forward right after it, and Open Selection,
/// with what's placed beside them (a board's way up, after Forward) and after them (where a mention goes).
public enum NavigationSection {}
extension NavigationSection: MenuBarSection {
    public static var menu: MenuBarMenu { "Go" }
}

/// Whether a kind's shapes can be selected. At most one rule per kind, plus one for every kind
/// (`.any`), which a kind's own overrides; a kind with neither is always selectable.
public enum ShapeSelectability: KeyedExtensionPoint {
    public typealias Contribution = @MainActor (AnyShapeRecord) -> Bool
    public static var owner: PluginID { .selection }
    public static func uniqueKeys(of _: Contribution, for target: ShapeTarget) -> [AnyHashable] { [target] }
}

/// What a double-click on empty canvas with the select tool places. At most one kind may claim it; a kit
/// switches it, so while the claimant's kit is off in a file a double-click there places nothing.
public enum DoubleClickPlacement: KeyedExtensionPoint, KitSwitched {
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
        registrar.overlay(PartFocusOverlay())
        // The keys the select tool and resizing read with the pointer, for the Keyboard Shortcuts window.
        registrar.keyHint("⇧ or ⌘ Click", "Add or Remove From Selection", while: .pointer)
        registrar.keyHint("⌘ Drag", "Select Shapes Wholly in the Box", while: .pointer)
        registrar.keyHint("⌥ Drag", "Drag a Copy", while: .pointer)
        registrar.keyHint("⇧ Resize", "Keep Proportions", while: .pointer)
        registrar.keyHint("⌥ Resize", "Resize From the Center", while: .pointer)
        // What a command run from a key or the menu bar acts on: the selection; and VoiceOver's press on
        // a shape selects it, as Tab does.
        registrar.commandShapes({ $0.selectedShapeIDs }, select: { editor, ids in
            editor.selectedShapeIDs = ids
            editor.revealIfOffscreen(ids)
        })
        // VoiceOver walks the board in Tab's order, and a shape's parts are ⌥Tab's (Accessibility.swift).
        registerAccessibility(into: &registrar)
        // Delete and Forward Delete, and Edit › Delete, delete the shapes, while there are some (a
        // locked one too, which shakes) and, from a key or the menu bar, no part of the shape has the keyboard
        // (⌥Tab: a chip focused is no shape to delete; a context menu's Delete deletes its shapes); ⌘A and Edit › Select All select everything, while the
        // board has shapes; ⌘[ (and VS Code's ⌃-) and Go › Back go back to the last place gone from, when
        // there's somewhere to go, and ⌘] (and ⌃⇧-, which types ⌃_) and Go › Forward undo it, the menu bar
        // answering each key wherever ⌘[ works; ⌘↓ opens the only selected shape, when it can be opened and isn't being
        // edited (⌘↓ is then the text's), and Return (and Enter) does too, but always takes the
        // key, as it did when it only edited; a group selected whole, or a container that is neither
        // opened nor edited (a frame), is gone into instead, selecting its first part, or the first
        // shape in it, in reading order; ⇧2 and View › Zoom to Selection bring the shapes
        // into view (tldraw's key), and a trackpad's smart zoom the shape under the pointer.
        // An offscreen selection is brought into view as it goes, so the key's effect shows (P7).
        registrar.command(.delete, title: "Delete", answering: .delete, shortcuts: [.delete, .deleteForward],
                          isEnabled: { !$0.shapes.isEmpty && !$0.editor.hasFocusedPart(for: $0) }) {
            $0.editor.revealIfOffscreen($0.shapes)
            $0.editor.deleteShapes($0.shapes)
        }
        registrar.command(.selectAll, title: "Select All", answering: .selectAll, shortcut: KeyChord("a", .command),
                          isEnabled: { !$0.editor.document.shapes.isEmpty }) { $0.editor.selectAll() }
        registrar.command(.goBack, title: "Back", in: NavigationSection.self, shortcuts: [KeyChord("[", .command), KeyChord("-", .control)],
                          runs: .betweenPresses, isEnabled: { $0.editor.canGoBack }) { $0.editor.goBack() }
        registrar.command(.goForward, title: "Forward", in: NavigationSection.self, placed: .after(.goBack),
                          shortcuts: [KeyChord("]", .command), KeyChord("_", .control)], runs: .betweenPresses,
                          isEnabled: { $0.editor.canGoForward }) { $0.editor.goForward() }
        // Return and Enter are keys of their own that always take the key, called as the command is, so
        // the Keyboard Shortcuts window lists them in its row.
        let openSelection = "Open Selection"
        registrar.command(.openSelection, title: openSelection, in: NavigationSection.self, shortcut: KeyChord(KeyChord.downArrow.key, .command),
                          runs: .whenIdle, isEnabled: { $0.editor.canOpenSelection($0.shapes) }) { $0.editor.openSelection($0.shapes) }
        // With a part of the shape focused (⌥Tab), they press it instead, as Space does (`pressFocused`); with a
        // tool picked that places a shape (N, F), they put its shape down at the pointer, or the view's middle, and
        // edit it (`placeAtKeyboard`), as a click with the tool does.
        registrar.shortcut(.return, openSelection) { $0.returnKey() }
        registrar.shortcut(.enter, openSelection) { $0.returnKey() }
        // With ⌥ held they do the same, ⌥ being what a placement lays its shapes out by (`placeLater`: ⌥↩ puts
        // shapes waiting to be placed down as ⌥ shows them).
        registrar.shortcut(KeyChord(KeyChord.return.key, .option), openSelection) { $0.returnKey() }
        registrar.pressFocused { $0.pressFocusedPart() }
        registrar.command(.zoomToSelection, title: "Zoom to Selection", in: ViewMenu.Zoom.self, shortcut: KeyChord("2", .shift),
                          isEnabled: { !$0.shapes.isEmpty && !$0.editor.unobscuredViewport.isEmpty }) { $0.editor.reveal($0.shapes) }
        registrar.command(.smartMagnify, title: "Smart Zoom", answering: .smartMagnify) { $0.editor.smartMagnify() }
        // ← → ↑ ↓ nudge the selection a world unit, and ten with ⇧, again and again while held (one
        // undo step, settled into or out of a container as the key is let go), while nothing's under way or
        // being edited; a focused part that adjusts (a handle) takes them instead. With nothing selected
        // they pan the view a step, and with ⇧ a page (the core's `pan`), as the Hand would.
        for (arrow, direction) in SelectionStyle.nudges {
            registrar.shortcut(arrow, SelectionStyle.nudgeOrPan, when: { $0.canNudge || $0.canPanByKeys }, repeats: true) {
                $0.arrowKey(direction, large: false)
            }
            registrar.shortcut(KeyChord(arrow.key, .shift), SelectionStyle.nudgeOrPan, when: { $0.canNudge || $0.canPanByKeys }, repeats: true) {
                $0.arrowKey(direction, large: true)
            }
        }
        // ⌥ and an arrow resize the only selected shape of a kind that resizes, from its top left: → and ↓ grow it,
        // ← and ↑ shrink it, a world unit, ten with ⇧, again and again while held, one step, "Resize", settled as
        // the key is let go as the drag's release settles it; a read-only one shakes.
        for (arrow, direction) in SelectionStyle.nudges {
            registrar.shortcut(KeyChord(arrow.key, .option), "Resize", when: { $0.keyResizable != nil }, repeats: true) {
                $0.resizeSelection(direction, large: false)
            }
            registrar.shortcut(KeyChord(arrow.key, [.option, .shift]), "Resize", when: { $0.keyResizable != nil }, repeats: true) {
                $0.resizeSelection(direction, large: true)
            }
        }
        // ⌥Tab and ⌥⇧Tab go into the only selected shape's parts (`ShapeParts`: its chips, pills, buttons,
        // handles), the first or the last in reading order, and step between them, round inside the shape;
        // Escape goes back to the shape. Tab stays the shapes'.
        registrar.shortcut(KeyChord(KeyChord.tab.key, .option), "Next Part", when: { $0.canFocusParts }, repeats: true) {
            $0.focusAdjacentPart(.next)
        }
        registrar.shortcut(KeyChord(KeyChord.tab.key, [.option, .shift]), "Previous Part", when: { $0.canFocusParts }, repeats: true) {
            $0.focusAdjacentPart(.previous)
        }
        // Tab and ⇧Tab select the next and previous shape in reading order, ⌥⌘ and an arrow the nearest in
        // that direction, and with ⇧ add it to the selection, among the selection's siblings (tldraw's);
        // again and again while held, while nothing's under way or being edited, and with nothing to step
        // to they take the key.
        registrar.shortcut(.tab, "Next Shape", when: { $0.canStepSelection }, repeats: true) { $0.selectAdjacentShape(.next) }
        registrar.shortcut(KeyChord(KeyChord.tab.key, .shift), "Previous Shape", when: { $0.canStepSelection }, repeats: true) {
            $0.selectAdjacentShape(.previous)
        }
        // A focused part that adjusts (an arrow's end) takes ⌥⌘ and an arrow first (`PartStep.toNearest`).
        for (arrow, direction) in SelectionStyle.steps {
            let vector = SelectionStyle.nudges.first { $0.0 == arrow }?.1 ?? .zero
            registrar.shortcut(KeyChord(arrow.key, [.option, .command]), "Select Nearest Shape", when: { $0.canStepSelection }, repeats: true) {
                if !$0.adjustFocusedPart(PartStep(direction: vector, toNearest: true)) { $0.selectAdjacentShape(direction) }
            }
            registrar.shortcut(KeyChord(arrow.key, [.option, .shift, .command]), "Add Nearest Shape to Selection", when: { $0.canStepSelection },
                               repeats: true) { $0.selectAdjacentShape(direction, adding: true) }
        }
    }
}
