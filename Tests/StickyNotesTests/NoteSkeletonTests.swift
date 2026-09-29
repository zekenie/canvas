import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Geometry
import Mentions
import StickyNotes
import TestKit

// A note zoomed out, under 35% (`CustomSkeleton`): its yellow with no shadow, and a bar where each
// line of its text would be, counted from its columns (`SkeletonText`), never laid out; the note
// being edited, and every note at 35% and above, drawn in full.

/// Where the notes sit, in world units: at 30% (`far`), 15 to 75 view points across and down.
private let noteFrame = CGRect(x: 50, y: 50, width: 200, height: 200)
/// Its text's box, where the render draws its text.
private let textBox = noteFrame.insetBy(dx: 16, dy: 16)
private let far: CGFloat = 0.3
private let canvas = CGSize(width: 100, height: 100)
/// Pixels per point: fine enough to tell a bar's rows from its line's.
private let scale: CGFloat = 4

@MainActor private func farEditor(_ texts: [MentionText], at zoom: CGFloat = far) throws -> (CanvasEditor, [ShapeID]) {
    let editor = CanvasEditor(registry: try Registry(plugins: notePlugins), scheduler: ManualScheduler())
    editor.camera = Camera(origin: .zero, zoom: zoom)
    let notes = texts.enumerated().map { i, text in
        ShapeRecord(StickyNote(frame: noteFrame.offsetBy(dx: CGFloat(i) * 300, dy: 0), text: text))
    }
    editor.transact { for note in notes { $0.insert(note) } }
    return (editor, notes.map(\.id))
}

/// A note of `text` at `noteFrame`, drawn at `zoom`: as the canvas draws it, and in full.
@MainActor private func drawn(_ text: MentionText, at zoom: CGFloat = far) throws -> (skeleton: NSBitmapImageRep, full: NSBitmapImageRep) {
    let (editor, _) = try farEditor([text], at: zoom)
    let skeleton = renderBitmap(editor, size: canvas, scale: scale)
    editor.skeletonZoom = 0
    return (skeleton, renderBitmap(editor, size: canvas, scale: scale))
}

/// A run of rows in a bitmap that differ from another: in world units from the text box's top-left,
/// at `far`, and the rightmost column that differs.
private struct Run {
    var top: CGFloat, bottom: CGFloat, right: CGFloat
}

/// The runs of rows, in the text box, in which `rep` differs from `background` by more than
/// `threshold` in some channel: its lines of text, or its bars.
@MainActor private func runs(_ rep: NSBitmapImageRep, over background: NSBitmapImageRep, threshold: Int, zoom: CGFloat = far) -> [Run] {
    let box = CGRect(x: textBox.minX * zoom, y: textBox.minY * zoom, width: textBox.width * zoom, height: textBox.height * zoom)
    var p = [Int](repeating: 0, count: 4), q = [Int](repeating: 0, count: 4)
    var found: [Run] = []
    var previous = Int.min
    let world = { (pixel: Int) in CGFloat(pixel) / scale / zoom }
    for y in Int(box.minY * scale)..<Int(box.maxY * scale) {
        let right = (Int(box.minX * scale)..<Int(box.maxX * scale)).last { x in
            rep.getPixel(&p, atX: x, y: y); background.getPixel(&q, atX: x, y: y)
            return zip(p, q).contains { abs($0 - $1) > threshold }
        }
        guard let right else { continue }
        if y != previous + 1 {
            found.append(Run(top: world(y) - textBox.minY, bottom: 0, right: 0))
        }
        found[found.count - 1].bottom = world(y + 1) - textBox.minY
        found[found.count - 1].right = max(found[found.count - 1].right, world(right + 1) - textBox.minX)
        previous = y
    }
    return found
}

/// A column's share of a bar, in world units, as `NoteTextBars` counts: 0.52 of the text's 16
/// points. A bar under a line's width is this times its columns.
private let column: CGFloat = 0.52 * 16

/// The bars of a note of `text` at 30%, drawn over a note with none.
@MainActor private func bars(_ text: MentionText) throws -> [Run] {
    runs(try drawn(text).skeleton, over: try drawn("").skeleton, threshold: 16)
}

