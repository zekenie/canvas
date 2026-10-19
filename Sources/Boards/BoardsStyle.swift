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
    /// What the root is called when the host names it nothing (`editor.rootName`): its crumb, and
    /// wherever else it's named.
    static let rootFallback = "Board"
    /// What going up is called in the table of contents' heading, as the Go menu calls it when there is
    /// no group or container to step out of first. The Go item (`.enclosingBoard`) is named for the
    /// step it takes: Enclosing Group, or "Enclosing " and what the container's kind is called.
    static let enclosingBoard = "Enclosing Board"
    static let enclosingGroup = "Enclosing Group"
    static let enclosing = "Enclosing "
    /// The lock after the name of the crumb where the read-only part of the path starts: its symbol,
    /// how far it is from the name, and what it's called (its tooltip, and to assistive apps).
    static let readOnlySymbol = "lock.fill"
    static let readOnlySpacing: CGFloat = 3
    static let readOnlyLabel = "Read-only"
    /// How long the pointer stays on a crumb before its menu shows, and off it and its menu before
    /// the menu closes (data-canvas's hover intent).
    static let menuDelay: Duration = .milliseconds(150)
    /// A menu: from its crumb's bottom edge to its top, lined up with the crumb's leading edge; its
    /// width, and how tall it grows before it scrolls; around its rows; its corners; and how near the
    /// canvas's edges it may come.
    static let menuGap: CGFloat = 6
    /// AppKit's padding above an `NSMenu`'s first item, which `popUp(positioning: nil, at:in:)` puts
    /// at the point it's given (measured: macOS 26), so the fold's menu (`BoardPath.foldedMenu`) is
    /// placed that much lower to start where a crumb's does.
    static let systemMenuTopPadding: CGFloat = 5
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
