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
    /// Bringing shapes into view (`reveal`), as selecting a row of data-canvas's table of contents
    /// does (its zoom config, and tldraw's zoomToBounds): 100 points of margin in all, no closer
    /// than 120%, over 200 ms.
    static let revealInset: CGFloat = 100
    static let revealMaxZoom: CGFloat = 1.2
    static let revealDuration: Duration = .milliseconds(200)
    /// Going to shapes (`goTo`) leaves the camera where it is when they're all in view at this zoom
    /// or closer. Text on the canvas is set for 100%, a note's at 16 points: at 70% that's 11.2
    /// points on screen, just over the 11 of `NSFont.smallSystemFontSize`, the smallest size macOS
    /// sets text to be read at. Further out the shapes are there but can't be read, so going to them
    /// brings them closer.
    static let readableZoom: CGFloat = 0.7
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
