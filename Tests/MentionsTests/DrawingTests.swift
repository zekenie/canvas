import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Geometry
import Mentions
import TestKit
import Titles

// Mention text on the canvas: what `drawMentionText` draws, where `mentionPills(of:)` says each pill
// is, and what's kept between frames. Pixels come from `renderBitmap`, with fixtures of this file's
// own: a scrap, which draws its text through its one placement on white, and an easel, which draws
// whatever a test hands it in the same box, so a test can hold the canvas to string drawing.

/// A white box whose text may mention shapes: drawn in the jot's style (16 points in fixed 19-point
/// lines), or `loose`, in the font's own lines, and in at most `lines` lines (0: as many as fit).
struct Scrap: BoxShapeProps {
    static let kind: ShapeKind = "scrap"
    static let properties = Properties<Scrap> {
        Property("frame", \.frame).required()
        Property("text", \.text)
        Property("loose", \.loose)
        Property("lines", \.lines)
    }
    var frame: CGRect
    var text: MentionText = ""
    var loose = false
    var lines = 0
    init(_ frame: CGRect, text: MentionText = "", loose: Bool = false, lines: Int = 0) {
        self.frame = frame
        self.text = text
        self.loose = loose
        self.lines = lines
    }
}

extension Scrap {
    init() { self.init(.zero) }
}

@MainActor
enum ScrapStyle {
    static let padding: CGFloat = 16
    /// The jot's font and color, in the font's own lines.
    static let loose = MentionTextStyle(font: .systemFont(ofSize: 16), color: NSColor(white: 0.12, alpha: 1))

    static func style(loose: Bool) -> MentionTextStyle { loose ? Self.loose : JotStyle.text }
}

extension ShapeRecord where Props == Scrap {
    @MainActor var placements: [MentionTextPlacement] {
        [MentionTextPlacement(props.text, in: props.frame.insetBy(dx: ScrapStyle.padding, dy: ScrapStyle.padding),
                              style: ScrapStyle.style(loose: props.loose), lines: props.lines > 0 ? props.lines : nil)]
    }
}

struct ScrapDefinition {}

extension ScrapDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Scrap>, in context: RenderContext) {
        context.cg.setFillColor(NSColor.white.cgColor)
        context.cg.fill(shape.frame)
        for placement in shape.placements { context.drawMentionText(placement) }
    }
}

/// A white box that draws, in a scrap's text box, what the test hands `Easel.draw`.
struct Easel: BoxShapeProps {
    static let kind: ShapeKind = "easel"
    static let properties = Properties<Easel> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }

    @MainActor static var draw: ((CGRect) -> Void)?
}

extension Easel {
    init() { self.init(.zero) }
}

struct EaselDefinition {}

extension EaselDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Easel>, in context: RenderContext) {
        context.cg.setFillColor(NSColor.white.cgColor)
        context.cg.fill(shape.frame)
        Easel.draw?(shape.frame.insetBy(dx: ScrapStyle.padding, dy: ScrapStyle.padding))
    }
}

struct ScrapsPlugin: CanvasPlugin {
    var id: PluginID { "scraps" }

    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(ScrapDefinition()) { scrap in
            scrap.mentionText { $0.placements }
        }
        registrar.shape(EaselDefinition())
    }
}

/// Where scraps and easels are drawn, and how big a picture of them is.
private let paper = CGRect(x: 20, y: 20, width: 200, height: 200)
private let pictureSize = CGSize(width: 240, height: 240)

/// A board of plates to mention, far from the paper: A "Groceries", B "Chores", C "Garden party".
@MainActor private final class DrawingBoard {
    let h: EditorHarness
    var editor: CanvasEditor { h.editor }

    init() throws {
        h = try mentionHarness([ScrapsPlugin()])
        editor.add(Plate(CGRect(x: 1000, y: 1000, width: 120, height: 80)), titled: "Groceries", id: idA)
        editor.add(Plate(CGRect(x: 1200, y: 1000, width: 120, height: 80)), titled: "Chores", id: idB)
        editor.add(Plate(CGRect(x: 1400, y: 1000, width: 120, height: 80)), titled: "Garden party", id: idC)
    }

