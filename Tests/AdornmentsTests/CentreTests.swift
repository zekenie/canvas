import Adornments
import CoreGraphics
import TestKit

// On an open shape with no label (a point anchor, `Slant.centersRow`) the row is centred on the anchor's middle as one
// run, the corner riding along, and the slide of a slanted body starts from there. Pure, on fixture items, in view
// points from the anchor's top-left corner. A labelled shape's row (`centersRow` false) and a closed shape's (no
// `Slant`) are laid out as they were.

private let width: CGFloat = 120

private func centred(slope: CGFloat = 0, scale: CGFloat = 1, height: CGFloat = 0) -> AdornmentLayout.Slant {
    AdornmentLayout.Slant(anchorHeight: height, slope: slope, maxSlide: AdornmentLayout.slideLimit(atScale: scale), centersRow: true)
}

private func tangent(_ degrees: CGFloat) -> CGFloat { tan(degrees * CGFloat.pi / 180) }

private func isCrossed(_ rect: CGRect, by slope: CGFloat, through middle: CGPoint) -> Bool {
    if slope.isInfinite { return rect.minX <= middle.x && middle.x <= rect.maxX }
    let a = middle.y + slope * (rect.minX - middle.x), b = middle.y + slope * (rect.maxX - middle.x)
    return max(a, b) >= rect.minY && min(a, b) <= rect.maxY
}

private let chip = Item(.aboveTopLeft, width: 50, isText: false)
private let rows: [(String, [Item])] = [
    ("one chip", [chip]),
    ("three chips", [Item(.aboveTopLeft, width: 40, isText: false), Item(.aboveTopLeft, width: 40, isText: false), Item(.aboveTopLeft, width: 18, isText: false)]),
    ("a chip wider than the anchor", [Item(.aboveTopRight, width: 150, isText: false)]),
    ("a chip and a lock", [Item(.aboveTopLeft, width: 40, isText: false), Item(.aboveTopRight, width: 18, isText: false)]),
    ("text with a flag and a tally", [Item(.aboveTopLeft, width: 200, isText: true), Item(.aboveTopRight, width: 18, isText: false), Item(.onTopRightCorner, width: 30, isText: true)]),
]

