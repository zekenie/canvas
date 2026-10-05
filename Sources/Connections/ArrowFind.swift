import AppKit
import Canvas
import Find
import TextEditing

extension PluginID {
    public static let arrowFind: PluginID = "arrow-find"
}

/// Arrows' labels, for Find: the label's text as it reads, washed where the label draws it (over
/// the canvas, whose color follows the appearance), from the label's own layout: string drawing's,
/// centered in its frame, kept by text and width (`ArrowLabels.layout(of:width:)`). A plugin value
/// of its own, after Find and Arrows, so a list without Find leaves it out.
public struct ArrowFindPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .arrowFind }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.findableTexts("label", of: Arrow.self, look: .wash,
                                texts: { arrow, _ in arrow.props.hasText ? [FindableText(field: "label", text: arrow.props.text)] : [] },
                                rects: { arrow, _, ranges, context in ArrowLabels.rects(of: ranges, in: arrow, shapes: context.editor.shapeContext) })
    }
}

extension ArrowLabels {
    /// Where each range (UTF-16) of an arrow's label is drawn, a rect a line, from the arrow's
    /// bounds' top-left: in its frame (its geometry's `label`), its padding in, as `drawText` draws it.
    static func rects(of ranges: [Range<Int>], in arrow: ShapeRecord<Arrow>, shapes: ShapeContext) -> [[CGRect]] {
        guard let geometry = shapes.geometry(of: arrow.id), let frame = geometry.label, !geometry.bounds.isNull else { return ranges.map { _ in [] } }
        let box = frame.insetBy(dx: ArrowStyle.labelPadding, dy: ArrowStyle.labelPadding)
        let found = layout(of: arrow.props.text, width: box.width).lineRects(of: ranges.map { NSRange(location: $0.lowerBound, length: $0.count) },
                                                                            height: box.height)
        let dx = box.minX - geometry.bounds.minX, dy = box.minY - geometry.bounds.minY
        return found.map { rects in rects.map { $0.offsetBy(dx: dx, dy: dy) } }
    }

    /// A label's text laid out as `drawText` draws it, `width` wide: kept by text and width, as its
    /// measures are, the last `kept` of them.
    static func layout(of text: String, width: CGFloat) -> StringDrawingLayout {
        let key = LayoutKey(text: text, width: width)
        if let known = layouts[key] { return known }
        let made = StringDrawingLayout(NSAttributedString(string: text, attributes: ArrowStyle.labelAttributes), width: width)
        if layouts.count >= keptLayouts { layouts.removeAll(keepingCapacity: true) }
        layouts[key] = made
        return made
    }

    /// How many layouts are kept: past it, they're all let go (each is laid out again when asked).
    static let keptLayouts = 256

    private struct LayoutKey: Hashable {
        let text: String
        let width: CGFloat
    }

    private static var layouts: [LayoutKey: StringDrawingLayout] = [:]
}
