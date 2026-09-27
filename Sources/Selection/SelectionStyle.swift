import AppKit

/// The selection's UI constants. Sizes are view points. The values follow tldraw.
@MainActor
enum SelectionStyle {
    static let accent = NSColor.controlAccentColor
    /// The halo around a hovered or pressed handle.
    static let accentFill = NSColor(name: nil) {
        NSColor.controlAccentColor.withAlphaComponent($0.isDark ? 0.2 : 0.24)
    }
    static let handleStrokeWidth: CGFloat = 1.5
    static let handleRadius: CGFloat = 4
    /// Also the radius of the halo.
    static let handleHitRadius: CGFloat = 12
    /// Below this zoom the handles shrink with the shapes.
    static let handleFullSizeZoom: CGFloat = 0.25
    /// The marquee: tldraw's hsl(0, 0%, 56%), in light and dark alike.
    static let brushFill = NSColor(srgbRed: 0.56, green: 0.56, blue: 0.56, alpha: 0.102)
    static let brushStroke = NSColor(srgbRed: 0.56, green: 0.56, blue: 0.56, alpha: 0.251)
    static let brushStrokeWidth: CGFloat = 1
    /// Going back moves the camera this long (data-canvas's).
    static let goBackDuration: Duration = .milliseconds(200)
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
