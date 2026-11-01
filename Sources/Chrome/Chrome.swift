import AppKit
import Palette
import SwiftUI

/// The look every surface around the board shares, so that the panes and what floats over the board
/// read as one kind of thing: the two panes (the sidebar and the inspector, sheets flush to the
/// window's edges and full height, one tone, a hairline and a shade where they meet the board), what
/// floats over the board (the minimap, the zoom, the board path, Jump To, crumb menus, the caret list,
/// cards and popovers: one corner and one shadow), and what both hold (a header, rows, tabs, fields).
/// A module's own style enum reads these, and keeps only what is its own.
@MainActor
public enum ChromeStyle {
    // MARK: Surfaces

    /// The panes' surface, and that of what floats over the board for the window (the minimap's
    /// frame, the zoom, the board path, Jump To, crumb menus): one tone the board never wears (its
    /// canvas is #1C1C1C dark and #F6F6F6 light, a frame #262626 and white), so a sheet over the board
    /// never reads as a part of it.
    public static let surface = NSColor(name: nil) {
        $0.isDark ? NSColor(white: 0.184, alpha: 1) : NSColor(white: 0.922, alpha: 1)
    }

    /// The line where a sheet meets the board, under a pane's header, and round what floats.
    public static let hairline = NSColor(name: nil) {
        $0.isDark ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.1)
    }
    public static let hairlineWidth: CGFloat = 1

    /// The shade a sheet lays on the board along its inner edge, so the board reads as going on under
    /// it: how far it reaches, and how dark it is at the edge, fading to nothing.
    public static let shadeWidth: CGFloat = 12
    public static let shade = NSColor(name: nil) {
        $0.isDark ? NSColor(white: 0, alpha: 0.32) : NSColor(white: 0, alpha: 0.1)
    }

    /// What floats over the board casts this: how far down, how blurred, and how dark; and how far
    /// below a float its shadow shows (its offset and the part of its blur that draws anything), what
    /// a float that says how far it covers counts (the board path's pill).
    public static let floatShadowY: CGFloat = 3
    public static let floatShadowBlur: CGFloat = 10
    public static let floatShadowReach: CGFloat = 6
    public static let floatShadow = NSColor(name: nil) {
        $0.isDark ? NSColor(white: 0, alpha: 0.45) : NSColor(white: 0, alpha: 0.14)
    }

    /// The fill of the one chosen among items (a pane's tab, a row while its list hasn't the
    /// keyboard: with it, a row is the accent), and of an item under the pointer.
    public static let selectedFill = NSColor.unemphasizedSelectedContentBackgroundColor
    public static let hoverFill = NSColor(name: nil) {
        $0.isDark ? NSColor(white: 1, alpha: 0.05) : NSColor(white: 0, alpha: 0.05)
    }

    // MARK: Corners

    /// One rule gives every corner. An item (a row, a tab, a field, a button, a crumb) is rounded
    /// `itemCorner`; what floats holds its items `itemCorner` in, so it is rounded `floatCorner`, or
    /// half its height where that is less (a capsule, `floatCorner(height:)`); a sheet is square, and
    /// its one curve is the window's own corner.
    public static let itemCorner: CGFloat = 6
    public static let floatCorner: CGFloat = 12
    public static func floatCorner(height: CGFloat) -> CGFloat { min(floatCorner, height / 2) }

    // MARK: Panes

    /// A pane's header, the same in both: its height, how far in its content starts from the sheet's
    /// edges, the column its symbol is centered in, its symbol's size and its title's.
    public static let headerHeight: CGFloat = 44
    public static let headerInset: CGFloat = 16
    public static let headerSymbolWidth: CGFloat = 20
    public static let headerSymbol = Font.system(size: 15)
    public static let headerTitle = Font.system(size: 13, weight: .semibold)
    /// `headerTitle`, for a title AppKit draws (the inspector's field).
    public static var headerTitleFont: NSFont { .systemFont(ofSize: 13, weight: .semibold) }
    /// Between a header's back or up button, its symbol and its title.
    public static let headerSpacing: CGFloat = 6

    /// How far in from a pane's sides a row's highlight starts and ends.
    public static let rowHighlightInset: CGFloat = 8

    /// A pane comes in over the board from its edge and goes back out: how long that takes, and, with
    /// Reduce Motion on, how long it fades in or out in place instead.
    public static let paneIn = 0.2
    public static let paneFade = 0.15

    /// A pane's inner edge, which a drag resizes it by: how wide the strip that takes the press is,
    /// centered on the hairline.
    public static let resizeGrip: CGFloat = 6
}

extension View {
    /// This, set on the chrome's surface as what floats over the board for the window is (the board
    /// path, Jump To, a crumb's menu): filled in `ChromeStyle.surface` within `shape`, a hairline round
    /// it, and the float's shadow.
    public func floatingSurface<S: InsettableShape>(in shape: S) -> some View {
        background {
            shape.fill(Color(nsColor: ChromeStyle.surface))
                .shadow(color: Color(nsColor: ChromeStyle.floatShadow), radius: ChromeStyle.floatShadowBlur / 2, y: ChromeStyle.floatShadowY)
        }
        .overlay(shape.strokeBorder(Color(nsColor: ChromeStyle.hairline), lineWidth: ChromeStyle.hairlineWidth))
    }
}
