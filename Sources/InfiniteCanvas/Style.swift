import AppKit

@MainActor
enum Style {
    static let canvasBackground = NSColor(name: nil) {
        $0.isDark ? NSColor(white: 0.11, alpha: 1) : NSColor(white: 0.965, alpha: 1)
    }
    static let gridDot = NSColor(name: nil) {
        $0.isDark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.16)
    }
    /// World-space distance between grid dots at 100% zoom.
    static let gridSpacing: CGFloat = 24
    /// Grid dots never get closer than this on screen; the grid coarsens instead.
    static let minGridSpacingOnScreen: CGFloat = 16
    static let gridDotDiameter: CGFloat = 2

    static let noteSize = CGSize(width: 200, height: 200)
    static let noteCornerRadius: CGFloat = 4
    static let notePadding: CGFloat = 16
    static let noteColor = NSColor(srgbRed: 1.0, green: 0.87, blue: 0.45, alpha: 1)

    static let ellipseSize = CGSize(width: 200, height: 140)
    static let ellipseColor = NSColor(srgbRed: 0.62, green: 0.81, blue: 1.0, alpha: 1)

    static let shapeShadow = NSColor(white: 0, alpha: 0.25)

    // Arrows, in world units.
    static let arrowColor = NSColor(name: nil) {
        $0.isDark ? NSColor(white: 0.92, alpha: 1) : NSColor(white: 0.11, alpha: 1)
    }
    static let arrowStrokeWidth: CGFloat = 3.5

    // Interaction and overlays, in view points unless noted. The values follow tldraw.
    static let accent = NSColor.controlAccentColor
    static let accentFill = NSColor(name: nil) {
        NSColor.controlAccentColor.withAlphaComponent($0.isDark ? 0.2 : 0.24)
    }
    static let indicatorWidth: CGFloat = 1.5
    static let dragThreshold: CGFloat = 4
    /// How far from an arrow's centerline (beyond its stroke) a click still hits it.
    static let arrowHitMargin: CGFloat = 3
    static let handleRadius: CGFloat = 4
    /// Also the radius of the hover halo around a handle.
    static let handleHitRadius: CGFloat = 12
    /// The bend handle hides when it's this close to an end handle.
    static let middleHandleMinDistance: CGFloat = 24

    /// Hovering one shape this long with the arrow tool makes the next arrow start precisely there.
    static let hoverPreciseDelay: Duration = .milliseconds(600)
    /// Holding still this long after pressing, or while dragging an arrow end over a shape, binds
    /// precisely to the pointer instead of the shape's center.
    static let pressPreciseDelay: Duration = .milliseconds(320)
    /// Entering a shape slower than this (view points per millisecond) binds precisely right away.
    static let slowPointerSpeed: CGFloat = 0.5
    /// Releasing a modifier takes effect this much later, so letting go of ⌥ and the mouse
    /// together doesn't undo what ⌥ did.
    static let modifierReleaseDelay: Duration = .milliseconds(150)

    // The dashed stub and marker drawn from a selected arrow's anchor to its visible end.
    static let bindingHintColor = NSColor(name: nil) {
        $0.isDark ? NSColor(white: 0.98, alpha: 1) : .black
    }
    static let bindingHintOpacity: CGFloat = 0.16
    static let bindingHintWidth: CGFloat = 2
    static let bindingDotRadius: CGFloat = 4
    static let bindingCrossSize: CGFloat = 6

    /// Shared by the canvas renderer and the note editor so text doesn't shift when editing starts.
    static let noteTextAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 16),
        .foregroundColor: NSColor(white: 0.12, alpha: 1),
    ]
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
