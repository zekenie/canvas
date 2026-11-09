import Adornments
import AppKit
import Canvas
import Draw
import Geometry
import LineRows
import Palette
import Titles

/// A table, at rest: its paper, and a row a column, `KitStyle.rowHeight` apart: in the gutter a primary key's key, else a
/// key's link (a column that starts a key, read from the key index), else a unique column's "1"; its name; and at the right its type in grey monospace, an enum-typed column's in a pill that says
/// the enum's name now, and a nullable column's `?` after it. Its width is its own; its height its rows' (`LaidOutBox`),
/// so nothing is written when rows come and go. Its rows are its parts (`PartedShape`), each where its row is in its
/// geometry. Edited, its title is typed in its pill (`TitleField`) and its columns a line each (LineRows): it draws no row
/// the field has and leaves the waiting line's room (`KitRows`).
@MainActor
struct TableDefinition {}

extension TableDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<DatabaseTable>, in context: RenderContext) {
        let frame = context.shapes.frame(of: shape)
        KitPaper.draw(frame, in: context)
        let columns = shape.props.columns, rows = KitRows(shape, in: context.shapes)
        let lines = KitPaper.rowsInView(rows.lines(columns.count), in: frame, context)
        // The table's keys, read once a frame and only for a table with rows in view.
        let keys = lines.isEmpty ? [:] : context.shapes.keys?.keys(of: shape.id) ?? [:]
        let more = rows.more, names = lines.isEmpty ? nil : context.service(KitNames.self)
        for line in lines {
            if line == more?.line, let more {
                MoreLine.draw(more.count, in: KitStyle.rowRect(line, in: frame), context)
                continue
            }
            guard let index = rows.row(atLine: line), columns[index].id != rows.focused else { continue }
            rows.drawing(columns[index].id, in: context.cg) {
                drawColumn(columns[index], of: shape.id, names: names, isKey: keys[columns[index].id] != nil, in: KitStyle.rowRect(line, in: frame), context)
            }
        }
    }

    /// One column's row: its mark, its name, and its type at the right (the type wins the room: a name too long is cut).
    private func drawColumn(_ column: Column, of table: ShapeID, names: KitNames?, isKey: Bool, in row: CGRect, _ context: RenderContext) {
        let cg = context.cg, middle = row.midY
        if column.primaryKey {
            RowMarks.draw(TableStyle.keySymbol, color: TableStyle.keyColor, centeredAt: CGPoint(x: row.minX + KitStyle.gutterMiddle, y: middle))
        } else if isKey {
            RowMarks.draw(TableStyle.linkSymbol, color: TableStyle.linkColor, centeredAt: CGPoint(x: row.minX + KitStyle.gutterMiddle, y: middle))
        } else if column.unique {
            RowMarks.draw(TableStyle.uniqueSymbol, color: TableStyle.uniqueColor, centeredAt: CGPoint(x: row.minX + KitStyle.gutterMiddle, y: middle))
        }
        let laid = ColumnRow(column, in: row, pill: Self.enumPill(of: column, in: table, registry: context.shapes.registry, inFile: context.shape(inFile:), names: names))
        if let null = laid.null { RowText.draw(null.line, at: null.x, middle: middle, in: cg) }
        if let pill = laid.pill { pill.label.draw(at: pill.rect.origin, in: cg) }
        if let type = laid.type { RowText.draw(type.line, at: type.x, middle: middle, room: type.width, in: cg) }
        RowText.draw(laid.name.line, at: laid.name.x, middle: middle, room: laid.name.width, in: cg)
    }

    /// How wide a table is drawn for every column to read whole at rest, as `ColumnRow` lays a row out (its name, the gap,
    /// its type or enum pill, a nullable's `?`), never narrower than a new table (`TableStyle.width`) nor wider than
    /// `TableStyle.mostWholeWidth`: what a commit widens a table to (`TableLines.wholeWidth`) and what a pasted table is made at.
    /// An enum the file doesn't hold (`inFile` finds none) measures as its type's words.
    static func wholeWidth(of columns: [Column], in table: ShapeID, registry: Registry, inFile: (ShapeID) -> AnyShapeRecord?, names: KitNames?) -> CGFloat {
        wholeWidth(of: columns.map { column in
            WholeRow(name: column.name, type: column.type.words, pill: enumPill(of: column, in: table, registry: registry, inFile: inFile, names: names),
                     nullable: column.nullable)
        })
    }

    /// What of a column `wholeWidth` measures: its name, its type's words, the enum pill they make (nil: none, or none known yet,
    /// as for a column the SQL paste reads), and whether it's nullable.
    struct WholeRow {
        let name: String
        let type: String
        let pill: AdornmentLabel?
        let nullable: Bool
    }

    /// The same, of columns as `WholeRow`s: what the SQL paste makes a table at.
    static func wholeWidth(of rows: [WholeRow]) -> CGFloat {
        var widest = TableStyle.width
        for row in rows {
            var width = KitStyle.nameInset + RowText.line(row.name, .name).width + KitStyle.nameGap + KitStyle.trailingInset
            if let pill = row.pill {
                width += pill.contentSize.width
            } else if !row.type.isEmpty {
                width += RowText.line(row.type, .type).width
            }
            if row.nullable { width += RowText.line(TableStyle.nullMark, .null).width }
            widest = max(widest, width)
        }
        return min(widest.rounded(.up), TableStyle.mostWholeWidth)
    }

    /// An enum-typed column's pill: the enum its type names, while it's in the file, by its name now.
    static func enumPill(of column: Column, in table: ShapeID, registry: Registry, inFile: (ShapeID) -> AnyShapeRecord?, names: KitNames?) -> AdornmentLabel? {
        guard let name = enumName(of: column, in: table, registry: registry, inFile: inFile, names: names) else { return nil }
        return AdornmentLabel(name).tinted(TableStyle.enumPill)
    }

    /// The name of the enum a column's type names, now, while it's in the file: what makes the type a pill, at rest and
    /// zoomed out, and what Find finds in it. A type whose words were written before their enum was made, or whose enum is gone
    /// and one of that name made since, names the enum its words name, nearest the table, as typing the line would bind it
    /// (`KitNames.enumNamed`), so the table at rest, Find, its width and its line say the same.
    static func enumName(of column: Column, in table: ShapeID, registry: Registry, inFile: (ShapeID) -> AnyShapeRecord?, names: KitNames?) -> String? {
        if let record = column.type.shape.flatMap(inFile), record.kind == DatabaseEnum.kind { return registry.title(of: record) ?? column.type.words }
        guard !column.type.words.isEmpty, let names, names.enumNamed(column.type.words, near: table) != nil else { return nil }
        return column.type.words
    }

    /// Its laid-out frame, and a part a row.
    func geometry(of shape: ShapeRecord<DatabaseTable>, in context: ShapeContext) -> ShapeGeometry {
        let frame = context.frame(of: shape), rows = KitRows(shape, in: context)
        let parts = shape.props.columns.enumerated().map { PartFrame(id: $1.id, rect: KitStyle.rowRect(rows.line(of: $0), in: frame), isShown: rows.isShown($0)) }
        // A line to the table as a whole meets its first row, at the side facing it (E8 panel 2, T6 panel 1).
        let entries = parts.first(where: \.isShown).map { ShapeEntry.sides(of: $0.rect) } ?? []
        return ShapeGeometry(outline: frame.polygon, bounds: frame, parts: PartFrames(parts), entries: entries)
    }

    func indicatorPath(of shape: ShapeRecord<DatabaseTable>, in context: ShapeContext) -> CGPath {
        KitStyle.paperPath(context.frame(of: shape))
    }
}

