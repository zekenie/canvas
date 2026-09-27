import AppKit
import Canvas
import Selection

@MainActor
enum LockStyle {
    // View points.
    /// The chip's diameter: a title's pill's height, as it shares the pill's row.
    static let size: CGFloat = 18
    /// Between the chip and the shape's top edge, as a title's pill has: clear of a badge centered on
    /// the edge (the checklist chip, on the top-right corner). Locking can't see either;
    /// CompositionTests, which ships all three, holds them apart.
    static let gap: CGFloat = 9
    /// How far past its edge a click still clicks the chip.
    static let hitMargin: CGFloat = 3
    /// Below this zoom the chip shrinks with the shapes, as a title's pill does.
    static let fullSizeZoom: CGFloat = 0.25
    static let fill = NSColor(white: 0.25, alpha: 0.9)
    static let hoverFill = NSColor(white: 0.4, alpha: 0.9)
    static let pressedFill = NSColor(white: 0.1, alpha: 0.9)
    static let glyph = symbol("lock.fill", "Locked")
    static let openGlyph = symbol("lock.open.fill", "Unlocked")

    private static func symbol(_ name: String, _ description: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        return NSImage(systemSymbolName: name, accessibilityDescription: description)?.withSymbolConfiguration(configuration)
    }

    /// World units per chip point at `zoom`: a chip keeps its size on screen, but below
    /// `fullSizeZoom` shrinks with the shapes.
    static func scale(zoom: CGFloat) -> CGFloat { min(1, zoom / fullSizeZoom) / zoom }

    /// A shape's chip, in world units, from its bounds: a disc ending at its right edge, `gap` above
    /// its top.
    static func chip(above bounds: CGRect, scale: CGFloat) -> CGRect {
        CGRect(x: bounds.maxX - size * scale, y: bounds.minY - (gap + size) * scale, width: size * scale, height: size * scale)
    }

    // Once a shape is unlocked (its chip clicked, or from the menu), its lock shows open this long, so
    // that a click by mistake can be taken back by another; longer while the pointer's on it; then it
    // fades.
    static let openLinger: Duration = .milliseconds(1500)
    static let openFade: Duration = .milliseconds(300)
    /// While the pointer's on an open lock that's had its time, how often to see if it's gone.
    static let openHoverRecheck: Duration = .milliseconds(500)

    // The shake a locked shape gives when something tries to change it, like a password field's.
    /// The farthest it goes to either side, in view points.
    static let shakeAmplitude: CGFloat = 5
    /// How many times it goes right and left.
    static let shakeCycles: Double = 3
    static let shakeDuration: Duration = .milliseconds(360)
    /// A frame of a shake or a fade.
    static let frame: Duration = .milliseconds(16)
}

/// A lock chip just above the top-right corner of every locked shape, in the row a title's pill
/// starts at the other end of, and an open one, for a moment, on a shape just unlocked. It's a
/// button the select tool clicks (`LockChip`), drawn lighter hovered and darker pressed. It goes
/// where its shape is drawn (`editor.setDrawingOffset`), so it shakes with it. Shapes never know
/// about it.
struct LockOverlay: CanvasOverlay {
    var space: OverlaySpace { .world }

    func draw(in context: OverlayContext) {
        guard let state = context.editor.service(LockState.self), state.hasChips else { return }
        let scale = LockStyle.scale(zoom: context.zoom)
        // The chip is above its shape, so a shape just below the view may have its chip in it.
        let visible = context.visibleRect
        let reach = (LockStyle.gap + LockStyle.size) * scale
        let area = CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: visible.height + reach)
        let hovered = context.editor.hoveredButton, pressed = context.editor.pressedButton
        // In paint order, so overlapping chips stack as their shapes do.
        for record in context.editor.paintOrder(in: area) {
            let isLocked = state.lockedIDs.contains(record.id)
            guard isLocked || state.opened[record.id] != nil,
                  let bounds = context.shapes.geometry(of: record.id)?.bounds, !bounds.isNull else { continue }
            let offset = context.worldDrawingOffset(of: record.id)
            let chip = LockStyle.chip(above: bounds.offsetBy(dx: offset.x, dy: offset.y), scale: scale)
            let button = AnyHashable(LockChip(shape: record.id))
            let fill = pressed == button ? LockStyle.pressedFill : hovered == button ? LockStyle.hoverFill : LockStyle.fill
            draw(chip, isLocked: isLocked, fill: fill, opacity: state.opacity(of: record.id), in: context.cg)
        }
    }

    /// A disc with the lock, closed or open, in its middle, at its size in view points (`chip` is in
    /// world units).
    private func draw(_ chip: CGRect, isLocked: Bool, fill: NSColor, opacity: CGFloat, in cg: CGContext) {
        cg.saveGState()
        defer { cg.restoreGState() }
        if opacity < 1 {
            cg.setAlpha(opacity)
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        cg.setFillColor(fill.cgColor)
        cg.fillEllipse(in: chip)
        if let glyph = isLocked ? LockStyle.glyph : LockStyle.openGlyph {
            // The glyph is sized in view points; the chip, in world units.
            let scale = chip.width / LockStyle.size, size = glyph.size
            let rect = CGRect(x: chip.midX - size.width * scale / 2, y: chip.midY - size.height * scale / 2,
                              width: size.width * scale, height: size.height * scale)
            glyph.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if opacity < 1 { cg.endTransparencyLayer() }
    }
}
