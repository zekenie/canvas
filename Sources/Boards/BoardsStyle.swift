import CoreGraphics

/// The path's constants, in points (data-canvas's crumb row).
@MainActor
enum BoardsStyle {
    /// From the canvas's top edge to the pill.
    static let topInset: CGFloat = 8
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 6
    static let spacing: CGFloat = 4
    static let fontSize: CGFloat = 12
    static let crumbMaxWidth: CGFloat = 180
    static let maxWidth: CGFloat = 640
    /// The root's crumb when the host names it nothing.
    static let rootFallback = "Board"
}
