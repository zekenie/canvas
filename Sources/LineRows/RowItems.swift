import AppKit
import Canvas
import ContextMenus
import Selection
import Titles

// Rows selected on the canvas, as Selection's items of their shape (`ShapeItems`), and moved as wholes (`LineRowsMoves`),
// for every kind written as lines: what `lineRows(_:)` contributes beside the kind's rows. The items are the lines the shape
// shows: each row, and, folded, a closed header and the "+N ›" line, each standing for the rows it hides (a selected row a
// fold hides shows as its line selected, and comes back as itself as it unfolds). ⌫ deletes the rows selected (the kind's
// counted step), ⌥↑ ⌥↓ moves them, Return edits the first (a click on the only selected one edits it there), → ← and Space
// open and close a header or the "+N ›" line. The selection's menu offers their take-out as one step ("Move Columns to New
// Table").

/// The "+N ›" line of a folded shape, as an item.
struct MoreLineItem: Hashable, Sendable {
    let shape: ShapeID
}

extension ShapeRegistrar {
    /// Rows selected as items, and moved as wholes, for this kind written as lines by `model`.
    mutating func lineRowItems<Model: LineModel>(_ model: Model) where Model.Props == Definition.Props {
        let kind = Model.Props.kind
        func typed(_ record: AnyShapeRecord) -> ShapeRecord<Model.Props>? { record.typed(as: Model.Props.self) }
        func rows(_ record: AnyShapeRecord) -> [Model.Row] { typed(record).map { model.rows(of: $0.props) } ?? [] }
        func with(_ record: AnyShapeRecord, rows: [Model.Row]) -> AnyShapeRecord? {
            guard var shape = typed(record) else { return nil }
            model.setRows(rows, in: &shape.props)
            return AnyShapeRecord(shape)
        }
        contribute(LineRowsMoving(
            noun: model.noun,
            takes: { $0 == kind },
            rows: { record in typed(record).map { model.rows(of: $0.props).map(model.id(of:)) } },
            carrier: { record, ids in
                guard let shape = typed(record) else { return nil }
                let wanted = Set(ids)
                var props = shape.props
                model.setRows(model.rows(of: props).filter { wanted.contains(model.id(of: $0)) }, in: &props)
                // Only the rows: no title, no other value the shape held.
                return AnyShapeRecord(ShapeRecord(id: shape.id, props))
            },
            removing: { record, ids in with(record, rows: rows(record).filter { !ids.contains(model.id(of: $0)) }) },
            inserting: { record, carrier, index, renaming in
                var held = rows(record)
                let added = rows(carrier).map { row in renaming[model.id(of: row)].map { model.renaming(row, to: $0) } ?? row }
                held.insert(contentsOf: added, at: min(max(0, index), held.count))
                return with(record, rows: held)
            },
            reordering: { record, ids, index in
                let all = rows(record), moved = Set(ids)
                var rest = all.filter { !moved.contains(model.id(of: $0)) }
                rest.insert(contentsOf: all.filter { moved.contains(model.id(of: $0)) }, at: min(max(0, index), rest.count))
                return with(record, rows: rest)
            },
            takeOut: { carrier in
                guard let shape = typed(carrier) else { return nil }
                return AnyShapeRecord(ShapeRecord(model.takeOut(model.rows(of: shape.props), from: shape)))
            },
            editsTitle: model.takeOutEditsTitle,
            lines: { carrier, editor in
                rows(carrier).map { row in
                    model.grammar(for: model.role(of: row)).print(row, in: LineContext(editor: editor, shape: carrier.id, row: model.id(of: row))).string
                }
            }), to: LineRowsMoves.self)
        shapeItems(named: "rows", { editor, record in
            // Each row's words are worked out only when an item's title is asked (VoiceOver), so listing them costs their rects.
            let all = rows(record)
            let byID = Dictionary(all.map { (model.id(of: $0), $0) }) { first, _ in first }
            return RowItems.items(of: record, in: editor) { [weak editor] id in
                guard let editor, let row = byID[id] else { return "" }
                return model.grammar(for: model.role(of: row)).spoken(row, in: LineContext(editor: editor, shape: record.id, row: id))
            }
        }, at: { editor, record, point in
            RowItems.items(of: record, in: editor) { _ in "" }.first { $0.rect.minY <= point.y && point.y < $0.rect.maxY && $0.rect.contains(point) }?.id
        }, actions: ShapeItemActions(
            delete: { editor, shape, ids in
                guard let record = editor.document[shape] else { return }
                let all = rows(record), wanted = Set(ids.compactMap { $0.base as? PartID })
                let gone = all.filter { wanted.contains(model.id(of: $0)) }
                guard !gone.isEmpty else { return }
                // The row after the last one deleted is selected next (else the one before): the keys go on from where they were.
                let last = all.lastIndex { wanted.contains(model.id(of: $0)) } ?? 0, first = all.firstIndex { wanted.contains(model.id(of: $0)) } ?? 0
                let next = all[(last + 1)...].first.map(model.id(of:)) ?? (first > 0 ? model.id(of: all[first - 1]) : nil)
                guard model.write([.delete(gone)], to: shape, in: editor) else { return }
                editor.selectItems(next.map { [AnyHashable($0)] } ?? [], of: shape)
            },
            move: { editor, shape, ids, delta in
                editor.moveRows(ids.compactMap { $0.base as? PartID }, of: shape, by: delta)
            },
            open: { editor, shape, id, point in RowItems.open(id, of: shape, at: point, in: editor) },
            setOpen: { editor, shape, id, open in RowItems.setOpen(id, of: shape, open, in: editor) },
            selectedWords: { LineFieldStyle.selected(model.noun.counted($0)) }))
    }
}

