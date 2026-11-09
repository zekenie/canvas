import Adornments
import AppKit
import Canvas
import CoreText
import Find
import LineRows

// Find over rows: a table's columns and an enum's values are found a text a row, in row order, each by its row's id (the
// field), so stepping goes top to bottom and a folded table shows the rows with hits while Find is open (LineRows' peeks,
// from `FindState.fieldsHit`). Two contributions, since a look is a contribution's: "rows", a highlighter over a column's
// `name type` and an enum's value where they're drawn on the paper; "row pills", a ring round an enum-typed column's
// pill, which says the enum's name now. Results stay one per shape: a shape's rows are its texts.

extension PluginID {
    public static let engineeringFind: PluginID = "engineering-find"
}

/// Which tables of the file name which shapes in a column's type (an enum, whether it is in the file or not), so a commit
/// that reaches a shape reads again the tables that name it, wherever they are, at the cost of what the commit touched.
/// Built from the file when Find first asks, and followed on every commit after; a file put in place is read afresh.
@MainActor
final class EnumUsers {
    private unowned let editor: CanvasEditor
    private var built = false
    /// For each shape named in a column's type, the tables that name it.
    private var users: [ShapeID: Set<ShapeID>] = [:]
    /// For each table, the shapes its columns name.
    private var named: [ShapeID: Set<ShapeID>] = [:]

    init(editor: CanvasEditor) {
        self.editor = editor
    }

    /// The tables that name a shape `changes` reaches: an enum renamed, deleted, restored or created, on any board.
    func tablesNaming(_ changes: ChangeSet) -> Set<ShapeID> {
        build()
        var tables = Set<ShapeID>()
        for id in touched(by: changes) { tables.formUnion(users[id] ?? []) }
        return tables
    }

    /// What a commit reached other than by moving it.
    private func touched(by changes: ChangeSet) -> Set<ShapeID> {
        changes.added.union(changes.removed).union(changes.elsewhere).union(changes.changed.subtracting(changes.moved))
    }

    private func build() {
        guard !built else { return }
        built = true
        users = [:]
        named = [:]
        let file = editor.file
        for board in file.everyBoard {
            for record in file[board].shapes { read(record) }
        }
    }

    /// Takes `record` into the index, or, not a table, out of it.
    private func read(_ record: AnyShapeRecord?, id: ShapeID? = nil) {
        guard let id = record?.id ?? id else { return }
        for shape in named.removeValue(forKey: id) ?? [] {
            users[shape]?.remove(id)
            if users[shape]?.isEmpty == true { users[shape] = nil }
        }
        guard let table = record?.typed(as: DatabaseTable.self) else { return }
        let shapes = Set(table.props.columns.compactMap(\.type.shape))
        guard !shapes.isEmpty else { return }
        named[id] = shapes
        for shape in shapes { users[shape, default: []].insert(id) }
    }
}

extension EnumUsers: EditorService {
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        guard built else { return }
        if changes.replacedDocument {
            built = false
            return
        }
        for id in touched(by: changes) { read(editor.shape(inFile: id), id: id) }
    }

    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        if change.isFileReplaced { built = false }
    }
}

