import Adornments
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import DetailPanel
import Geometry
import Mentions
import Selection
import TestKit
import Types

// An arrow between two notes, slanted: the chip of its type above its anchor slides clear of its own body (Adornments'
// `slideRow`), at the slopes the design's pure test uses.

/// Two notes whose centers are `length` apart at `degrees` below the horizontal (a rising arrow is negative; 90 is upright), an
/// arrow between them bound at the centers, and a type on it.
@MainActor
private struct SlantBoard {
    let h: EditorHarness
    let arrow: ShapeID
    let a: ShapeID, b: ShapeID

    init(degrees: CGFloat, length: CGFloat = 520, bend: CGFloat = 0, words: String = "", typed: Bool = true, title: String = "Person") throws {
        h = try EditorHarness(plugins: arrowsPlugins(more: [DetailPanelPlugin(), LabelFixturesPlugin()]))
        let radians = degrees * CGFloat.pi / 180
        let first = CGPoint(x: 600, y: 600), second = CGPoint(x: first.x + length * cos(radians), y: first.y + length * sin(radians))
        a = h.add(Box(CGRect(x: first.x - 40, y: first.y - 30, width: 80, height: 60)))
        b = h.add(Box(CGRect(x: second.x - 40, y: second.y - 30, width: 80, height: 60)))
        func bound(_ id: ShapeID) -> ArrowTerminal {
            .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
        }
        arrow = h.add(Arrow(start: bound(a), end: bound(b), bend: bend, text: MentionText(plain: words)))
        guard typed else { return }
        let person = h.editor.addType(title, at: CGRect(x: 3000, y: 3000, width: 200, height: 60))
        h.editor.addTypeLink(person, to: arrow)
    }

    var editor: CanvasEditor { h.editor }
    var outline: [CGPoint] { editor.shapeContext.geometry(of: arrow)?.outline ?? [] }
    var frames: [AdornmentFrame] { editor.adornmentFrames(of: arrow) }
    var chip: CGRect { frames.first { $0.adornment == .of(TypeChips.self) }?.rect ?? .null }

    /// The least distance from a point of the arrow's body to the rect, sampled every quarter point.
    func nearest(_ rect: CGRect) -> CGFloat {
        var least = CGFloat.infinity
        let points = outline
        for (from, to) in zip(points, points.dropFirst()) {
            let length = hypot(to.x - from.x, to.y - from.y)
            for step in 0...Int(length * 4) {
                let t = length == 0 ? 0 : CGFloat(step) / (length * 4)
                let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
                let dx = max(rect.minX - p.x, 0, p.x - rect.maxX), dy = max(rect.minY - p.y, 0, p.y - rect.maxY)
                least = min(least, hypot(dx, dy))
            }
        }
        return least
    }

    /// The least distance from the arc itself (its drawn body, flattened) to the rect; zero where a point of it is inside.
    /// `outline` is only start, middle and end, so it cannot see a bow.
    func nearestArc(_ rect: CGRect) -> CGFloat {
        guard let geometry = editor.arrowGeometry(of: arrow) else { return .infinity }
        return flattened(geometry.bodyPath).map { hypot(max(rect.minX - $0.x, 0, $0.x - rect.maxX), max(rect.minY - $0.y, 0, $0.y - rect.maxY)) }.min() ?? .infinity
    }
}

/// A path's points, each curve taken in 200 steps.
private func flattened(_ path: CGPath) -> [CGPoint] {
    var points: [CGPoint] = [], current = CGPoint.zero
    path.applyWithBlock { element in
        let p = element.pointee.points
        switch element.pointee.type {
        case .moveToPoint, .addLineToPoint:
            current = p[0]
            points.append(current)
        case .addQuadCurveToPoint:
            for k in 1...200 {
                let t = CGFloat(k) / 200, u = 1 - t
                points.append(CGPoint(x: u * u * current.x + 2 * u * t * p[0].x + t * t * p[1].x, y: u * u * current.y + 2 * u * t * p[0].y + t * t * p[1].y))
            }
            current = p[1]
        case .addCurveToPoint:
            for k in 1...200 {
                let t = CGFloat(k) / 200, u = 1 - t
                points.append(CGPoint(x: u * u * u * current.x + 3 * u * u * t * p[0].x + 3 * u * t * t * p[1].x + t * t * t * p[2].x,
                                      y: u * u * u * current.y + 3 * u * u * t * p[0].y + 3 * u * t * t * p[1].y + t * t * t * p[2].y))
            }
            current = p[2]
        default: break
        }
    }
    return points
}