    /// Puts a shape on the paper, and returns its id.
    @discardableResult
    func place<P: ShapeProps>(_ props: P) -> ShapeID { editor.add(props) }

    /// The picture with `props` on the paper, alone, at `scale`; then it's taken off.
    func picture<P: ShapeProps>(of props: P, scale: CGFloat = 2) -> NSBitmapImageRep {
        let id = place(props)
        defer { editor.delete(id) }
        return renderBitmap(editor, size: pictureSize, scale: scale)
    }

    /// The picture of an easel drawing `draw` in the text box.
    func easel(scale: CGFloat = 2, _ draw: @escaping (CGRect) -> Void) -> NSBitmapImageRep {
        Easel.draw = draw
        defer { Easel.draw = nil }
        return picture(of: Easel(paper), scale: scale)
    }

    /// The text as the canvas builds it, each mention as it shows on this board now.
    func string(_ text: MentionText, loose: Bool = false) -> NSAttributedString {
        let state = editor.mentionState
        return ScrapStyle.style(loose: loose).attributedString(text, width: paper.width - 2 * ScrapStyle.padding) { state.resolve($0) }
    }
}

/// The same string, each pill a blank of its size: laid out alike, with no pill drawn.
@MainActor private func withBlankPills(_ string: NSAttributedString) -> NSAttributedString {
    let blank = NSMutableAttributedString(attributedString: string)
    string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: string.length)) { value, range, _ in
        guard let pill = value as? MentionAttachment else { return }
        let standIn = NSTextAttachment()
        standIn.bounds = pill.bounds
        standIn.image = NSImage(size: pill.bounds.size, flipped: false) { _ in true }
        blank.addAttribute(.attachment, value: standIn, range: range)
    }
    return blank
}

/// How tall string drawing makes a line of a font's text, with nothing fixed.
@MainActor private func naturalLineHeight(_ font: NSFont) -> CGFloat {
    NSAttributedString(string: "Hg", attributes: [.font: font]).boundingRect(with: CGSize(width: 1000, height: 1000), options: [.usesLineFragmentOrigin]).height
}

private func draw(_ string: NSAttributedString, in box: CGRect) {
    string.draw(with: box, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
}

/// Pixels a point in a picture.
@MainActor private func scale(of picture: NSBitmapImageRep) -> CGFloat { CGFloat(picture.pixelsWide) / pictureSize.width }

/// The largest difference in any channel between two pictures, over all of them.
@MainActor private func largestDifference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
    largestDifference(a, b, in: CGRect(origin: .zero, size: pictureSize), scale: scale(of: a))
}

/// How many pixels differ between two pictures within a rect of points.
@MainActor private func changed(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, in rect: CGRect) -> Int {
    differences(a, b).count { rect.intersects($0) }
}

