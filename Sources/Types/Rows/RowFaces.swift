import AppKit
import Canvas
import CoreGraphics
import LanguageModels
import Mentions
import Selection

// Clicks on rows: the parts of a row that answer a click without taking the note's press (Selection's faces),
// on the canvas and, while the words are edited, through the rows view over them. Nothing in a type's rows is
// edited: a row with `›` opens its card to be read, a `Choice` lists its options, a failed read offers Retry or
// Settings…. On a note that is one a click on a value acts at once, even on a note that is not selected: it
// begins the note's editing session in that row, ticks the box, pops the choice's menu or opens the card; a
// click on a name only selects the note. Anywhere else a press is the note's: it selects, edits its words, moves.

/// A part of a row under a point.
struct RowFace: Hashable, Sendable {
    enum Part: Hashable, Sendable {
        /// A row with `›`, or a fold: its read-only card.
        case more
        /// A `Choice` or `Choices` row: its options, listed.
        case options
        /// The failed read's `Retry`, and `Settings…`.
        case retry, settings
        /// A note that is one: a field's name, which only selects the note (a double-click edits its words).
        case name
        /// A note that is one: the value of a row, which acts by what the row holds (`RowClass`).
        case value
        /// A note that is one: a pill of a relation row, which goes to its note while it is live, else to the pill its arrow ends on.
        case pill(ShapeID)
        /// A type's note: a relation row, which goes to its relationship type.
        case relationType(ShapeID)
        /// A note that is one: the `›` that ends a relation row that holds a relationship, which opens the card of its relationships.
        case chevron
    }

    let shape: ShapeID
    /// The row's place in the rows as drawn.
    let row: Int
    let part: Part
    /// Where it was found, world units.
    let at: CGPoint
}