@MainActor let centreLayoutTests = Suite("Centring the row on a point anchor", [
    test("a chip of one is centred on the middle: (120 - 50) / 2 from the left; three chips as one run: (120 - 106) / 2") {
        expectEqual(AdornmentLayout.frames(of: [chip], width: width, slant: centred())[0], CGRect(x: 35, y: -27, width: 50, height: 18))
        let three = [Item(.aboveTopLeft, width: 40, isText: false), Item(.aboveTopLeft, width: 40, isText: false), Item(.aboveTopLeft, width: 18, isText: false)]
        // The run is 40 + 4 + 40 + 4 + 18 = 106 wide.
        let frames = AdornmentLayout.frames(of: three, width: width, slant: centred())
        expectEqual(frames.map { $0?.minX ?? -1 }, [7, 51, 95])
        expectEqual((frames[0]?.minX ?? 0) + (frames[2]?.maxX ?? 0), width, "the run's middle is the anchor's")
    },
    test("a chip wider than the anchor is centred too, and reaches past the anchor either side: (120 - 150) / 2 from the left edge") {
        let frames = AdornmentLayout.frames(of: [Item(.aboveTopRight, width: 150, isText: false)], width: width, slant: centred())
        // Placed from the right edge it starts at -30 and ends at 120; centred it is -15 to 135.
        expectEqual(frames[0], CGRect(x: -15, y: -27, width: 150, height: 18))
    },
    test("a chip and a lock, or text and a flag, fill the anchor: their extent is the anchor's, and nothing moves") {
        for (name, items) in rows where name == "a chip and a lock" || name.hasPrefix("text") {
            expectEqual(AdornmentLayout.frames(of: items, width: width, slant: centred()), AdornmentLayout.frames(of: items, width: width), name)
        }
    },
    test("the corner rides along with the row") {
        let items = [chip, Item(.onTopRightCorner, width: 30, isText: true)]
        let level = AdornmentLayout.frames(of: items, width: width), moved = AdornmentLayout.frames(of: items, width: width, slant: centred())
        expectEqual(level[0]?.minX ?? 0, 0)
        expectEqual(moved[0]?.minX ?? 0, 35)
        expectEqual(moved[1]?.minX ?? 0, (level[1]?.minX ?? 0) + 35)
    },
    test("a labelled open shape (no centring) and a closed shape (no slant) are laid out exactly as they were") {
        for (name, items) in rows {
            let old = AdornmentLayout.frames(of: items, width: width)
            expectEqual(AdornmentLayout.frames(of: items, width: width, slant: .init(anchorHeight: 18, slope: 0)), old, "\(name), labelled, level")
        }
        expectEqual(AdornmentLayout.frames(of: [chip], width: width, slant: .init(anchorHeight: 18, slope: 0))[0]?.minX, 0)
    },
    test("centred then slid: only as far as it must from the centred row") {
        let t = tangent(35)
        // The row's left may be no farther left than 4 - 5 / t from the middle falling: the centred chip (35) is left of 60 - 5 / t + 4.
        let falling = AdornmentLayout.frames(of: [chip], width: width, slant: centred(slope: t))
        expectEqual(falling[0]?.minX ?? 0, 60 - 5 / t + 4, accuracy: 1e-9)
        let rising = AdornmentLayout.frames(of: [chip], width: width, slant: centred(slope: -t))
        expectEqual(rising[0]?.maxX ?? 0, 60 + 5 / t - 4, accuracy: 1e-9)
        // A slope too slight to need it leaves the centred row where it is: 3 / 1000 falling needs 5 / 0.003 = 1666 points.
        expectEqual(AdornmentLayout.frames(of: [chip], width: width, slant: centred(slope: 0.003))[0]?.minX ?? 0, 35, accuracy: 1e-9)
    },
    test("centred then slid, no slot grown by the margin is crossed by the body, at every slope, for every row") {
        var checked = 0
        for (name, items) in rows {
            for height in [0, 18] as [CGFloat] {
                var slopes: [CGFloat] = [0, .infinity, -.infinity]
                for degrees in [3, 10, 20, 35, 45, 60] as [CGFloat] { slopes += [tangent(degrees), -tangent(degrees)] }
                for slope in slopes {
                    let frames = AdornmentLayout.frames(of: items, width: width, slant: centred(slope: slope, height: height))
                    for (item, frame) in zip(items, frames) {
                        guard let frame, item.placement != .onTopRightCorner else { continue }
                        checked += 1
                        let grown = frame.insetBy(dx: -3.99, dy: -3.99)
                        expect(!isCrossed(grown, by: slope, through: CGPoint(x: width / 2, y: height / 2)), "\(name), height \(height), slope \(slope): \(frame)")
                    }
                }
            }
        }
        expect(checked > 100, "\(checked)")
    },
    test("centred then slid, continuous in the slope: a twentieth of a degree moves no slot more than a few points, from level to nearly upright, both ways") {
        var worst: CGFloat = 0
        for (name, items) in rows {
            for sign in [1, -1] as [CGFloat] {
                var previous = AdornmentLayout.frames(of: items, width: width, slant: centred())
                var degrees: CGFloat = 0.05
                while degrees < 89 {
                    let frames = AdornmentLayout.frames(of: items, width: width, slant: centred(slope: sign * tangent(degrees)))
                    for (a, b) in zip(previous, frames) {
                        guard let a, let b else { expect(a == nil && b == nil, "\(name): a slot came or went at \(degrees)"); continue }
                        worst = max(worst, abs(a.minX - b.minX))
                    }
                    previous = frames
                    degrees += 0.05
                }
            }
        }
        expect(worst < 3, "the worst step: \(worst)")
    },
    test("the area holds every slot of a centred row, at 25%, 100% and 800%: centring keeps the run within 100 points of the middle, inside what the slide already reaches") {
        var checked = 0
        for scale in [4, 1, 0.125] as [CGFloat] {
            let anchor = CGRect(x: 1000, y: 1000, width: width * scale, height: 0)
            for (name, items) in rows {
                for slope in [0, tangent(10), -tangent(10), tangent(35), -tangent(35), tangent(60), -tangent(60), .infinity] as [CGFloat] {
                    for frame in AdornmentLayout.frames(of: items, width: width, slant: centred(slope: slope, scale: scale)).compactMap({ $0 }) {
                        let world = CGRect(x: anchor.minX + frame.minX * scale, y: anchor.minY + frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
                        checked += 1
                        expect(AdornmentLayout.area(showing: world, scale: scale).contains(CGPoint(x: anchor.midX, y: anchor.midY)), "\(name) at \(scale), slope \(slope): \(world)")
                    }
                }
            }
        }
        expect(checked > 100, "\(checked)")
    },
])
