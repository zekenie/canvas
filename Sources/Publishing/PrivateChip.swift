import Adornments
import Canvas

/// A private shape's chip: the crossed eye alone, at the right end of the row above its top edge, next
/// to the lock's (both last, the lock first in plugin order, so nearest the end; this 4 points to its
/// left), as the lock is a lock alone: the shapes that wear it are the exception, every other shape
/// being public. A click makes the shape public; the chip then shows the eye open for a moment and
/// fades (Adornments' `ChipFade`, as the open lock does), and a click on that makes the shape private
/// again, unless something has come to stand for it: then nothing is written, the shape shakes, and
/// its panel shows what stands for it. Only on the kinds that hold the property (not an always-public
/// kind's, not a never-public kind's), and not on a shape drawn as a skeleton (no adornment is).
public enum PrivateChip {}

extension PrivateChip: Adornment {
    public static var placement: AdornmentPlacement { .aboveTopRight }
    /// A state that comes and goes, as a lock is: last, after the lock in plugin order.
    public static var order: Order<Self> { .last }
}

extension PrivateChip: ClickableAdornment {
    /// The chip is an eye alone: VoiceOver reads it as the state it shows.
    public static var partTitle: String { PublicStyle.privateWord }

    public static func click(_ click: AdornmentClick, in editor: CanvasEditor) { editor.publishing?.click(click.shape) }
}

/// The chip, on the kinds `scope` reaches: those that can be private.
@MainActor
func registerPrivateChip(into scope: inout ScopedRegistrar) {
    scope.adornment(PrivateChip.self) { shape, context in
        guard let state = context.service(PublishingState.self) else { return nil }
        return state.chip(of: shape)
    }
}

extension PublishingState {
    /// The chip a shape shows: the crossed eye while it's private; or, for a moment after it went
    /// public, the eye open, fading; else none.
    func chip(of shape: AnyShapeRecord) -> AdornmentLabel? {
        if shape[PrivateProperty.self] == true { return AdornmentLabel(systemImage: PublicStyle.privateSymbol) }
        guard let opacity = publicChipOpacity(of: shape.id) else { return nil }
        return AdornmentLabel(systemImage: PublicStyle.publicSymbol).opacity(opacity)
    }
}
