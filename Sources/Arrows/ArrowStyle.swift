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

    // An arrow with an end at a row is a level curve (`ArrowGeometry.Path.level`): each end leaves along the way out of its
    // side, reaching this far before it turns, in world units: half the way to the other end when that is ahead, else
    // `levelBackReach` times the square root of how far behind it is (a C, not a wide loop), never under `levelMinReach`. The
    // frames' S-curves and React Flow's default edge.
    nonisolated static let levelMinReach: CGFloat = 24
    nonisolated static let levelAheadShare: CGFloat = 0.5
    nonisolated static let levelBackReach: CGFloat = 6.25
    /// A curve between ends carrying marks runs out far enough that its turn is clear of the longer mark by this much: a
    /// cubic with its controls `r` out bends back by `3/4 r` at the most, so the reach is the mark's, and this, over 3/4.
    nonisolated static let levelMarkClearance: CGFloat = 6
    nonisolated static func levelClearReach(ofMark reach: CGFloat) -> CGFloat {
        reach > 0 ? (reach + levelMarkClearance) / 0.75 : 0
    }
    /// How far from an arrow's centerline (beyond its stroke) a click still hits it, in view points.
    static let hitMargin: CGFloat = 3
    /// The bend handle hides when it's this close to an end handle, in view points.
    static let middleHandleMinDistance: CGFloat = 24
    /// The bend handle is left off when its point is within this many view points of the pill that leads the arrow's label.
    static let leadHandleClearance: CGFloat = 4

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

    // An arrow's parts, as ⌥Tab reaches them (`ArrowParts`).
    /// How wide a handle's part is, in view points: the handle as drawn (Selection's handle, 4 points across its middle), which the focus ring goes round.
    static let handlePartSize: CGFloat = 8
    /// What VoiceOver calls each.
    static let startPart = "Start"
    static let endPart = "End"
    static let bendPart = "Bend"
    static let labelPart = "Label"
    /// The Shape menu's items for each head.
    static let toggleStartHead = "Toggle Start Arrowhead"
    static let toggleEndHead = "Toggle End Arrowhead"
    /// A key's step that bends an arrow less than this (along it) bends it not at all, in world units.
    static let keyBendEpsilon: CGFloat = 0.001
    /// A label drawn within this of where it is kept, in world units, slides by the keys from where it is kept.
    static let labelKeySlack: CGFloat = 1

    /// Where an arrow runs, as VoiceOver says it after "Arrow": "from Checkout to Payment", "to Payment"; nil with
    /// neither end bound.
    static func accessibleRun(from start: String?, to end: String?) -> String? {
        let run = [start.map { "from \($0)" }, end.map { "to \($0)" }].compactMap { $0 }.joined(separator: " ")
        return run.isEmpty ? nil : run
    }
}
