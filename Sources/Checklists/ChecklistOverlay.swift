import AppKit
import Canvas

@MainActor
enum ChecklistStyle {
    // View points.
    static let height: CGFloat = 16
    static let padding: CGFloat = 5
    /// How far the chip reaches past the shape's right edge; it's centered on the top edge.
    static let overhang: CGFloat = 6
    /// Below this zoom the chip shrinks with the shapes, as the selection's handles do.
    static let fullSizeZoom: CGFloat = 0.25
    /// No chip is this wide (in view points), so a shape farther than this outside the view has no
    /// chip in it.
    static let reach: CGFloat = 200
    static let fill = NSColor(white: 0.25, alpha: 0.9)
    static let doneFill = NSColor.systemGreen
    static let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
        .foregroundColor: NSColor.white,
    ]
}

/// A "☑ 2/5" chip on the top-right corner of every shape whose kind opted in with the badge on.
/// Shapes never know about it, and an empty checklist draws nothing.
struct ChecklistOverlay: CanvasOverlay {
    var space: OverlaySpace { .world }

    func draw(in context: OverlayContext) {
        let registry = context.editor.registry
        // The kinds whose checklist shows the chip, found once per kind rather than per shape.
        var badged: Set<ShapeKind> = []
        for kind in registry.kinds where registry.contributions(to: ShapeChecklists.self, for: kind).first?.showsBadge == true {
            badged.insert(kind)
        }
        guard !badged.isEmpty else { return }
        // From the shape's top-right corner on, in view points (fewer when zoomed far out).
        let scale = min(1, context.zoom / ChecklistStyle.fullSizeZoom) / context.zoom
        let reach = ChecklistStyle.reach * scale
        // In paint order, so overlapping chips stack as their shapes do.
        for record in context.editor.paintOrder(in: context.visibleRect.insetBy(dx: -reach, dy: -reach)) {
            guard badged.contains(record.kind), let items = record[ChecklistProperty.self], !items.isEmpty,
                  let bounds = context.shapes.geometry(of: record.id)?.bounds else { continue }
            context.cg.saveGState()
            context.cg.translateBy(x: bounds.maxX, y: bounds.minY)
            context.cg.scaleBy(x: scale, y: scale)
            drawChip(for: items, in: context.cg)
            context.cg.restoreGState()
        }
    }

    private func drawChip(for items: [ChecklistItem], in cg: CGContext) {
        let done = items.doneCount
        let text = NSAttributedString(string: "☑ \(items.tally ?? "")", attributes: ChecklistStyle.attributes)
        let size = text.size(), height = ChecklistStyle.height
        let width = (size.width + ChecklistStyle.padding * 2).rounded(.up)
        let chip = CGRect(x: ChecklistStyle.overhang - width, y: -height / 2, width: width, height: height)
        cg.addPath(CGPath(roundedRect: chip, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
        cg.setFillColor((done == items.count ? ChecklistStyle.doneFill : ChecklistStyle.fill).cgColor)
        cg.fillPath()
        text.draw(at: CGPoint(x: chip.minX + ChecklistStyle.padding, y: chip.midY - size.height / 2))
    }
}
