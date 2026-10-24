import CoreGraphics
import Snapping
import TestKit

// `SnapTargets`' resize snapping, pure: a rect resized from where it began about what stays put, the
// sides it moves snapped to frames' edges and middles within 8 world units, and the guides for every
// line its sides are on along the ways it changes. The rects are the ones a drag of a handle gives.

@MainActor let resizeTargetsTests = Suite("Snap targets, resizing", [
    test("the side that moves snaps onto another frame's edge or middle within the threshold; the side that stays, stays") {
        let targets = SnapTargets([CGRect(x: 300, y: 0, width: 100, height: 100)])
        let start = CGRect(x: 0, y: 200, width: 100, height: 100), anchor = CGPoint(x: 0, y: 250)
        func resized(toRight right: CGFloat) -> ResizeSnap {
            targets.snap(CGRect(x: 0, y: 200, width: right, height: 100), resizedFrom: start, about: anchor, along: [.x], inProportion: false,
                         minimum: CGSize(width: 20, height: 20), room: nil, within: 8)
        }
        // Its right side 3 short of the frame's left edge.
        let edge = resized(toRight: 297)
        expectEqual(edge.rect, CGRect(x: 0, y: 200, width: 300, height: 100))
        expectEqual(edge.guides, [.alignment(.x, at: 300, points: [CGPoint(x: 300, y: 0), CGPoint(x: 300, y: 100),
                                                                     CGPoint(x: 300, y: 200), CGPoint(x: 300, y: 300)])])
        // 3 past its middle.
        let middle = resized(toRight: 353)
        expectEqual(middle.rect, CGRect(x: 0, y: 200, width: 350, height: 100))
        expectEqual(middle.guides, [.alignment(.x, at: 350, points: [CGPoint(x: 350, y: 50), CGPoint(x: 350, y: 200), CGPoint(x: 350, y: 300)])])
        expectEqual(resized(toRight: 292).rect, CGRect(x: 0, y: 200, width: 300, height: 100), "8 away snaps")
        let beyond = resized(toRight: 291.5)
        expectEqual(beyond.rect, CGRect(x: 0, y: 200, width: 291.5, height: 100), "8.5 away doesn't")
        expectEqual(beyond.guides, [])
    },
    test("only the ways it changes snap: a side's handle leaves the other way as it is, and shows no guide there") {
        // The bottom 3 above a frame's top, but only its width changes.
        let targets = SnapTargets([CGRect(x: 600, y: 303, width: 100, height: 100)])
        let snap = targets.snap(CGRect(x: 0, y: 200, width: 250, height: 100), resizedFrom: CGRect(x: 0, y: 200, width: 100, height: 100),
                                about: CGPoint(x: 0, y: 250), along: [.x], inProportion: false,
                                minimum: CGSize(width: 20, height: 20), room: nil, within: 8)
        expectEqual(snap.rect, CGRect(x: 0, y: 200, width: 250, height: 100))
        expectEqual(snap.guides, [])
    },
    test("a corner snaps each way on its own, and a guide shows for each") {
        let targets = SnapTargets([CGRect(x: 200, y: 250, width: 50, height: 50)])
        let snap = targets.snap(CGRect(x: 0, y: 0, width: 197, height: 253), resizedFrom: CGRect(x: 0, y: 0, width: 100, height: 100),
                                about: .zero, along: [.x, .y], inProportion: false,
                                minimum: CGSize(width: 20, height: 20), room: nil, within: 8)
        expectEqual(snap.rect, CGRect(x: 0, y: 0, width: 200, height: 250))
        expectEqual(snap.guides, [
            .alignment(.x, at: 200, points: [CGPoint(x: 200, y: 0), CGPoint(x: 200, y: 250), CGPoint(x: 200, y: 300)]),
            .alignment(.y, at: 250, points: [CGPoint(x: 0, y: 250), CGPoint(x: 200, y: 250), CGPoint(x: 250, y: 250)]),
        ])
    },
    test("dragged by its left side, the left side snaps and the right stays put") {
        let targets = SnapTargets([CGRect(x: 0, y: 0, width: 50, height: 100)])
        let snap = targets.snap(CGRect(x: 53, y: 200, width: 147, height: 100), resizedFrom: CGRect(x: 100, y: 200, width: 100, height: 100),
                                about: CGPoint(x: 200, y: 250), along: [.x], inProportion: false,
                                minimum: CGSize(width: 20, height: 20), room: nil, within: 8)
        expectEqual(snap.rect, CGRect(x: 50, y: 200, width: 150, height: 100))
    },
    test("from its center, whichever side is nearer a line snaps, and the other mirrors it") {
        // Lines at 0, 37.5 and 75: the left side 1 past 75, the right side nowhere near one.
        let targets = SnapTargets([CGRect(x: 0, y: 0, width: 75, height: 100)])
        let snap = targets.snap(CGRect(x: 74, y: 200, width: 152, height: 100), resizedFrom: CGRect(x: 100, y: 200, width: 100, height: 100),
                                about: CGPoint(x: 150, y: 250), along: [.x], inProportion: false,
                                minimum: CGSize(width: 20, height: 20), room: nil, within: 8)
        expectEqual(snap.rect, CGRect(x: 75, y: 200, width: 150, height: 100))
        expectEqual(snap.guides, [.alignment(.x, at: 75, points: [CGPoint(x: 75, y: 0), CGPoint(x: 75, y: 100),
                                                                    CGPoint(x: 75, y: 200), CGPoint(x: 75, y: 300)])])
    },
    test("in proportion, of every side that moves the one nearest a line snaps, and the rest follow at its scale") {
        // From a 200 × 100 box by its bottom right corner, half as big again: its right side 7 short of
        // 307, its bottom 6.25 short of 156.25, which wins.
        let targets = SnapTargets([CGRect(x: 307, y: 500, width: 20, height: 10), CGRect(x: 500, y: 156.25, width: 10, height: 20)])
        let corner = targets.snap(CGRect(x: 0, y: 0, width: 300, height: 150), resizedFrom: CGRect(x: 0, y: 0, width: 200, height: 100),
                                  about: .zero, along: [.x, .y], inProportion: true,
                                  minimum: CGSize(width: 20, height: 20), room: nil, within: 8)
        expectEqual(corner.rect, CGRect(x: 0, y: 0, width: 312.5, height: 156.25))
        expectEqual(corner.guides, [.alignment(.y, at: 156.25, points: [CGPoint(x: 0, y: 156.25), CGPoint(x: 312.5, y: 156.25),
                                                                          CGPoint(x: 500, y: 156.25), CGPoint(x: 510, y: 156.25)])])
        // By its right side, about its middle across: its top 2.5 below a frame's bottom at −37.5.
        let side = SnapTargets([CGRect(x: 600, y: -137.5, width: 10, height: 100)])
            .snap(CGRect(x: 0, y: -35, width: 340, height: 170), resizedFrom: CGRect(x: 0, y: 0, width: 200, height: 100),
                  about: CGPoint(x: 0, y: 50), along: [.x, .y], inProportion: true,
                  minimum: CGSize(width: 20, height: 20), room: nil, within: 8)
        expectEqual(side.rect, CGRect(x: 0, y: -37.5, width: 350, height: 175))
        expectEqual(side.guides, [.alignment(.y, at: -37.5, points: [CGPoint(x: 0, y: -37.5), CGPoint(x: 350, y: -37.5),
                                                                       CGPoint(x: 600, y: -37.5), CGPoint(x: 610, y: -37.5)])])
    },
    test("a line that would leave it under its minimum isn't snapped to, but a line further off within the threshold is") {
        let start = CGRect(x: 0, y: 200, width: 100, height: 100), anchor = CGPoint(x: 0, y: 250)
        let minimum = CGSize(width: 50, height: 50)
        // A line at 46, 5 short of its right side at 51: a width of 46 is under 50.
        let short = SnapTargets([CGRect(x: 46, y: 500, width: 100, height: 10)])
        let alone = short.snap(CGRect(x: 0, y: 200, width: 51, height: 100), resizedFrom: start, about: anchor, along: [.x],
                               inProportion: false, minimum: minimum, room: nil, within: 8)
        expectEqual(alone.rect, CGRect(x: 0, y: 200, width: 51, height: 100))
        expectEqual(alone.guides, [])
        // With a line at 58 too, 7 past it.
        let further = SnapTargets([CGRect(x: 46, y: 500, width: 100, height: 10), CGRect(x: 58, y: 600, width: 10, height: 10)])
        expectEqual(further.snap(CGRect(x: 0, y: 200, width: 51, height: 100), resizedFrom: start, about: anchor, along: [.x],
                                 inProportion: false, minimum: minimum, room: nil, within: 8).rect,
                    CGRect(x: 0, y: 200, width: 58, height: 100))
    },
    test("a line past its room isn't snapped to: a shape in a container never snaps across the gap inside its edge") {
        let targets = SnapTargets([CGRect(x: 300, y: 0, width: 100, height: 100)])
        let snap = targets.snap(CGRect(x: 0, y: 200, width: 296, height: 100), resizedFrom: CGRect(x: 0, y: 200, width: 100, height: 100),
                                about: CGPoint(x: 0, y: 250), along: [.x], inProportion: false, minimum: CGSize(width: 20, height: 20),
                                room: CGRect(x: -100, y: 0, width: 398, height: 1000), within: 8)
        expectEqual(snap.rect, CGRect(x: 0, y: 200, width: 296, height: 100))
        expectEqual(snap.guides, [])
    },
])
