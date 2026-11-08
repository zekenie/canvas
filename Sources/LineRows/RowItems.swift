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
            // Each change through the kind's own (`applying`, `placing`, `reordering`), so what a row says by its neighbors
            // stays said wherever it goes (an API's endpoint its full path).
            carrier: { record, ids in
                guard let shape = typed(record) else { return nil }
                let wanted = Set(ids)
                var props = shape.props
                let all = model.rows(of: props)
                model.setRows(model.removing(Set(all.map(model.id(of:)).filter { !wanted.contains($0) }), from: all), in: &props)
                // Only the rows: no title, no other value the shape held.
                return AnyShapeRecord(ShapeRecord(id: shape.id, props))
            },
            removing: { record, ids in with(record, rows: model.removing(ids, from: rows(record))) },
            inserting: { record, carrier, index, renaming in
                let added = rows(carrier).map { row in renaming[model.id(of: row)].map { model.renaming(row, to: $0) } ?? row }
                return model.inserting(added, at: index, into: rows(record)).flatMap { with(record, rows: $0) }
            },
            reordering: { record, ids, index in with(record, rows: model.reordering(Set(ids), to: index, in: rows(record))) },
            takeOut: { carrier in
                guard let shape = typed(carrier) else { return nil }
                return AnyShapeRecord(ShapeRecord(model.takeOut(model.rows(of: shape.props), from: shape)))
            },
            editsTitle: model.takeOutEditsTitle,
            headerNoun: model.headerNoun,
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
            drag: { editor, shape, ids, origin in
                // What the keys act on: a line standing for rows a fold hides drags those rows, never itself.
                let acting = editor.selectedItems.flatMap { $0.shape == shape ? $0.acting : nil } ?? ids
                return RowDragSession(rows: acting.compactMap { $0.base as? PartID }, of: shape, from: origin, in: editor)
            },
            lead: { editor, record, point in
                // Zoomed out the marks aren't drawn: a press there moves the shape.
                guard !editor.drawsSkeletons, let shape = typed(record) else { return nil }
                let all = model.rows(of: shape.props)
                guard let item = RowItems.items(of: record, in: editor, title: { _ in "" }).first(where: { $0.rect.contains(point) }),
                      let id = item.id.base as? PartID, let index = all.firstIndex(where: { model.id(of: $0) == id }),
                      let rect = model.lead(of: all[index], at: index, among: all, line: item.rect,
                                            in: LineContext(editor: editor, shape: record.id, row: id)),
                      rect.contains(point) else { return nil }
                return ItemLead(item: id) { editor, wasSelected in RowItems.clickLead(id, of: record.id, wasSelected: wasSelected, in: editor) }
            },
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

    /// A click on a row's lead: what a click there would do without one, a level at a time: on the shape that was the only one
    /// selected, the row selected; else the shape, which the press selected.
    static func clickLead(_ row: PartID, of shape: ShapeID, wasSelected: Bool, in editor: CanvasEditor) {
        if wasSelected { editor.selectItems([AnyHashable(row)], of: shape) }
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
        let title = RowSteps.takeOut(editor.stepNoun(of: rows, in: record, moving), count: rows.count, into: record.kind, in: editor.registry)
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