private let slantCases: [(String, CGFloat)] = [("level", 0), ("3 falling", 3), ("3 rising", -3), ("10 falling", 10), ("10 rising", -10), ("20 falling", 20),
                                               ("20 rising", -20), ("35 falling", 35), ("35 rising", -35), ("45 falling", 45), ("45 rising", -45),
                                               ("60 falling", 60), ("60 rising", -60), ("upright down", 90), ("upright up", -90)]

@MainActor let slantArrowTests = Suite("A slanted arrow's chip", [
    test("the chip is clear of the arrow's body at every slope, falling and rising, at three zooms") {
        for zoom in [1, 0.5, 2] as [CGFloat] {
            let scale = AdornmentLayout.scale(atZoom: zoom)
            for (name, degrees) in slantCases {
                let board = try SlantBoard(degrees: degrees)
                board.editor.camera = Camera(origin: .zero, zoom: zoom)
                let frames = board.frames
                expectEqual(Set(frames.map(\.adornment)), [.of(TypeChips.self)], "\(name) at \(zoom)")
                for frame in frames {
                    let gap = board.nearest(frame.rect)
                    expect(gap >= (AdornmentLayout.margin - 0.01) * scale, "\(name) at \(zoom): \(frame.adornment) \(gap) from the body, \(frame.rect)")
                }
            }
        }
    },
    test("a level arrow with no words: the chip's middle is the arrow's middle") {
        let board = try SlantBoard(degrees: 0)
        let middle = try require(board.outline.dropFirst().first)
        let anchor = try require(board.editor.adornmentAnchor(of: board.arrow))
        expectEqual(board.chip.midX, middle.x, "the row is centred on the middle of the arrow: a chip of one is centred above it")
        expectEqual(board.chip.maxY, anchor.minY - AdornmentLayout.rowGap)
        // What hangs from the row (the arrow's card, the list at an arrow, the name card) hangs at the chip's left edge, as before.
        expectEqual(anchor.minX, board.chip.minX, "the anchor's left edge is the chip's, now \(board.chip.width / 2) left of the middle, not 60")
        expectEqual(anchor.width, 120)
    },
    test("typing the first character into an arrow with no words moves the row from centred to the label's left edge, and a longer label moves it to the label's") {
        let bare = try SlantBoard(degrees: 0)
        let middle = try require(bare.outline.dropFirst().first)
        expectEqual(bare.chip.minX - middle.x, -bare.chip.width / 2, "no words: centred")
        for words in ["a", "abcdefghij", String(repeating: "label ", count: 14)] {
            let board = try SlantBoard(degrees: 0, words: words)
            let label = try require(board.editor.shapeContext.geometry(of: board.arrow)?.label, "\(words.count) characters: a label")
            let anchorLeft = label.midX - max(label.width, AdornmentLayout.minAnchorWidth) / 2
            // The row starts at the label's anchor, widened to 120 view points about the label's middle (zoom 1), not at the middle.
            expect(abs(board.chip.minX - anchorLeft) < 0.5, "\(words.count) characters: the chip's left edge \(board.chip.minX) is the label's anchor's \(anchorLeft)")
            expect(board.chip.minX < middle.x - board.chip.width / 2 - 10, "\(words.count) characters: the chip is left of where it was centred: \(board.chip.minX - middle.x)")
            expect(board.chip.maxY <= label.minY, "\(words.count) characters: and above the label, not over the words")
        }
        let long = try SlantBoard(degrees: 0, words: String(repeating: "label ", count: 14))
        expect(try require(long.editor.shapeContext.geometry(of: long.arrow)?.label).width > 120, "the long label is wider than the anchor, so its left edge is the row's")
    },
    test("a slanted arrow's chip, centred on the middle, slides only as far as it must: right where the body falls, left where it rises") {
        // Centred, a chip of one reaches half its width either side of the middle; a body at 35 degrees leaves the row (bottom
        // `rowGap` above a point anchor, 9, less the margin, 4) room for 5 / tan 35 less the margin (4) on the clear side: 3.14.
        let reach = (AdornmentLayout.rowGap - AdornmentLayout.margin) / tan(35 * CGFloat.pi / 180) - AdornmentLayout.margin
        let falling = try SlantBoard(degrees: 35), rising = try SlantBoard(degrees: -35)
        let fallingMiddle = try require(falling.outline.dropFirst().first), risingMiddle = try require(rising.outline.dropFirst().first)
        expect(abs(falling.chip.minX - (fallingMiddle.x - reach)) < 0.01, "slid right until its left is \(reach) left of the middle: \(falling.chip) from \(fallingMiddle)")
        expect(abs(rising.chip.maxX - (risingMiddle.x + reach)) < 0.01, "slid left until its right is \(reach) right of the middle: \(rising.chip) from \(risingMiddle)")
    },
    test("the anchor is the middle of the outline, widened and moved along with the row: its left edge is the chip's, with the chip above it") {
        for (name, degrees) in slantCases {
            let board = try SlantBoard(degrees: degrees)
            let middle = try require(board.outline.dropFirst().first)
            let anchor = try require(board.editor.adornmentAnchor(of: board.arrow))
            expectEqual(anchor.minY, middle.y, name)
            expectEqual(anchor.size, CGSize(width: 120, height: 0), name)
            expectEqual(anchor.minX, board.chip.minX, "\(name): what hangs from the anchor (the card, the list at an arrow, the name card) hangs from the chip")
            expect(board.chip.maxY <= anchor.minY, "\(name): above the anchor")
            if degrees == 0 { expectEqual(board.chip.midX, middle.x, name) }
        }
    },
    test("the anchor is the middle of the outline, widened, where there is no row: a plain arrow's, and a level arrow's moved by the centring only") {
        let bare = try SlantBoard(degrees: 35, typed: false)
        let bareMiddle = try require(bare.outline.dropFirst().first)
        expectEqual(bare.editor.adornmentAnchor(of: bare.arrow), CGRect(x: bareMiddle.x - 60, y: bareMiddle.y, width: 120, height: 0))
        let level = try SlantBoard(degrees: 0)
        let middle = try require(level.outline.dropFirst().first)
        expectEqual(level.editor.adornmentAnchor(of: level.arrow), CGRect(x: middle.x - level.chip.width / 2, y: middle.y, width: 120, height: 0))
    },
    test("a type's chips (one, three, one wider than the anchor) and a lock are clear of the body of a straight arrow, with and without words, at every ten degrees and three zooms") {
        var checked = 0
        for words in ["", "employs", String(repeating: "this arrow says a great deal more than one line can hold ", count: 2)] {
            for reverse in [false, true] {
                for degrees in stride(from: -90, through: 90, by: 10).map({ CGFloat($0) }) {
                    let board = try SlantFixturesBoard(degrees: degrees, words: words, reverse: reverse)
                    for zoom in [0.5, 1, 2] as [CGFloat] {
                        board.editor.camera = Camera(origin: .zero, zoom: zoom)
                        let scale = AdornmentLayout.scale(atZoom: zoom)
                        for (shows, arrow) in board.arrows {
                            let outline = board.editor.shapeContext.geometry(of: arrow)?.outline ?? []
                            for frame in board.editor.adornmentFrames(of: arrow) {
                                checked += 1
                                let gap = distance(from: outline, to: frame.rect)
                                expect(gap >= (AdornmentLayout.margin - 0.25) * scale,
                                       "\(degrees) degrees, words \(words.count), reverse \(reverse), zoom \(zoom), \(shows.rawValue): \(frame.adornment) \(frame.rect) is \(gap) from the body")
                            }
                        }
                    }
                }
            }
        }
        expect(checked > 2000, "frames were checked: \(checked)")
    },
    test("on a bent arrow the chip is clear of the line through the middle of the anchor in the chord's direction, the arc's tangent there; the arc itself may still cross it") {
        for bend in [34, -34, 120, -120] as [CGFloat] {
            for words in ["", "employs"] {
                for degrees in stride(from: -90, through: 90, by: 15).map({ CGFloat($0) }) {
                    let board = try SlantBoard(degrees: degrees, bend: bend, words: words)
                    let geometry = try require(board.editor.shapeContext.geometry(of: board.arrow))
                    let first = try require(geometry.outline.first), last = try require(geometry.outline.last)
                    let middle = geometry.label.flatMap { $0.isNull ? nil : CGPoint(x: $0.midX, y: $0.midY) } ?? geometry.outline[geometry.outline.count / 2]
                    let slope = (last.x - first.x) == 0 ? CGFloat.infinity : (last.y - first.y) / (last.x - first.x)
                    for frame in board.frames {
                        let rect = frame.rect.insetBy(dx: -(AdornmentLayout.margin - 0.05), dy: -(AdornmentLayout.margin - 0.05))
                        let crossed: Bool
                        if slope.isInfinite {
                            crossed = rect.minX <= middle.x && middle.x <= rect.maxX
                        } else {
                            let left = middle.y + slope * (rect.minX - middle.x), right = middle.y + slope * (rect.maxX - middle.x)
                            crossed = max(left, right) >= rect.minY && min(left, right) <= rect.maxY
                        }
                        expect(!crossed, "bend \(bend), \(degrees) degrees, words \(words): \(frame.adornment) \(frame.rect) is across the tangent")
                    }
                }
            }
        }
    },
    test("a slid chip is drawn from a view that shows only it, however the arrow slants") {
        for (name, degrees) in slantCases {
            let board = try SlantBoard(degrees: degrees)
            let scale = AdornmentLayout.scale(atZoom: 1)
            for frame in board.frames {
                let area = AdornmentLayout.area(showing: frame.rect, scale: scale)
                expect(board.editor.paintOrder(in: area).contains { $0.id == board.arrow }, "\(name): \(frame.adornment) \(frame.rect) is found by the area of a view that shows it")
            }
        }
    },
    test("turning an arrow by moving a bound note makes no label again that moving it without turning does not") {
        @MainActor func facesMade(turning: Bool) throws -> Int {
            let board = try SlantBoard(degrees: 0)
            _ = board.frames
            let before = board.editor.adornmentFacesMade
            for step in 1...20 {
                let to = turning ? CGPoint(x: 1120, y: 600 + CGFloat(step) * 12) : CGPoint(x: 1120 + CGFloat(step) * 12, y: 600)
                board.editor.transact("Move") { tx in tx.update(board.b, as: Box.self) { $0.frame = CGRect(x: to.x - 40, y: to.y - 30, width: 80, height: 60) } }
                _ = board.frames
            }
            return board.editor.adornmentFacesMade - before
        }
        expectEqual(try facesMade(turning: true), try facesMade(turning: false))
    },
    test("a click on the chip finds it where it is drawn, slid, and not where it was") {
        for (name, degrees) in slantCases {
            let board = try SlantBoard(degrees: degrees)
            let chip = try require(board.frames.first { $0.adornment == .of(TypeChips.self) })
            let button = AnyHashable(AdornmentButton(TypeChips.self, on: board.arrow, tag: chip.tag))
            let drawn = board.editor.camera.toView(CGPoint(x: chip.rect.midX, y: chip.rect.midY))
            expectEqual(board.editor.button(atViewPoint: drawn), button, "\(name): at \(chip.rect)")
            let anchor = try require(board.editor.adornmentAnchor(of: board.arrow))
            if chip.rect.minX > anchor.minX + chip.rect.width + 8 {
                let before = board.editor.camera.toView(CGPoint(x: anchor.minX + 4, y: chip.rect.midY))
                expect(board.editor.button(atViewPoint: before) == nil, "\(name): nothing at the chip's old place")
            }
        }
    },
])

