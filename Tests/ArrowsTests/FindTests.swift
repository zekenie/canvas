import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Find
import Keyboard
import Selection
import TableOfContents
import TestKit

// Arrows' labels for Find (`ArrowFindPlugin`): the label's text, and where each hit is drawn, from
// the label's own layout.

/// A free arrow from (100, 200) to (500, 200) labelled `text`, with Find and arrows' labels.
@MainActor private func labelledArrow(_ text: String) throws -> (EditorHarness, ShapeID) {
    let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), ArrowsPlugin(), TableOfContentsPlugin(),
                                        FindPlugin(), ArrowFindPlugin()])
    let id = h.add(Arrow(start: .free(CGPoint(x: 100, y: 200)), end: .free(CGPoint(x: 500, y: 200)), text: text))
    return (h, id)
}

@MainActor private func search(_ query: String, in h: EditorHarness) throws -> FindState {
    let find = try require(h.editor.find)
    if !find.isActive { find.open() }
    find.query = query
    while find.isIndexing { h.wait(0) }
    _ = try awaitResult { await find.settled() }
    return find
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

@MainActor let arrowFindTests = Suite("Arrows' labels for Find", [
    test("a label is found by its text; an arrow without one isn't searched") {
        let (h, id) = try labelledArrow("calls home")
        _ = h.add(Arrow(start: .free(CGPoint(x: 100, y: 400)), end: .free(CGPoint(x: 500, y: 400))))
        let find = try search("home", in: h)
        expectEqual(find.results.map(\.id), [id])
        expectEqual(find.texts(of: id), ["calls home"])
        expectEqual(find.indexedShapes, 1)
    },
    test("a hit is where its word's ink is, in the label's frame; washed over the canvas") {
        let (h, id) = try labelledArrow("calls home")
        let find = try search("home", in: h)
        let frame = try require(h.editor.arrowLabelFrame(of: id))
        let hit = try require(find.currentHit?.hit)
        let word = try require(find.rects(of: hit, in: id).first)
        expect(frame.contains(word), "\(word) in the label \(frame)")
        let washed = renderBitmap(h.editor, size: CGSize(width: 600, height: 400))
        find.close()
        let image = renderBitmap(h.editor, size: CGSize(width: 600, height: 400))
        let ink = try require(inkExtent(image, band: (word.minY + 3)...(word.maxY - 3), from: word.minX - 2, to: frame.maxX))
        expect(ink.lowerBound >= word.minX - 1 && ink.upperBound <= word.maxX + 1, "the word's ink \(ink) is inside \(word)")
        expect(word.minX >= ink.lowerBound - 3 && word.maxX <= ink.upperBound + 3, "and the rect hugs it")
        let spot = CGPoint(x: word.minX + 1, y: word.minY + 1)
        expect(pixel(washed, at: spot) != pixel(image, at: spot), "washed: \(pixel(washed, at: spot))")
        let before = CGPoint(x: frame.minX + 6, y: word.minY + 1)
        expectEqual(pixel(washed, at: before), pixel(image, at: before), "the first word isn't")
    },
])
