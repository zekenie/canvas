import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Find
import Mentions
import TestKit
import Titles

// Mention text for Find (`MentionFindPlugin`): a jot's text as it reads, each mention its target's
// live name, and where each hit is drawn, from the render's own layout.

/// Mentions' fixtures with Find and its mention text; a plate named "Groceries" (`idA`) and a jot
/// that mentions it, "Ask @Groceries first".
@MainActor private func findHarness() throws -> (EditorHarness, jot: ShapeID) {
    let h = try mentionHarness([FindPlugin(), MentionFindPlugin()])
    h.editor.add(Plate(CGRect(x: 600, y: 100, width: 120, height: 80)), titled: "Groceries", id: idA)
    let jot = h.add(Jot(CGRect(x: 100, y: 100, width: 300, height: 120), text: MentionText([.text("Ask "), .mention(idA, label: "Old"), .text(" first")])))
    return (h, jot)
}

/// Opens Find on `query`, its index built and its search answered.
@MainActor private func search(_ query: String, in h: EditorHarness) throws -> FindState {
    let find = try require(h.editor.find)
    if !find.isActive { find.open() }
    find.query = query
    while find.isIndexing { h.wait(0) }
    _ = try awaitResult { await find.settled() }
    return find
}

/// A kind whose text is drawn over the canvas itself, with no surface of its own, as an arrow's label
/// is: one placement, `overCanvas`.
struct Banner: BoxShapeProps {
    static let kind: ShapeKind = "banner"
    static let properties = Properties<Banner> {
        Property("frame", \.frame).required()
        Property("text", \.text)
    }
    var frame: CGRect
    var text: MentionText
    init(_ frame: CGRect, text: MentionText = "") {
        self.frame = frame
        self.text = text
    }
}

extension Banner {
    init() { self.init(.zero) }
}

struct BannerDefinition {}

extension BannerDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Banner>, in context: RenderContext) {
        for placement in shape.mentionTexts(in: context.shapes) { context.drawMentionText(placement) }
    }
}

extension ShapeRecord where Props == Banner {
    /// Centered in its geometry's bounds, which the context says (as an arrow's label is placed by
    /// its geometry): the placement a kind that needs the shapes around it gives.
    @MainActor func mentionTexts(in shapes: ShapeContext) -> [MentionTextPlacement] {
        let bounds = shapes.geometry(of: id)?.bounds ?? props.frame
        let style = MentionTextStyle(font: .systemFont(ofSize: 16), color: .black, lineHeight: 19, alignment: .center)
        return [MentionTextPlacement(props.text, in: bounds.insetBy(dx: JotStyle.padding, dy: JotStyle.padding), style: style, overCanvas: true)]
    }
}

struct BannersPlugin: CanvasPlugin {
    var id: PluginID { "banners" }

    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(BannerDefinition()) { banner in banner.mentionText { banner, shapes in banner.mentionTexts(in: shapes) } }
    }
}

/// The leftmost and rightmost columns of dark ink in a band of a picture, between two x's.
@MainActor private func inkExtent(_ rep: NSBitmapImageRep, band: ClosedRange<CGFloat>, from: CGFloat, to: CGFloat) -> ClosedRange<CGFloat>? {
    var low: CGFloat?, high: CGFloat?
    for x in stride(from: from, to: to, by: 1) {
        for y in stride(from: band.lowerBound, through: band.upperBound, by: 1) where pixel(rep, at: CGPoint(x: x, y: y)).prefix(3).allSatisfy({ $0 < 110 }) {
            low = low ?? x
            high = x
            break
        }
    }
    guard let low, let high else { return nil }
    return low...high
}

