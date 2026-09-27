import AppKit

/// The core's UI constants. Sizes are view points unless noted.
@MainActor
public enum Style {
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

    static let shapeShadow = NSColor(white: 0, alpha: 0.25)

    // Interaction and overlays. The values follow tldraw.
    static let accent = NSColor.controlAccentColor
    static let accentFill = NSColor(name: nil) {
        NSColor.controlAccentColor.withAlphaComponent($0.isDark ? 0.2 : 0.24)
    }
    static let indicatorWidth: CGFloat = 1.5
    public static let dragThreshold: CGFloat = 4
    /// The select tool's marquee: tldraw's hsl(0, 0%, 56%), in light and dark alike.
    static let brushFill = NSColor(srgbRed: 0.56, green: 0.56, blue: 0.56, alpha: 0.102)
    static let brushStroke = NSColor(srgbRed: 0.56, green: 0.56, blue: 0.56, alpha: 0.251)
    static let handleRadius: CGFloat = 4
    /// Also the radius of the hover halo around a handle.
    static let handleHitRadius: CGFloat = 12

    /// Releasing a modifier takes effect this much later, so letting go of it and the mouse
    /// together doesn't undo what it did.
    static let modifierReleaseDelay: Duration = .milliseconds(150)

    // The camera's slide after a flung hand drag (tldraw's slideCamera). Speeds are view points
    // per millisecond.
    /// A release slower than this doesn't slide.
    static let cameraSlideMinSpeed: CGFloat = 0.1
    /// Release speeds are clamped to this (the slide itself starts at no more than 1).
    static let cameraSlideMaxSpeed: CGFloat = 2
    /// The speed lost every frame.
    static let cameraSlideFriction: CGFloat = 0.09
    /// The slide stops once its speed would drop under this.
    static let cameraSlideStopSpeed: CGFloat = 0.01
    /// A slide frame's length.
    static let cameraSlideFrameMilliseconds: CGFloat = 16
    static var cameraSlideFrame: Duration { .milliseconds(Int(cameraSlideFrameMilliseconds)) }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