/// As wide as it stores, as tall as its rows.
extension TableDefinition: LaidOutBox {
    func laidOutSize(of shape: ShapeRecord<DatabaseTable>, in context: ShapeContext) -> CGSize {
        let rows = KitRows(shape, in: context)
        return CGSize(width: rows.width(stored: shape.frame.width), height: KitStyle.height(rows: rows.lines(shape.props.columns.count)))
    }
}

/// Makes room as its rows grow: a table gaining a column pushes what is below it in its database down, in the same step.
extension TableDefinition: MakesRoomAsItGrows {
    var roomKeptBelow: CGFloat { KitStyle.roomKeptBelow }
}

/// Its stored height is kept in step with its rows wherever it's made from properties (`canvas draw`), so the box it
/// stores is the table as it's laid out.
extension TableDefinition: DerivedProps {
    func derive(_ table: inout DatabaseTable) {
        table.frame.size.height = KitStyle.height(rows: table.columns.count)
    }
}

/// Drawn by `canvas draw`, it's as wide as its columns read whole at rest, as a commit of its lines makes it.
extension TableDefinition: DrawnWhole {
    func wholeWidth(of shape: ShapeRecord<DatabaseTable>, in context: ShapeContext) -> CGFloat? {
        let names = context.service(KitNames.self)
        return Self.wholeWidth(of: shape.props.columns, in: shape.id, registry: context.registry, inFile: { context.shape($0) ?? names?.editor.shape(inFile: $0) },
                               names: names)
    }
}

