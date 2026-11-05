import Adornments
import CoreGraphics
import TestKit

// The row above an anchor slides clear of a slanted shape's body (`Slant.slope`), pure, on fixture items
// (`AdornmentLayout.frames(of:width:slant:)`): view points from the anchor's top-left corner, y down,
// the body's centre line through the anchor's middle at the chord's slope. Whatever the slope, falling or rising to
// the right, no slot grown by `margin` (less a hair) is crossed by it; a level shape is laid out as it was; the slots
// are continuous in the slope; and the area culling and hit testing look in bounds every slot. The corner rides
// with the row and is not held clear of the body: it is a tally's place, and an arrow has none.

private let slantWidth: CGFloat = 120

private struct RowSet {
    let name: String
    let items: [Item]
}

private let rowSets = [
    RowSet(name: "one chip", items: [Item(.aboveTopLeft, width: 50, isText: false)]),
    RowSet(name: "three chips", items: [Item(.aboveTopLeft, width: 40, isText: false), Item(.aboveTopLeft, width: 40, isText: false),
                                        Item(.aboveTopLeft, width: 18, isText: false)]),
    RowSet(name: "a chip wider than the anchor", items: [Item(.aboveTopRight, width: 150, isText: false)]),
    RowSet(name: "text, a flag and a tally", items: [Item(.aboveTopLeft, width: 200, isText: true), Item(.aboveTopRight, width: 18, isText: false),
                                                     Item(.onTopRightCorner, width: 30, isText: true)]),
]

/// The slopes: 0, 3, 10, 20, 35, 45, 60 degrees and upright, each falling to the right and rising to it (and upright both ways).
private let slopes: [(name: String, slope: CGFloat)] = {
    var list: [(String, CGFloat)] = [("level", 0)]
    for degrees in [3.0, 10, 20, 35, 45, 60] as [CGFloat] {
        let slope = tangent(degrees)
        list += [("\(Int(degrees)) degrees falling", slope), ("\(Int(degrees)) degrees rising", -slope)]
    }
    return list + [("upright, down to the right", .infinity), ("upright, down to the left", -.infinity)]
}()

/// Whether the body, the line through `middle` at `slope`, passes through `rect`.
private func isCrossed(_ rect: CGRect, by slope: CGFloat, through middle: CGPoint) -> Bool {
    if slope.isInfinite { return rect.minX <= middle.x && middle.x <= rect.maxX }
    let a = middle.y + slope * (rect.minX - middle.x), b = middle.y + slope * (rect.maxX - middle.x)
    return max(a, b) >= rect.minY && min(a, b) <= rect.maxY
}

private func slant(height: CGFloat, slope: CGFloat, scale: CGFloat = 1) -> AdornmentLayout.Slant {
    AdornmentLayout.Slant(anchorHeight: height, slope: slope, maxSlide: AdornmentLayout.slideLimit(atScale: scale))
}

private let hair: CGFloat = 0.01

private func tangent(_ degrees: CGFloat) -> CGFloat { tan(degrees * CGFloat.pi / 180) }

