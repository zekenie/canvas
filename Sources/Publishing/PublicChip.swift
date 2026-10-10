import Adornments
import Canvas

/// A public shape's chip: "Public" with a globe, after "·" and how many things stand for the shape
/// once any do ("Public · 3"), at the right end of the row above its top edge, next to the lock's
/// (the lock, order 300, is nearest the end; this is order 310, 4 points to its left). A click
/// makes the shape private, unless something stands for it: then nothing is written, the shape
/// shakes, and its panel shows what stands for it. The chip then reads "Private" for a moment and
/// fades (Adornments' `ChipFade`, as the open lock does), and a click on it makes the shape public
/// again. Where the title's pill would lose room to it, it takes a compact face: the globe alone, or
/// the count with the globe; every face's globe is full white (`brightSymbol()`). Only on the kinds
/// that hold the property (not an always-public kind's, not a never-public kind's), and not on a
/// shape drawn as a skeleton (no adornment is).
public enum PublicChip {}

extension PublicChip: Adornment {
    public static var placement: AdornmentPlacement { .aboveTopRight }
    public static var order: Int { 310 }
}

extension PublicChip: ClickableAdornment {
    public static func click(_ click: AdornmentClick, in editor: CanvasEditor) { editor.publishing?.click(click.shape) }
}

@MainActor
func registerPublicChip(into registrar: inout PluginRegistrar) {
    registrar.adornmentForEveryShape(PublicChip.self, where: { $0.holds(PublicProperty.self) }) { shape, context in
        guard let state = context.service(PublishingState.self) else { return nil }
        return state.chip(of: shape)
    }
}

extension PublishingState {
    /// The chip a shape shows: public, how many things stand for it; or, for a moment after it went
    /// private, "Private", fading; else none.
    func chip(of shape: AnyShapeRecord) -> AdornmentLabel? {
        if shape[PublicProperty.self] == true {
            let count = count(for: shape.id)
            return AdornmentLabel(PublicStyle.face(references: count), systemImage: PublicStyle.symbol).brightSymbol()
                .compact((count > 0 ? AdornmentLabel(String(count), systemImage: PublicStyle.symbol) : AdornmentLabel(systemImage: PublicStyle.symbol)).brightSymbol())
        }
        guard let opacity = privateChipOpacity(of: shape.id) else { return nil }
        return AdornmentLabel(PublicStyle.privateWord, systemImage: PublicStyle.symbol).brightSymbol()
            .compact(AdornmentLabel(systemImage: PublicStyle.symbol).brightSymbol())
            .opacity(opacity)
    }
}
