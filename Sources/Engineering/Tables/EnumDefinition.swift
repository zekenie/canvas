import AppKit
import Canvas
import Geometry
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
        let values = shape.props.values
        for index in KitPaper.rowsInView(values.count, in: frame, context) {
            let row = KitStyle.rowRect(index, in: frame), start = row.minX + KitStyle.nameInset
            RowText.draw(RowText.line(values[index].text, .value), at: start, middle: row.midY, room: row.maxX - KitStyle.trailingInset - start, in: context.cg)
        }
    }

    func geometry(of shape: ShapeRecord<DatabaseEnum>, in context: ShapeContext) -> ShapeGeometry {
        let frame = context.frame(of: shape)
        let parts = shape.props.values.enumerated().map { PartFrame(id: $1.id, rect: KitStyle.rowRect($0, in: frame)) }
        return ShapeGeometry(outline: frame.polygon, bounds: frame, parts: PartFrames(parts))
    }

    func indicatorPath(of shape: ShapeRecord<DatabaseEnum>, in context: ShapeContext) -> CGPath {
        KitStyle.paperPath(context.frame(of: shape))
    }
}

extension EnumDefinition: LaidOutBox {
    func laidOutSize(of shape: ShapeRecord<DatabaseEnum>, in context: ShapeContext) -> CGSize {
        CGSize(width: shape.frame.width, height: KitStyle.height(rows: shape.props.values.count))
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
}

/// Zoomed out: its paper, and a bar a value in one fill.
extension EnumDefinition: CustomSkeleton {
    func renderSkeleton(_ shape: ShapeRecord<DatabaseEnum>, in context: RenderContext) {
        let frame = context.shapes.frame(of: shape)
        KitPaper.drawSkeleton(frame, in: context)
        let values = shape.props.values
        context.fillSkeletonText(KitPaper.rowsInView(values.count, in: frame, context).compactMap { index in
            let row = KitStyle.rowRect(index, in: frame), start = row.minX + KitStyle.nameInset
            return KitPaper.bar(columns: SkeletonText.columns(of: values[index].text, upTo: TableStyle.skeletonMostColumns), column: EnumStyle.skeletonColumn,
                                at: start, in: row, room: row.maxX - KitStyle.trailingInset - start)
        })
    }
}

extension EnumDefinition: Editable {
    func editingFrame(of shape: ShapeRecord<DatabaseEnum>, in context: ShapeContext) -> CGRect? {
        TitleField.editingFrame(around: context.frame(of: shape), zoom: context.zoom)
    }

    func makeEditingView(for shape: ShapeRecord<DatabaseEnum>, context: EditContext<DatabaseEnum>) -> EditingView {
        TitleField.editingView(for: shape, context: context, systemImage: EnumStyle.symbol, tint: EnumStyle.titleTint, name: EnumStyle.titleFieldName)
    }

    var editingStepName: String? { EnumStyle.renameStep }
}
