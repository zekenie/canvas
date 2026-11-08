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
    /// Shows what the row holds now, true where its size changed.
    private var reload: (@MainActor () -> Bool)?

    init(editor: CanvasEditor) {
        self.editor = editor
    }

    func show<Model: LineModel>(_ card: LineCard<Model.Row>, of row: PartID, in session: LineSession<Model>) -> Bool {
        guard let anchor = session.worldRect(of: row), session.storedRow(row) != nil else { return false }
        let view = LineCardSession(card: card, row: row, session: session, editor: editor)
        view.headerDidChange = { [weak self] header in self?.editor.setCardLabel(LineCardStyle.label(header.name)) }
        let id = LineCardID(shape: session.id, row: row)
        let made = CanvasCard(id: id, about: session.id, anchor: anchor, view: view, firstResponder: view.firstResponderStop,
                              returnsKeyboardTo: session.field, accessibilityLabel: LineCardStyle.label(card.header.name),
                              size: { [weak view] room in view?.size(in: room) ?? .zero },
                              didClose: { [weak self, weak view] _ in self?.closed(view) })
        shown = view
        shownID = id
        anchorNow = { [weak view] in view?.anchorNow() }
        reload = { [weak view] in view?.reload() ?? false }
        guard editor.showCard(made) else {
            forget()
            return false
        }
        return true
    }

    func follow(_ changes: ChangeSet?) {
        guard let shownID, editor.card?.id == AnyHashable(shownID) else { return }
        guard let rect = anchorNow?() else { return editor.closeCard() }
        // Every commit, not only the card's shape's: the lines read what other shapes hold (the key an arrow is, an enum's name).
        let resized = changes != nil ? reload?() ?? false : false
        editor.moveCard(to: rect)
        if resized { editor.cardDidResize() }
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

extension LineCardLine {
    /// What the line says of `row`, as its stop shows it: its words (a list's lines one under another), "yes" or "no", its option
    /// (the first, where the row holds none).
    func printed(_ row: Row, in context: LineContext) -> String {
        switch kind {
        case .text(let text): text.lines(row, context).map(\.string).joined(separator: "\n")
        case .toggle(let get, _): get(row) ? LineCardStyle.yes : LineCardStyle.no
        case .choice(let options, let get, _): get(row) ?? options.first ?? ""
        }
    }
}

/// A card's view told it's taken down, whatever its rows are.
@MainActor
protocol AnyLineCardClosing: AnyObject {
    func didClose()
}

extension LineCardSession: AnyLineCardClosing {}
