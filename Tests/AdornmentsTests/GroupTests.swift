import Adornments
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TestKit

// Several labels from one adornment (a group): each a chip of its own, in order, at the row's left
// end only; shown whole or folded, the first that doesn't fit and those after it, into one "+N"
// chip, shown if it fits; a chip's hover, press and click told apart by its tag; a long title
// before a group leaving the "+N" chip its width.

let rowY: CGFloat = -27

/// A group's items: `widths` chips, each folded, with those after it, into `overflow` wide.
func group(_ widths: [CGFloat], overflow: CGFloat = 22, id: Int = 0) -> [Item] {
    widths.map { Item(.aboveTopLeft, width: $0, isText: true, group: id, overflowWidth: overflow) }
}

@MainActor let groupLayoutTests = Suite("Laying out a group of adornments", [
    test("a group's chips are in order, 4 points apart, at the left end of the row") {
        expectEqual(AdornmentLayout.frames(of: group([40, 50, 30]), width: 300), [rect(0, rowY, 40, 18), rect(44, rowY, 50, 18), rect(98, rowY, 30, 18)])
    },
    test("a chip is whole or not at all: the first that doesn't fit and those after it are one \"+N\" chip, if that fits") {
        let chips = group([40, 40, 40, 40])
        // Two fit whole (to 84); the third has 32 points, not 40: it and the fourth fold.
        expectEqual(AdornmentLayout.frames(of: chips, width: 120), [rect(0, rowY, 40, 18), rect(44, rowY, 40, 18), rect(88, rowY, 22, 18), nil])
        expectEqual(AdornmentLayout.frames(of: chips, width: 128), [rect(0, rowY, 40, 18), rect(44, rowY, 40, 18), rect(88, rowY, 22, 18), nil],
                    "the third would fit whole, but then the fourth's \"+1\" wouldn't: it folds into a \"+2\"")
        expectEqual(AdornmentLayout.frames(of: chips, width: 162), [rect(0, rowY, 40, 18), rect(44, rowY, 40, 18), rect(88, rowY, 40, 18), rect(132, rowY, 30, 18)], "the fourth, the last, cut short at 30")
        // The "+N" is shown whole or not at all: 21 points of room is too few for 22.
        expectEqual(AdornmentLayout.frames(of: chips, width: 109), [rect(0, rowY, 40, 18), rect(44, rowY, 22, 18), nil, nil], "21 points for the \"+2\": the second folds with them, into the \"+3\"")
        expectEqual(AdornmentLayout.frames(of: chips, width: 110), [rect(0, rowY, 40, 18), rect(44, rowY, 40, 18), rect(88, rowY, 22, 18), nil])
        // Nothing fits whole: the "+N" for all of them stands alone.
        expectEqual(AdornmentLayout.frames(of: chips, width: 30), [rect(0, rowY, 22, 18), nil, nil, nil])
        expectEqual(AdornmentLayout.frames(of: chips, width: 21), [nil, nil, nil, nil])
    },
    test("the group's last chip may be cut short like any text, 30 points at least; with less it folds into \"+1\"") {
        let chips = group([40, 40, 40])
        expectEqual(AdornmentLayout.frames(of: chips, width: 130)[2], rect(88, rowY, 40, 18), "whole")
        expectEqual(AdornmentLayout.frames(of: chips, width: 120)[2], rect(88, rowY, 32, 18), "cut short")
        expectEqual(AdornmentLayout.frames(of: chips, width: 118)[2], rect(88, rowY, 30, 18), "30")
        expectEqual(AdornmentLayout.frames(of: chips, width: 117)[2], rect(88, rowY, 22, 18), "29 points of room: the \"+1\"")
        // Only the last is cut short: the one before it, short of room, folds with it.
        expectEqual(AdornmentLayout.frames(of: chips, width: 100), [rect(0, rowY, 40, 18), rect(44, rowY, 22, 18), nil], "the second folds with the third, into the \"+2\"")
        expectEqual(AdornmentLayout.frames(of: chips, width: 70), [rect(0, rowY, 40, 18), rect(44, rowY, 22, 18), nil])
    },
    test("a chip that isn't text is whole or folded, and so is the last") {
        let discs = (0..<3).map { _ in Item(.aboveTopLeft, width: 18, isText: false, group: 0, overflowWidth: 22) }
        expectEqual(AdornmentLayout.frames(of: discs, width: 60), [rect(0, rowY, 18, 18), rect(22, rowY, 22, 18), nil], "16 points for the third, and the second folds into its \"+2\"")
        expectEqual(AdornmentLayout.frames(of: discs, width: 62)[2], rect(44, rowY, 18, 18), "18")
    },
    test("a title before a group leaves the group's \"+N\" its width: a long title can't hide every chip") {
        let title = Item(.aboveTopLeft, width: 500, isText: true)
        let chips = group([40, 40, 40], overflow: 22)
        // 200 wide: the title gets all but the gap and the "+3" (22), and the "+3" has no more room than that.
        expectEqual(AdornmentLayout.frames(of: [title] + chips, width: 200), [rect(0, rowY, 174, 18), rect(178, rowY, 22, 18), nil, nil])
        expectEqual(AdornmentLayout.frames(of: [title], width: 200), [rect(0, rowY, 200, 18)], "with no group, the title has the row")
        // A title that is short keeps its width, and the chips theirs.
        expectEqual(AdornmentLayout.frames(of: [Item(.aboveTopLeft, width: 60, isText: true)] + chips, width: 300).compactMap { $0 }.count, 4)
        // The title always keeps the room it needs to show at all (30); the chips then have what's left.
        expectEqual(AdornmentLayout.frames(of: [title] + chips, width: 40), [rect(0, rowY, 30, 18), nil, nil, nil])
        expectEqual(AdornmentLayout.frames(of: [title] + chips, width: 60), [rect(0, rowY, 34, 18), rect(38, rowY, 22, 18), nil, nil])
        // The right end's items are placed first, and the title and the chips share what they leave.
        let flag = Item(.aboveTopRight, width: 18, isText: false)
        expectEqual(AdornmentLayout.frames(of: [title, flag] + chips, width: 200).compactMap { $0 }.map(\.width), [152, 18, 22])
    },
    test("when the \"+N\" doesn't fit after the chips shown, the later chips fold into it, back toward the front, so what folds is never unsaid") {
        let chips = group([46, 60, 68, 56], overflow: 26)
        // Two fit whole (to 110), the third has 16 points less than it needs, and the "+2" needs 26: the second folds too.
        expectEqual(AdornmentLayout.frames(of: chips, width: 130), [rect(0, rowY, 46, 18), rect(50, rowY, 26, 18), nil, nil])
        expectEqual(AdornmentLayout.frames(of: chips, width: 139), [rect(0, rowY, 46, 18), rect(50, rowY, 26, 18), nil, nil], "one short of the \"+2\" fitting")
        expectEqual(AdornmentLayout.frames(of: chips, width: 140), [rect(0, rowY, 46, 18), rect(50, rowY, 60, 18), rect(114, rowY, 26, 18), nil])
        // Not even the second chip fits whole beside the first: the "+3".
        expectEqual(AdornmentLayout.frames(of: chips, width: 100), [rect(0, rowY, 46, 18), rect(50, rowY, 26, 18), nil, nil])
        // Nor the first beside its own "+4"'s room: the "+4" stands alone, and the title, as always, gives way first.
        expectEqual(AdornmentLayout.frames(of: chips, width: 60), [rect(0, rowY, 26, 18), nil, nil, nil])
        expectEqual(AdornmentLayout.frames(of: chips, width: 25), [nil, nil, nil, nil])
        // After a short title.
        let title = Item(.aboveTopLeft, width: 20, isText: true)
        expectEqual(AdornmentLayout.frames(of: [title] + group([30, 30, 30, 30], overflow: 26), width: 100),
                    [rect(0, rowY, 20, 18), rect(24, rowY, 30, 18), rect(58, rowY, 26, 18), nil, nil])
        // After a long one, which keeps 30 points and leaves the rest.
        let long = Item(.aboveTopLeft, width: 500, isText: true)
        expectEqual(AdornmentLayout.frames(of: [long] + chips, width: 100), [rect(0, rowY, 70, 18), rect(74, rowY, 26, 18), nil, nil, nil])
    },
    test("four type chips after a title pill, at a sticky note's 200 and 230: the \"+N\" is always said") {
        // A pill 70 wide, then Person, Employee, Contractor, Manager; a "+N" is 26.
        let items = [Item(.aboveTopLeft, width: 70, isText: true)] + group([44, 60, 72, 56], overflow: 26)
        // 200: Contractor doesn't fit whole and neither would a "+2" after Employee, so Employee folds too.
        expectEqual(AdornmentLayout.frames(of: items, width: 200), [rect(0, rowY, 70, 18), rect(74, rowY, 44, 18), rect(122, rowY, 26, 18), nil, nil])
        // 230: the "+2" fits after Employee.
        expectEqual(AdornmentLayout.frames(of: items, width: 230), [rect(0, rowY, 70, 18), rect(74, rowY, 44, 18), rect(122, rowY, 60, 18), rect(186, rowY, 26, 18), nil])
        // A title that fills the row gives way to the "+4", which stands alone after it.
        let long = [Item(.aboveTopLeft, width: 400, isText: true)] + group([44, 60, 72, 56], overflow: 26)
        expectEqual(AdornmentLayout.frames(of: long, width: 200), [rect(0, rowY, 170, 18), rect(174, rowY, 26, 18), nil, nil, nil])
        // At every width, a group with chips left out shows a "+N", unless it shows nothing.
        for width in stride(from: CGFloat(0), through: 400, by: 1) {
            let frames = AdornmentLayout.frames(of: items, width: width)
            let chips = frames.dropFirst()
            guard chips.contains(where: { $0 == nil }), let last = chips.last(where: { $0 != nil }) else { continue }
            expectEqual(last?.width, 26, "the last chip shown is a \"+N\" at \(width)")
        }
    },
    test("a group's chips aren't a title: they don't make the right end take its compact face") {
        let flag = Item(.aboveTopRight, width: 60, isText: false, compact: .init(width: 18))
        let frames = AdornmentLayout.frames(of: group([40, 40, 40]) + [flag], width: 120)
        expectEqual(frames.last, rect(60, rowY, 60, 18), "in full")
        let title = Item(.aboveTopLeft, width: 100, isText: true)
        expectEqual(AdornmentLayout.frames(of: [title, flag], width: 120).last, rect(102, rowY, 18, 18), "but a title does")
    },
    test("whatever the groups and the width: none overlaps another, the left end stays over the shape, a fold is the last of its group, and only a group's last is cut short") {
        var random = SeededGenerator(seed: 4242)
        var cases = 0, folds = 0, cut = 0
        for width in stride(from: CGFloat(0), through: 400, by: 1) {
            for _ in 0..<12 {
                var items: [Item] = []
                if Bool.random(using: &random) { items.append(Item(.aboveTopLeft, width: CGFloat(Int.random(in: 20...300, using: &random)), isText: true)) }
                if Bool.random(using: &random) { items.append(Item(.aboveTopRight, width: CGFloat(Int.random(in: 14...40, using: &random)), isText: false)) }
                let counts = (0..<Int.random(in: 1...2, using: &random)).map { _ in Int.random(in: 1...6, using: &random) }
                for (g, count) in counts.enumerated() {
                    items += group((0..<count).map { _ in CGFloat(Int.random(in: 14...90, using: &random)) }, overflow: CGFloat(Int.random(in: 16...30, using: &random)), id: g)
                }
                let frames = AdornmentLayout.frames(of: items, width: width)
                cases += 1
                for (i, frame) in frames.enumerated() {
                    guard let frame else { continue }
                    if items[i].placement == .aboveTopLeft {
                        expect(frame.minX >= 0 && frame.maxX <= width, "\(frame) off the shape, width \(width): \(items)")
                    }
                    for other in frames[(i + 1)...].compactMap({ $0 }) where frame.intersects(other) {
                        expect(false, "\(frame) and \(other) overlap, width \(width): \(items)")
                    }
                }
                for g in 0..<counts.count {
                    let members = items.indices.filter { items[$0].group == g }
                    // Shown from the first, in a run: once one isn't, none after is.
                    let shown = members.map { frames[$0] != nil }
                    // What folds is said: a group with chips left out and some shown ends in its "+N".
                    if shown.contains(false), shown.contains(true), let last = members.last(where: { frames[$0] != nil }) {
                        expect(frames[last]?.width == items[last].overflowWidth, "the last chip shown is the fold, width \(width): \(items)")
                    }
                    expect(!zip(shown, shown.dropFirst()).contains { !$0 && $1 }, "a group's chips are a run from its first: \(shown), width \(width): \(items)")
                    for (position, i) in members.enumerated() {
                        guard let frame = frames[i] else { continue }
                        let isLast = position == members.count - 1, isFold = frame.width == items[i].overflowWidth && frame.width != items[i].width
                        if isFold { folds += 1 }
                        if frame.width < items[i].width, !isFold {
                            cut += 1
                            expect(isLast && frame.width >= AdornmentLayout.minTextRoom, "cut short but for the last, or to under 30: \(frame), width \(width): \(items)")
                        }
                        if !isFold, !isLast { expectEqual(frame.width, items[i].width, "whole, width \(width): \(items)") }
                        if isFold { expect(members[(position + 1)...].allSatisfy { frames[$0] == nil }, "nothing after a fold: width \(width): \(items)") }
                    }
                }
            }
        }
        expect(folds > cases / 10 && cut > cases / 50, "the cases reach folds and cut chips: \(folds), \(cut) of \(cases)")
    },
])

