import CoreGraphics
import Snapping
import TestKit

/// A space between two edges, as a spacing guide shows it.
func gap(_ start: CGFloat, _ startSpan: ClosedRange<CGFloat>, _ end: CGFloat, _ endSpan: ClosedRange<CGFloat>) -> SnapGap {
    SnapGap(start: start, startSpan: startSpan, end: end, endSpan: endSpan)
}

// `SnapTargets`, pure: a rect moved by a delta, snapped to frames within 8 world units, and the guides
// for what lines up where it ends up. The rects that shouldn't snap along the other axis keep every
// edge and their middle more than 8 away from every frame's.
@MainActor let targetsTests = Suite("Snap targets", [
    test("an edge within the threshold snaps onto another frame's, landing on it, and the other axis is left as it came") {
        let targets = SnapTargets([CGRect(x: 200, y: 0, width: 100, height: 100)])
        let rect = CGRect(x: 0, y: 300, width: 50, height: 50)
        // The right edge 3 short of the frame's left edge.
        let snap = targets.snap(rect, movedBy: CGPoint(x: 147, y: 1), within: 8)
        expectEqual(snap.delta, CGPoint(x: 150, y: 1))
        expectEqual(snap.guides, [.alignment(.x, at: 200, points: [CGPoint(x: 200, y: 0), CGPoint(x: 200, y: 100),
                                                                     CGPoint(x: 200, y: 301), CGPoint(x: 200, y: 351)])])
        expectEqual(targets.snap(rect, movedBy: CGPoint(x: 142, y: 1), within: 8).delta, CGPoint(x: 150, y: 1), "8 away snaps")
        let beyond = targets.snap(rect, movedBy: CGPoint(x: 141.5, y: 1), within: 8)
        expectEqual(beyond.delta, CGPoint(x: 141.5, y: 1), "8.5 away doesn't")
        expectEqual(beyond.guides, [])
    },
    test("the nearest line wins, an edge's or a middle's; a tie goes to the near edge") {
        // Lines at 60, 80, 100 and 406, 426, 446, far below the rect.
        let targets = SnapTargets([CGRect(x: 60, y: 500, width: 40, height: 10), CGRect(x: 406, y: 500, width: 40, height: 10)])
        let rect = CGRect(x: 0, y: 0, width: 300, height: 50)
        // The near edge 3 past 100, the far edge 3 short of 406: a tie, which the near edge wins.
        let tie = targets.snap(rect, movedBy: CGPoint(x: 103, y: 0), within: 8)
        expectEqual(tie.delta, CGPoint(x: 100, y: 0))
        expectEqual(tie.guides, [.alignment(.x, at: 100, points: [CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 50),
                                                                   CGPoint(x: 100, y: 500), CGPoint(x: 100, y: 510)])])
        // The far edge 2 short of 406, the near edge 4 past 100: the nearer wins.
        expectEqual(targets.snap(rect, movedBy: CGPoint(x: 104, y: 0), within: 8).delta, CGPoint(x: 106, y: 0))
        // The middle 3 past 80, the edges 17 and 23 from 60 and 100.
        expectEqual(targets.snap(CGRect(x: 0, y: 0, width: 80, height: 50), movedBy: CGPoint(x: 43, y: 0), within: 8).delta,
                    CGPoint(x: 40, y: 0))
    },
    test("middles snap to middles, and the guide joins the centers") {
        let targets = SnapTargets([CGRect(x: 200, y: 200, width: 100, height: 100)])
        let snap = targets.snap(CGRect(x: 0, y: 0, width: 60, height: 60), movedBy: CGPoint(x: 222, y: 0), within: 8)
        expectEqual(snap.delta, CGPoint(x: 220, y: 0))
        expectEqual(snap.guides, [.alignment(.x, at: 250, points: [CGPoint(x: 250, y: 30), CGPoint(x: 250, y: 250)])])
    },
    test("each axis snaps on its own, and every line lined up gets a guide, its points each once") {
        let targets = SnapTargets([CGRect(x: 200, y: 200, width: 100, height: 100)])
        // x: the right edge 3 short of 200. y: the top 3 past 250 (the frame's middle) and the bottom 3
        // past 300: a tie, which the top wins.
        let snap = targets.snap(CGRect(x: 0, y: 0, width: 50, height: 50), movedBy: CGPoint(x: 147, y: 253), within: 8)
        expectEqual(snap.delta, CGPoint(x: 150, y: 250))
        expectEqual(snap.guides, [
            .alignment(.x, at: 200, points: [CGPoint(x: 200, y: 200), CGPoint(x: 200, y: 250), CGPoint(x: 200, y: 300)]),
            .alignment(.y, at: 250, points: [CGPoint(x: 150, y: 250), CGPoint(x: 200, y: 250), CGPoint(x: 250, y: 250)]),
            .alignment(.y, at: 300, points: [CGPoint(x: 150, y: 300), CGPoint(x: 200, y: 300), CGPoint(x: 300, y: 300)]),
        ])
    },
    test("centered in the space between two neighbors, when it fits there") {
        let targets = SnapTargets([CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 300, y: 0, width: 100, height: 100)])
        // Its middle 2 short of 200, the space's.
        let snap = targets.snap(CGRect(x: 0, y: 10, width: 50, height: 30), movedBy: CGPoint(x: 173, y: 0), within: 8)
        expectEqual(snap.delta, CGPoint(x: 175, y: 0))
        expectEqual(snap.guides, [.spacing(.x, gaps: [gap(100, 0...100, 175, 10...40), gap(225, 10...40, 300, 0...100)])])
        // Wider than the space: it doesn't center there.
        let wide = targets.snap(CGRect(x: 0, y: 10, width: 250, height: 30), movedBy: CGPoint(x: 73, y: 0), within: 8)
        expectEqual(wide.delta, CGPoint(x: 73, y: 0))
        expectEqual(wide.guides, [])
    },
    test("the space again, after two neighbors or before them") {
        let targets = SnapTargets([CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 150, y: 0, width: 100, height: 100)])
        let rect = CGRect(x: 0, y: 10, width: 100, height: 30)
        // 3 short of 50 past the second.
        let after = targets.snap(rect, movedBy: CGPoint(x: 297, y: 0), within: 8)
        expectEqual(after.delta, CGPoint(x: 300, y: 0))
        expectEqual(after.guides, [.spacing(.x, gaps: [gap(100, 0...100, 150, 0...100), gap(250, 0...100, 300, 10...40)])])
        // 3 short of 50 before the first.
        let before = targets.snap(rect, movedBy: CGPoint(x: -153, y: 0), within: 8)
        expectEqual(before.delta, CGPoint(x: -150, y: 0))
        expectEqual(before.guides, [.spacing(.x, gaps: [gap(-50, 10...40, 0, 0...100), gap(100, 0...100, 150, 0...100)])])
    },
    test("spaces of that length one after another show with it, in one guide") {
        let targets = SnapTargets([CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 150, y: 0, width: 100, height: 100),
                                   CGRect(x: 300, y: 0, width: 100, height: 100)])
        let snap = targets.snap(CGRect(x: 0, y: 10, width: 100, height: 30), movedBy: CGPoint(x: 452, y: 0), within: 8)
        expectEqual(snap.delta, CGPoint(x: 450, y: 0))
        expectEqual(snap.guides, [.spacing(.x, gaps: [gap(100, 0...100, 150, 0...100), gap(250, 0...100, 300, 0...100),
                                                     gap(400, 0...100, 450, 10...40)])])
    },
    test("a guide whose every space another shows too is left out: the one with the most spaces shows them") {
        // Repeating the space after the first two, and centered between the second and third, at once.
        let targets = SnapTargets([CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 150, y: 0, width: 100, height: 100),
                                   CGRect(x: 400, y: 0, width: 100, height: 100)])
        let snap = targets.snap(CGRect(x: 0, y: 10, width: 50, height: 30), movedBy: CGPoint(x: 298, y: 0), within: 8)
        expectEqual(snap.delta, CGPoint(x: 300, y: 0))
        expectEqual(snap.guides, [.spacing(.x, gaps: [gap(100, 0...100, 150, 0...100), gap(250, 0...100, 300, 10...40),
                                                     gap(350, 10...40, 400, 0...100)])])
    },
    test("only neighbors' spaces count: a frame between two, across the stretch they share, keeps theirs out") {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100), c = CGRect(x: 400, y: 0, width: 100, height: 100)
        let rect = CGRect(x: 0, y: 10, width: 40, height: 30)
        // Its middle 2 past 250, the middle of the space between the two.
        expectEqual(SnapTargets([a, c]).snap(rect, movedBy: CGPoint(x: 232, y: 0), within: 8).delta, CGPoint(x: 230, y: 0))
        let between = SnapTargets([a, CGRect(x: 150, y: 0, width: 50, height: 100), c])
        expectEqual(between.snap(rect, movedBy: CGPoint(x: 232, y: 0), within: 8).delta, CGPoint(x: 232, y: 0))
        // Below the stretch they share, it's no frame between them.
        let below = SnapTargets([a, CGRect(x: 150, y: 200, width: 50, height: 100), c])
        expectEqual(below.snap(rect, movedBy: CGPoint(x: 232, y: 0), within: 8).delta, CGPoint(x: 230, y: 0))
    },
    test("a space counts only for what shares its stretch across by more than the threshold, so a snap across never leaves it without a guide") {
        let targets = SnapTargets([CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 300, y: 0, width: 100, height: 100)])
        let below = targets.snap(CGRect(x: 0, y: 200, width: 50, height: 30), movedBy: CGPoint(x: 173, y: 0), within: 8)
        expectEqual(below.delta, CGPoint(x: 173, y: 0))
        expectEqual(below.guides, [])
        // Sharing 5 of it, its middle 2 short of the space's: it doesn't center there. Its top 5 above
        // the frames' bottoms snaps down onto them, out of the stretch, where no space's guide shows.
        let edge = targets.snap(CGRect(x: 0, y: 95, width: 50, height: 30), movedBy: CGPoint(x: 173, y: 0), within: 8)
        expectEqual(edge.delta, CGPoint(x: 173, y: 5))
        expectEqual(edge.guides, [.alignment(.y, at: 100, points: [0, 100, 173, 223, 300, 400].map { CGPoint(x: $0, y: 100) })])
        // Sharing 9 of it (and its middle and bottom 11 and 31 from the frames' bottoms), it does.
        expectEqual(targets.snap(CGRect(x: 0, y: 91, width: 50, height: 40), movedBy: CGPoint(x: 173, y: 0), within: 8).delta,
                    CGPoint(x: 175, y: 0))
    },
    test("spaces along y, as along x") {
        let targets = SnapTargets([CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 0, y: 150, width: 100, height: 100)])
        let snap = targets.snap(CGRect(x: 10, y: 0, width: 30, height: 100), movedBy: CGPoint(x: 0, y: 297), within: 8)
        expectEqual(snap.delta, CGPoint(x: 0, y: 300))
        expectEqual(snap.guides, [.spacing(.y, gaps: [gap(100, 0...100, 150, 0...100), gap(250, 0...100, 300, 10...40)])])
    },
    test("centered among neighbors spaced evenly across, only the smallest space it's centered in shows (tldraw's)") {
        // Two pairs, one above the other, each space centered on 200: 200 long above, 160 below.
        let targets = SnapTargets([CGRect(x: 0, y: 0, width: 100, height: 50), CGRect(x: 300, y: 0, width: 100, height: 50),
                                   CGRect(x: 0, y: 50, width: 120, height: 50), CGRect(x: 280, y: 50, width: 100, height: 50)])
        let snap = targets.snap(CGRect(x: 0, y: 12, width: 40, height: 50), movedBy: CGPoint(x: 182, y: 0), within: 8)
        expectEqual(snap.delta, CGPoint(x: 180, y: 0))
        expectEqual(snap.guides, [.spacing(.x, gaps: [gap(120, 50...100, 180, 12...62), gap(220, 12...62, 280, 50...100)])])
    },
    test("frames that aren't finite are left out; with none, nothing snaps") {
        expectEqual(SnapTargets([CGRect(x: CGFloat.infinity, y: 0, width: 10, height: 10), CGRect(x: 0, y: 0, width: 10, height: 10)]).frames,
                    [CGRect(x: 0, y: 0, width: 10, height: 10)])
        let snap = SnapTargets([]).snap(CGRect(x: 0, y: 0, width: 10, height: 10), movedBy: CGPoint(x: 1, y: 2), within: 8)
        expectEqual(snap.delta, CGPoint(x: 1, y: 2))
        expectEqual(snap.guides, [])
    },
])