@MainActor let slantLayoutTests = Suite("Sliding the row clear of a slanted body", [
    test("no slot, grown by the margin, is crossed by the body, at every slope, for every row, with and without a label's height") {
        var checked = 0
        for rows in rowSets {
            for height in [0, 18] as [CGFloat] {
                for (name, slope) in slopes {
                    let items = rows.items
                    let frames = AdornmentLayout.frames(of: items, width: slantWidth, slant: slant(height: height, slope: slope))
                    let middle = CGPoint(x: slantWidth / 2, y: height / 2)
                    for (item, frame) in zip(items, frames) {
                        guard let frame, item.placement != .onTopRightCorner else { continue }
                        checked += 1
                        let grown = frame.insetBy(dx: -(AdornmentLayout.margin - hair), dy: -(AdornmentLayout.margin - hair))
                        expect(!isCrossed(grown, by: slope, through: middle), "\(rows.name), height \(height), \(name): \(item.placement) at \(frame)")
                    }
                }
            }
        }
        expect(checked > 150, "slots were checked: \(checked)")
    },
    test("the body does cross the row where it was, on a slanted shape: the test above sees the slide") {
        let items = [Item(.aboveTopLeft, width: 50, isText: false)]
        let middle = CGPoint(x: 60, y: 0)
        for slope in [tangent(35), -tangent(35)] as [CGFloat] {
            let level = AdornmentLayout.frames(of: items, width: slantWidth, slant: slant(height: 0, slope: 0))
            // The chip from the anchor's left edge is crossed where the body falls, and clear where it rises.
            let crossed = level.compactMap { $0 }.filter { isCrossed($0.insetBy(dx: -3.99, dy: -3.99), by: slope, through: middle) }
            expectEqual(crossed.count, slope > 0 ? 1 : 0, "slope \(slope)")
        }
    },
    test("level, or nearly: nothing moves, and the numbers are what they were") {
        let items = [caption(60), flag]
        let old = AdornmentLayout.frames(of: items, width: 200, slant: .init(anchorHeight: 20))
        expectEqual(old, [rect(0, -27, 60, 18), rect(182, -27, 18, 18)])
        for slope in [0, 1e-9, -1e-9, 0.01, -0.01, 0.03, -0.03] as [CGFloat] {
            expectEqual(AdornmentLayout.frames(of: items, width: 200, slant: .init(anchorHeight: 20, slope: slope)), old, "slope \(slope)")
        }
        expectEqual(AdornmentLayout.frames(of: items, width: 200), old, "a closed shape has no slant at all")
    },
    test("only as far as it must: the row's edge is within a hair of the limit where it moved") {
        // 35 degrees falling, a point anchor 120 wide: the limit of the row's left end is 60 - 5 / t + 4 from the anchor's left edge.
        let t = tangent(35)
        let row = AdornmentLayout.frames(of: [Item(.aboveTopLeft, width: 50, isText: false)], width: 120, slant: slant(height: 0, slope: t))
        expectEqual(row[0]?.minX ?? 0, 60 - 5 / t + 4, accuracy: 1e-9)
        let rising = AdornmentLayout.frames(of: [Item(.aboveTopLeft, width: 50, isText: false)], width: 120, slant: slant(height: 0, slope: -t))
        // Rising, the row's right end may reach 60 + 5 / t - 4, and it starts at the left edge: it ends at 50, inside that, so it stays.
        expectEqual(rising[0], rect(0, -27, 50, 18), "already clear")
        let wide = AdornmentLayout.frames(of: [Item(.aboveTopLeft, width: 100, isText: false)], width: 120, slant: slant(height: 0, slope: -t))
        expectEqual(wide[0]?.maxX ?? 0, 60 + 5 / t - 4, accuracy: 1e-9)
    },
    test("the tally moves with the row, and the right end keeps its own packing") {
        let items = [Item(.aboveTopLeft, width: 40, isText: false), Item(.aboveTopRight, width: 18, isText: false), Item(.onTopRightCorner, width: 30, isText: true)]
        let level = AdornmentLayout.frames(of: items, width: 120)
        let slid = AdornmentLayout.frames(of: items, width: 120, slant: slant(height: 0, slope: tangent(35)))
        let moved = (slid[0]?.minX ?? 0) - (level[0]?.minX ?? 0)
        expect(moved > 20, "the row moved: \(moved)")
        for index in 0..<3 { expectEqual(slid[index]?.minX ?? 0, (level[index]?.minX ?? 0) + moved, accuracy: 1e-9, "item \(index)") }
        expectEqual(slid[1]?.minX ?? 0, 102 + moved, accuracy: 1e-9, "the flag at the right edge of the anchor, moved")
    },
    test("the row slides at most maxSlide, and its reach is held") {
        let items = [Item(.aboveTopLeft, width: 100, isText: false)]
        // An anchor 4000 points wide (a label of 500 world units at 800%): the row would slide 1,984 points; it slides the cap.
        let capped = AdornmentLayout.frames(of: items, width: 4000, slant: slant(height: 18, slope: tangent(35), scale: 0.125))
        expectEqual(capped[0]?.minX ?? 0, 200 / 0.125, "at most maxSlide world units, 1,600 points at 800%")
    },
    test("the slots are continuous in the slope: a turn of a twentieth of a degree moves each a small way") {
        let items = rowSets[3].items + rowSets[1].items
        for height in [0, 18] as [CGFloat] {
            for sign in [1, -1] as [CGFloat] {
                var degrees: CGFloat = 0.5
                while degrees < 89.9 {
                    let next = degrees + 0.05
                    let a = AdornmentLayout.frames(of: items, width: slantWidth, slant: slant(height: height, slope: sign * tangent(degrees)))
                    let b = AdornmentLayout.frames(of: items, width: slantWidth, slant: slant(height: height, slope: sign * tangent(next)))
                    for index in items.indices {
                        guard let p = a[index], let q = b[index] else {
                            expect(a[index] == nil && b[index] == nil, "shown at one slope and not the next, \(degrees) degrees, item \(index)")
                            continue
                        }
                        expect(abs(p.minX - q.minX) < 1 && abs(p.minY - q.minY) < 1 && abs(p.width - q.width) < 1e-9,
                              "item \(index) at \(degrees) degrees, height \(height), sign \(sign): \(p) then \(q)")
                    }
                    degrees = next
                }
            }
        }
    },
    test("turning through the vertical is the one jump: the row is on one side of the body falling and on the other rising, and just short of upright it is continuous") {
        let items = [Item(.aboveTopLeft, width: 50, isText: false)]
        let falling = AdornmentLayout.frames(of: items, width: slantWidth, slant: slant(height: 0, slope: tangent(89.9)))[0]
        let rising = AdornmentLayout.frames(of: items, width: slantWidth, slant: slant(height: 0, slope: -tangent(89.9)))[0]
        // Falling, the row starts a margin right of the middle; rising, it is already clear where it was.
        expectEqual(falling?.minX ?? 0, slantWidth / 2 + AdornmentLayout.margin, accuracy: 0.1, "right of the body")
        expectEqual(rising?.minX ?? 1, 0, accuracy: 0.1, "left of it")
        let nearly = AdornmentLayout.frames(of: items, width: slantWidth, slant: slant(height: 0, slope: tangent(89.5)))[0]
        expect(abs((nearly?.minX ?? 0) - (falling?.minX ?? 0)) < 1, "continuous up to the vertical: \(String(describing: nearly)) then \(String(describing: falling))")
        let upright = AdornmentLayout.frames(of: items, width: slantWidth, slant: slant(height: 0, slope: .infinity))[0]
        expectEqual(upright?.minX ?? 0, falling?.minX ?? 1, accuracy: 0.1, "an upright chord counts as falling")
    },
    test("the area culling and hit testing look in holds every slot: its anchor is in the shape's bounds, at 25%, 100% and 800% and for anchors as wide as a label") {
        var checked = 0
        for scale in [4, 1, 0.125] as [CGFloat] {
            for worldWidth in [0, 250, 400] as [CGFloat] {
                // A label's rect, or the widened middle: the shape's bounds hold the first and the middle of the second.
                let width = max(slantWidth, worldWidth / scale)
                for height in [0, 18] as [CGFloat] {
                    let anchor = CGRect(x: 1000, y: 1000, width: width * scale, height: height * scale)
                    // The shape's bounds: its label, or the middle of its outline.
                    let bounds = CGRect(x: anchor.midX - worldWidth / 2, y: anchor.midY - height * scale / 2, width: worldWidth, height: height * scale)
                    for rows in rowSets {
                        for (name, slope) in slopes {
                            let frames = AdornmentLayout.frames(of: rows.items, width: width, slant: slant(height: height, slope: slope, scale: scale))
                            for frame in frames.compactMap({ $0 }) {
                                let world = CGRect(x: anchor.minX + frame.minX * scale, y: anchor.minY + frame.minY * scale,
                                                   width: frame.width * scale, height: frame.height * scale)
                                let area = AdornmentLayout.area(showing: world, scale: scale)
                                let found = worldWidth == 0 ? area.contains(CGPoint(x: anchor.midX, y: anchor.midY)) : area.intersects(bounds)
                                checked += 1
                                expect(found, "scale \(scale), width \(worldWidth), height \(height), \(rows.name), \(name): \(world) against \(area)")
                            }
                        }
                    }
                }
            }
        }
        expect(checked > 800, "slots were checked: \(checked)")
    },
    test("the area grows left and right by the slid reach, and up and down as it did") {
        let visible = CGRect(x: 0, y: 0, width: 400, height: 300)
        let area = AdornmentLayout.area(showing: visible, scale: 1)
        expectEqual(area.minX, -400, "the row slid: 2 x maxRun from the middle")
        expectEqual(area.maxX, 800)
        expectEqual(area.minY, -8, "the corner's reach under the top edge")
        expectEqual(area.maxY, 300 + 31, "the row's reach over a tab")
        expectEqual(AdornmentLayout.area(showing: visible, scale: 0.125).minX, -200.75, "at 800% the row's world reach, maxSlide and the overhang, is what counts")
    },
])

@MainActor func expectEqual(_ actual: CGFloat, _ expected: CGFloat, accuracy: CGFloat, _ message: @autoclosure () -> String = "", file: StaticString = #fileID, line: UInt = #line) {
    expect(abs(actual - expected) <= accuracy, "\(actual) is not \(expected) \(message())", file: file, line: line)
}