// A second arrow between a pair is stored bent by 34 (arrows.md), and the slide reasons from the chord, so the arc is not held
// clear. With no words, Employment's chip, the row centred, at lengths of 150, 250 and 400 (centre to centre, less the notes), each
// way of bending and level, 10, 20 and 35 degrees either way, the least distance from the arc itself (its drawn body; the outline is
// only start, middle and end and cannot see a bow) to the chip, in points (the margin is 4):
//   bent -34: clear at every length and slope (5.2 at least; it bows away from the row);
//   bent +34: touched by the arc at 150 long rising 10 degrees (a gap of 0); nearer than the margin at 150 long level and
//         falling 10 (2.8, 3.3), and at 250 long falling 10 and rising 10 (3.5, 2.2); clear (3.9 at least) at the rest.
@MainActor let centreBentArrowTests = Suite("A bent arrow's chip, centred", [
    test("with no words, Employment's chip: where the arc touches it, where it comes nearer than the margin, and where it is clear") {
        // A cell is "bend length degrees"; a gap under 0.1 is touched, under 3.6 is nearer than the margin, and the rest is clear (3.8 and more).
        let chipTouched: Set<String> = ["34 150 -10"], chipNear: Set<String> = ["34 150 0", "34 150 10", "34 250 -10", "34 250 10"]
        @MainActor func check(_ what: String, _ name: String, _ gap: CGFloat, touched: Set<String>, near: Set<String>) {
            if touched.contains(name) { expect(gap < 0.1, "\(name): the arc touches the \(what): \(gap)") }
            else if near.contains(name) { expect(gap >= 0.1 && gap < 3.6, "\(name): the arc comes nearer than the margin to the \(what): \(gap)") }
            else { expect(gap >= 3.8, "\(name): the \(what) is clear of the arc: \(gap)") }
        }
        for bend in [34, -34] as [CGFloat] {
            for length in [150, 250, 400] as [CGFloat] {
                for degrees in [0, 10, -10, 20, -20, 35, -35] as [CGFloat] {
                    let board = try SlantBoard(degrees: degrees, length: length, bend: bend, title: "Employment")
                    let name = "\(Int(bend)) \(Int(length)) \(Int(degrees))"
                    check("chip", name, board.nearestArc(board.chip), touched: chipTouched, near: chipNear)
                }
            }
        }
    },
])

