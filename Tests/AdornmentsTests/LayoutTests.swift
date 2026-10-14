import Adornments
import CoreGraphics
import TestKit

// The layout alone (`AdornmentLayout.frames`): view points from the shape's top-left corner, y down.
// The row is 18 tall and ends 9 above the top edge (y −27 to −9); the corner is 16 tall, centered on
// the top edge (y −8 to 8), reaching 6 past the right edge.

typealias Item = AdornmentLayout.Item

func caption(_ width: CGFloat) -> Item { Item(.aboveTopLeft, width: width, isText: true) }
let flag = Item(.aboveTopRight, width: 18, isText: false)
let pin = Item(.aboveTopRight, width: 18, isText: false)
func count(_ width: CGFloat) -> Item { Item(.onTopRightCorner, width: width, isText: true) }

func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect { CGRect(x: x, y: y, width: width, height: height) }

@MainActor let layoutTests = Suite("Laying out adornments", [
    test("the extent is how far above the top edge what's shown reaches: the row 27, the corner 8, nothing 0, and text left out for want of room nothing") {
        expectEqual(AdornmentLayout.extent(of: [], in: 200), 0)
        expectEqual(AdornmentLayout.extent(of: [caption(60)], in: 200), 27)
        expectEqual(AdornmentLayout.extent(of: [flag], in: 200), 27)
        expectEqual(AdornmentLayout.extent(of: [count(40)], in: 200), 8)
        expectEqual(AdornmentLayout.extent(of: [count(40), caption(60)], in: 200), 27, "the farthest")
        expectEqual(AdornmentLayout.extent(of: [caption(60)], in: 20), 0, "no room for the text: nothing shown")
        expectEqual(AdornmentLayout.extent(of: [caption(60), count(40)], in: 20), 8, "only the corner is")
        expectEqual(AdornmentLayout.extent(of: [caption(60), flag], in: 20), 27)
        expectEqual(AdornmentLayout.extent(of: [caption(60)], in: 200), AdornmentLayout.rowGap + AdornmentLayout.rowHeight)
        expectEqual(AdornmentLayout.extent(of: [count(40)], in: 200), AdornmentLayout.cornerHeight / 2)
    },
    test("a caption is at the left end of the row just above the shape, as wide as its text") {
        expectEqual(AdornmentLayout.frames(of: [caption(60)], width: 200), [rect(0, -27, 60, 18)])
    },
    test("the row's right end fills leftward from the right edge, 4 points apart, in the order given") {
        expectEqual(AdornmentLayout.frames(of: [flag, pin], width: 200), [rect(182, -27, 18, 18), rect(160, -27, 18, 18)])
    },
    test("a long caption runs to the right edge, and stops 4 points short of what's at the row's right end") {
        expectEqual(AdornmentLayout.frames(of: [caption(500)], width: 200), [rect(0, -27, 200, 18)])
        expectEqual(AdornmentLayout.frames(of: [caption(500), flag], width: 200)[0], rect(0, -27, 178, 18))
        expectEqual(AdornmentLayout.frames(of: [flag, caption(500), pin], width: 200)[1], rect(0, -27, 156, 18))
    },
    test("text needs 30 points of room at the row's left end; the right end runs past the left edge of a narrow shape") {
        expectEqual(AdornmentLayout.frames(of: [caption(60), flag, pin], width: 10), [nil, rect(-8, -27, 18, 18), rect(-30, -27, 18, 18)])
        expectEqual(AdornmentLayout.frames(of: [caption(60), flag], width: 51)[0], nil, "29 points of room")
        expectEqual(AdornmentLayout.frames(of: [caption(60), flag], width: 52)[0], rect(0, -27, 30, 18), "30")
        expectEqual(AdornmentLayout.frames(of: [caption(20)], width: 30), [rect(0, -27, 20, 18)], "narrower than 30 itself, in 30 of room")
        expectEqual(AdornmentLayout.frames(of: [caption(20)], width: 29), [nil])
    },
    test("text after a symbol needs 30 points of room and the symbol's place besides, so it's never the symbol alone") {
        let marked = Item(.aboveTopLeft, width: 80, isText: true, lead: 14)
        expectEqual(AdornmentLayout.frames(of: [marked, flag], width: 65)[0], nil, "43 points of room")
        expectEqual(AdornmentLayout.frames(of: [marked, flag], width: 66)[0], rect(0, -27, 44, 18), "44: 30 and its 14")
        expectEqual(AdornmentLayout.frames(of: [marked], width: 200), [rect(0, -27, 80, 18)], "as long as it is, with room")
    },
    test("at the row's left end, a symbol is shown whole or not at all, and what comes after it is left out with it") {
        let symbol = Item(.aboveTopLeft, width: 18, isText: false)
        expectEqual(AdornmentLayout.frames(of: [symbol, caption(100)], width: 60), [rect(0, -27, 18, 18), rect(22, -27, 38, 18)])
        expectEqual(AdornmentLayout.frames(of: [symbol, caption(100)], width: 17), [nil, nil])
    },
    test("the corner is centered on the top edge, reaching 6 points past the right edge, and fills leftward") {
        expectEqual(AdornmentLayout.frames(of: [count(40), count(30)], width: 200), [rect(166, -8, 40, 16), rect(132, -8, 30, 16)])
        expectEqual(AdornmentLayout.frames(of: [caption(500), count(40)], width: 200), [rect(0, -27, 200, 18), rect(166, -8, 40, 16)],
                    "the row clear of it, a point above its top")
    },
    test("a run is cut where it would reach more than 200 points from its start") {
        let flags = AdornmentLayout.frames(of: Array(repeating: flag, count: 12), width: 0)
        expectEqual(flags.compactMap { $0 }.map(\.minX), [-18, -40, -62, -84, -106, -128, -150, -172, -194])
        expectEqual(Array(flags.suffix(3)), [nil, nil, nil])
        let counts = AdornmentLayout.frames(of: [count(50), count(50), count(50), count(50), count(10)], width: 100)
        expectEqual(counts.map { $0?.minX }, [56, 2, -52, nil, nil], "the fourth would reach 212 from its start; the fifth comes after it")
    },
    test("whatever the items and the width, none overlaps another, the left end stays over the shape, and all is within reach") {
        var random = SeededGenerator(seed: 2026)
        let places = AdornmentPlacement.allCases
        var cases = 0, shown = 0
        for width in stride(from: CGFloat(0), through: 400, by: 1) {
            for _ in 0..<12 {
                let items = (0..<Int.random(in: 1...7, using: &random)).map { _ in
                    Item(places.randomElement(using: &random)!, width: CGFloat(Int.random(in: 8...240, using: &random)),
                         isText: Bool.random(using: &random))
                }
                let frames = AdornmentLayout.frames(of: items, width: width)
                cases += 1
                shown += frames.compactMap { $0 }.count
                for (i, frame) in frames.enumerated() {
                    guard let frame else { continue }
                    let reach = CGRect(x: min(0, width - 200), y: -27, width: width + 6 - min(0, width - 200), height: 35)
                    expect(reach.contains(frame), "\(frame) past \(reach), width \(width): \(items)")
                    if items[i].placement == .aboveTopLeft {
                        expect(frame.minX >= 0 && frame.maxX <= width, "\(frame) off the shape, width \(width): \(items)")
                    }
                    for other in frames[(i + 1)...].compactMap({ $0 }) where frame.intersects(other) {
                        expect(false, "\(frame) and \(other) overlap, width \(width): \(items)")
                    }
                }
            }
        }
        expect(shown > cases, "most items are shown: \(shown) of \(cases) cases")
    },
    test("a closed shape's reach is the rect its row and corner lie in, at any scale: what the property above holds them to") {
        for scale: CGFloat in [0.125, 1, 2.5, 4] {
            for width: CGFloat in [0, 50, 200, 201, 400] {
                let bounds = CGRect(x: 30, y: 40, width: width * scale, height: 100)
                let reach = AdornmentLayout.reach(ofClosed: bounds, scale: scale)
                let least = min(0, width - 200)
                let expected = CGRect(x: bounds.minX + least * scale, y: bounds.minY - 27 * scale,
                                      width: (width + 6 - least) * scale, height: 35 * scale)
                expect(abs(reach.minX - expected.minX) + abs(reach.minY - expected.minY) + abs(reach.width - expected.width)
                       + abs(reach.height - expected.height) < 1e-6, "width \(width) at \(scale): \(reach) is not \(expected)")
            }
        }
    },
    test("adornments keep their size on screen down to 25%, then shrink with the shapes") {
        for zoom: CGFloat in [4, 2, 1, 0.5, 0.25] { expectClose(AdornmentLayout.scale(atZoom: zoom), 1 / zoom) }
        for zoom: CGFloat in [0.2, 0.125, 0.05] { expectClose(AdornmentLayout.scale(atZoom: zoom), 4) }
    },
])
