import AppKit
import Canvas
import Selection

/// The leading symbol's hover and pressed looks (`GoButton`, a canvas button Selection presses and
/// clicks): while the pointer is on it, its disc is the accent's, an arrow going up and out, a step
/// darker while it's pressed. It draws only for the one button hovered or pressed, so it costs
/// nothing otherwise.
@MainActor
struct ReferenceButtonOverlay: CanvasOverlay {
    var space: OverlaySpace { .world }

    func draw(in context: OverlayContext) {
        let editor = context.editor
        let pressed = editor.pressedButton as? GoButton
        guard let button = pressed ?? (editor.hoveredButton as? GoButton), let record = context.shapes.shape(button.reference),
              let reference = record.typed(as: Reference.self), !context.drawsSkeleton(of: button.reference) else { return }
        let offset = context.worldDrawingOffset(of: button.reference)
        let box = CGRect(x: reference.frame.minX + ReferenceStyle.leadingPad + offset.x,
                         y: reference.frame.midY - ReferenceStyle.symbolBox / 2 + offset.y,
                         width: ReferenceStyle.symbolBox, height: ReferenceStyle.symbolBox)
        // The arrow is the symbol's first layer, white; the disc its second, the accent: one color
        // alone fills both and the arrow is lost.
        let cg = context.cg
        cg.setFillColor(ReferenceStyle.fill.cgColor)
        cg.fillEllipse(in: box)
        let color = pressed != nil ? ReferenceStyle.goPressedColor : ReferenceStyle.goColor
        let configuration = NSImage.SymbolConfiguration(pointSize: ReferenceStyle.symbolBox, weight: ReferenceStyle.symbolWeight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, color]))
        guard let image = NSImage(systemSymbolName: ReferenceStyle.goSymbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        let size = image.size
        let rect = CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}