/// `units` as the text view hands text over (`MentionTextStyle.mentionText(from:)`): cut from the
/// NSString of its storage, bridged from it lazily, so its UTF-8 isn't at hand, until the board is
/// read again. Lone surrogates are kept, as the storage keeps them.
private func typed(_ units: [unichar]) -> String {
    let storage = NSTextStorage(string: NSString(characters: units, length: units.count) as String)
    return (storage.string as NSString).substring(with: NSRange(location: 0, length: storage.length))
}

private func typed(_ text: String) -> String { typed(Array(text.utf16)) }

/// Whether a string's UTF-8 isn't at hand: a string bridged from an NSString, read as UTF-16.
private func isBridged(_ text: String) -> Bool { text.utf8.withContiguousStorageIfAvailable { _ in true } == nil }

/// The color at a view point of a bitmap drawn at `scale`.
@MainActor private func color(_ rep: NSBitmapImageRep, at point: CGPoint) -> [Int] { pixel(rep, at: point, scale: scale) }

/// The sum of the darkest pixel's channels within a rect of view points.
@MainActor private func darkest(_ rep: NSBitmapImageRep, in rect: CGRect) -> Int {
    var darkest = Int.max, p = [Int](repeating: 0, count: 4)
    for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
        for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
            rep.getPixel(&p, atX: x, y: y)
            darkest = min(darkest, p.prefix(3).reduce(0, +))
        }
    }
    return darkest
}

/// How many pixels differ between two bitmaps of one size, drawn at `scale`, within a rect of view
/// points.
@MainActor private func differing(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, in rect: CGRect, scale: CGFloat) -> Int {
    var p = [Int](repeating: 0, count: 4), q = [Int](repeating: 0, count: 4), count = 0
    for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
        for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
            a.getPixel(&p, atX: x, y: y); b.getPixel(&q, atX: x, y: y)
            if p != q { count += 1 }
        }
    }
    return count
}

