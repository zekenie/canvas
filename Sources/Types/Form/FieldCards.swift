import Adornments
import Canvas
import CoreGraphics
import DetailPanel
import Selection

// The card a row with more in it opens under itself. This file holds the request, the card's id and the
// service that opens it. The core piece the card stands on is generic and knows no field.

public struct FieldCardRequest {
    public enum Target: Hashable, Sendable {
        /// A row's field.
        case field(FieldPath)
        /// The fold's rows (`folded` says which).
        case fold
        /// Every field of the shape's types, one line each: an arrow's card (its relationship's fields). It has no row, so
        /// it hangs from the shape's adornment anchor.
        case shape
        /// A note's relation row: a line for each relationship in it, the note at the other end and the fields of the
        /// relationship type, and a blank line that picks a note (a `RelationshipRow` by its key).
        case relations(RelationshipRowKey)
    }

    public var shape: ShapeID
    public var target: Target
    public var mode: FieldFormMode
    /// A type's note, a locked note, a read-only board: the card opens to be read.
    public var isReadOnly: Bool
    /// The row, world units, in the laid-out paper.
    public var rowRect: CGRect
    /// The rows a fold hides, in row order: read only for `.fold`. A note can have two folds, `from Person`
    /// and `+N more`, and the target does not say which.
    public var folded: [Resolved.Field]
    /// Where the row is now (world units), asked while the card is open; nil closes it. A nil closure: the
    /// card keeps its offset from the paper's top-left.
    public var rowRectNow: (@MainActor () -> CGRect?)?
    /// Lists the notes a row's card may name on its blank line (`.relations`): the list of notes a row of the same note finds one in.
    public var makePicker: (@MainActor (_ note: ShapeID, _ row: RelationshipRow) -> (any NotePicking)?)?
    /// Esc from the top level, a click outside: the caller focuses the row again.
    public var closed: @MainActor () -> Void
    /// Tab off the last row: the caller focuses the next row, or ends editing.
    public var tabbedOut: @MainActor (_ forward: Bool) -> Void

    public init(shape: ShapeID, target: Target, mode: FieldFormMode, isReadOnly: Bool, rowRect: CGRect,
                folded: [Resolved.Field] = [], rowRectNow: (@MainActor () -> CGRect?)? = nil,
                closed: @escaping @MainActor () -> Void, tabbedOut: @escaping @MainActor (_ forward: Bool) -> Void) {
        self.shape = shape
        self.target = target
        self.mode = mode
        self.isReadOnly = isReadOnly
        self.rowRect = rowRect
        self.folded = folded
        self.rowRectNow = rowRectNow
        self.closed = closed
        self.tabbedOut = tabbedOut
    }
}

/// What a card is, to the core: its row's shape and target, and for a fold the first row it hides, so a note's two
/// folds (`from Person`, `+N more`) are two cards. Also the key of the step a card's writes join.
struct FieldCardID: Hashable, Sendable {
    var shape: ShapeID
    var target: FieldCardRequest.Target
    var folded: String?
}

@MainActor
public final class FieldCards {
    private weak var editor: CanvasEditor?
    /// What the person opened or closed in the panel's forms, for the session, by shape and path: SwiftUI makes the
    /// forms' views again whenever the selection changes. A shape's entry goes when a commit removes the shape.
    public internal(set) var panelOpen: [ShapeID: [FieldPath: Bool]] = [:]
    private var forms: [WeakForm] = []
    private var pass: ScheduledTask?
    private var session: Session?

    private struct WeakForm {
        weak var form: FieldFormView?
    }

    /// The card showing: what asked for it, the form in it, and where it hangs from the shape's paper.
    private struct Session {
        var id: FieldCardID
        var request: FieldCardRequest
        var form: FieldFormView
        var offset: CGVector
    }

    public init(editor: CanvasEditor) {
        self.editor = editor
        // A service may reach another as it is made; the check is registered ahead of this one.
        editor.fieldChecks?.onTypingChange { [weak self] in self?.checkDidMove() }
        // A relationship drawn or taken away, near or far: the cards of the rows it is in are made again.
        editor.relationships?.onChange { [weak self] change in self?.relationsChanged(change) }
    }

    // MARK: Opening

