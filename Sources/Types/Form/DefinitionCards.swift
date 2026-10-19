import Canvas
import CoreGraphics
import Foundation
import Selection

// The card that defines a relationship type: a click on its pill opens it under the pill, and Tab in the pill's name does
// (`RelationshipHooks.openDefinition`) at `add field`. The core's card about the type with a `DefinitionView` in it, which hangs
// from the pill's laid-out frame and follows it; it reads the file again after each commit (the type, its schema, its title, its
// end arrows' words and rules, an end drawn or taken away) and closes when the type goes or stops being a relationship type.

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

    /// Opens the type's card under its pill, with the type selected, and the keyboard at `stop` (the name when none is given).
    /// Asked for the type whose card is open, it takes the card down and answers true. False, and nothing shown, for a shape that
    /// is no relationship type, one not on the board shown, and a board drawn as skeletons (a card is refused among them). A
    /// locked type's card opens to be read, with no caret.
    @discardableResult
    public func open(_ hub: ShapeID, focus stop: DefinitionStop? = nil) -> Bool {
        guard let editor, editor.document[hub] != nil, let model = DefinitionModel.read(hub, in: editor), let anchor = editor.frame(inFile: hub) else { return false }
        let id = DefinitionCardID(hub: hub)
        if session?.id == id {
            editor.closeCard()
            return true
        }
        let view = DefinitionView(editor: editor, hub: hub, model: model)
        view.onClose = { [weak self] _ in self?.close() }
        view.onResize = { [weak editor] in editor?.cardDidResize() }
        view.onGone = { [weak self] in self?.close() }
        let card = CanvasCard(id: id, about: hub, anchor: anchor, view: view, firstResponder: view, stepName: nil,
                              size: { [unowned view] room in view.fittingSize(room: room) },
                              didClose: { [weak self] reason in self?.cardClosed(id: id, reason) })
        guard editor.showCard(card) else { return false }
        session = (id, view)
        if editor.selection != hub { editor.selection = hub }
        editor.setNeedsDisplay()
        if let stop { view.focus(stop) } else { view.focusFirst() }
        return true
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

extension CanvasEditor {
    /// The card that defines a relationship type (`DefinitionCards`); nil without TypesPlugin.
    public var definitionCards: DefinitionCards? { service(DefinitionCards.self) }
}
