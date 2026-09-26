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
    static let noteShadow = NSColor(white: 0, alpha: 0.25)

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