    /// Opens the card under the row: of its field's rows (a group, another type's fields, a list, pairs, several
    /// choices, either of two with more in it), of the rows the fold hides, or, on a type's note and a locked
    /// note, to be read. False when there is none to open: a plain field, a field no type names, a
    /// fold with nothing folded, a shape not on the board shown. `Other` has no card: the note is selected and
    /// the panel shows where its JSON is (true). Asked for the target that is open, it closes the card, tells
    /// its `closed` and answers true: a click on the row of an open card.
    @discardableResult
    public func open(_ request: FieldCardRequest) -> Bool {
        guard let editor, editor.document[request.shape] != nil, let book = editor.fieldBook else { return false }
        let id = FieldCardID(shape: request.shape, target: request.target, folded: request.target == .fold ? request.folded.first?.field.name : nil)
        if let held = session, held.id == id {
            editor.closeCard()
            held.request.closed()
            return true
        }
        let types = request.mode == .kinds ? [request.shape] : editor.document[request.shape]?[IsAProperty.self]?.map(\.shape) ?? []
        let root: FieldFormRoot
        var stepField: ChainField?
        var relationRow: RelationshipRow?
        switch request.target {
        case .field(let path):
            guard let field = book.field(at: path, types: types) else { return false }
            let kind = book.kind(of: field)
            if kind == .other {
                Self.revealInPanel(request.shape, in: editor, mode: request.mode)
                return true
            }
            guard request.mode == .kinds ? kind.opensOnType : kind.hasMore else { return false }
            root = .field(path: path, field: field, kind: kind)
            // The step is the row on the note's, whatever depth the card is at.
            stepField = book.fields(types: types).fields.first { $0.field.name == path.field }?.field
        case .fold:
            guard !request.folded.isEmpty else { return false }
            root = .fold(request.folded)
        case .shape:
            // The arrow's relationship types' fields alone: a plain type beside them is not what the relationship holds.
            let relating = types.filter { editor.relationships?.graph.isRelationshipType($0) == true }
            let fields = book.fields(types: relating).fields
            guard !fields.isEmpty else { return false }
            root = .shape(fields)
        case .relations(let key):
            // The row as this note has it now. Every write of the card is its one step, named for the row (`Change Friends`).
            guard let row = editor.relationships?.rows(for: types, isType: false).first(where: { $0.key == key }), let graph = editor.types?.graph else { return false }
            relationRow = row
            root = .relations(RelationCardRoot(note: request.shape, row: row))
            stepField = ChainField(name: row.name(in: graph), schema: .null)
        }
        let isReadOnly = request.isReadOnly || request.mode == .kinds || editor.isReadOnly(request.shape)
        let form = FieldFormView(editor: editor, shape: request.shape, root: root, mode: request.mode, isReadOnly: isReadOnly, presentation: .card, cardKey: id)
        // The blank line lists the notes the row may name, on any board: whoever asks for the card says how (the rows know which
        // kinds an open side lists).
        if let row = relationRow, let makePicker = request.makePicker {
            form.makePicker = { note in makePicker(note, row) }
        }
        var stepName: String?
        if !isReadOnly, let stepField { stepName = FieldName.stepName(of: stepField) }
        let paper = editor.frame(inFile: request.shape)?.origin ?? request.rowRect.origin
        let offset = CGVector(dx: request.rowRect.minX - paper.x, dy: request.rowRect.minY - paper.y)
        form.onClose = { [weak self] closing in self?.formClosed(closing, id: id) }
        form.onGone = { [weak self] in self?.close() }
        form.onReadOnly = { [weak editor] in editor?.setCardStep(nil) }
        form.onResize = { [weak editor] in editor?.cardDidResize() }
        let card = CanvasCard(id: id, about: request.shape, anchor: request.rowRect, view: form, firstResponder: form, stepName: stepName,
                              size: { [unowned form, weak editor] room in
                                  form.fittingSize(anchorWidth: request.rowRect.width * CGFloat(editor?.zoomPercentage ?? 100) / 100, room: room)
                              },
                              didClose: { [weak self] reason in self?.cardClosed(id: id, reason) })
        // The card it replaces hears `.replaced` as this one shows, and forgets its session then.
        guard editor.showCard(card) else { return false }
        session = Session(id: id, request: request, form: form, offset: offset)
        editor.setNeedsDisplay()
        form.focusFirst()
        return true
    }

    /// The row whose card is open: the caller outlines it. Redraws when it changes.
    public var openTarget: (shape: ShapeID, target: FieldCardRequest.Target)? {
        session.map { ($0.id.shape, $0.id.target) }
    }

    /// The key of the first folded field of the fold whose card is open: tells a note's two folds apart.
    public var openFolded: String? { session?.id.folded }

    /// The form the card shows: for tests and the gallery.
    public var openForm: FieldFormView? { session?.form }

    /// Takes the card down, if one of this service's shows; its row's `closed` is not told.
    public func close() {
        guard session != nil else { return }
        editor?.closeCard()
    }

    /// The form asks to close, from its top level: Esc and Return on a blank last line leave the row focused
    /// (`closed`), Tab off the last stop goes on to the note's next row, ⇧Tab off the first back onto its own.
    private func formClosed(_ closing: FieldFormView.Closing, id: FieldCardID) {
        guard let held = session, held.id == id else { return }
        editor?.closeCard()
        switch closing {
        case .escaped, .returned, .tabbed(forward: false): held.request.closed()
        case .tabbed(forward: true): held.request.tabbedOut(true)
        }
    }