@MainActor let noteSkeletonTests = Suite("Note skeleton", [
    test("at 30% a note's lines are bars, one each, where its lowercase letters are, about as long as its words run") {
        let text = MentionText(plain: multiLineText)
        let (skeleton, full) = try drawn(text)
        let (plainSkeleton, fullNoText) = try drawn("")
        let bars = runs(skeleton, over: plainSkeleton, threshold: 16)
        let lines = runs(full, over: fullNoText, threshold: 64)
        expectEqual(lines.count, 6, "the render's lines with text: four, one, a blank one, one")
        expectEqual(bars.count, lines.count, "a bar a line: \(bars)")
        let tolerance = 1 / scale / far
        for (bar, line) in zip(bars, lines) {
            expect(bar.top >= line.top - tolerance && bar.bottom <= line.bottom + tolerance, "a bar within its line's ink: \(bar), \(line)")
            expect(bar.bottom - bar.top > 7 && bar.bottom - bar.top < 11, "a bar about an x-height tall: \(bar)")
            expect(abs(bar.right - line.right) < 40, "a bar about as long as its line: \(bar), \(line)")
        }
        expect(bars[5].top - bars[4].top > 37, "the blank line left blank: \(bars[4]), \(bars[5])")
    },
    test("at 30% a note is its yellow, with no shadow, and no text: nothing in it darker than a bar") {
        let (skeleton, full) = try drawn(MentionText(plain: multiLineText))
        let blank = renderBitmap(try farEditor([]).0, size: canvas, scale: scale)
        let note = CGRect(x: noteFrame.minX * far, y: noteFrame.minY * far, width: noteFrame.width * far, height: noteFrame.height * far)
        let corner = CGPoint(x: note.maxX - 2, y: note.maxY - 2)
        expectEqual(color(skeleton, at: corner), color(full, at: corner), "the note's own yellow, in its padding")
        let barMiddle = CGPoint(x: (textBox.minX + 20) * far, y: (textBox.minY + 6.5 + 4.25) * far)
        let bar = color(skeleton, at: barMiddle), yellow = color(skeleton, at: corner)
        expect(zip(bar.prefix(3), yellow.prefix(3)).allSatisfy { $0 < $1 }, "a bar darkens the yellow: \(bar), \(yellow)")
        expect(darkest(skeleton, in: note) >= bar.prefix(3).reduce(0, +) - 3, "no glyph, darker than a bar, anywhere in the note")
        expect(darkest(full, in: note) < 200, "where the render draws its text")
        // Just right of the note, where the render's shadow is.
        let halo = CGRect(x: note.maxX, y: note.minY + 10, width: 1, height: 30)
        expectEqual(largestDifference(blank, skeleton, in: halo, scale: scale), 0, "no shadow")
        expect(largestDifference(blank, full, in: halo, scale: scale) > 0, "the render's shadow")
    },
    test("an empty note is its yellow alone, with no bars") {
        let (skeleton, _) = try drawn("")
        let (spaces, _) = try drawn("  \n \n")
        let note = CGRect(x: noteFrame.minX * far, y: noteFrame.minY * far, width: noteFrame.width * far, height: noteFrame.height * far)
        let inside = note.insetBy(dx: 2, dy: 2)
        let yellow = color(skeleton, at: CGPoint(x: inside.midX, y: inside.midY))
        expectEqual(darkest(skeleton, in: inside), yellow.prefix(3).reduce(0, +))
        expectEqual(differing(skeleton, spaces, in: inside, scale: scale), 0, "spaces show nothing, so they're blank lines")
    },
    test("paragraphs: each at least a line, a blank one or one of spaces a line left blank, a return and a line feed one break; no more than the box holds") {
        let (plain, _) = try drawn("")
        let (skeleton, _) = try drawn(MentionText(plain: "One\r\ntwo\n\n   \nthree"))
        let tops = runs(skeleton, over: plain, threshold: 16).map { (($0.top - 6.5) / 19).rounded() }
        expectEqual(tops, [0, 1, 4], "lines 2 and 3 blank")
        let (long, _) = try drawn(MentionText(plain: String(repeating: "word ", count: 80)))
        let bars = runs(long, over: plain, threshold: 16)
        expectEqual(bars.count, 8, "the eight lines 168 points hold")
        expect(bars.allSatisfy { $0.right > 160 }, "each full: the last is cut short with more to come")
        let (short, _) = try drawn("a")
        let one = try require(runs(short, over: plain, threshold: 16).first)
        expect(one.right > 12 && one.right < 20, "a word of a letter is two characters' bar: \(one)")
    },
    test("a mention counts as its pill is wide, and draws no pill, nor its name") {
        let sam = ShapeID()
        let text = MentionText([.text("Ask "), .mention(sam, label: "Sam"), .text(" about the cake")])
        let (editor, _) = try farEditor([text])
        #if DEBUG
        let built = MentionDrawingCounts.stringsBuilt
        #endif
        let skeleton = renderBitmap(editor, size: canvas, scale: scale)
        #if DEBUG
        expectEqual(MentionDrawingCounts.stringsBuilt, built, "a skeleton builds no text")
        #endif
        editor.skeletonZoom = 0
        let full = renderBitmap(editor, size: canvas, scale: scale)
        #if DEBUG
        expect(MentionDrawingCounts.stringsBuilt > built, "the render builds it")
        #endif
        let (plain, fullNoText) = try drawn("")
        expectEqual(runs(full, over: fullNoText, threshold: 64).count, 2, "it wraps")
        expectEqual(runs(skeleton, over: plain, threshold: 16).count, 2, "and so do its bars")
        // "a " is 2 columns, and a pill 3 (its symbol and padding) and 0.75 a column of its name,
        // 30 at most: Sam's 5.25, where "Sam" as text would be 3; a name in Japanese is two
        // columns a character, as text is.
        for (label, columns) in [("Sam", 7.25), ("東京", 8)] as [(String, CGFloat)] {
            let one = try bars(MentionText([.text("a "), .mention(sam, label: label)]))
            expectEqual(one.count, 1, label)
            expect(abs((one.first?.right ?? 0) - columns * column) < 3, "\(label): \(columns) columns, \(one)")
        }
        let long = try bars(MentionText([.text("a "), .mention(sam, label: String(repeating: "x", count: 60))]))
        expectEqual(long.count, 2, "32 columns: a line and what's left")
        expect(abs((long.last?.right ?? 0) - (32 * column - textBox.width)) < 3, "\(long)")
    },
    test("a line's bar is as long as its columns, as SkeletonText counts them: a CJK character or an emoji two, a mark none, a joined emoji one") {
        for (text, columns) in [("Groceries", 9), ("東京の会議", 10), ("👨‍👩‍👧‍👦 and 🎉", 9), ("cafe\u{301} cafe\u{301}", 9), ("ｆｕｌｌ １２", 13)] {
            expectEqual(SkeletonText.columns(of: text), columns, text)
            for text in [MentionText(plain: text), MentionText([.text(typed(text))])] {
                let one = try bars(text)
                expectEqual(one.count, 1, text.stored)
                expect(abs((one.first?.right ?? 0) - CGFloat(columns) * column) < 3, "\(text.stored): \(columns) columns, \(one)")
            }
        }
    },
    test("a paragraph in Japanese takes the lines the render gives it: each character a full em, two columns") {
        let text = MentionText(plain: String(repeating: "東京の会議", count: 10))
        let (skeleton, full) = try drawn(text)
        let (plain, fullNoText) = try drawn("")
        let lines = runs(full, over: fullNoText, threshold: 64), bars = runs(skeleton, over: plain, threshold: 16)
        expectEqual(lines.count, 5, "ten characters a line")
        expectEqual(bars.count, lines.count, "a bar a line: \(bars)")
        for (bar, line) in zip(bars, lines) {
            expect(abs(bar.right - line.right) < 20, "a bar about as long as its line: \(bar), \(line)")
        }
    },
    test("text typed in the app, bridged from the text view's NSString, draws the bars a Swift string does") {
        let x = Array(repeating: unichar(0x78), count: 63), xs = String(repeating: "x", count: 63)
        let sam = ShapeID()
        // Read 64 code units at a time: a pair of surrogates, and a return and its line feed,
        // across a chunk's end; lone surrogates, read as U+FFFD.
        let cases: [([MentionRun], [MentionRun])] = [
            ([.text(typed(multiLineText))], [.text(multiLineText)]),
            ([.text(typed("Call “Sam” — tomorrow,\r\nand bring the café receipts.\rThen 東京の会議 👨‍👩‍👧‍👦 🎉"))],
             [.text("Call “Sam” — tomorrow,\r\nand bring the café receipts.\rThen 東京の会議 👨‍👩‍👧‍👦 🎉")]),
            ([.text(typed(x + Array("😀 and the rest".utf16)))], [.text(xs + "😀 and the rest")]),
            ([.text(typed(x + Array("\r\nnext line".utf16)))], [.text(xs + "\r\nnext line")]),
            ([.text(typed(x + [0xD83D] + Array("y and z".utf16) + [0xDE00] + Array(" end".utf16)))], [.text(xs + "\u{FFFD}y and z\u{FFFD} end")]),
            ([.text(typed("Please ask them ")), .mention(sam, label: "Sam"), .text(typed(" about the cake, tomorrow at noon"))],
             [.text("Please ask them "), .mention(sam, label: "Sam"), .text(" about the cake, tomorrow at noon")]),
            ([.text(typed(String(repeating: "Lorem ipsum dolor sit amet. ", count: 200)))], [.text(String(repeating: "Lorem ipsum dolor sit amet. ", count: 200))]),
        ]
        for (typedRuns, runs) in cases {
            let typedText = MentionText(typedRuns), text = MentionText(runs)
            expectEqual(typedText, text)
            for case .text(let run) in typedText.runs { expect(isBridged(run), "bridged, as the text view's are: \(run.prefix(20))") }
            let (typedSkeleton, _) = try drawn(typedText), (skeleton, _) = try drawn(text)
            expectEqual(differing(typedSkeleton, skeleton, in: CGRect(origin: .zero, size: canvas), scale: scale), 0, "\(text.stored.prefix(40))")
        }
    },
    test("a paragraph far longer than the box is read only as far as its bars go: it draws, and costs, as one that fills the box") {
        // Its first line a word, so a note's name (its first line) is short, and a million
        // characters after it: 200 columns fill the seven lines left.
        let fills = MentionText(plain: "Groceries\n" + String(repeating: "word ", count: 40))
        let long = "Groceries\n" + String(repeating: "word ", count: 200_000)
        let (fillsSkeleton, _) = try drawn(fills)
        for text in [MentionText(plain: long), MentionText([.text(typed(long))])] {
            let (editor, _) = try farEditor([text])
            let (short, _) = try farEditor([fills])
            var skeleton = renderBitmap(editor, size: canvas, scale: scale)
            expectEqual(differing(skeleton, fillsSkeleton, in: CGRect(origin: .zero, size: canvas), scale: scale), 0, "a line and seven full ones")
            // The fastest of a few is what it costs. Read whole, a debug build takes some 14 ms for
            // a native string and 25 for a bridged one, where a frame of this note takes a fifth
            // of a millisecond.
            let took = (0..<5).map { _ in threadCPUTime { skeleton = renderBitmap(editor, size: canvas, scale: scale) } }.min() ?? .zero
            let fillsTook = (0..<5).map { _ in threadCPUTime { skeleton = renderBitmap(short, size: canvas, scale: scale) } }.min() ?? .zero
            expect(took < fillsTook + .milliseconds(2), "\(took), where one that fills the box takes \(fillsTook)")
        }
    },
    test("a note of any height or width draws its bars as any note does, from its top") {
        let (normal, _) = try drawn(MentionText(plain: multiLineText))
        let box = CGRect(x: textBox.minX * far, y: textBox.minY * far, width: textBox.width * far, height: textBox.height * far)
        // A billion billion points: more lines than an Int holds.
        let (tall, _) = try farEditor([])
        tall.transact { $0.insert(ShapeRecord(StickyNote(frame: CGRect(origin: noteFrame.origin, size: CGSize(width: 200, height: 1e21)),
                                                         text: MentionText(plain: multiLineText)))) }
        expectEqual(differing(renderBitmap(tall, size: canvas, scale: scale), normal, in: box, scale: scale), 0, "its lines, from its top")
        // A bar a paragraph, as long as its columns.
        let frame = CGRect(origin: noteFrame.origin, size: CGSize(width: 1e21, height: 200))
        let (wide, _) = try farEditor([]), (wideBlank, _) = try farEditor([])
        wide.transact { $0.insert(ShapeRecord(StickyNote(frame: frame, text: MentionText(plain: multiLineText)))) }
        wideBlank.transact { $0.insert(ShapeRecord(StickyNote(frame: frame, text: ""))) }
        let tops = runs(renderBitmap(wide, size: canvas, scale: scale), over: renderBitmap(wideBlank, size: canvas, scale: scale), threshold: 16)
            .map { (($0.top - 6.5) / 19).rounded() }
        expectEqual(tops, [0, 1, 3], "the blank line left blank")
    },
    test("at 35% and above a note draws in full, as it did") {
        for zoom: CGFloat in [0.35, 0.5] {
            let (skeleton, full) = try drawn(MentionText(plain: multiLineText), at: zoom)
            expectEqual(differing(skeleton, full, in: CGRect(origin: .zero, size: canvas), scale: scale), 0, "at \(zoom)")
        }
        let (skeleton, full) = try drawn(MentionText(plain: multiLineText), at: 0.349)
        expect(differing(skeleton, full, in: CGRect(origin: .zero, size: canvas), scale: scale) > 100, "just under it, a skeleton")
    },
    test("the note being edited draws in full at 30%, while the others are skeletons") {
        let (editor, ids) = try farEditor([MentionText(plain: multiLineText), MentionText(plain: multiLineText)])
        expect(editor.beginEditing(ids[0]))
        let size = CGSize(width: 190, height: 100)
        let skeletons = renderBitmap(editor, size: size, scale: 2)
        editor.skeletonZoom = 0
        let full = renderBitmap(editor, size: size, scale: 2)
        let edited = CGRect(x: noteFrame.minX * far, y: noteFrame.minY * far, width: noteFrame.width * far, height: noteFrame.height * far)
        expectEqual(differing(skeletons, full, in: edited.insetBy(dx: -3, dy: -3), scale: 2), 0, "the edited note, its shadow too")
        expect(differing(skeletons, full, in: edited.offsetBy(dx: 300 * far, dy: 0), scale: 2) > 100, "the other, a skeleton")
    },
])
