import AppKit
import TextEditing

/// Jump To's constants: the palette's size and place, what its list shows, and how its catalog is
/// built. Points, and the same at any zoom.
@MainActor
enum JumpToStyle {
    // MARK: The palette

    /// The capsule's width, which its list is as wide as, and its height.
    static let width: CGFloat = 560
    static let fieldHeight: CGFloat = 40
    /// Between the capsule's edge and the text.
    static let horizontalPadding: CGFloat = 16
    static let fieldFont = NSFont.systemFont(ofSize: 16)
    /// From the part of the canvas the host leaves clear (below the path over a subboard) to the
    /// capsule: fixed once the palette opens.
    static let topOffset: CGFloat = 12
    /// The capsule's shadow, as the path's menus have: soft, a little below.
    static let shadowRadius: CGFloat = 9
    static let shadowY: CGFloat = 4
    static let shadowOpacity: Double = 0.14
    static let placeholder = "Jump To"
    /// What VoiceOver calls the palette's field and its list.
    static let accessibilityLabel = "Jump To"

    // MARK: The list

    static let rowHeight: CGFloat = 28
    static let rowsShown = 10
    /// Between the capsule and its list.
    static let listOffset: CGFloat = 6
    static let metrics = CaretListMetrics(width: width, rowHeight: rowHeight, rowsShown: rowsShown, offset: listOffset)
    /// A path's names are separated by this.
    nonisolated static let separator = " › "
    static let recentHeader = "Recent"
    static let nearbyHeader = "Nearby"
    static let noMatches = "No matches"
    static let nothingToJumpTo = "Nothing to jump to"

    // MARK: What it lists

    /// What an empty query lists: this many recent picks, then this many shapes in view nearest its
    /// center.
    static let recentShown = 5
    static let nearbyShown = 5
    /// The picks kept: those shown, and a tie-break for the rest.
    static let recentKept = 20
    /// The most rows a query lists.
    static let maxRows = 50
    /// Where Nearby looks for the shapes nearest the view's center: a square this far out, then four
    /// times as far, up to this many times or the whole view.
    static let nearbySearch: CGFloat = 400
    static let nearbySearchSteps = 5

    // MARK: The catalog

    /// How long one slice of building the catalog may take, on the main actor: the clock is read
    /// every `clockStride` shapes.
    static let buildSlice: Duration = .milliseconds(2)
    static let clockStride = 16
    /// The deepest a path is followed: a file whose boards hold each other's has no end.
    static let deepest = 64
}