    /// The core took the card down, for any reason: the session is forgotten before anything else hears, the
    /// check is told the caret is gone, and a press elsewhere is the row's to hear (`closed`); a row that is
    /// closed some other way (editing ended, the board changed, an undo, `close()`) has its owner's own state
    /// to keep, which may be gone.
    private func cardClosed(id: FieldCardID, _ reason: CanvasCardClosing) {
        guard let held = session, held.id == id else { return }
        session = nil
        editor?.setNeedsDisplay()
        held.form.stopTyping()
        if reason == .pressedElsewhere { held.request.closed() }
    }

    /// A form tells the service of itself as it is made: the card's, the panel's and a test's are followed alike.
    /// Kept weakly; one that has gone is dropped at the next commit.
    func follow(_ form: FieldFormView) {
        forms.removeAll { $0.form == nil }
        forms.append(WeakForm(form: form))
    }

    /// Selects the note and chooses the tab its fields are edited in: where `Other` is JSON. A type's note
    /// shows its schema, any other note its Types tab.
    static func revealInPanel(_ shape: ShapeID, in editor: CanvasEditor, mode: FieldFormMode = .values) {
        guard let record = editor.document[shape] else { return }
        editor.selection = shape
        if mode == .kinds {
            editor.detailPanel?.choose(.of(TypeSchemaTab.self), for: record.kind)
        } else {
            editor.detailPanel?.choose(.of(TypesTab.self), for: record.kind)
        }
    }

    /// Every form for a shape a commit changed is drawn again at once; any commit schedules one pass a turn
    /// later, in which each live form reloads if a type or the check moved since it last did (a type's change
    /// is a change to the type's record, so `changes` does not name its instances, and the index, the check and
    /// the rows may hear the commit after this service does) and the card is hung from its row again.
    private func hear(_ changes: ChangeSet, in editor: CanvasEditor) {
        for id in changes.removed { panelOpen[id] = nil }
        forms.removeAll { $0.form == nil }
        guard !forms.isEmpty else { return }
        // A row's card also shows the arrows of its lines, on whichever board they are.
        for held in forms where held.form.map({ form in
            changes.shapeIDs.contains(form.shape) || form.owners.contains { changes.shapeIDs.contains($0) || changes.elsewhere.contains($0) }
        }) == true { held.form?.reloadOnce() }
        schedulePass(in: editor)
    }

    /// The relationship index told what a commit changed: the card of a row whose note it names, or whose lines' arrows, is made
    /// again at once (a relationship drawn writes nothing to the note).
    private func relationsChanged(_ change: RelationshipChange) {
        forms.removeAll { $0.form == nil }
        for held in forms {
            guard let form = held.form, form.relations != nil else { continue }
            if change.everything || change.notes.contains(form.shape) {
                form.reload()
            } else if !form.owners.isDisjoint(with: change.arrows) || !form.owners.isDisjoint(with: change.values) {
                // A value typed on a line's arrow names the arrow alone; the commit's own hearing has reloaded the form for it.
                form.reloadOnce()
            }
        }
    }

    /// What the check says moved with no commit (a caret came to a field or left it, on a surface that is not one of
    /// the forms): the forms look again a turn later, and a form that already shows it (its own caret) is left be.
    func checkDidMove() {
        guard let editor, !forms.isEmpty else { return }
        schedulePass(in: editor)
    }

    private func schedulePass(in editor: CanvasEditor) {
        guard pass == nil else { return }
        pass = editor.scheduler.schedule(after: .zero) { [weak self] in
            guard let self, let editor = self.editor else { return }
            pass = nil
            forms.removeAll { $0.form == nil }
            for held in forms { held.form?.reloadIfStale() }
            reanchor(in: editor)
        }
    }

    /// The row moved (the note was dragged, a row above it came or went): the card follows it. With no
    /// `rowRectNow` it keeps its offset from the shape's frame; a row that answers nil is gone, and the card with it.
    private func reanchor(in editor: CanvasEditor) {
        guard let held = session, editor.card?.id == AnyHashable(held.id) else { return }
        if let now = held.request.rowRectNow {
            guard let rect = now() else { return editor.closeCard() }
            editor.moveCard(to: rect)
        } else if let paper = editor.frame(inFile: held.id.shape) {
            let size = held.request.rowRect.size
            editor.moveCard(to: CGRect(x: paper.minX + held.offset.dx, y: paper.minY + held.offset.dy, width: size.width, height: size.height))
        }
    }
}

extension FieldCards: EditorService {
    /// It keeps nothing per shape or per board, so a switch needs no change set (the default works one out).
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {}

    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        hear(changes, in: editor)
    }
}

extension CanvasEditor {
    /// The cards rows open (`FieldCards`); nil without TypesPlugin.
    public var fieldCards: FieldCards? { service(FieldCards.self) }
}