@MainActor
enum RowFind {
    static func register(into registrar: inout PluginRegistrar) {
        registrar.findableTexts("rows", of: DatabaseTable.self, affected: { changes, context in
            context.service(EnumUsers.self)?.tablesNaming(changes) ?? []
        }, texts: { shape, context in
            shape.props.columns.map { column in
                let pill = TableDefinition.enumName(of: column, registry: context.registry, inFile: context.editor.shape(inFile:)) != nil
                return FindableText(field: column.id.description, text: pill || column.type.words.isEmpty ? column.name : column.name + " " + column.type.words)
            }
        }, rects: { shape, field, ranges, context in
            guard let (column, row, bounds) = columnRow(shape, field: field, context) else { return ranges.map { _ in [] } }
            let laid = ColumnRow(column, in: row, pill: TableDefinition.enumPill(of: column, registry: context.registry, inFile: context.editor.shape(inFile:)))
            let nameLength = (column.name as NSString).length
            return ranges.map { range in
                var rects: [CGRect] = []
                if range.lowerBound < nameLength {
                    rects.append(span(laid.name, range.clamped(to: 0..<nameLength), in: row))
                }
                if let type = laid.type, range.upperBound > nameLength + 1 {
                    let start = max(range.lowerBound, nameLength + 1) - nameLength - 1, end = range.upperBound - nameLength - 1
                    rects.append(span(type, start..<end, in: row))
                }
                return rects.map { $0.offsetBy(dx: -bounds.minX, dy: -bounds.minY) }
            }
        })
        // An enum's name in a column's pill, and whether a column's type is a pill at all: an enum renamed, deleted, brought
        // back (an undo) or made changes both with no commit to the table, so a commit that reaches an enum reads again the
        // tables of the file that name it.
        registrar.findableTexts("row pills", of: DatabaseTable.self, look: .ring, affected: { changes, context in
            context.service(EnumUsers.self)?.tablesNaming(changes) ?? []
        }, texts: { shape, context in
            shape.props.columns.compactMap { column in
                TableDefinition.enumName(of: column, registry: context.registry, inFile: context.editor.shape(inFile:))
                    .map { FindableText(field: column.id.description, text: $0) }
            }
        }, rects: { shape, field, ranges, context in
            guard let (column, row, bounds) = columnRow(shape, field: field, context),
                  let label = TableDefinition.enumPill(of: column, registry: context.registry, inFile: context.editor.shape(inFile:)),
                  let pill = ColumnRow(column, in: row, pill: label).pill else { return ranges.map { _ in [] } }
            let ring = pill.rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
            return ranges.map { _ in [ring] }
        })
        registrar.findableTexts("rows", of: DatabaseEnum.self, texts: { shape, _ in
            shape.props.values.map { FindableText(field: $0.id.description, text: $0.text) }
        }, rects: { shape, field, ranges, context in
            let editor = context.editor
            guard let index = shape.props.values.firstIndex(where: { $0.id.description == field }),
                  let bounds = editor.shapeContext.geometry(of: shape.id)?.bounds, !bounds.isNull else { return ranges.map { _ in [] } }
            let shapes = editor.shapeContext, frame = shapes.frame(of: shape)
            let row = KitStyle.rowRect(KitRows(shape, in: shapes).line(of: index), in: frame), start = row.minX + KitStyle.nameInset
            let text = ColumnRow.Text(line: RowText.line(shape.props.values[index].text, .value), x: start, width: row.maxX - KitStyle.trailingInset - start)
            let length = (shape.props.values[index].text as NSString).length
            return ranges.map { [span(text, $0.clamped(to: 0..<length), in: row).offsetBy(dx: -bounds.minX, dy: -bounds.minY)] }
        })
    }

    /// The column a field names, the rect of the line it's drawn on (or stands at, folded), and the shape's bounds.
    private static func columnRow(_ shape: ShapeRecord<DatabaseTable>, field: String, _ context: FindContext) -> (Column, CGRect, CGRect)? {
        let editor = context.editor
        guard let index = shape.props.columns.firstIndex(where: { $0.id.description == field }),
              let bounds = editor.shapeContext.geometry(of: shape.id)?.bounds, !bounds.isNull else { return nil }
        let shapes = editor.shapeContext
        return (shape.props.columns[index], KitStyle.rowRect(KitRows(shape, in: shapes).line(of: index), in: shapes.frame(of: shape)), bounds)
    }

    /// Where UTF-16 `range` of a line drawn as `text` is, in a row: as tall as the row's text, cut where the line is.
    private static func span(_ text: ColumnRow.Text, _ range: Range<Int>, in row: CGRect) -> CGRect {
        let from = CTLineGetOffsetForStringIndex(text.line.line, range.lowerBound, nil)
        let to = CTLineGetOffsetForStringIndex(text.line.line, range.upperBound, nil)
        let left = text.x + min(from, text.width), right = text.x + min(to, text.width)
        let height = KitStyle.findHitHeight
        return CGRect(x: left, y: row.midY - height / 2, width: max(0, right - left), height: height)
    }
}
