import AppKit
import Canvas
import CoreGraphics

// What the rows of a note that is one do when they are used: what each row is to the keyboard and the
// pointer, how a typed value is written (through the one writer: each keystroke is a commit, one undo step a
// field), how the check is told which field is typed in, the choice's menu and the card a row with more in it
// opens. The view that takes the keys and presses is `RowsView`; this is the book's side of it.

/// What a row is to the keyboard and the pointer.
enum RowClass: Equatable {
    /// Typed in the row: text, a number, a date, either of two such kinds.
    case typed([PlainKind])
    /// A yes or no: a box.
    case box
    /// One of a few: a menu.
    case choice([FieldOption])
    /// A row with more in it: a card.
    case more
    /// What no control suits: the panel's JSON.
    case json
    /// A row that takes the focus and does nothing (a link to a note until slice 14, a type that is gone).
    case still
    /// The fold: a card of the rows it holds.
    case fold

    /// Whether Return or Space on the row asks for a card.
    var opensCard: Bool {
        switch self {
        case .more, .json, .fold: true
        default: false
        }
    }
}

/// A note's rows as they are now, for the view over them and the faces: its record, the template, the rows as
/// shown (rects from the block's top-left) and the block.
struct EditedRows {
    let record: AnyShapeRecord
    let template: RowTemplate
    let shown: ShownRows
    let block: CGRect
    let classes: [RowClass]

    var count: Int { shown.rows.count }

    func index(ofField key: String) -> Int? { shown.rows.firstIndex { $0.path?.field == key } }

    /// A fold's place: `+N more` by `isMore`, a `from` fold the other.
    func index(ofFold isMore: Bool) -> Int? {
        template.items.firstIndex { if case .fold(let fold) = $0 { fold.isMore == isMore } else { false } }
    }

    func field(_ row: Int) -> FieldRowTemplate? {
        if case .field(let field) = template.items[row] { field } else { nil }
    }

    func fold(_ row: Int) -> FoldTemplate? {
        if case .fold(let fold) = template.items[row] { fold } else { nil }
    }

    /// A row's rect on the board.
    func rect(_ row: Int) -> CGRect { shown.rows[row].rect.offsetBy(dx: block.minX, dy: block.minY) }
    func valueRect(_ row: Int) -> CGRect { shown.rows[row].valueRect.offsetBy(dx: block.minX, dy: block.minY) }
}

extension RowBook {
    /// The rows of the shape being used, as they are now; nil for a shape that has none or is a type.
    func editedRows(of id: ShapeID) -> EditedRows? {
        editor?.document[id].flatMap { editedRows(for: $0) }
    }

    func editedRows(for record: AnyShapeRecord) -> EditedRows? {
        guard let subject = subject(of: record), !subject.isType, kinds.contains(record.kind),
              let block = rowsRect(of: record) else { return nil }
        let template = template(subject)
        guard !template.items.isEmpty else { return nil }
        let shown = shownRows(of: record, subject: subject, template: template, block: block)
        return EditedRows(record: record, template: template, shown: shown, block: block, classes: template.items.map { classOf($0) })
    }

    private func classOf(_ item: RowTemplateItem) -> RowClass {
        switch item {
        case .fold: return .fold
        case .field(let field):
            switch field.kind {
            case .plain(.yesNo): return .box
            case .plain(.choice(let options)): return .choice(options)
            case .plain(let kind): return .typed([kind])
            case .either(.plain(let first), .plain(let second)): return .typed([first, second])
            case .pointer, .pointers: return .still
            case .other: return .json
            case .typeFields(let target), .listOfTypeFields(let target):
                return editor?.types?.isType(target) == true ? .more : .still
            default: return field.kind.hasMore ? .more : .still
            }
        }
    }

    /// The row under a point in the block's coordinates, and whether the point is on its value: the part of
    /// a row that answers a press (a box, a gone type's chip: only the thing itself; a fold: all of it).
    func target(at point: CGPoint, in edited: EditedRows) -> (row: Int, onValue: Bool)? {
        guard let row = edited.shown.rows.firstIndex(where: { $0.rect.contains(point) }) else { return nil }
        let shown = edited.shown.rows[row]
        switch edited.classes[row] {
        case .fold: return (row, true)
        case .box, .still:
            return (row, shown.valueRect.contains(point) && hug(shown).contains(point))
        default: return (row, shown.valueRect.contains(point))
        }
    }

