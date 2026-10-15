import AppKit
import Palette

/// Arrow constants, in world units unless noted. The values follow tldraw.
@MainActor
enum ArrowStyle {
    static let color = NSColor(name: nil) {
        $0.isDark ? NSColor(white: 0.92, alpha: 1) : NSColor(white: 0.11, alpha: 1)
    }
    /// What an arrow is shown by: its row, its kind's label.
    static let symbol = "arrow.up.right"
    static let strokeWidth: CGFloat = 3.5
    /// How far from an arrow's centerline (beyond its stroke) a click still hits it, in view points.
    static let hitMargin: CGFloat = 3
    /// The bend handle hides when it's this close to an end handle, in view points.
    static let middleHandleMinDistance: CGFloat = 24

    /// Holding still this long while dragging an arrow end over a shape binds precisely to the
    /// pointer instead of the shape's center.
    static let pressPreciseDelay: Duration = .milliseconds(320)
    /// Entering a shape slower than this (view points per millisecond) binds precisely right away.
    static let slowPointerSpeed: CGFloat = 0.5

    // The dashed stub and marker drawn from a selected arrow's anchor to its visible end (view points).
    static let bindingHintColor = NSColor(name: nil) {
        $0.isDark ? NSColor(white: 0.98, alpha: 1) : .black
    }
    static let bindingHintOpacity: CGFloat = 0.16
    static let bindingHintWidth: CGFloat = 2
    static let bindingDotRadius: CGFloat = 4
    static let bindingCrossSize: CGFloat = 6
}