/// The items of a shape written as lines, and what opening one does.
@MainActor
enum RowItems {
    /// The lines `record` shows as items, top to bottom: a row each, or, folded, the rows shown, its closed headers and its
    /// "+N ›" line, each of those standing for the rows it hides. `title` says a row.
    static func items(of record: AnyShapeRecord, in editor: CanvasEditor, title: @escaping @MainActor (PartID) -> String) -> [ShapeItem] {
        let shapes = editor.shapeContext
        guard let kind = editor.registry.lineRows(of: record.kind), let rows = kind.rows(record), !rows.isEmpty,
              let frame = shapes.frame(of: record) else { return [] }
        guard let shown = shapes.layoutInput(LineRowsLayout.shown, of: record) else {
            let parts = shapes.geometry(of: record.id)?.parts
            return rows.enumerated().map { index, row in
                ShapeItem(id: row.id, title: title(row.id), rect: parts?.frame(row.id)?.rect ?? kind.lineRect(index, frame),
                          outline: row.isHeader ? .open : nil)
            }
        }
        var hidden: [Int: [AnyHashable]] = [:]
        for index in rows.indices where !shown.isShown(index) { hidden[shown.line(standingFor: index), default: []].append(AnyHashable(rows[index].id)) }
        return shown.lines.enumerated().map { line, kept in
            let rect = kind.lineRect(line, frame)
            switch kept {
            case .row(let index):
                return ShapeItem(id: rows[index].id, title: title(rows[index].id), rect: rect, outline: rows[index].isHeader ? .open : nil)
            case .header(let index, _):
                return ShapeItem(id: rows[index].id, title: title(rows[index].id), rect: rect, outline: .closed, stands: hidden[line] ?? [])
            case .more(let count):
                return ShapeItem(id: MoreLineItem(shape: record.id), title: LineFoldStyle.more(count, noun: kind.noun), rect: rect, outline: .closed,
                                 stands: hidden[line] ?? [])
            }
        }
    }

    /// Return on an item, or a click on the only selected one: the "+N ›" line opened; a row edited there (from the click's
    /// point, else at its line's end).
    static func open(_ id: AnyHashable, of shape: ShapeID, at point: CGPoint?, in editor: CanvasEditor) {
        if id.base is MoreLineItem {
            setOpen(id, of: shape, true, in: editor)
            return
        }
        guard let row = id.base as? PartID else { return }
        editor.service(LineRowsService.self)?.edit(row, of: shape, at: point)
    }

    /// → ← Space on a header or the "+N ›" line: opened or closed; the selection stays on it.
    static func setOpen(_ id: AnyHashable, of shape: ShapeID, _ open: Bool, in editor: CanvasEditor) {
        guard let folds = editor.rowFolds else { return }
        if id.base is MoreLineItem {
            guard open else { return }
            folds.openMore(of: shape)
        } else if let header = id.base as? PartID {
            folds.setClosed(!open, header: header, of: shape)
        }
        editor.announce(open ? LineFoldStyle.unfolded : LineFoldStyle.closed)
    }

    /// The take-out of the rows selected on the canvas, in the selection's menu: "Move Columns to New Table", one step, the
    /// new shape beside the old.
    static func takeOutItem(_ subject: MenuSubject) -> MenuItem<MenuSubject>? {
        let editor = subject.editor
        guard let selection = editor.selectedItems, subject.shapes == [selection.shape], let record = editor.document[selection.shape],
              let moving = editor.registry.rowMoving(of: record.kind) else { return nil }
        let rows = selection.acting.compactMap { $0.base as? PartID }
        guard !rows.isEmpty else { return nil }
        let title = RowSteps.takeOut(moving.noun, count: rows.count, into: record.kind, in: editor.registry)
        return MenuItem(title, in: RowsMenuGroup.self, id: "take-out-rows", stepName: title) { ids, editor in
            editor.moveRows(rows, of: selection.shape, to: .beside(ids))
        }
    }
}

/// The take-out of selected rows' group in a context menu: right after the kind's own items, as it's about the rows selected.
public enum RowsMenuGroup {}
extension RowsMenuGroup: MenuGroup {
    public static var order: Order<Self> { .after(ShapeMenuGroup.self) }
}
