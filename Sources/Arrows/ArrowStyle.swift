import AppKit
import Connections
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
    /// A marked end leaves its row straight along its way out for as far as its mark reaches and this much more, a stub the
    /// curve starts from, so the mark lies level and upright however steeply the line turns after it (a C between stacked
    /// tables, a fan, rows far across): 23.5 for bars, 36 for a bar and circle, 19 for a crow's foot. Ends facing each other too
    /// near for both stubs share what room there is.
    nonisolated static let levelMarkClearance: CGFloat = 6
    nonisolated static func levelStub(ofMark reach: CGFloat) -> CGFloat {
        reach > 0 ? reach + levelMarkClearance : 0
    }
    // Connections drawn together (Connections' `ConnectionBundle`): those with the same two ends bow apart by a slot each, far
    // enough that their pills sit on lines of their own; those fanned into one place come in at angles of their own, spread
    // `fanStep` apart up to `fanSpread` in all, a marked end (a key's bars) also `fanMarkShift` apart along its side, so two keys
    // into one row meet it apart.
    nonisolated static let slotSpacing: CGFloat = 30
    nonisolated static let fanStep: CGFloat = 25 * .pi / 180
    nonisolated static let fanSpread: CGFloat = 70 * .pi / 180
    nonisolated static let fanMarkShift: CGFloat = 8
    /// Pills slid toward a row their connections part from to different places stand this far apart along their lines (a pill's
    /// width and a gap), world units.
    nonisolated static let partingLabelStep: CGFloat = 90
    /// A level curve's end keeps this far inside the container both its ends are in (a database's edge), where it can; and it
    /// leaves the side of its row with at least `containerSideRoom` inside it (its turn and half a pill on it), else the other.
    nonisolated static let containerClearance: CGFloat = PartSide.containerClearance
    nonisolated static let containerSideRoom: CGFloat = PartSide.containerSideRoom
    /// Arrows bowed apart by a slot also leave and meet their rows this far apart along the side, a slot each, within the row.
    nonisolated static let slotEndShift: CGFloat = 6

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