/// Given a frame (a resize, `size:`), it takes its place and its width; its height stays its rows'.
extension TableDefinition: CustomSizing {
    func size(_ shape: inout ShapeRecord<DatabaseTable>, to frame: CGRect, giving axes: SizeAxes, in context: ShapeContext) {
        shape.props.frame.origin = frame.origin
        if axes.contains(.width) { shape.props.frame.size.width = frame.width }
        derive(&shape.props)
    }

    /// Its height is its rows': only its width is given by hand, so it is resized by its corners (no handle on a row's end).
    func resizedAxes(of shape: ShapeRecord<DatabaseTable>) -> SizeAxes { .width }
}

/// Its rows are its parts: a column each, by its name; and taken out by their ids (`canvas draw`'s `delete "orders".id`).
extension TableDefinition: PartedShape {
    func parts(of shape: ShapeRecord<DatabaseTable>) -> [PartName] {
        shape.props.columns.map { column in
            PartName(id: column.id, name: column.name, kindWord: "Column",
                     lead: column.primaryKey ? .symbol(TableStyle.keySymbol) : column.unique ? .symbol(TableStyle.uniqueSymbol) : .none)
        }
    }

    func removing(_ parts: Set<PartID>, from shape: ShapeRecord<DatabaseTable>) -> DatabaseTable? {
        var table = shape.props
        table.columns.removeAll { parts.contains($0.id) }
        guard table.columns.count < shape.props.columns.count else { return nil }
        derive(&table)
        return table
    }
}

/// Zoomed out: its paper, a bar a name and a bar a type in one fill, and its enums' pills in another.
extension TableDefinition: CustomSkeleton {
    func renderSkeleton(_ shape: ShapeRecord<DatabaseTable>, in context: RenderContext) {
        let frame = context.shapes.frame(of: shape)
        KitPaper.drawSkeleton(frame, in: context)
        let columns = shape.props.columns, rows = KitRows(shape, in: context.shapes)
        var text: [CGRect] = [], pills: [CGRect] = [], fadedText: [CGRect] = [], fadedPills: [CGRect] = []
        let more = rows.more, names = context.service(KitNames.self)
        for line in KitPaper.skeletonRowsInView(rows.lines(columns.count), in: frame, context) {
            if line == more?.line, let more {
                if let bar = MoreLine.bar(more.count, in: KitStyle.rowRect(line, in: frame)) { text.append(bar) }
                continue
            }
            guard let index = rows.row(atLine: line) else { continue }
            let column = columns[index], row = KitStyle.rowRect(line, in: frame)
            let start = row.minX + KitStyle.nameInset, end = row.maxX - KitStyle.trailingInset
            // The rows a drag takes, as bars faded where they are.
            let taken = rows.faded?.contains(column.id) == true
            let type = KitPaper.bar(columns: SkeletonText.columns(of: column.type.words, upTo: TableStyle.skeletonMostColumns),
                                    column: TableStyle.skeletonTypeColumn, at: end, trailing: true, in: row, room: (end - start) / 2)
            if let type {
                if Self.enumName(of: column, in: shape.id, registry: context.shapes.registry, inFile: context.shape(inFile:), names: names) != nil {
                    if taken { fadedPills.append(type) } else { pills.append(type) }
                } else if taken { fadedText.append(type) } else { text.append(type) }
            }
            if let name = KitPaper.bar(columns: SkeletonText.columns(of: column.name, upTo: TableStyle.skeletonMostColumns), column: TableStyle.skeletonNameColumn,
                                       at: start, in: row, room: max(0, (type?.minX ?? end) - KitStyle.nameGap - start)) {
                if taken { fadedText.append(name) } else { text.append(name) }
            }
        }
        context.fillSkeletonText(text)
        Self.fillPills(pills, in: context)
        rows.fillFaded(text: fadedText, in: context) { Self.fillPills(fadedPills, in: context) }
    }

