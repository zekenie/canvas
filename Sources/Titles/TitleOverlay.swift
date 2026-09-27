import AppKit
import Canvas

@MainActor
enum TitleStyle {
    // View points.
    static let height: CGFloat = 18
    static let padding: CGFloat = 7
    /// Between the pill and the shape's top edge: clear of a badge centered on the edge, as the
    /// checklist chip is on the top-right corner, reaching 8 points above it. Titles can't see the
    /// chip, so CompositionTests, which ships both, holds a long title's pill clear of it.
    static let gap: CGFloat = 9
    /// The end of the pill's row, above the shape's top-right corner, is left to a round chip as
    /// tall as the pill (Locking's lock), and a little room before it. Titles can't see that chip
    /// either; CompositionTests holds a long title's pill clear of it too.
    static let cornerReserve: CGFloat = height + 4
    /// A pill narrower than this, with the corner left out, isn't drawn: there'd be no room for its
    /// title.
    static let minWidth: CGFloat = 30
    /// Below this zoom the pill shrinks with the shapes, as the checklist chip does.
    static let fullSizeZoom: CGFloat = 0.25
    static let fill = NSColor(white: 0.25, alpha: 0.9)
    static let attributes: [NSAttributedString.Key: Any] = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
    }()
}

/// A pill with the shape's title, just outside its top-left corner, on every titled shape whose
/// kind shows it. On one line, and no wider than the shape, less the row's corner: a longer title
/// ends in "…". Shapes never know about it, and an untitled one draws nothing. It goes where its
/// shape is drawn (`editor.setDrawingOffset`), so it moves with a shaking shape.
struct TitleOverlay: CanvasOverlay {
    var space: OverlaySpace { .world }

    func draw(in context: OverlayContext) {
        guard let pills = context.editor.service(TitleState.self)?.pills, !pills.isEmpty else { return }
        // World units per view point, from the shape's top-left corner up (more when zoomed far out).
        let scale = min(1, context.zoom / TitleStyle.fullSizeZoom) / context.zoom
        // A pill is above its shape, so a shape just below the view may have its pill in it.
        let visible = context.visibleRect
        let reach = (TitleStyle.gap + TitleStyle.height) * scale
        let area = CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: visible.height + reach)
        // In paint order, so overlapping pills stack as their shapes do.
        for record in context.editor.paintOrder(in: area) {
            guard let title = pills[record.kind]?.title(record),
                  let bounds = context.shapes.geometry(of: record.id)?.bounds, !bounds.isNull else { continue }
            let maxWidth = bounds.width / scale - TitleStyle.cornerReserve
            guard maxWidth >= TitleStyle.minWidth else { continue }
            let offset = context.worldDrawingOffset(of: record.id)
            context.cg.saveGState()
            context.cg.translateBy(x: bounds.minX + offset.x, y: bounds.minY + offset.y)
            context.cg.scaleBy(x: scale, y: scale)
            drawPill(title, maxWidth: maxWidth, in: context.cg)
            context.cg.restoreGState()
        }
    }

    /// In view points, with the shape's top-left corner at the origin.
    private func drawPill(_ title: String, maxWidth: CGFloat, in cg: CGContext) {
        let text = NSAttributedString(string: title, attributes: TitleStyle.attributes)
        let size = text.size(), height = TitleStyle.height, padding = TitleStyle.padding
        let pill = CGRect(x: 0, y: -TitleStyle.gap - height, width: min((size.width + padding * 2).rounded(.up), maxWidth), height: height)
        cg.addPath(CGPath(roundedRect: pill, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
        cg.setFillColor(TitleStyle.fill.cgColor)
        cg.fillPath()
        text.draw(with: CGRect(x: pill.minX + padding, y: pill.midY - size.height / 2, width: pill.width - padding * 2, height: size.height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
