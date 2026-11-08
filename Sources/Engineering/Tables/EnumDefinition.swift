import AppKit
import Canvas
import Geometry
import LineRows
import Titles

/// An enum, at rest: its paper, and its values a row each in monospace at the names' inset. Its width is its own, its
/// height its rows' (`LaidOutBox`); its values are its parts. Its title's pill is solid purple, after a list's glyph;
/// edited, its name is typed in it.
@MainActor
struct EnumDefinition {}

extension EnumDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<DatabaseEnum>, in context: RenderContext) {
        let frame = context.shapes.frame(of: shape)
        KitPaper.draw(frame, in: context)
        let values = shape.props.values, rows = KitRows(shape, in: context.shapes)
        let more = rows.more
        for line in KitPaper.rowsInView(rows.lines(values.count), in: frame, context) {
            if line == more?.line, let more {
                MoreLine.draw(more.count, in: KitStyle.rowRect(line, in: frame), context)
                continue
            }
            guard let index = rows.row(atLine: line), values[index].id != rows.focused else { continue }
            let row = KitStyle.rowRect(line, in: frame), start = row.minX + KitStyle.nameInset
            rows.drawing(values[index].id, in: context.cg) {
                RowText.draw(RowText.line(values[index].text, .value), at: start, middle: row.midY, room: row.maxX - KitStyle.trailingInset - start, in: context.cg)
            }
        }
    }

    func geometry(of shape: ShapeRecord<DatabaseEnum>, in context: ShapeContext) -> ShapeGeometry {
        let frame = context.frame(of: shape), rows = KitRows(shape, in: context)
        let parts = shape.props.values.enumerated().map { PartFrame(id: $1.id, rect: KitStyle.rowRect(rows.line(of: $0), in: frame), isShown: rows.isShown($0)) }
        return ShapeGeometry(outline: frame.polygon, bounds: frame, parts: PartFrames(parts))
    }

    func indicatorPath(of shape: ShapeRecord<DatabaseEnum>, in context: ShapeContext) -> CGPath {
        KitStyle.paperPath(context.frame(of: shape))
    }
}

extension EnumDefinition: LaidOutBox {
    func laidOutSize(of shape: ShapeRecord<DatabaseEnum>, in context: ShapeContext) -> CGSize {
        let rows = KitRows(shape, in: context)
        return CGSize(width: rows.width(stored: shape.frame.width), height: KitStyle.height(rows: rows.lines(shape.props.values.count)))
    }
}

extension EnumDefinition: DerivedProps {
    func derive(_ type: inout DatabaseEnum) {
        type.frame.size.height = KitStyle.height(rows: type.values.count)
    }
}

extension EnumDefinition: CustomSizing {
    func size(_ shape: inout ShapeRecord<DatabaseEnum>, to frame: CGRect, giving axes: SizeAxes, in context: ShapeContext) {
        shape.props.frame.origin = frame.origin
        if axes.contains(.width) { shape.props.frame.size.width = frame.width }
        derive(&shape.props)
    }
}

extension EnumDefinition: PartedShape {
    func parts(of shape: ShapeRecord<DatabaseEnum>) -> [PartName] {
        shape.props.values.map { PartName(id: $0.id, name: $0.text, kindWord: "Value") }
    }

    func removing(_ parts: Set<PartID>, from shape: ShapeRecord<DatabaseEnum>) -> DatabaseEnum? {
        var type = shape.props
        type.values.removeAll { parts.contains($0.id) }
        guard type.values.count < shape.props.values.count else { return nil }
        derive(&type)
        return type
    }
}

/// Zoomed out: its paper, and a bar a value in one fill.
extension EnumDefinition: CustomSkeleton {
    func renderSkeleton(_ shape: ShapeRecord<DatabaseEnum>, in context: RenderContext) {
        let frame = context.shapes.frame(of: shape)
        KitPaper.drawSkeleton(frame, in: context)
        let values = shape.props.values, rows = KitRows(shape, in: context.shapes), more = rows.more
        var bars: [CGRect] = [], faded: [CGRect] = []
        for line in KitPaper.skeletonRowsInView(rows.lines(values.count), in: frame, context) {
            if line == more?.line, let more {
                if let bar = MoreLine.bar(more.count, in: KitStyle.rowRect(line, in: frame)) { bars.append(bar) }
                continue
            }
            guard let index = rows.row(atLine: line) else { continue }
            let row = KitStyle.rowRect(line, in: frame), start = row.minX + KitStyle.nameInset
            guard let bar = KitPaper.bar(columns: SkeletonText.columns(of: values[index].text, upTo: TableStyle.skeletonMostColumns), column: EnumStyle.skeletonColumn,
                                         at: start, in: row, room: row.maxX - KitStyle.trailingInset - start) else { continue }
            // The rows a drag takes, as bars faded where they are.
            if rows.faded?.contains(values[index].id) == true { faded.append(bar) } else { bars.append(bar) }
        }
        context.fillSkeletonText(bars)
        rows.fillFaded(text: faded, in: context) {}
    }
}

extension EnumDefinition: Editable {
    func editingFrame(of shape: ShapeRecord<DatabaseEnum>, in context: ShapeContext) -> CGRect? {
        TitleField.editingFrame(around: context.frame(of: shape), zoom: context.zoom)
    }

    func makeEditingView(for shape: ShapeRecord<DatabaseEnum>, context: EditContext<DatabaseEnum>) -> EditingView {
        LineRowsView.make(shape, context: context, model: EnumLines(), title: LineTitle { title in
            TitleField(title: title, systemImage: EnumStyle.symbol, tint: EnumStyle.titleTint, name: EnumStyle.titleFieldName)
        })
    }

    var editingStepName: String? { EnumStyle.renameStep }
}
