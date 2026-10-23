import Adornments
import AppKit

/// A title's tab in its shape's colors (`titleTab`): filled with the shape's surface, a line of its edge
/// inside, and its words in the cover's inks, dark on a light surface and light on a dark one, chosen in
/// the appearance it's drawn in.
@MainActor
enum TitleTabStyle {
    /// Each surface's ink, kept with the surface, so a tab made again for the same surface is the same tint
    /// (Adornments keeps a tint's fills by the tint, and a dynamic color is equal to itself only).
    private static var inks: [ObjectIdentifier: (surface: NSColor, ink: NSColor)] = [:]
    /// The tints made, by their colors, for the same reason.
    private static var tints: [TintKey: AdornmentTint] = [:]

    private struct TintKey: Hashable {
        let surface: ObjectIdentifier
        let edge: ObjectIdentifier
    }

    /// A tab's tint for a look: solid in its surface, with its edge and an ink that reads on the surface.
    static func tint(_ look: TitleTabLook) -> AdornmentTint {
        let key = TintKey(surface: ObjectIdentifier(look.surface), edge: ObjectIdentifier(look.edge))
        if let known = tints[key] { return known }
        let tint = AdornmentTint(look.surface, ink: ink(on: look.surface), edge: look.edge, style: .solid)
        // A color picked by dragging asks for a surface a frame: let the lot go now and then.
        if tints.count >= 256 { tints.removeAll(keepingCapacity: true) }
        tints[key] = tint
        return tint
    }

    /// The ink that reads on a surface, as it resolves in the appearance drawn.
    static func ink(on surface: NSColor) -> NSColor {
        let id = ObjectIdentifier(surface)
        if let known = inks[id], known.surface === surface { return known.ink }
        let ink = inkProvider(on: surface, dark: TitleCoverStyle.darkInk, light: TitleCoverStyle.lightInk)
        if inks.count >= 256 { inks.removeAll(keepingCapacity: true) }
        inks[id] = (surface, ink)
        return ink
    }

    /// The dynamic color itself, made away from the main actor: AppKit may resolve it on any thread, so its
    /// provider reads only what it captured.
    nonisolated private static func inkProvider(on surface: NSColor, dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            var isLight = true
            appearance.performAsCurrentDrawingAppearance { isLight = TitleCoverStyle.isLight(surface) }
            return isLight ? dark : light
        }
    }
}