/// The least distance from the polyline to the rect, sampled every half point.
@MainActor
private func distance(from points: [CGPoint], to rect: CGRect) -> CGFloat {
    var least = CGFloat.infinity
    for (from, to) in zip(points, points.dropFirst()) {
        let length = hypot(to.x - from.x, to.y - from.y)
        let n = max(1, Int(length * 2))
        for step in 0...n {
            let t = CGFloat(step) / CGFloat(n)
            let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            least = min(least, hypot(max(rect.minX - p.x, 0, p.x - rect.maxX), max(rect.minY - p.y, 0, p.y - rect.maxY)))
        }
    }
    return least
}

// Fixtures of this target's own beside a type's chips: a lock at the row's right end, on the arrows that are given it.
struct SlantShows: OptionSet {
    let rawValue: Int
    static let oneChip = SlantShows(rawValue: 1), threeChips = SlantShows(rawValue: 2), wideChip = SlantShows(rawValue: 4)
    static let lock = SlantShows(rawValue: 8)
}

@MainActor var slantShows: [ShapeID: SlantShows] = [:]

enum SlantLock {}
extension SlantLock: Adornment { static var placement: AdornmentPlacement { .aboveTopRight }; static var order: Order<Self> { .last } }

struct SlantFixturesPlugin: CanvasPlugin {
    var id: PluginID { "slant-fixtures" }
    func register(into registrar: inout PluginRegistrar) {
        func shows(_ shape: ShapeRecord<Arrow>) -> SlantShows { let id = shape.id; return MainActor.assumeIsolated { slantShows[id] ?? [] } }
        registrar.adornment(SlantLock.self, on: Arrow.self) { shows($0).contains(.lock) ? AdornmentLabel(systemImage: "lock") : nil }
    }
}

