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
    /// A marked end leaves its row straight along its way out for as far as the longest mark reaches (a bar and circle's, 30)
    /// and this much more, 36 whatever its own mark, a stub the curve starts from, so the mark lies level and upright however
    /// steeply the line turns after it (a C between stacked tables, a fan, rows far across), and keys between the same two
    /// shapes turn at the same places, their middles one shape: they cross only where their ends' order swaps, and then once
    /// (UX walk 4 tables-1; with a stub as long as each one's own mark, a bar's 23.5 inside a circle's 36, two keys in a narrow
    /// gap crossed twice). Ends facing each other too near for both stubs share what room there is.
    nonisolated static let levelMarkClearance: CGFloat = 6
    nonisolated static let levelMarkStub: CGFloat = 30 + levelMarkClearance
    nonisolated static func levelStub(ofMark reach: CGFloat) -> CGFloat {
        reach > 0 ? max(levelMarkStub, reach + levelMarkClearance) : 0
    }
    // Connections drawn together (Connections' `ConnectionBundle`): those with the same two ends bow apart by a slot each, far
    // enough that their pills sit on lines of their own; those fanned into one place come in at angles of their own, spread
    // `fanStep` apart up to `fanSpread` in all. Marked ends (keys' bars) fanned into one row come in level instead, `fanMarkSpacing`
    // apart along its side (a bar's height, its stroke and a gap, so two keys' bars never merge: UX walk 4 tables-2), each in a
    // slice of the row of its own at most (never on the line between two rows); in a row too short for that (the kit's, 24 tall),
    // each one's stub is `fanMarkStagger` longer than the next one's on the side its line turns away from (two steps at most), its marks with it, so they stand past its neighbors' and no bars or lines cross.
    nonisolated static let slotSpacing: CGFloat = 30
    nonisolated static let fanStep: CGFloat = 25 * .pi / 180
    nonisolated static let fanSpread: CGFloat = 70 * .pi / 180
    nonisolated static let fanMarkSpacing: CGFloat = 24
    nonisolated static let fanMarkStagger: CGFloat = 30
    nonisolated static let fanMarkStaggerLevels = 2
    /// Where there is no room to stagger, fanned marks' outermost ends stand this far in from the row's edges, never on the line
    /// between two rows: as far apart as a kit row (24 tall) holds two bars (18 tall, 2.5 stroke) with a gap between them, the line's
    /// own stroke inside the row (a bar is longer than the row is tall, so two never fit in it; they are apart, and the lines inside).
    nonisolated static let fanMarkEdge: CGFloat = 1.5
    /// Spread so, each place's marks stand this much further out than the one before, three columns round along its line: a bar's stroke and a gap, so two keys' bars
    /// into one row never stand in one column end to end, read as one long stroke (UX walk 5, tables-4-2's remainder).
    nonisolated static let fanMarkNudge: CGFloat = 6
    /// Connections parting from one row to different places (`ConnectionBundle.parting`) whose pills are slid to the row leave
    /// it `partingLineSpacing` apart along its side, top to bottom as their far ends are, within the row's band, so each line
    /// leaves on its own; their pills stack out from the row in that band, `partingLabelGap` apart, each on a straight stub of
    /// its line, which turns after it (UX walk 4 evolve-1: pills spaced along their lines landed beside other rows' pills).
    nonisolated static let partingLineSpacing: CGFloat = 20
    /// How far from the row's middle, as much of its height either way, a parted line may leave it: its inner band, so each line
    /// leaves well inside its own row (a kit row's 24: 6 either way), never near the line between two rows.
    nonisolated static let partingBand: CGFloat = 0.25
    nonisolated static let partingLabelGap: CGFloat = 8
    /// A pill of a parted connection laid along its line moves out along it, at least this much at a time and in at most
    /// `partingLabelSteps` (its cost is a bounded number of tests, however long the line), until it is clear of the lines of the
    /// connections parting beside it in their row's order (`partingNeighbors` either way: those further off are kept from it by those
    /// between) by `partingLineClearance`: its lit ring's reach, about 5 view points, in world units at the lowest zoom full drawing
    /// is shown at (0.35), so the ring clears them wherever it is drawn (UX walk 3 connect-4: a calls line ran under the reads pill's
    /// ring; review U12-E6).
    nonisolated static let partingLabelNudge: CGFloat = 6
    nonisolated static let partingLabelSteps = 30
    nonisolated static let partingNeighbors = 2
    nonisolated static let partingLineClearance: CGFloat = 14
    /// Where no place along the line has that room (lines running nearly side by side), the first with at least this much: clear of
    /// the pill itself, its ring perhaps touched.
    nonisolated static let partingLineLeastClearance: CGFloat = 6
    /// Rows facing each other across a gap narrower than this (between their stubs) have near upright middles: each line turns at
    /// a place of its own across it, `narrowTurnMargin` of the gap in from either side at most (`ArrowGeometry`).
    nonisolated static let narrowGap: CGFloat = 80
    nonisolated static let narrowTurnMargin: CGFloat = 0.1
    /// The least between two lines' turn columns in a run across a narrow gap: a stroke and a gap, so no two lie on each other.
    nonisolated static let narrowTurnSeparation: CGFloat = 5
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