// On a board: a group's chips as an editor lays them out, points at and draws them.

let names = ["Alexander", "Benjamin", "Charlotte", "Dominique"]

/// A box `width` wide with a group of chips, `names`, its chips' frames in the order claimed.
@MainActor func boxWithChips(_ names: [String], width: CGFloat, zoom: CGFloat = 1) throws -> (h: EditorHarness, box: ShapeID, frames: [AdornmentFrame]) {
    let h = try adornedHarness([chipsPlugin(names)])
    h.editor.camera = Camera(origin: .zero, zoom: zoom)
    let box = h.add(Box(CGRect(x: 100, y: 100, width: width, height: 120)))
    return (h, box, h.editor.adornmentFrames(of: box))
}

/// A box just wide enough for the first two of `names` whole and the third not, but the "+2" that
/// stands for the third and fourth.
@MainActor func foldingWidth() throws -> CGFloat {
    let widths = try boxWithChips(names, width: 600).frames.map(\.rect.width)
    return widths[0] + widths[1] + 8 + widths[2] - 1
}

@MainActor func center(_ h: EditorHarness, _ frame: AdornmentFrame) -> CGPoint {
    let rect = h.editor.camera.toView(frame.rect)
    return CGPoint(x: rect.midX, y: rect.midY)
}

