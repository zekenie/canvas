import AppKit
import Canvas

// What shows a row's card: a core card (`CanvasCard`) hung from the row, its view the card's lines, the keyboard on its first
// stop, given back to the row's line as it closes. It follows the row as commits move it (a row above added, the table moved),
// shows what the row holds now, and closes when the row goes. It holds no step: each line is the row's commit.

/// The card of a row, to the core: its shape and its row.
struct LineCardID: Hashable, Sendable {
    let shape: ShapeID
    let row: PartID
}

@MainActor
final class LineCards: LineCardShowing {
    private unowned let editor: CanvasEditor
    private weak var shown: LineCardView?
    private var shownID: LineCardID?
    /// The row's rect now, and what the card shows reloaded, for the card showing.
    private var anchorNow: (@MainActor () -> CGRect?)?
    private var reload: (@MainActor () -> Void)?

    init(editor: CanvasEditor) {
        self.editor = editor
    }

    func show<Model: LineModel>(_ card: LineCard<Model.Row>, of row: PartID, in session: LineSession<Model>) -> Bool {
        guard let anchor = session.worldRect(of: row), session.storedRow(row) != nil else { return false }
        let view = LineCardSession(card: card, row: row, session: session, editor: editor)
        let id = LineCardID(shape: session.id, row: row)
        let made = CanvasCard(id: id, about: session.id, anchor: anchor, view: view, firstResponder: view.firstResponderStop,
                              returnsKeyboardTo: session.field, accessibilityLabel: LineCardStyle.label(card.header.name),
                              size: { [weak view] room in view?.size(in: room) ?? .zero },
                              didClose: { [weak self, weak view] _ in self?.closed(view) })
        shown = view
        shownID = id
        anchorNow = { [weak view] in view?.anchorNow() }
        reload = { [weak view] in view?.reload() }
        guard editor.showCard(made) else {
            forget()
            return false
        }
        return true
    }

    func follow() {
        guard let shownID, editor.card?.id == AnyHashable(shownID) else { return }
        guard let rect = anchorNow?() else { return editor.closeCard() }
        reload?()
        editor.moveCard(to: rect)
        editor.cardDidResize()
    }

    private func closed(_ view: LineCardView?) {
        (view as? AnyLineCardClosing)?.didClose()
        if view == nil || view === shown { forget() }
    }

    private func forget() {
        shown = nil
        shownID = nil
        anchorNow = nil
        reload = nil
    }
}

/// A card's view told it's taken down, whatever its rows are.
@MainActor
protocol AnyLineCardClosing: AnyObject {
    func didClose()
}

extension LineCardSession: AnyLineCardClosing {}