/// One arrow for each of a set of what an arrow shows, each between two notes `degrees` below the horizontal.
@MainActor
private struct SlantFixturesBoard {
    let h: EditorHarness
    var arrows: [(SlantShows, ShapeID)] = []
    var editor: CanvasEditor { h.editor }

    init(degrees: CGFloat, words: String, reverse: Bool) throws {
        h = try EditorHarness(plugins: arrowsPlugins(more: [DetailPanelPlugin(), LabelFixturesPlugin(), SlantFixturesPlugin()]))
        let shown: [SlantShows] = [.oneChip, .threeChips, .wideChip, [.oneChip, .lock], [.threeChips, .lock], [.wideChip, .lock]]
        let radians = degrees * CGFloat.pi / 180
        for (i, set) in shown.enumerated() {
            let first = CGPoint(x: 600, y: 600 + CGFloat(i) * 1400), second = CGPoint(x: first.x + 520 * cos(radians), y: first.y + 520 * sin(radians))
            let a = h.add(Box(CGRect(x: first.x - 40, y: first.y - 30, width: 80, height: 60)))
            let b = h.add(Box(CGRect(x: second.x - 40, y: second.y - 30, width: 80, height: 60)))
            func bound(_ id: ShapeID) -> ArrowTerminal {
                .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
            }
            let arrow = h.add(Arrow(start: bound(reverse ? b : a), end: bound(reverse ? a : b), text: MentionText(plain: words)))
            slantShows[arrow] = set.subtracting([.oneChip, .threeChips, .wideChip])
            let titles = set.contains(.threeChips) ? ["Employment", "Manager", "Owner"]
                : set.contains(.wideChip) ? ["A rather long relationship type title that is wider than the anchor"] : set.contains(.oneChip) ? ["Employment"] : []
            for (k, title) in titles.enumerated() {
                let type = h.editor.addType(title, at: CGRect(x: 3000 + CGFloat(k) * 300, y: 3000 + CGFloat(i) * 100, width: 200, height: 60))
                h.editor.addTypeLink(type, to: arrow)
            }
            arrows.append((set, arrow))
        }
    }
}