/// What a click on a type's row pops up.
@MainActor
enum RowMenus {
    /// The options of a `Choice` or `Choices` row, in the schema's order, each there to be read: none can be
    /// chosen. Nil for a kind that has none.
    static func options(of kind: FieldKind) -> NSMenu? {
        let options: [FieldOption]
        switch kind {
        case .plain(.choice(let choices)), .choices(let choices): options = choices
        default: return nil
        }
        guard !options.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for option in options {
            let item = NSMenuItem(title: option.label, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        return menu
    }
}

extension RowMenus {
    /// The menu of a choice: the options in the schema's order, a check by the one stored, a separator, and None
    /// last. A pick hands over the option's value, None nil (the field is cleared).
    static func choice(options: [FieldOption], current: JSONValue?, pick: @escaping @MainActor (JSONValue?) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, ticked: Bool, _ run: @escaping @MainActor () -> Void) {
            let action = TypeMenuAction(run)
            let item = NSMenuItem(title: title, action: #selector(TypeMenuAction.fire), keyEquivalent: "")
            item.target = action
            item.representedObject = action          // the item holds its target weakly
            item.state = ticked ? .on : .off
            menu.addItem(item)
        }
        for option in options { add(option.label, ticked: option.value == current) { pick(option.value) } }
        menu.addItem(.separator())
        add(FieldWords.none, ticked: false) { pick(nil) }
        return menu
    }
}

extension RowBook {
    /// Where a failed read's action words are (`Retry`, `Settings…`), world units: in the only row, or in the one at
    /// the foot of a type's rows; nil with none. For tests and the gallery.
    public func actionRect(of id: ShapeID) -> CGRect? {
        guard let record = editor?.document[id], let subject = subject(of: record), subject.isType, let block = rowsRect(of: record) else { return nil }
        let template = template(subject)
        guard case let (reason, action?, row)? = failure(of: record, template: template) else { return nil }
        let geometry = RowGeometry(block: block, hasLead: hasWords(record), template: template)
        return FailureLayout(reason, action: action, in: geometry.rect(row)).actionRect
    }

    /// The failed read a type's note shows and the row it is in: its spot's only row, or the one past its rows.
    private func failure(of record: AnyShapeRecord, template: RowTemplate) -> (String, RowSpot.Action?, Int)? {
        switch spot(of: record, template: template) {
        case .failed(let reason, let action)?: return (reason, action, 0)
        case .rows?:
            guard case .failed(let reason, let action)? = footFailure(of: record.id) else { return nil }
            return (reason, action, template.items.count)
        default: return nil
        }
    }

    /// The part of a row at a world point on the shape, nil off every part and for a shape with no rows to
    /// click: a type's note not showing rows or an action has nothing, and a note that is one has a name or a
    /// value in each row it has. Asked as the pointer moves over a shape, so it costs the lookups the render
    /// pays and no more: the shape's kept rows are all it reads.
    func face(at point: CGPoint, on record: AnyShapeRecord) -> RowFace? {
        guard kinds.contains(record.kind), editor?.editingShapeID != record.id, let block = rowsRect(of: record), block.contains(point) else { return nil }
        if record[TypeSchemaProperty.self] != nil { return part(at: point, on: record, in: block) }
        return valuePart(at: point, on: record)
    }

    /// The same for the rows view over a shape being edited: no test of the edit.
    func editedFace(at point: CGPoint, on id: ShapeID) -> RowFace? {
        guard let record = editor?.document[id], record[TypeSchemaProperty.self] != nil, kinds.contains(record.kind),
              let block = rowsRect(of: record), block.contains(point) else { return nil }
        return part(at: point, on: record, in: block)
    }

    /// A row of a note that is one: its value if the point is on the part of the row that answers a press (a
    /// box, a gone type's chip: only the thing itself), else its name. A row that takes the focus and does
    /// nothing has no value to click: a click there is the note's.
    private func valuePart(at point: CGPoint, on record: AnyShapeRecord) -> RowFace? {
        guard let edited = editedRows(for: record) else { return nil }
        let local = CGPoint(x: point.x - edited.block.minX, y: point.y - edited.block.minY)
        guard let hit = target(at: local, in: edited) else { return nil }
        if hit.onValue, let pointed = pill(at: local, row: hit.row, in: edited) { return RowFace(shape: record.id, row: hit.row, part: .pill(pointed), at: point) }
        if hit.onValue, isChevron(local, row: hit.row, in: edited) { return RowFace(shape: record.id, row: hit.row, part: .chevron, at: point) }
        if hit.onValue { return edited.classes[hit.row] == .still ? nil : RowFace(shape: record.id, row: hit.row, part: .value, at: point) }
        return RowFace(shape: record.id, row: hit.row, part: .name, at: point)
    }

    /// Where the pill of a relation row under a point in the block's coordinates goes: its note while it is live, else the
    /// pill its arrow ends on; nil off every pill, and for a dashed one whose arrow ends on no pill.
    func pill(at local: CGPoint, row: Int, in edited: EditedRows) -> ShapeID? {
        let shown = edited.shown.rows[row]
        guard case .related(let pills, _) = shown.content, shown.valueRect.contains(local) else { return nil }
        let x = local.x - shown.valueRect.minX
        return pills.first { x >= $0.x && x <= $0.x + $0.width }?.destination
    }

    private func part(at point: CGPoint, on record: AnyShapeRecord, in block: CGRect) -> RowFace? {
        guard let subject = subject(of: record), subject.isType else { return nil }
        let template = template(subject)
        guard let spot = spot(of: record, template: template) else { return nil }
        let geometry = RowGeometry(block: block, hasLead: hasWords(record), template: template)
        let id = record.id
        switch spot {
        case .failed(let reason, let action?):
            guard let words = FailureLayout(reason, action: action, in: geometry.rect(0)).actionRect, words.contains(point) else { return nil }
            return RowFace(shape: id, row: 0, part: action == .retry ? .retry : .settings, at: point)
        case .rows:
            // Nil on the dashed line and above the first row.
            guard let row = geometry.row(at: point.y) else { return nil }
            if row == template.items.count, case .failed(let reason, let action?)? = footFailure(of: id) {
                guard let words = FailureLayout(reason, action: action, in: geometry.rect(row)).actionRect, words.contains(point) else { return nil }
                return RowFace(shape: id, row: row, part: action == .retry ? .retry : .settings, at: point)
            }
            guard template.items.indices.contains(row) else { return nil }
            switch template.items[row] {
            case .fold:
                return RowFace(shape: id, row: row, part: .more, at: point)
            case .field(let field):
                if field.opensOnType { return RowFace(shape: id, row: row, part: .more, at: point) }
                if field.kind.hasOptions, geometry.valueRect(row).contains(point) { return RowFace(shape: id, row: row, part: .options, at: point) }
                return nil
            case .relation(let relation):
                // A type's relation row goes to its relationship type, wherever in the row the click is.
                return RowFace(shape: id, row: row, part: .relationType(relation.row.key.type), at: point)
            }
        default:
            return nil
        }
    }

    /// What a click on a part does. A type's rows are never edited, so a locked type changes nothing here but
    /// Retry, which would write the schema: that shakes it, and Settings… opens whatever the lock.
    func perform(_ face: RowFace) {
        switch face.part {
        case .name: return
        case .value: performValue(face)
        // Going to the note changes nothing in this one, so a read-only note goes too.
        case .pill(let target): editor?.mentions?.follow(target)
        // Going to the relationship type changes nothing in this note either.
        case .relationType(let type): editor?.goTo([type])
        case .chevron: performChevron(face)
        default: performOnType(face)
        }
    }

    /// A click on a value of a note that is one acts at once. A typed value, a row with more in it and the
    /// fold begin the note's editing session (the row's field has the caret there, a card is asked for on the
    /// session's next turn); a read-only note refuses, which shakes it, but a card opens to be read, and no
    /// shake: reading is no try. The box writes, the choice pops its menu, and a row that reads `edited as
    /// JSON in the panel` asks for the panel and begins nothing.
    private func performValue(_ face: RowFace) {
        guard let editor, let record = editor.document[face.shape], let edited = editedRows(for: record), edited.classes.indices.contains(face.row) else { return }
        let id = face.shape, row = face.row
        func card() { openCard(valuesCardRequest(row: row, of: edited, closed: {}, tabbedOut: { _ in })) }
        switch edited.classes[row] {
        case .typed:
            editor.beginEditing(id, at: face.at)
        case .more, .fold:
            if editor.isReadOnly(id) { card() } else { editor.beginEditing(id, at: face.at) }
        case .json:
            card()
        case .box:
            if let key = edited.shown.rows[row].path?.field { toggle(key, of: id) }
        case .choice:
            if editor.isReadOnly(id) { editor.refuseChanges(to: [id]) } else { popChoiceMenu(row: row, of: edited) }
        case .relation:
            // The session begins in the row and its list opens a turn later (`RowsView.begin`).
            if editor.isReadOnly(id) { editor.refuseChanges(to: [id]) } else { editor.beginEditing(id, at: face.at) }
        case .still:
            break
        }
    }

    /// A click on the `›` of a relation row: its card. A read-only note opens it to be read; any other begins the session in the
    /// row and the card is asked for on its next turn (`RowsView.begin`).
    private func performChevron(_ face: RowFace) {
        guard let editor, let record = editor.document[face.shape], let edited = editedRows(for: record), edited.classes.indices.contains(face.row) else { return }
        if editor.isReadOnly(face.shape) {
            openCard(valuesCardRequest(row: face.row, of: edited, closed: {}, tabbedOut: { _ in }))
        } else {
            editor.beginEditing(face.shape, at: face.at)
        }
    }

    private func performOnType(_ face: RowFace) {
        guard let editor, let record = editor.document[face.shape], let subject = subject(of: record), subject.isType else { return }
        switch face.part {
        case .settings:
            _ = AnthropicSettingsView.showSettings()
        case .retry:
            if editor.isReadOnly(face.shape) { editor.refuseChanges(to: [face.shape]) } else { editor.typeSync?.retry(face.shape) }
        case .more:
            guard let request = cardRequest(for: face, subject: subject, record: record) else { return }
            openCard(request)
        case .options:
            let template = template(subject)
            guard template.items.indices.contains(face.row), case .field(let field) = template.items[face.row],
                  let block = rowsRect(of: record), let menu = RowMenus.options(of: field.kind) else { return }
            let geometry = RowGeometry(block: block, hasLead: hasWords(record), template: template)
            editor.popUpMenu(menu, below: geometry.valueRect(face.row))
        case .name, .value, .pill, .relationType, .chevron:
            break
        }
    }

    /// The read-only card of a row: the row's field, or a fold's rows.
    private func cardRequest(for face: RowFace, subject: RowSubject, record: AnyShapeRecord) -> FieldCardRequest? {
        let template = template(subject)
        guard template.items.indices.contains(face.row), let block = rowsRect(of: record) else { return nil }
        let geometry = RowGeometry(block: block, hasLead: hasWords(record), template: template)
        let id = face.shape
        let target: FieldCardRequest.Target, folded: [Resolved.Field], isMore: Bool
        let path: FieldPath?
        switch template.items[face.row] {
        case .field(let field):
            (target, folded, isMore, path) = (.field(field.path), [], false, field.path)
        case .fold(let fold):
            (target, folded, isMore, path) = (.fold, fold.folded, fold.isMore, nil)
        case .relation:
            // A relation row goes to its type and opens no card (only a face of `.more` asks for one).
            return nil
        }
        // Where the row is now: its place among the rows as drawn, asked while the card is open; nil once it
        // is gone (the card closes).
        let now: @MainActor () -> CGRect? = { [weak self] in
            self?.rows(of: id).first { row in
                if let path { return row.path == path }
                return row.isFold && (row.content == .fold("")) == isMore
            }?.rect
        }
        return FieldCardRequest(shape: id, target: target, mode: .kinds, isReadOnly: true, rowRect: geometry.rect(face.row), folded: folded,
                                rowRectNow: now, closed: {}, tabbedOut: { _ in })
    }

    /// Asks the field cards to open a row's card: the one door the faces and the rows view use.
    @discardableResult
    public func openCard(_ request: FieldCardRequest) -> Bool {
        #if DEBUG
        opened.append(request)
        #endif
        return editor?.fieldCards?.open(request) ?? false
    }
}

extension FieldKind {
    /// A `Choice` or `Choices` row: a click on its value lists the options.
    var hasOptions: Bool {
        switch self {
        case .plain(.choice), .choices: true
        default: false
        }
    }
}

@MainActor
func registerRowFaces(into registrar: inout PluginRegistrar) {
    registrar.shapeFaces(at: { editor, shape, point in editor.rowBook?.face(at: point, on: shape) },
                         click: { face, editor in editor.rowBook?.perform(face) },
                         // Without it the second press of a fast pair would open the note for editing.
                         doubleClick: { face, editor in
                             switch face.part {
                             case .more, .options, .value, .pill, .relationType, .chevron: editor.rowBook?.perform(face)
                             // A name only selects; its second press edits the words, as one on the note does.
                             case .name: editor.open(face.shape, at: face.at, clickCount: 2)
                             case .retry, .settings: break
                             }
                         },
                         // The pointer over a live pill hovers the note it points at, as a mention's pill does.
                         hovering: { face, editor in
                             if case .pill(let target) = face.part, editor.document[target] != nil { target } else { nil }
                         })
}