    // MARK: Writing

    /// A typed value, written through the one writer: what typed text is stored as is `FieldText`'s (one
    /// kind, or the first of two that reads it), each keystroke is a commit and typing in one field is one
    /// undo step named for it.
    func write(_ text: String, key: String, of shape: ShapeID, kinds: [PlainKind]) {
        let path = FieldPath(field: key)
        if kinds.count == 1 {
            editor?.fieldWriter?.setTyped(text, as: kinds[0], at: path, of: shape)
        } else {
            editor?.fieldWriter?.set(stored(text, kinds: kinds), at: path, of: shape)
        }
    }

    /// What typed text is stored as in a field of these kinds (`FieldText`): nil clears the field.
    func stored(_ text: String, kinds: [PlainKind]) -> JSONValue? {
        kinds.count == 1 ? FieldText.value(from: text, as: kinds[0]) : FieldText.value(from: text, asOneOf: kinds)
    }

    /// A box's click or Space: the other of ticked and not. An unticked box that was ticked holds `false`,
    /// which is a value.
    func toggle(_ key: String, of shape: ShapeID) {
        let path = FieldPath(field: key)
        let ticked = editor?.fieldWriter?.values(of: shape).value(at: path) == .bool(true)
        editor?.fieldWriter?.set(.bool(!ticked), at: path, of: shape)
    }

    // MARK: Telling the check

    /// Tells the check which field has the caret: its value is left out of every read until the caret leaves.
    func setTyping(_ path: FieldPath, of shape: ShapeID) {
        editor?.fieldChecks?.typing = (shape, path)
    }

    /// The caret left the field: only whoever set `typing` clears it (the panel's boxes set it too).
    func clearTyping(_ path: FieldPath, of shape: ShapeID) {
        guard let checks = editor?.fieldChecks, let typing = checks.typing, typing.shape == shape, typing.path == path else { return }
        checks.typing = nil
    }

    // MARK: The choice's menu

    /// Pops the menu of a choice row under its value: a pick writes the option, None clears the field.
    func popChoiceMenu(row: Int, of edited: EditedRows, then done: @escaping @MainActor () -> Void = {}) {
        guard let editor, case .choice(let options) = edited.classes[row], let key = edited.shown.rows[row].path?.field else { return }
        let shape = edited.record.id
        let current = editor.fieldWriter?.values(of: shape).value(at: FieldPath(field: key))
        let menu = RowMenus.choice(options: options, current: current) { [weak self] picked in
            self?.editor?.fieldWriter?.set(picked, at: FieldPath(field: key), of: shape)
            done()
        }
        editor.popUpMenu(menu, below: edited.valueRect(row))
    }

    // MARK: The card

    /// The request for the card of a row with more in it on a note that is one: the row's field (a fold: the
    /// rows it holds), where the row is now, and what to do when it closes and when Tab leaves its last row.
    func valuesCardRequest(row: Int, of edited: EditedRows, closed: @escaping @MainActor () -> Void,
                           tabbedOut: @escaping @MainActor (Bool) -> Void) -> FieldCardRequest {
        let id = edited.record.id
        let target: FieldCardRequest.Target, folded: [Resolved.Field], path: FieldPath?, isMore: Bool
        if let field = edited.field(row) {
            (target, folded, path, isMore) = (.field(field.path), [], field.path, false)
        } else if let fold = edited.fold(row) {
            (target, folded, path, isMore) = (.fold, fold.folded, nil, fold.isMore)
        } else {
            (target, folded, path, isMore) = (.fold, [], nil, false)
        }
        let now: @MainActor () -> CGRect? = { [weak self] in
            self?.rows(of: id).first { row in
                if let path { return row.path == path }
                return row.path == nil && (row.content == .fold("")) == isMore
            }?.rect
        }
        return FieldCardRequest(shape: id, target: target, mode: .values, isReadOnly: editor?.isReadOnly(id) ?? true, rowRect: edited.rect(row),
                                folded: folded, rowRectNow: now, closed: closed, tabbedOut: tabbedOut)
    }
}
