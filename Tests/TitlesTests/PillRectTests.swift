import Adornments
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import TestKit
import Titles

// Where a shape's title pill is (`editor.titlePillRect(of:)`): what a card that names the shape hangs
// from, and what Find rings. In world units, where the shape is, nil where it shows none.

/// Something at the top-right corner from a plugin Titles doesn't know, as a tally is.
enum CornerTally {}

extension CornerTally: Adornment {
    static var placement: AdornmentPlacement { .onTopRightCorner }
}

@MainActor let pillRectTests = Suite("Where a title pill is", [
    test("a titled shape's pill is its row's frame: from the shape's left edge, 27 points above its top and 18 tall, as long as its title, longer for a longer one") {
        let editor = try titleEditor()
        let id = editor.add(Plaque(plaqueFrame), named: "Lobby")          // its top-left corner at (60, 100)
        let rect = try require(editor.titlePillRect(of: id))
        expectEqual(rect.minX, 60)
        expectEqual(rect.minY, 73)
        expectEqual(rect.height, 18)
        expectEqual(rect, editor.adornmentFrames(of: id).first { $0.adornment == .of(TitlePill.self) }?.rect, "the pill's frame, not another adornment's")
        editor.rename(id, "Lobby and the whole front desk")
        let longer = try require(editor.titlePillRect(of: id))
        expect(longer.width > rect.width, "follows the name: \(longer.width) over \(rect.width)")
        expectEqual(longer.minX, 60)
    },
    test("a shape that shows other adornments has the pill's rect, not the first adornment's") {
        let tallies = Contributor(id: "corner-tallies") { $0.adornmentForEveryShape(CornerTally.self) { _, _ in AdornmentLabel(systemImage: "circle.fill") } }
        let discs = Contributor(id: "corner-discs") { $0.adornmentForEveryShape(CornerDisc.self) { _, _ in AdornmentLabel(systemImage: "circle.fill") } }
        let editor = try titleEditor([tallies, discs])
        let id = editor.add(Plaque(plaqueFrame), named: "Lobby")
        let frames = editor.adornmentFrames(of: id)
        let pill = try require(frames.first { $0.adornment == .of(TitlePill.self) }?.rect)
        expect(frames.count >= 3, "the pill, the disc and the tally are all shown: \(frames.count)")
        expect(frames.contains { $0.rect != pill }, "another adornment has a rect of its own")
        expectEqual(editor.titlePillRect(of: id), pill)
        expectEqual(pill.minX, 60)
    },
    test("it is where the shape is, whatever the zoom: 27 view points above, and as long in view points") {
        let editor = try titleEditor()
        let id = editor.add(Plaque(plaqueFrame), named: "Lobby")
        let full = try require(editor.titlePillRect(of: id))
        editor.camera = Camera(origin: .zero, zoom: 0.5)
        editor.skeletonZoom = 0
        let out = try require(editor.titlePillRect(of: id))
        expectEqual(out.minX, 60)
        expectEqual(out.minY, 100 - 27 * 2, "27 view points are 54 world units at 50%")
        expectClose(out.width, full.width * 2, within: 0.5)
        expectEqual(out.height, 36)
    },
    test("an untitled shape with a placeholder pill has one; a plain untitled shape, a shape whose look hides the pill, and one not on the board have none") {
        let editor = try titleEditor([starPlugin, looks { shape, _ in shape[Starred.self] == true ? TitlePillLook(placeholder: "Unnamed") : nil }])
        let plain = editor.add(Plaque(plaqueFrame))
        expectEqual(editor.titlePillRect(of: plain), nil, "no title, no placeholder")
        editor.star(plain)
        let rect = try require(editor.titlePillRect(of: plain))
        expectEqual(rect.minX, 60)
        expectEqual(editor.titlePillRect(of: ShapeID()), nil, "not on the board")
        let hiding = try titleEditor([starPlugin, looks { _, _ in TitlePillLook(hidesPill: true) }])
        let hidden = hiding.add(Plaque(plaqueFrame), named: "Lobby")
        hiding.star(hidden)
        expectEqual(hiding.titlePillRect(of: hidden), nil)
    },
    test("a shape drawn as a skeleton, zoomed out, has none: its title is its cover") {
        let editor = try titleEditor()
        editor.camera = Camera(origin: .zero, zoom: 0.3)
        let id = editor.add(Plaque(plaqueFrame), named: "Lobby")
        expect(editor.drawsSkeleton(of: id))
        expectEqual(editor.titlePillRect(of: id), nil)
        expect(editor.titleCover(of: id) != nil, "the cover says it instead")
    },
])