    /// The enum pills' bars, one fill.
    private static func fillPills(_ pills: [CGRect], in context: RenderContext) {
        guard !pills.isEmpty else { return }
        context.cg.saveGState()
        for pill in pills { context.cg.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil)) }
        context.cg.setFillColor(TableStyle.enumPill.color.cgColor)
        context.cg.fillPath()
        context.cg.restoreGState()
    }
}

/// Edited, its name is typed in its pill (the field over the pill's row, above its paper) and its columns a line each.
extension TableDefinition: Editable {
    func editingFrame(of shape: ShapeRecord<DatabaseTable>, in context: ShapeContext) -> CGRect? {
        TitleField.editingFrame(around: context.frame(of: shape), zoom: context.zoom)
    }

    func makeEditingView(for shape: ShapeRecord<DatabaseTable>, context: EditContext<DatabaseTable>) -> EditingView {
        LineRowsView.make(shape, context: context, model: TableLines(table: shape.id, keys: context.service(KeyIndex.self)), title: LineTitle { title in
            TitleField(title: title, systemImage: TableStyle.symbol, tint: nil, placeholder: TableStyle.placeholder, name: TableStyle.titleFieldName)
        })
    }

    var editingStepName: String? { TableStyle.renameStep }
}

/// Where a column's row puts what it says, world units: at the right its nullable's `?`, then its type (an enum's pill, or
/// grey text, which wins the room over the name), and its name from the names' inset, cut short where it meets the type.
/// What the render draws and what Find rings and marks.
@MainActor
struct ColumnRow {
    /// A line of text, from `x`, as wide as it may be drawn (`width`; past it, cut short).
    struct Text {
        let line: RowText.Line
        let x: CGFloat
        let width: CGFloat
    }

    let name: Text
    let type: Text?
    let pill: (label: AdornmentLabel, rect: CGRect)?
    let null: Text?

    init(_ column: Column, in row: CGRect, pill label: AdornmentLabel?) {
        let middle = row.midY
        var end = row.maxX - KitStyle.trailingInset
        if column.nullable {
            let null = RowText.line(TableStyle.nullMark, .null)
            end -= null.width
            self.null = Text(line: null, x: end, width: null.width)
        } else {
            null = nil
        }
        let start = row.minX + KitStyle.nameInset
        let name = RowText.line(column.name, .name)
        if let label = label {
            let size = label.contentSize
            end = max(start, end - size.width)
            pill = (label, CGRect(x: end, y: middle - size.height / 2, width: size.width, height: size.height))
            type = nil
        } else if !column.type.words.isEmpty {
            let line = RowText.line(column.type.words, .type)
            let room = max(0, end - start - KitStyle.nameGap - name.width)
            let width = min(line.width, max(room, (end - start) / 2))
            end -= width
            type = Text(line: line, x: end, width: width)
            pill = nil
        } else {
            type = nil
            pill = nil
        }
        self.name = Text(line: name, x: start, width: end - KitStyle.nameGap - start)
    }
}