@MainActor let mentionFindTests = Suite("Mention text for Find", [
    test("a jot's text as it reads, each mention its target's name now; a rename reads its mentioners again") {
        let (h, jot) = try findHarness()
        let find = try search("groceries", in: h)
        expectEqual(find.results.map(\.id), [jot])
        expectEqual(find.texts(of: jot), ["Ask Groceries first"], "the live name, not the one the mention holds")
        h.editor.transact { $0.update(idA) { $0[TitleProperty.self] = "Shopping" } }
        _ = try awaitResult { await find.settled() }
        expect(find.results.isEmpty, "renamed: groceries no more")
        find.query = "shopping"
        _ = try awaitResult { await find.settled() }
        expectEqual(find.results.map(\.id), [jot])
        expectEqual(find.texts(of: jot), ["Ask Shopping first"])
    },
    test("a hit in a name is its whole pill; a word's is where its ink is") {
        let (h, jot) = try findHarness()
        let find = try search("roce", in: h)
        let pill = try require(h.editor.mentionPills(of: jot).first?.frame)
        let named = find.rects(of: FindHit(text: 0, range: 5..<9), in: jot)
        expectEqual(named.count, 1)
        let rect = try require(named.first)
        expect(abs(rect.minX - pill.minX) < 0.5 && abs(rect.maxX - pill.maxX) < 0.5, "\(rect) against the pill \(pill)")
        expect(rect.minY <= pill.minY && rect.maxY >= pill.maxY, "the line holds the pill: \(rect), \(pill)")

        find.query = "first"
        _ = try awaitResult { await find.settled() }
        let hit = try require(find.currentHit)
        expectEqual(hit.hit.range, 14..<19)
        let word = try require(find.rects(of: hit.hit, in: jot).first)
        find.close()
        let image = renderBitmap(h.editor, size: CGSize(width: 800, height: 400))
        let ink = try require(inkExtent(image, band: (word.minY + 3)...(word.maxY - 3), from: pill.maxX + 1, to: 400))
        expect(ink.lowerBound >= word.minX - 1 && ink.upperBound <= word.maxX + 1, "the word's ink \(ink) is inside \(word)")
        expect(word.minX >= ink.lowerBound - 3 && word.maxX <= ink.upperBound + 3, "and the rect hugs it")
    },
    test("drawing keeps no text layout of a text with pills, only Find's rects do, once") {
        #if DEBUG
        let h = try mentionHarness([FindPlugin(), MentionFindPlugin()])
        h.editor.add(Plate(CGRect(x: 600, y: 100, width: 120, height: 80)), titled: "Groceries", id: idA)
        // Text no other test draws, so the memo has never built it.
        let word = "kept\(UUID().uuidString.prefix(8))"
        let jot = h.add(Jot(CGRect(x: 100, y: 100, width: 300, height: 120), text: MentionText([.text("Ask "), .mention(idA, label: "Old"), .text(" \(word)")])))
        let kept = MentionDrawingCounts.layoutsKept, laidOut = MentionDrawingCounts.layoutsBuilt
        _ = renderBitmap(h.editor, size: CGSize(width: 800, height: 400))
        expect(!h.editor.mentionPills(of: jot).isEmpty, "the pills are where they were")
        expect(MentionDrawingCounts.layoutsBuilt > laidOut, "their places were laid out")
        expectEqual(MentionDrawingCounts.layoutsKept, kept, "drawing kept no layout")
        let find = try search(word, in: h)
        let hit = try require(find.currentHit)
        expect(!find.rects(of: hit.hit, in: jot).isEmpty, "a hit has its rect")
        expectEqual(MentionDrawingCounts.layoutsKept, kept + 1, "Find's rects kept one")
        _ = find.rects(of: hit.hit, in: jot)
        _ = renderBitmap(h.editor, size: CGSize(width: 800, height: 400))
        expectEqual(MentionDrawingCounts.layoutsKept, kept + 1, "and asking again, or drawing, keeps no other")
        #endif
    },
    test("drawn: a hit on the jot is marked over its word, the text still dark over it") {
        let (h, jot) = try findHarness()
        let find = try search("ask", in: h)
        let word = try require(find.rects(of: FindHit(text: 0, range: 0..<3), in: jot).first)
        let image = renderBitmap(h.editor, size: CGSize(width: 800, height: 400))
        find.close()
        let plain = renderBitmap(h.editor, size: CGSize(width: 800, height: 400))
        let spot = CGPoint(x: word.minX + 1, y: word.minY + 1)
        let marked = pixel(image, at: spot), before = pixel(plain, at: spot)
        expect(marked != before && marked[2] < before[2], "marked: \(marked) against \(before)")
        let ink = try require(inkExtent(image, band: (word.minY + 3)...(word.maxY - 3), from: word.minX, to: word.maxX))
        expect(ink.upperBound > ink.lowerBound, "the text is still dark over the mark")
    },
    test("text drawn over the canvas (an arrow's label) is washed where text on a shape's surface is marked: the same words, each in the contribution of its look") {
        let h = try mentionHarness([FindPlugin(), MentionFindPlugin(), BannersPlugin()])
        h.editor.add(Plate(CGRect(x: 600, y: 100, width: 120, height: 80)), titled: "Groceries", id: idA)
        let said = MentionText([.text("Ask "), .mention(idA, label: "Old"), .text(" first")])
        let banner = h.add(Banner(CGRect(x: 100, y: 20, width: 300, height: 60), text: said))
        let jot = h.add(Jot(CGRect(x: 100, y: 200, width: 300, height: 120), text: said))
        let find = try search("ask", in: h)
        expectEqual(Set(find.results.map(\.id)), [banner, jot])
        expectEqual(find.texts(of: banner), ["Ask Groceries first"], "one text: the other contribution has no placement over the canvas to read")
        expectEqual(find.texts(of: jot), ["Ask Groceries first"], "and none on a surface")
        let hit = FindHit(text: 0, range: 0..<3)
        let onBanner = try require(find.rects(of: hit, in: banner).first), onJot = try require(find.rects(of: hit, in: jot).first)
        let size = CGSize(width: 800, height: 400)
        // One hit is the current one, marked deeper; each shape is looked at where it's an ordinary hit.
        let current = try require(find.currentHit).shape
        let first = renderBitmap(h.editor, size: size)
        find.step(forward: true)
        let second = renderBitmap(h.editor, size: size)
        find.close()
        let plain = renderBitmap(h.editor, size: size)
        @MainActor func ordinary(_ shape: ShapeID, _ rect: CGRect) -> (marked: [Int], plain: [Int]) {
            let point = CGPoint(x: rect.minX + 1, y: rect.minY + 1)
            return (pixel(shape == current ? second : first, at: point), pixel(plain, at: point))
        }
        // A marker multiplies orange over what it marks, so blue falls to a quarter; a wash lays a
        // translucent orange over it, so blue stays above half.
        let washed = ordinary(banner, onBanner), highlighted = ordinary(jot, onJot)
        expect(washed.marked != washed.plain && washed.marked[2] * 2 > washed.plain[2], "washed: \(washed.marked) over \(washed.plain)")
        expect(highlighted.marked[2] * 2 < highlighted.plain[2], "marked: \(highlighted.marked) over \(highlighted.plain)")
    },
])