/// Every pixel that differs between two pictures of one size, as a rect of points.
@MainActor private func differences(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> [CGRect] {
    let scale = CGFloat(a.pixelsWide) / pictureSize.width
    var p = [Int](repeating: 0, count: 4), q = [Int](repeating: 0, count: 4)
    var found: [CGRect] = []
    for y in 0..<a.pixelsHigh {
        for x in 0..<a.pixelsWide {
            a.getPixel(&p, atX: x, y: y)
            b.getPixel(&q, atX: x, y: y)
            if p != q { found.append(CGRect(x: CGFloat(x) / scale, y: CGFloat(y) / scale, width: 1 / scale, height: 1 / scale)) }
        }
    }
    return found
}

/// Holds each pill's drawn pixels (`drawn`, the pixels that differ where only pills do) to its
/// frame: every one within half a point of some frame, and each frame's pixels spanning it to within
/// half a point.
@MainActor private func expectPills(_ frames: [MentionPillFrame], match drawn: [CGRect], file: StaticString = #fileID, line: UInt = #line) {
    expect(!drawn.isEmpty, "some pill is drawn", file: file, line: line)
    // Half a point, or at 1×, where a pixel is a point, the pixel an edge falls in.
    let slack = max(0.5, drawn.first?.width ?? 0)
    let stray = drawn.filter { pixel in !frames.contains { $0.frame.insetBy(dx: -slack, dy: -slack).contains(pixel) } }
    expect(stray.isEmpty, "\(stray.count) pill pixels outside every frame, the first at \(stray.first.map { "\($0.origin)" } ?? "")",
           file: file, line: line)
    for pill in frames {
        let own = drawn.filter { pill.frame.insetBy(dx: -slack, dy: -slack).contains($0) }
        guard let first = own.first else {
            expect(false, "nothing drawn in \(pill.frame)", file: file, line: line)
            continue
        }
        let box = own.dropFirst().reduce(first) { $0.union($1) }
        let off = [box.minX - pill.frame.minX, box.minY - pill.frame.minY, box.maxX - pill.frame.maxX, box.maxY - pill.frame.maxY]
        expect(off.allSatisfy { abs($0) <= slack }, "drawn at \(box), its frame \(pill.frame)", file: file, line: line)
    }
}

@MainActor let drawingTests = Suite("Drawing", [
    test("text without mentions draws exactly as a plain string with the style's attributes, at 1× and 2×, in fixed lines and the font's") {
        let board = try DrawingBoard()
        let text = "Buy milk and bread for the party,\nthen ask about it tomorrow morning, before the shops close at six."
        for loose in [false, true] {
            for scale in [1, 2] as [CGFloat] {
                let drawn = board.picture(of: Scrap(paper, text: MentionText(plain: text), loose: loose), scale: scale)
                let plain = board.easel(scale: scale) { box in
                    draw(NSAttributedString(string: text, attributes: ScrapStyle.style(loose: loose).attributes), in: box)
                }
                expectEqual(largestDifference(drawn, plain), 0, "loose \(loose), \(scale)×")
                let empty = board.picture(of: Scrap(paper), scale: scale)
                expect(changed(drawn, empty, in: paper) > 100, "it drew the text")
            }
        }
        let escaped = MentionText(plain: "Not a mention: @[Groceries](shape:\(idA))")
        expectEqual(escaped.mentioned, [])
        let drawn = board.picture(of: Scrap(paper, text: escaped))
        let plain = board.easel { box in draw(NSAttributedString(string: escaped.plainText(), attributes: JotStyle.text.attributes), in: box) }
        expectEqual(largestDifference(drawn, plain), 0, "a look-alike is text as it reads")
    },
    test("text with mentions draws exactly the attributed string the style builds, each pill as its shape shows now") {
        let board = try DrawingBoard()
        let text = mentioning([.mention(idA, label: "Old"), .text(" buy milk and bread for the party, then ask "), .mention(idB, label: "B"),
                               .text(" and "), .mention(idC, label: "C"), .text(" about it tomorrow.")])
        for loose in [false, true] {
            for scale in [1, 2] as [CGFloat] {
                let drawn = board.picture(of: Scrap(paper, text: text, loose: loose), scale: scale)
                let string = board.string(text, loose: loose)
                let expected = board.easel(scale: scale) { draw(string, in: $0) }
                expectEqual(largestDifference(drawn, expected), 0, "loose \(loose), \(scale)×")
            }
        }
    },
    test("each pill is drawn where mentionPills says, to within half a point, on several lines, in fixed lines and the font's") {
        let board = try DrawingBoard()
        // Pills alone (and spaces, and line breaks), so every pixel the text adds is a pill's.
        let text = mentioning([.mention(idA, label: "A"), .text(" "), .mention(idB, label: "B"), .text(" "), .mention(idC, label: "C"),
                               .text(" "), .mention(idA, label: "A"), .text("\n\n"), .mention(idB, label: "B"), .text("\n "),
                               .mention(idC, label: "C")])
        for loose in [false, true] {
            for scale in [1, 2] as [CGFloat] {
                let id = board.place(Scrap(paper, text: text, loose: loose))
                let frames = board.editor.mentionPills(of: id)             // laid out before the first frame draws them
                let drawn = renderBitmap(board.editor, size: pictureSize, scale: scale)
                board.editor.delete(id)
                let empty = board.picture(of: Scrap(paper, loose: loose), scale: scale)
                expectEqual(frames.map(\.target), [idA, idB, idC, idA, idB, idC])
                expect(frames.allSatisfy(\.isLive))
                expect(Set(frames.map(\.frame.minY)).count >= 5, "on five lines or more: \(frames.map(\.frame))")
                expect(frames.allSatisfy { paper.insetBy(dx: ScrapStyle.padding, dy: ScrapStyle.padding).contains($0.frame) })
                expectPills(frames, match: differences(drawn, empty))
            }
        }
    },
    test("pills among words are drawn where mentionPills says, to within half a point, zoomed in and out") {
        let board = try DrawingBoard()
        let text = mentioning([.mention(idA, label: "A"), .text(" buy milk and bread for the party, then ask "), .mention(idB, label: "B"),
                               .text(" and "), .mention(idC, label: "C"), .text(" about it tomorrow morning."), .text("\n\n"),
                               .mention(idA, label: "A")])
        for loose in [false, true] {
            let id = board.place(Scrap(paper, text: text, loose: loose))
            let frames = board.editor.mentionPills(of: id)
            board.editor.delete(id)
            expectEqual(frames.map(\.target), [idA, idB, idC, idA])
            expect(Set(frames.map(\.frame.minY)).count >= 3, "on three lines or more: \(frames.map(\.frame))")
            let string = board.string(text, loose: loose)
            let pills = board.easel { draw(string, in: $0) }
            let blanks = board.easel { draw(withBlankPills(string), in: $0) }
            expectPills(frames, match: differences(pills, blanks))
        }
        // Where they are is in world units, whatever the camera.
        let id = board.place(Scrap(paper, text: text))
        let frames = board.editor.mentionPills(of: id)
        board.editor.camera.setZoom(2, around: .zero)
        expectEqual(board.editor.mentionPills(of: id), frames)
        board.editor.camera.setZoom(0.3, around: CGPoint(x: 50, y: 50))
        expectEqual(board.editor.mentionPills(of: id), frames)
    },
    test("a pill naming a shape that isn't there draws the name it holds, dashed; undoing the deletion makes it live again, and redoing it missing") {
        let board = try DrawingBoard()
        let text = mentioning([.text("Ask "), .mention(idA, label: "Old groceries"), .text(" today")])
        let id = board.place(Scrap(paper, text: text))
        let live = renderBitmap(board.editor, size: pictureSize, scale: 2)
        expectEqual(board.editor.mentionPills(of: id).map(\.isLive), [true])
        board.editor.delete(idA)
        let missing = renderBitmap(board.editor, size: pictureSize, scale: 2)
        let frame = try require(board.editor.mentionPills(of: id).first)
        expect(!frame.isLive)
        expect(changed(live, missing, in: frame.frame.insetBy(dx: -1, dy: -1)) > 0, "it shows as missing")
        expectEqual(try require(board.editor.document[id]?.typed(as: Scrap.self)).props.text, text, "nothing is written")
        let string = JotStyle.text.attributedString(text, width: paper.width - 2 * ScrapStyle.padding) { _ in .missing }
        board.editor.delete(id)
        let expected = board.easel { draw(string, in: $0) }
        expectEqual(largestDifference(missing, expected), 0, "the name it holds, dashed")
        let renamedText = mentioning([.text("Ask "), .mention(idA, label: "Other name"), .text(" today")])
        let other = board.picture(of: Scrap(paper, text: renamedText))
        expect(changed(missing, other, in: frame.frame) > 0, "the name it holds is what it shows")
        // Undone to the deletion (and the pictures made since), it's live again; redone, missing.
        while board.editor.document[idA] == nil, board.editor.canUndo { board.editor.undo() }
        expect(board.editor.document[id] != nil)
        expectEqual(board.editor.mentionPills(of: id).map(\.isLive), [true])
        expectEqual(largestDifference(renderBitmap(board.editor, size: pictureSize, scale: 2), live), 0, "live again")
        board.editor.redo()
        expectEqual(board.editor.mentionPills(of: id).map(\.isLive), [false])
        expectEqual(largestDifference(renderBitmap(board.editor, size: pictureSize, scale: 2), missing), 0, "missing again")
    },
    test("a pill naming a shape that can't be mentioned, or is kept aside, draws as missing") {
        let board = try DrawingBoard()
        let box = board.editor.add(Box(CGRect(x: 1000, y: 1300, width: 50, height: 50)))
        let keptID = ShapeID()
        append([try keptAside(Plate.kind, id: keptID, in: board.editor.registry)], to: board.editor)
        let text = mentioning([.mention(box, label: "A box"), .text(" "), .mention(keptID, label: "Kept")])
        let id = board.place(Scrap(paper, text: text))
        expectEqual(board.editor.mentionPills(of: id).map(\.isLive), [false, false])
        let drawn = renderBitmap(board.editor, size: pictureSize, scale: 2)
        let string = JotStyle.text.attributedString(text, width: paper.width - 2 * ScrapStyle.padding) { _ in .unavailable }
        board.editor.delete(id)
        let expected = board.easel { draw(string, in: $0) }
        expectEqual(largestDifference(drawn, expected), 0)
    },
    test("renaming a mentioned shape changes the pill on the next frame, its frame too; a frame of text that didn't change builds nothing") {
        let board = try DrawingBoard()
        let text = mentioning([.text("Ask "), .mention(idA, label: "Groceries"), .text(" today")])
        let id = board.place(Scrap(paper, text: text))
        let before = renderBitmap(board.editor, size: pictureSize, scale: 2)
        let frame = try require(board.editor.mentionPills(of: id).first).frame
        #if DEBUG
        let built = MentionDrawingCounts.stringsBuilt
        _ = renderBitmap(board.editor, size: pictureSize, scale: 2)
        _ = board.editor.mentionPills(of: id)
        expectEqual(MentionDrawingCounts.stringsBuilt, built, "kept from the frame before")
        board.editor.transact { $0.update(id, as: Scrap.self) { $0.props.frame.origin.x += 1 } }
        board.editor.transact { $0.update(id, as: Scrap.self) { $0.props.frame.origin.x -= 1 } }
        _ = renderBitmap(board.editor, size: pictureSize, scale: 2)
        expectEqual(MentionDrawingCounts.stringsBuilt, built, "moving it builds nothing")
        #endif
        board.editor.rename(idA, "Groceries for the whole week")
        let after = renderBitmap(board.editor, size: pictureSize, scale: 2)
        let renamed = try require(board.editor.mentionPills(of: id).first).frame
        expect(changed(before, after, in: frame.union(renamed)) > 0)
        expect(renamed.width > frame.width, "\(renamed.width) after \(frame.width)")
        expect(renamed.minY > frame.minY, "too long for the rest of the first line, so on the second: \(renamed)")
        #if DEBUG
        expectEqual(MentionDrawingCounts.stringsBuilt, built + 1, "built once, for the new name")
        #endif
        let string = board.string(text)
        board.editor.delete(id)
        let expected = board.easel { draw(string, in: $0) }
        expectEqual(largestDifference(after, expected), 0)
        board.editor.rename(idA, "Groceries")
        let id2 = board.place(Scrap(paper, text: text))
        expectEqual(board.editor.mentionPills(of: id2).first?.frame, frame, "named back, as it was")
    },
    test("a pill on a line past the box, or on a cut-short last line where its \"…\" goes, has no frame, and isn't drawn") {
        let board = try DrawingBoard()
        board.editor.rename(idB, "Bo")
        board.editor.rename(idC, "Cy")
        let textRight = paper.maxX - ScrapStyle.padding
        let ellipsis = ("\u{2026}" as NSString).size(withAttributes: [.font: JotStyle.text.font]).width
        for loose in [false, true] {
            // A on the first line; on the second, B, some x's, then C near its right end, where the
            // "…" would go, then more text, so two lines cut the second short.
            func text(_ xs: Int) -> MentionText {
                mentioning([.mention(idA, label: "A"), .text("\n"), .mention(idB, label: "B"), .text(" " + String(repeating: "x", count: xs) + " "),
                            .mention(idC, label: "C"), .text(" and more words that go on to the lines below")])
            }
            var found: MentionText?
            for xs in 0..<40 {
                let id = board.place(Scrap(paper, text: text(xs), loose: loose))
                let all = board.editor.mentionPills(of: id)
                board.editor.delete(id)
                guard all.count == 3, all[1].frame.minY == all[2].frame.minY, all[2].frame.maxX + ellipsis > textRight else { continue }
                found = text(xs)
                break
            }
            let cutShort = try require(found, "a C at the second line's end (loose \(loose))")
            let id = board.place(Scrap(paper, text: cutShort, loose: loose, lines: 2))
            let frames = board.editor.mentionPills(of: id)
            let drawn = renderBitmap(board.editor, size: pictureSize, scale: 2)
            board.editor.delete(id)
            expectEqual(frames.map(\.target), [idA, idB], "B, first on the cut line, shows; C, where the \"…\" goes, doesn't")
            let string = board.string(cutShort, loose: loose)
            let lineHeight = loose ? naturalLineHeight(ScrapStyle.loose.font) : 19
            func twoLines(_ box: CGRect) -> CGRect { CGRect(x: box.minX, y: box.minY, width: box.width, height: 2 * lineHeight + 0.5) }
            let pills = board.easel { draw(string, in: twoLines($0)) }
            let blanks = board.easel { draw(withBlankPills(string), in: twoLines($0)) }
            expectEqual(largestDifference(drawn, pills), 0, "two lines, as string drawing has them")
            expectPills(frames, match: differences(pills, blanks))
        }
        // A pill wholly below the box: none, until the box is tall enough.
        let tall = mentioning([.text("One\nTwo\nThree\nFour\nFive\nSix\nSeven\nEight\nNine\nTen\n"), .mention(idA, label: "A")])
        let id = board.place(Scrap(paper, text: tall))
        expectEqual(board.editor.mentionPills(of: id), [])
        board.editor.transact { $0.update(id, as: Scrap.self) { $0.props.frame.size.height = 260 } }
        expectEqual(board.editor.mentionPills(of: id).map(\.target), [idA], "in a taller box, it fits")
    },
    test("lines limits the lines, with fixed lines and the font's") {
        let board = try DrawingBoard()
        let text = mentioning([.text("One\nTwo\n"), .mention(idA, label: "A"), .text("\nFour")])
        for loose in [false, true] {
            let three = board.place(Scrap(paper, text: text, loose: loose, lines: 3))
            let two = board.place(Scrap(paper, text: text, loose: loose, lines: 2))
            expectEqual(board.editor.mentionPills(of: three).map(\.target), [idA], "the pill is on the third line")
            expectEqual(board.editor.mentionPills(of: two), [], "two lines hold no pill")
            board.editor.delete(three, two)
            let drawnTwo = board.picture(of: Scrap(paper, text: text, loose: loose, lines: 2))
            let drawnAll = board.picture(of: Scrap(paper, text: text, loose: loose))
            let string = board.string(text, loose: loose)
            let lineHeight = loose ? naturalLineHeight(ScrapStyle.loose.font) : 19
            let expected = board.easel { box in draw(string, in: CGRect(x: box.minX, y: box.minY, width: box.width, height: 2 * lineHeight + 0.5)) }
            expectEqual(largestDifference(drawnTwo, expected), 0, "loose \(loose)")
            let empty = board.picture(of: Scrap(paper, loose: loose))
            let below = CGRect(x: paper.minX, y: paper.minY + ScrapStyle.padding + 2 * lineHeight + 1, width: paper.width, height: 80)
            expectEqual(changed(drawnTwo, empty, in: below), 0, "nothing below two lines (loose \(loose))")
            expect(changed(drawnAll, empty, in: below) > 0, "where the rest goes without a limit")
        }
    },
    test("more texts in view than the canvas keeps built: the next frame builds none of them, nor do their pills; once they're gone, it keeps 2,048") {
        #if DEBUG
        let board = try DrawingBoard()
        let capacity = MentionDrawingCounts.capacity
        let count = capacity + 100, columns = 50
        var scraps: [ShapeID] = []
        board.editor.transact { transaction in
            for n in 0..<count {
                let frame = CGRect(x: CGFloat(n % columns) * 60, y: CGFloat(n / columns) * 60, width: 50, height: 50)
                let scrap = ShapeRecord(Scrap(frame, text: mentioning([.mention(idA, label: "A"), .text(" \(n)")])))
                transaction.insert(scrap)
                scraps.append(scrap.id)
            }
        }
        board.editor.camera = Camera(origin: CGPoint(x: -10, y: -10), zoom: 0.2)
        board.editor.skeletonZoom = 0          // every text drawn in full at 20%, the memo's bound being the point
        let size = CGSize(width: 640, height: 580)
        var built = MentionDrawingCounts.stringsBuilt
        _ = renderBitmap(board.editor, size: size)
        expectEqual(MentionDrawingCounts.stringsBuilt - built, count, "the first frame builds each")
        expect(MentionDrawingCounts.kept >= count, "and keeps them all: \(MentionDrawingCounts.kept)")
        built = MentionDrawingCounts.stringsBuilt
        _ = renderBitmap(board.editor, size: size)
        expectEqual(MentionDrawingCounts.stringsBuilt, built, "the next builds none")
        _ = board.editor.mentionPills(of: scraps[0])
        _ = board.editor.mentionPills(of: scraps[count - 1])
        _ = renderBitmap(board.editor, size: size)
        expectEqual(MentionDrawingCounts.stringsBuilt, built, "a hover's pills, and the frame after, build none either")
        board.editor.transact { $0.delete(Set(scraps)) }
        _ = renderBitmap(board.editor, size: size)
        expectEqual(MentionDrawingCounts.kept, capacity, "a frame with none in view lets them go")
        #endif
    },

    test("zoomed out past 35%, text isn't drawn: a skeleton builds no string and lays out no pill; at 35%, it's drawn") {
        #if DEBUG
        let board = try DrawingBoard()
        // Text no other test draws, so the memo has never built it.
        board.place(Scrap(paper, text: mentioning([.mention(idA, label: "A"), .text(" \(UUID())")])))
        board.editor.camera = Camera(zoom: 0.3)
        let built = MentionDrawingCounts.stringsBuilt, laidOut = MentionDrawingCounts.layoutsBuilt
        _ = renderBitmap(board.editor, size: pictureSize)
        expectEqual(MentionDrawingCounts.stringsBuilt, built)
        expectEqual(MentionDrawingCounts.layoutsBuilt, laidOut)
        board.editor.camera = Camera(zoom: 0.35)
        _ = renderBitmap(board.editor, size: pictureSize)
        expectEqual(MentionDrawingCounts.stringsBuilt - built, 1)
        #endif
    },
    test("a frame of skeletons draws no text, so at its end the memo lets go of all but 2,048 of what a full frame kept") {
        #if DEBUG
        let board = try DrawingBoard()
        let capacity = MentionDrawingCounts.capacity
        let count = capacity + 100, columns = 50
        board.editor.transact { transaction in
            for n in 0..<count {
                let frame = CGRect(x: CGFloat(n % columns) * 60, y: CGFloat(n / columns) * 60, width: 50, height: 50)
                transaction.insert(ShapeRecord(Scrap(frame, text: mentioning([.mention(idA, label: "A"), .text(" \(n)")]))))
            }
        }
        let level = board.editor.skeletonZoom
        board.editor.skeletonZoom = 0          // every text drawn in full at 20%
        board.editor.camera = Camera(origin: CGPoint(x: -10, y: -10), zoom: 0.2)
        let size = CGSize(width: 640, height: 580)
        _ = renderBitmap(board.editor, size: size)
        expect(MentionDrawingCounts.kept >= count, "a full frame keeps them all: \(MentionDrawingCounts.kept)")
        board.editor.skeletonZoom = level
        board.editor.camera = Camera(origin: CGPoint(x: -10, y: -10), zoom: 0.3)
        let built = MentionDrawingCounts.stringsBuilt
        _ = renderBitmap(board.editor, size: size)
        expectEqual(MentionDrawingCounts.stringsBuilt, built, "skeletons at 30% build none")
        expectEqual(MentionDrawingCounts.kept, capacity, "and keep what the memo keeps")
        #endif
    },
    test("a pill's image is drawn afresh at every scale, never kept as a bitmap") {
        let board = try DrawingBoard()
        let string = board.string(mentioning([.text("Ask "), .mention(idA, label: "Groceries")]))
        let pill = try require(string.attribute(.attachment, at: 4, effectiveRange: nil) as? MentionAttachment)
        expectEqual(pill.image?.cacheMode, .never)
        pill.isSelected = true
        expectEqual(pill.image?.cacheMode, .never, "made again")
    },

    test("the canvas keeps at most 2,048 texts built, those used longest ago going first") {
        #if DEBUG
        let board = try DrawingBoard()
        let id = board.place(Scrap(paper))
        let capacity = MentionDrawingCounts.capacity
        expectEqual(capacity, 2048)
        let first = mentioning([.mention(idA, label: "A"), .text(" first")])
        board.editor.transact { $0.update(id, as: Scrap.self) { $0.props.text = first } }
        _ = board.editor.mentionPills(of: id)
        for n in 0..<capacity + 50 {
            board.editor.transact { $0.update(id, as: Scrap.self) { $0.props.text = mentioning([.mention(idA, label: "A"), .text(" \(n)")]) } }
            _ = board.editor.mentionPills(of: id)
            if n == capacity / 2 {
                // The first, used again, is the newest again.
                board.editor.transact { $0.update(id, as: Scrap.self) { $0.props.text = first } }
                let built = MentionDrawingCounts.stringsBuilt
                _ = board.editor.mentionPills(of: id)
                expectEqual(MentionDrawingCounts.stringsBuilt, built, "still kept")
            }
        }
        expectEqual(MentionDrawingCounts.kept, capacity)
        board.editor.transact { $0.update(id, as: Scrap.self) { $0.props.text = first } }
        var built = MentionDrawingCounts.stringsBuilt
        _ = board.editor.mentionPills(of: id)
        expectEqual(MentionDrawingCounts.stringsBuilt, built, "used halfway through, so it's among the newest")
        board.editor.transact { $0.update(id, as: Scrap.self) { $0.props.text = mentioning([.mention(idA, label: "A"), .text(" 0")]) } }
        built = MentionDrawingCounts.stringsBuilt
        _ = board.editor.mentionPills(of: id)
        expectEqual(MentionDrawingCounts.stringsBuilt, built + 1, "the oldest went")
        expectEqual(MentionDrawingCounts.kept, capacity)
        #endif
    },
])
