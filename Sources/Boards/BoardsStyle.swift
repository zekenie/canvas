import CoreGraphics

/// The path's constants, in points (data-canvas's crumb row and its menus).
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
    /// The caret after the title of a crumb with a menu, and between them.
    static let caretSize: CGFloat = 8
    static let caretSpacing: CGFloat = 3
    /// How long the pointer stays on a crumb before its menu shows, and off it and its menu before
    /// the menu closes (data-canvas's hover intent).
    static let menuDelay: Duration = .milliseconds(150)
    /// A menu: from its crumb's bottom edge to its top, lined up with the crumb's leading edge; its
    /// width, and how tall it grows before it scrolls; around its rows; its corners; and how near the
    /// canvas's edges it may come.
    static let menuGap: CGFloat = 6
    static let menuWidth: CGFloat = 300
    static let menuMaxHeight: CGFloat = 360
    static let menuPadding: CGFloat = 6
    static let menuRadius: CGFloat = 8
    static let menuMargin: CGFloat = 8
    /// Its shadow, as data-canvas's: 18 points of blur, 6 down, at 14%.
    static let menuShadowRadius: CGFloat = 9
    static let menuShadowY: CGFloat = 6
    static let menuShadowOpacity: Double = 0.14
}
