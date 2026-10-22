import Canvas
import CoreGraphics
import Foundation
import Selection
import Titles

// The card that defines a relationship type: a click on its pill opens it under the pill, so do Open Fields and the pill's part
// (⌥Tab), and Tab in the pill's name does (`RelationshipHooks.openDefinition`) at its first line past the name. The core's card about the type with a
// `DefinitionView` in it, which hangs from the pill's laid-out frame and follows it; it reads the file again after each commit (the
// type, its schema, its title, its end arrows' words and rules, an end drawn or taken away) and closes when the type goes or stops
// being a relationship type.
//
// The card is the pill's parts, as a typed note's rows are its words': Tab walks the pill's name, the card's stops, then the next
// shape the pill's kind goes on to (`DefinitionWalks`: a note's, the next note, at its words). So Tab off the card's last stop goes
// there, ⇧Tab off its first stop (or at the stop Tab in the name brought the keyboard in at) comes back to the name, and Escape and
// Return on the blank `add field` leave the type selected with the canvas having the keyboard.

/// The card's id: its type.
struct DefinitionCardID: Hashable, Sendable {
    var hub: ShapeID
}

@MainActor
public final class DefinitionCards {
    private weak var editor: CanvasEditor?
    private var session: (id: DefinitionCardID, view: DefinitionView)?

    public init(editor: CanvasEditor) {
        self.editor = editor
    }

    /// The type whose card is open.
    public var openType: ShapeID? { session?.id.hub }

    /// The card showing: for tests and the gallery.
    public var openView: DefinitionView? { session?.view }

    /// Opens the type's card under its pill, with the type selected, and the keyboard at `stop` (the name when none is given), or at
    /// its last stop `fromEnd` (⇧Tab from the shape after the pill). `enteredByKey`: a key from outside the card brought the keyboard
    /// in (Tab in the pill's name), so ⇧Tab at that stop goes back out. Asked for the type whose card is open, it takes the card down
    /// and answers true. False, and nothing shown, for a shape that is no relationship type, one not on the board shown, and a board
    /// drawn as skeletons (a card is refused among them). A locked type's card opens to be read, with no caret.
    @discardableResult
    public func open(_ hub: ShapeID, focus stop: DefinitionStop? = nil, fromEnd: Bool = false, enteredByKey: Bool = false) -> Bool {
        guard let editor, editor.document[hub] != nil, let model = DefinitionModel.read(hub, in: editor), let anchor = editor.frame(inFile: hub) else { return false }
        let id = DefinitionCardID(hub: hub)
        if session?.id == id {
            editor.closeCard()
            return true
        }
        let view = DefinitionView(editor: editor, hub: hub, model: model)
        view.onClose = { [weak self] closing in self?.closed(closing, hub: hub) }
        view.onResize = { [weak editor] in editor?.cardDidResize() }
        view.onGone = { [weak self] in self?.close() }
        let card = CanvasCard(id: id, about: hub, anchor: anchor, view: view, firstResponder: view, stepName: nil,
                              accessibilityLabel: TypesStyle.fieldsAccessibilityLabel(of: editor.document[hub].flatMap { editor.registry.title(of: $0) }),
                              size: { [unowned view] room in view.fittingSize(room: room) },
                              didClose: { [weak self] reason in self?.cardClosed(id: id, reason) })
        guard editor.showCard(card) else { return false }
        session = (id, view)
        if editor.selection != hub { editor.selection = hub }
        editor.setNeedsDisplay()
        // Tab in the pill's name comes in at the first line past the name (the name is the pill's), as ⇧Tab from the shape after it
        // comes in at the last: the walk visits every line once, and each key undoes the other.
        view.passesTitle = enteredByKey || fromEnd
        let at = fromEnd ? view.stops.last : stop ?? (enteredByKey ? view.stops.first { $0 != .title } : view.stops.first)
        if enteredByKey { view.enter(at: at) } else { view.focus(at) }
        return true
    }

    /// The card asked to be taken down by a key: Escape and Return leave the type selected and the canvas with the keyboard; ⇧Tab
    /// off the first stop edits the pill's name again; Tab off the last goes on to the shape the kind says (`DefinitionWalks`),
    /// else round to the name. A type that is gone, or locked, is left selected.
    private func closed(_ closing: DefinitionView.Closing, hub: ShapeID) {
        close()
        guard let editor, let record = editor.document[hub] else { return }
        if editor.selection != hub { editor.selection = hub }
        guard case .tabbed(let forward) = closing, !editor.isReadOnly(hub) else { return }
        if forward, let walk = editor.registry.contributions(to: DefinitionWalks.self, for: record.kind).first, walk.onward(editor, hub) { return }
        editor.beginEditing(hub)
    }

    /// Takes the card down, if one of this service's shows.
    public func close() {
        guard session != nil else { return }
        editor?.closeCard()
    }

    /// The core took the card down, for any reason: what was typed is kept where the person left it (a press elsewhere, `close()`);
    /// an undo, another board or the type going leave the file as it is.
    private func cardClosed(id: DefinitionCardID, _ reason: CanvasCardClosing) {
        guard let held = session, held.id == id else { return }
        session = nil
        if reason == .pressedElsewhere || reason == .asked { held.view.commitPending() }
        editor?.setNeedsDisplay()
    }

    /// A commit: the card reads the type again and hangs from its pill where it is now.
    private func hear(_ changes: ChangeSet, in editor: CanvasEditor) {
        guard let held = session, editor.card?.id == AnyHashable(held.id) else { return }
        guard DefinitionModel.read(held.id.hub, in: editor) != nil, let frame = editor.frame(inFile: held.id.hub) else { return editor.closeCard() }
        held.view.reload()
        editor.moveCard(to: frame)
    }
}

extension DefinitionCards: EditorService {
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        hear(changes, in: editor)
    }
}

/// Where Tab goes on to off the last stop of the card that defines a relationship type, for the kind whose pill it hangs from:
/// the next shape the kind's editor would go to (a note's, the next note, edited at its words). One per kind; without one, Tab comes
/// round to the pill's name.
public enum DefinitionWalks {}

extension DefinitionWalks: KeyedExtensionPoint {
    public typealias Contribution = DefinitionWalk
    public static var owner: PluginID { .types }
    public static func uniqueKeys(of _: DefinitionWalk, for target: ShapeTarget) -> [AnyHashable] { [target] }
    public static func summary(of _: DefinitionWalk, for target: ShapeTarget) -> String { "definition walk → \(target)" }
}

/// One kind's walk on from its pill's card: only the sugar makes one.
@MainActor
public struct DefinitionWalk {
    /// Goes on from the pill `id`: whether it went anywhere.
    let onward: @MainActor (CanvasEditor, ShapeID) -> Bool
}

extension ShapeRegistrar {
    /// Where Tab off the last stop of this kind's relationship type's card goes on to (`DefinitionWalks`): `onward` goes on from the
    /// pill and says whether it went anywhere (false comes round to the pill's name).
    ///
    ///     note.definitionWalk { editor, id in editor.service(NoteHops.self)?.editNote(.next, from: id) ?? false }
    public mutating func definitionWalk(_ onward: @escaping @MainActor (CanvasEditor, ShapeID) -> Bool) {
        contribute(DefinitionWalk(onward: onward), to: DefinitionWalks.self)
    }
}

extension CanvasEditor {
    /// The card that defines a relationship type (`DefinitionCards`); nil without TypesPlugin.
    public var definitionCards: DefinitionCards? { service(DefinitionCards.self) }
}
