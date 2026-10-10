import AppKit
import Canvas
import CoreGraphics
import LanguageModels
import Selection

// Clicks on a type's rows: the parts of a row that answer a click without taking the note's press (Selection's
// faces), on the canvas and, while the words are edited, through the rows view over them. Nothing in a type's
// rows is edited: a row with `›` opens its card to be read, a `Choice` lists its options, a failed read offers
// Retry or Settings…. Anywhere else a press is the note's: it selects, edits its words, moves.

/// A part of a type's row under a point.
struct RowFace: Hashable, Sendable {
    enum Part: Hashable, Sendable {
        /// A row with `›`, or a fold: its read-only card.
        case more
        /// A `Choice` or `Choices` row: its options, listed.
        case options
        /// The failed read's `Retry`, and `Settings…`.
        case retry, settings
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

extension RowBook {
    /// Where a failed read's action words are (`Retry`, `Settings…`), world units; nil with none. For tests and
    /// the gallery.
    public func actionRect(of id: ShapeID) -> CGRect? {
        guard let record = editor?.document[id], let subject = subject(of: record), subject.isType, let block = rowsRect(of: record) else { return nil }
        let template = template(subject)
        guard case .failed(let reason, let action?)? = spot(of: record, template: template) else { return nil }
        let geometry = RowGeometry(block: block, hasLead: hasWords(record), longestName: template.nameColumn)
        return FailureLayout(reason, action: action, in: geometry.rect(0)).actionRect
    }

    /// The part of a type's row at a world point on the shape, nil off every part and for a shape with no
    /// rows to click: a note that is one is the values' (slice 11), and a type's note not showing rows or
    /// an action has nothing. Asked as the pointer moves over a shape, so it costs the lookups the render
    /// pays and no more.
    func face(at point: CGPoint, on record: AnyShapeRecord) -> RowFace? {
        guard record[TypeSchemaProperty.self] != nil, kinds.contains(record.kind), editor?.editingShapeID != record.id,
              let block = rowsRect(of: record), block.contains(point) else { return nil }
        return part(at: point, on: record, in: block)
    }

    /// The same for the rows view over a shape being edited: no test of the edit.
    func editedFace(at point: CGPoint, on id: ShapeID) -> RowFace? {
        guard let record = editor?.document[id], record[TypeSchemaProperty.self] != nil, kinds.contains(record.kind),
              let block = rowsRect(of: record), block.contains(point) else { return nil }
        return part(at: point, on: record, in: block)
    }

    private func part(at point: CGPoint, on record: AnyShapeRecord, in block: CGRect) -> RowFace? {
        guard let subject = subject(of: record), subject.isType else { return nil }
        let template = template(subject)
        guard let spot = spot(of: record, template: template) else { return nil }
        let geometry = RowGeometry(block: block, hasLead: hasWords(record), longestName: template.nameColumn)
        let id = record.id
        switch spot {
        case .failed(let reason, let action?):
            guard let words = FailureLayout(reason, action: action, in: geometry.rect(0)).actionRect, words.contains(point) else { return nil }
            return RowFace(shape: id, row: 0, part: action == .retry ? .retry : .settings, at: point)
        case .rows:
            let row = Int(((point.y - geometry.top) / TypesStyle.rowHeight).rounded(.down))
            guard template.items.indices.contains(row), point.y >= geometry.top else { return nil }
            switch template.items[row] {
            case .fold:
                return RowFace(shape: id, row: row, part: .more, at: point)
            case .field(let field):
                if field.opensOnType { return RowFace(shape: id, row: row, part: .more, at: point) }
                if field.kind.hasOptions, geometry.valueRect(row).contains(point) { return RowFace(shape: id, row: row, part: .options, at: point) }
                return nil
            }
        default:
            return nil
        }
    }

    /// What a click on a part does. A type's rows are never edited, so a locked type changes nothing here but
    /// Retry, which would write the schema: that shakes it, and Settings… opens whatever the lock.
    func perform(_ face: RowFace) {
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
            let geometry = RowGeometry(block: block, hasLead: hasWords(record), longestName: template.nameColumn)
            editor.popUpMenu(menu, below: geometry.valueRect(face.row))
        }
    }

    /// The read-only card of a row: the row's field, or a fold's rows.
    private func cardRequest(for face: RowFace, subject: RowSubject, record: AnyShapeRecord) -> FieldCardRequest? {
        let template = template(subject)
        guard template.items.indices.contains(face.row), let block = rowsRect(of: record) else { return nil }
        let geometry = RowGeometry(block: block, hasLead: hasWords(record), longestName: template.nameColumn)
        let id = face.shape
        let target: FieldCardRequest.Target, folded: [Resolved.Field], isMore: Bool
        let path: FieldPath?
        switch template.items[face.row] {
        case .field(let field):
            (target, folded, isMore, path) = (.field(field.path), [], false, field.path)
        case .fold(let fold):
            (target, folded, isMore, path) = (.fold, fold.folded, fold.isMore, nil)
        }
        // Where the row is now: its place among the rows as drawn, asked while the card is open; nil once it
        // is gone (the card closes).
        let now: @MainActor () -> CGRect? = { [weak self] in
            self?.rows(of: id).first { row in
                if let path { return row.path == path }
                return row.path == nil && (row.content == .fold("")) == isMore
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
                             if face.part == .more || face.part == .options { editor.rowBook?.perform(face) }
                         })
}