@MainActor let groupTests = Suite("A group of adornments on a board", [
    test("each label is a chip of its own, in order, 4 points apart, tagged, with the row above the shape") {
        let (_, _, frames) = try boxWithChips(names, width: 600)
        expectEqual(frames.map(\.label.text), names)
        expectEqual(frames.map(\.tag), names.map { AdornmentTag($0) })
        expectEqual(frames.map(\.isOverflow), [false, false, false, false])
        expectEqual(Set(frames.map(\.adornment)), [.of(Chips.self)])
        expectEqual(frames[0].rect.minX, 100)
        expectEqual(frames[0].rect.minY, 73)
        for (a, b) in zip(frames, frames.dropFirst()) { expectEqual(b.rect.minX - a.rect.maxX, 4) }
        // A label that says nothing is left out, and the rest keep their order.
        let blank = try boxWithChips(["Alexander", "  ", "Charlotte"], width: 600).frames
        expectEqual(blank.map(\.label.text), ["Alexander", "Charlotte"])
        expectEqual(try boxWithChips([], width: 600).frames, [])
    },
    test("with less room, a chip is whole or not at all, and the first that doesn't fit and those after it are one \"+N\" chip") {
        let wide = try boxWithChips(names, width: 600).frames
        let (_, _, frames) = try boxWithChips(names, width: try foldingWidth())
        expectEqual(frames.map(\.label.text), ["Alexander", "Benjamin", "+2"])
        expectEqual(frames.map(\.isOverflow), [false, false, true])
        expectEqual(frames.map(\.tag), [AdornmentTag("Alexander"), AdornmentTag("Benjamin"), nil])
        expectEqual(frames[0].rect.width, wide[0].rect.width, "whole")
        expectEqual(frames[2].rect.minX, frames[1].rect.maxX + 4, "the \"+2\" after the last that fit")
        // The "+N" is shown whole or not at all: with 4 points less than the "+2" takes, none is.
        let tight = try boxWithChips(names, width: wide[0].rect.width + frames[2].rect.width).frames
        expectEqual(tight.map(\.label.text), ["+4"], "no room for the \"+3\": the first folds too, into the \"+4\"")
    },
    test("the pointer over a chip hovers that chip, and a press presses it; the \"+N\" is its own button") {
        let (h, box, frames) = try boxWithChips(names, width: try foldingWidth())
        h.move(to: center(h, frames[1]))
        expectEqual(h.editor.hoveredButton, AnyHashable(AdornmentButton(Chips.self, on: box, tag: AdornmentTag("Benjamin"))))
        expectEqual(h.editor.cursor, .pointingHand)
        h.move(to: center(h, frames[0]))
        expectEqual(h.editor.hoveredButton, AnyHashable(AdornmentButton(Chips.self, on: box, tag: AdornmentTag("Alexander"))))
        h.press(at: center(h, frames[0]))
        expectEqual(h.editor.pressedButton, AnyHashable(AdornmentButton(Chips.self, on: box, tag: AdornmentTag("Alexander"))))
        h.release()
        h.move(to: center(h, frames[2]))
        expectEqual(h.editor.hoveredButton, AnyHashable(AdornmentButton.overflow(of: Chips.self, on: box)))
        expect(AdornmentButton.overflow(of: Chips.self, on: box) != AdornmentButton(Chips.self, on: box), "not an untagged chip")
        h.move(to: CGPoint(x: 400, y: 280))
        expectEqual(h.editor.hoveredButton, nil)
    },
    test("a click says which chip, and where it is in world units, at every zoom; the \"+N\" says it is one") {
        for zoom in [1, 0.5, 2] as [CGFloat] {
            clicked = []
            clicks = []
            let (h, box, frames) = try boxWithChips(names, width: try foldingWidth() / zoom, zoom: zoom)
            expectEqual(frames.count, 3, "at \(zoom): two whole and the \"+2\"")
            h.click(at: center(h, frames[1]))
            h.click(at: center(h, frames[2]))
            expectEqual(clicked, [box, box])
            expectEqual(clicks, [AdornmentClick(shape: box, tag: AdornmentTag("Benjamin"), rect: frames[1].rect),
                                 AdornmentClick(shape: box, tag: nil, rect: frames[2].rect, isOverflow: true)], "at \(zoom)")
            expectEqual(h.editor.selectedShapeIDs, [], "a chip is a button: the shape isn't selected")
        }
    },
    test("a group that isn't clickable is its shape's: no button, and the shape is hovered") {
        let h = try adornedHarness([Contributor(id: "plain") { $0.adornmentsForEveryShape(PlainChips.self) { _, _ in [chip("a"), chip("b")] } }])
        let box = h.add(Box(boxFrame))
        let frames = h.editor.adornmentFrames(of: box)
        expectEqual(frames.count, 2)
        h.move(to: center(h, frames[0]))
        expectEqual(h.editor.hoveredButton, nil)
        expectEqual(h.editor.hovered, box)
    },
    test("a group is refused anywhere but the row's left end, with its adornment and its plugin named") {
        let base: [any CanvasPlugin] = [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), AdornmentsPlugin()]
        expectThrows(RegistryError.invalid(point: "ShapeAdornments", reason: "AdornmentsTests.RightChips (from groups) shows several labels, which only aboveTopLeft allows, not aboveTopRight")) {
            _ = try Registry(plugins: base + [Contributor(id: "groups") { $0.adornmentsForEveryShape(RightChips.self) { _, _ in [chip("a")] } }])
        }
        expectThrows(RegistryError.invalid(point: "ShapeAdornments", reason: "AdornmentsTests.CornerChips (from groups) shows several labels, which only aboveTopLeft allows, not onTopRightCorner")) {
            _ = try Registry(plugins: base + [Contributor(id: "groups") { $0.adornments(CornerChips.self, on: Box.self) { _ in [chip("a")] } }])
        }
        _ = try Registry(plugins: base + [chipsPlugin(["a"])])
        // One label at the right end is as it was.
        _ = try Registry(plugins: base + [everyShape(Flag.self) { _ in flagLabel }])
    },
    test("a group on a kind of its own is the same, and a kind's own takes the place of an every-shape one") {
        let h = try adornedHarness([GroupSignsPlugin(), chipsPlugin(["Zed"])])
        let sign = h.add(Sign(boxFrame, text: "Ann Bob"))
        let box = h.add(Box(boxFrame))
        expectEqual(h.editor.adornmentFrames(of: sign).filter { $0.adornment == .of(Chips.self) }.map(\.label.text), ["Ann", "Bob"], "the sign's own")
        expectEqual(h.editor.adornmentFrames(of: box).map(\.label.text), ["Zed"], "every other shape's")
    },
    test("`adornmentsDidChange` makes a renamed chip again, and its tag stays where the pointer was") {
        let h = try adornedHarness([Contributor(id: "named") { r in
            r.service { _ in Names() }
            r.adornmentsForEveryShape(Chips.self) { _, context in (context.service(Names.self)?.names ?? []).map { AdornmentLabel($0.1).tagged(AdornmentTag($0.0)) } }
        }])
        let box = h.add(Box(boxFrame))
        let service = try require(h.editor.service(Names.self))
        service.names = [("a", "Ann"), ("b", "Bob")]
        h.editor.adornmentsDidChange(for: [box])
        expectEqual(h.editor.adornmentFrames(of: box).map(\.label.text), ["Ann", "Bob"])
        let before = h.editor.adornmentFrames(of: box)
        h.move(to: center(h, before[1]))
        expectEqual(h.editor.hoveredButton, AnyHashable(AdornmentButton(Chips.self, on: box, tag: AdornmentTag("b"))))
        service.names = [("a", "Annabelle"), ("b", "Robert")]
        h.editor.adornmentsDidChange(for: [box])
        expectEqual(h.editor.adornmentFrames(of: box).map(\.label.text), ["Annabelle", "Robert"])
        expectEqual(h.editor.adornmentFrames(of: box).map(\.tag), [AdornmentTag("a"), AdornmentTag("b")], "tagged by what they name, not what they say")
    },
    test("each chip draws in its frame and nowhere else, the \"+N\" too") {
        for width in [600, try foldingWidth()] as [CGFloat] {
            let (plain, adorned, h) = try renders([chipsPlugin(names)]) { $0.add(Box(CGRect(x: 100, y: 100, width: width, height: 120))) }
            let frames = viewRects(h, h.editor.document.shapes[0].id)
            expect(frames.count >= 3)
            var inside = 0
            for frame in frames {
                let changed = changedPixels(plain, adorned, in: frame.insetBy(dx: -1, dy: -1).integral)
                expect(changed > 100, "a chip draws: \(changed)")
                inside += changed
            }
            expectEqual(changedPixels(plain, adorned, in: wholeView) - inside, 0, "and nowhere else")
        }
    },
    test("the hovered chip is drawn lighter and the others as they were") {
        let (h, _, frames) = try boxWithChips(names, width: 600)
        let idle = render(h)
        h.move(to: center(h, frames[1]))
        let hovered = render(h)
        let rects = frames.map { h.editor.camera.toView($0.rect).insetBy(dx: -1, dy: -1).integral }
        expect(changedPixels(idle, hovered, in: rects[1]) > 100, "the hovered one")
        for other in [0, 2, 3] { expectEqual(changedPixels(idle, hovered, in: rects[other]), 0, "chip \(other)") }
    },
    test("zoomed out, below 35%, no chip is made, laid out or drawn; at 35% each is drawn") {
        let h = try adornedHarness([chipsPlugin(names)])
        let box = h.add(Box(world(boxFrame, atZoom: 0.3)))
        h.editor.camera = Camera(origin: .zero, zoom: 0.3)
        let made = h.editor.adornmentFacesMade
        expectEqual(h.editor.adornmentFrames(of: box), [])
        _ = render(h)
        expectEqual(h.editor.adornmentFacesMade, made, "none measured")
        expectEqual(h.editor.adornmentFacesKept, 0)
        h.editor.skeletonZoom = 0.2                                 // in full at 30%
        expect(h.editor.adornmentFrames(of: box).count >= 1, "in full, there are")
    },
])

/// Chips from a service, which tell Adornments when they change.
@MainActor final class Names: EditorService {
    var names: [(String, String)] = []
}

/// A group at the row's left end that nothing clicks.
enum PlainChips {}
extension PlainChips: Adornment {
    static var placement: AdornmentPlacement { .aboveTopLeft }
}

/// A sign (a kind of this target's) with its own group: one chip for each word of its text.
struct GroupSignsPlugin: CanvasPlugin {
    var id: PluginID { "group-signs" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.adornments(Chips.self, on: Sign.self) { sign in sign.props.text.split(separator: " ").map { chip(String($0)) } }
    }
}
