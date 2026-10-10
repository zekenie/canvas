import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Foundation
import Geometry
import Mentions
import StickyNotes
import TestKit
import Titles
import Types

// A note laid out by its words and what goes under them (`NoteLayout`): the stored box while nothing
// provides its rows, and, with rows (a test provider stands in for Types'), wider and taller from the
// same top-left, its words wrapping at the width it is laid out at. The stored box stays the note as
// it is with no rows.

/// A note's padding all round, and the gap between its words and the rows under them.
private let padding: CGFloat = 16, gap: CGFloat = 12

/// Provides `TypeRows.extent` for the notes it has an extent for, as Types will for a typed note
/// (slice 9 replaces it with a real type, since one key takes one provider).
@MainActor
private final class Rows {
    var extents: [ShapeID: RowsExtent] = [:]
    /// Each time the provider was asked.
    var asked = 0

    var plugin: some CanvasPlugin { RowsPlugin(rows: self) }
}

private struct RowsPlugin: CanvasPlugin {
    let rows: Rows
    var id: PluginID { "test-note-rows" }
    func register(into registrar: inout PluginRegistrar) {
        let rows = rows
        registrar.layoutInput(TypeRows.extent) { record, _ in
            rows.asked += 1
            return rows.extents[record.id]
        }
    }
}

@MainActor private func makeEditor(_ rows: Rows, zoom: CGFloat = 1) throws -> CanvasEditor {
    let editor = CanvasEditor(registry: try Registry(plugins: notePlugins + [rows.plugin]), scheduler: ManualScheduler())
    editor.camera.setZoom(zoom, around: .zero)
    return editor
}

extension CanvasEditor {
    /// A shape's laid-out frame.
    @MainActor fileprivate func laidOut(_ id: ShapeID) -> CGRect? { shapeContext.frame(of: id) }

    /// A shape's frame as it is stored.
    @MainActor fileprivate func stored(_ id: ShapeID) -> CGRect? { document[id]?.box }

    /// Where the note draws its words.
    @MainActor fileprivate func words(of id: ShapeID) -> CGRect? {
        document[id].flatMap { registry.mentionTextPlacements(of: $0, in: shapeContext).first?.box }
    }

    /// Gives a note rows, or takes them (nil), and says its layout changed.
    @MainActor fileprivate func setRows(_ rows: Rows, _ extent: RowsExtent?, for id: ShapeID) {
        rows.extents[id] = extent
        shapesDidChangeLayout([id])
    }
}

/// `count` short lines, each its own, so how tall they are doesn't depend on where they wrap.
private func lines(_ count: Int) -> String { (1...count).map { "x\($0)" }.joined(separator: "\n") }

private let rows96 = RowsExtent(minimumWidth: 320, height: 96)

/// How many lines of `text` a note stored 200 wide draws, with the rows, if any: its render over the
/// same note with no text.
@MainActor private func drawnLines(of text: MentionText, rows extent: RowsExtent?) throws -> Int {
    let rows = Rows()
    let editor = try makeEditor(rows)
    let note = editor.add(StickyNote(frame: CGRect(x: 20, y: 20, width: 200, height: 200), text: text))
    if let extent { editor.setRows(rows, extent, for: note) }
    let size = CGSize(width: 400, height: 400)
    let drawn = renderBitmap(editor, size: size)
    let frame = try require(editor.laidOut(note))
    editor.transact { $0.update(note, as: StickyNote.self) { $0.props.text = "" } }
    return lineTops(drawn, over: renderBitmap(editor, size: size), in: frame).count
}

@MainActor let noteLayoutTests = Suite("Note layout", [
    test("with no rows a note is its stored frame, its words that inset by the padding, and nothing is measured") {
        let rows = Rows()
        let editor = try makeEditor(rows)
        let measured = NoteWordsCounts.measured
        let id = editor.add(StickyNote(frame: CGRect(x: 40, y: 30, width: 200, height: 200), text: MentionText(plain: lines(3))))
        _ = renderBitmap(editor, size: CGSize(width: 400, height: 300))
        expectEqual(editor.laidOut(id), CGRect(x: 40, y: 30, width: 200, height: 200))
        expectEqual(editor.words(of: id), CGRect(x: 56, y: 46, width: 168, height: 168))
        expectEqual(NoteWordsCounts.block(of: id, in: editor), nil)
        expectEqual(editor.shapeContext.geometry(of: id)?.bounds, editor.stored(id))
        expect(rows.asked > 0, "a plain note is a failed lookup")
        expectEqual(NoteWordsCounts.measured, measured, "and no measure")
    },
    test("rows of 320 by 96 on a new note: 320 wide, 200 tall, the words at 288 and the rows right under them; the stored frame is as it was") {
        let rows = Rows()
        let editor = try makeEditor(rows)
        let id = editor.add(StickyNote(frame: CGRect(x: 40, y: 30, width: 200, height: 200), text: MentionText(plain: lines(3))))
        editor.setRows(rows, rows96, for: id)
        let frame = try require(editor.laidOut(id))
        expectEqual(frame, CGRect(x: 40, y: 30, width: 320, height: 200))
        let words = try require(editor.words(of: id))
        expectEqual(words.minX, 56)
        expectEqual(words.minY, 46)
        expectEqual(words.width, 288)
        expect(abs(words.height - 3 * 19) <= 1.5, "three lines tall: \(words.height)")
        let block = try require(NoteWordsCounts.block(of: id, in: editor))
        expectEqual(block, CGRect(x: 56, y: words.maxY + gap, width: 288, height: 96))
        expect(frame.maxY >= block.maxY + padding, "the paper holds its rows and the padding")
        expectEqual(editor.stored(id), CGRect(x: 40, y: 30, width: 200, height: 200), "what is stored is the note with no rows")
        expectEqual(editor.shapeContext.geometry(of: id)?.bounds, frame, "its geometry is the paper")
    },
    test("as tall as the padding, the words, the gap, the rows and the padding need; paper left over is under the rows") {
        let rows = Rows()
        let editor = try makeEditor(rows)
        let tall = editor.add(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: MentionText(plain: lines(20))))
        let short = editor.add(StickyNote(frame: CGRect(x: 600, y: 0, width: 200, height: 600), text: MentionText(plain: lines(3))))
        editor.setRows(rows, rows96, for: tall)
        editor.setRows(rows, rows96, for: short)
        let words = try require(editor.words(of: tall))
        expect(abs(words.height - 20 * 19) <= 1.5, "twenty lines: \(words.height)")
        expectEqual(editor.laidOut(tall)?.height, padding + words.height + gap + 96 + padding)
        expectEqual(editor.laidOut(tall)?.width, 320)
        let block = try require(NoteWordsCounts.block(of: tall, in: editor))
        expectEqual(block.minY, words.maxY + gap, "the rows right under the words")
        expectEqual(editor.laidOut(tall)?.maxY, block.maxY + padding)
        // Stored taller than it needs: its height stays, and the paper is under the rows.
        expectEqual(editor.laidOut(short)?.height, 600)
        let shortBlock = try require(NoteWordsCounts.block(of: short, in: editor))
        expect(shortBlock.maxY + padding < 600, "paper under the rows: \(shortBlock)")
    },
    test("no words, no gap: the rows start at the padding") {
        let rows = Rows()
        let editor = try makeEditor(rows)
        let id = editor.add(StickyNote(frame: CGRect(x: 10, y: 10, width: 200, height: 200)))
        editor.setRows(rows, RowsExtent(minimumWidth: 320, height: 300), for: id)
        expectEqual(editor.words(of: id)?.height, 0)
        expectEqual(NoteWordsCounts.block(of: id, in: editor), CGRect(x: 26, y: 26, width: 288, height: 300))
        expectEqual(editor.laidOut(id), CGRect(x: 10, y: 10, width: 320, height: padding + 300 + padding))
    },
    test("as wide as its rows read at, and no narrower than it stores") {
        let rows = Rows()
        let editor = try makeEditor(rows)
        let wide = editor.add(StickyNote(frame: CGRect(x: 0, y: 0, width: 500, height: 200)))
        editor.setRows(rows, RowsExtent(minimumWidth: 320, height: 40), for: wide)
        expectEqual(editor.laidOut(wide)?.width, 500)
        expectEqual(editor.words(of: wide)?.width, 468)
    },
    test("its words wrap at the laid-out width: fewer lines than at the width it stores") {
        let text = MentionText(plain: "Ask about the cake and the candles and then the plates for the party tomorrow at noon")
        let narrow = try drawnLines(of: text, rows: nil)
        let wide = try drawnLines(of: text, rows: RowsExtent(minimumWidth: 320, height: 40))
        expect(wide > 0 && wide < narrow, "\(wide) lines at 320 wide, \(narrow) at 200")
    },
    test("the editor's lines fall on the render's at 320 wide, at 1× and 2×, zoomed in and out, and its view is laid over the paper") {
        for (scale, zoom) in [(1, 1), (2, 1), (1, 2), (2, 0.6)] as [(CGFloat, CGFloat)] {
            let rows = Rows()
            let editor = try makeEditor(rows, zoom: zoom)
            let note = editor.add(StickyNote(frame: CGRect(x: 20, y: 15, width: 200, height: 200), text: MentionText(plain: multiLineText)))
            editor.setRows(rows, rows96, for: note)
            let paper = try require(editor.laidOut(note))
            expectEqual(paper.width, 320)
            let size = CGSize(width: 360 * zoom, height: 260 * zoom), inView = editor.camera.toView(paper)
            let drawn = renderBitmap(editor, size: size, scale: scale)
            expect(editor.beginEditing(note))
            expectEqual(editor.editingFrame, paper, "at \(scale)×, zoom \(zoom): the view lies over the paper")
            let fill = renderBitmap(editor, size: size, scale: scale)
            let editing = try require(editor.makeEditingView())
            let edited = renderBitmap(editor, size: size, scale: scale, editing: editing)
            let tops = lineTops(drawn, over: fill, in: inView, scale: scale)
            expect(tops.count >= 5, "at \(scale)×, zoom \(zoom): the render's lines, \(tops)")
            expectEqual(lineTops(edited, over: fill, in: inView, scale: scale), tops, "at \(scale)×, zoom \(zoom): the editor's lines")
            let difference = largestDifference(drawn, edited, in: inView, scale: scale)
            expect(difference <= antiAliasing, "at \(scale)×, zoom \(zoom): a pixel differs by \(difference)")
            editor.endEditing()
        }
    },
    test("typing stores the height the words need at the stored width, and nothing of the rows") {
        let rows = Rows()
        let editor = try makeEditor(rows)
        let note = editor.add(StickyNote(frame: CGRect(x: 20, y: 15, width: 200, height: 200)))
        editor.setRows(rows, rows96, for: note)
        expect(editor.beginEditing(note))
        let editing = try require(editor.makeEditingView())
        let textView = try require(editing.firstResponder as? NSTextView)
        textView.insertText(lines(14), replacementRange: textView.selectedRange())
        // Fourteen lines of 19 points, half a point spare, rounded up, and the padding: 299.
        expectEqual(editor.stored(note), CGRect(x: 20, y: 15, width: 200, height: 14 * 19 + 1 + 32))
        let paper = try require(editor.laidOut(note))
        expectEqual(paper.width, 320)
        expectEqual(paper.height, padding + (14 * 19 + 1) + gap + 96 + padding, "laid out by the rows beside the words")
        editor.endEditing()
    },
    test("the rows gone, announced: the note is its stored size again") {
        let rows = Rows()
        let editor = try makeEditor(rows)
        let note = editor.add(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 100), text: MentionText(plain: "A line of words")))
        let revision = editor.revision
        expectEqual(editor.laidOut(note), CGRect(x: 0, y: 0, width: 200, height: 100), "a plain note is its stored box")
        editor.setRows(rows, RowsExtent(minimumWidth: 320, height: 48), for: note)
        // Never shorter than a new note while it has rows.
        expectEqual(editor.laidOut(note), CGRect(x: 0, y: 0, width: 320, height: 200))
        expectEqual(editor.stored(note), CGRect(x: 0, y: 0, width: 200, height: 100))
        editor.setRows(rows, nil, for: note)
        expectEqual(editor.laidOut(note), CGRect(x: 0, y: 0, width: 200, height: 100))
        expectEqual(editor.revision, revision, "a layout change is no commit")
    },
    test("zoomed out, the skeleton's paper is the laid-out frame") {
        let rows = Rows()
        let editor = try makeEditor(rows, zoom: 0.3)
        let note = editor.add(StickyNote(frame: CGRect(x: 50, y: 50, width: 200, height: 200)))
        editor.setRows(rows, RowsExtent(minimumWidth: 320, height: 300), for: note)
        let paper = try require(editor.laidOut(note))
        expectEqual(paper, CGRect(x: 50, y: 50, width: 320, height: 332))
        let drawn = renderBitmap(editor, size: CGSize(width: 200, height: 200))
        let yellow = [255, 222, 115, 255]
        @MainActor func isYellow(_ point: CGPoint) -> Bool { zip(pixel(drawn, at: point), yellow).allSatisfy { abs($0 - $1) <= 3 } }
        // Past the stored frame (to 75) and inside the paper (to 111 across, 114 down), and outside it.
        expect(isYellow(CGPoint(x: 100, y: 100)), "paper past the stored frame: \(pixel(drawn, at: CGPoint(x: 100, y: 100)))")
        expect(isYellow(CGPoint(x: 108, y: 112)), "paper at its far corner")
        expect(!isYellow(CGPoint(x: 120, y: 100)), "none past it")
        expect(!isYellow(CGPoint(x: 100, y: 120)), "none below it")
    },
    test("a pill lies in the words' box at the laid-out width, and wraps where the render does") {
        let rows = Rows()
        let editor = try makeEditor(rows)
        var groceries = ShapeRecord(StickyNote(frame: CGRect(x: 600, y: 15, width: 200, height: 200), text: "Milk"))
        groceries[TitleProperty.self] = "Groceries"
        let text = MentionText([.text("Ask about the cake with "), .mention(groceries.id, label: "Groceries"), .text(" tomorrow")])
        let note = ShapeRecord(StickyNote(frame: CGRect(x: 20, y: 15, width: 200, height: 200), text: text))
        editor.transact { $0.insert(groceries); $0.insert(note) }
        let before = try require(editor.mentionPills(of: note.id).first)
        editor.setRows(rows, rows96, for: note.id)
        let pill = try require(editor.mentionPills(of: note.id).first)
        let words = try require(editor.words(of: note.id))
        expect(words.contains(pill.frame), "\(pill.frame) in \(words)")
        expect(pill.frame.minY < before.frame.minY, "on the first line at 288, where it wrapped at 168: \(pill.frame), \(before.frame)")
    },
    test("a type's highlights fall on its words where the note lays them out") {
        let rows = Rows()
        let b = try TypeNoteBench(plugins: [rows.plugin])
        let id = b.add(jiraSchema, words: jiraWords, width: 200)
        b.frame()
        let before = try b.line(of: "link to it", on: id)
        b.editor.setRows(rows, rows96, for: id)
        b.frame()
        let after = try b.line(of: "link to it", on: id)
        let words = try require(b.editor.words(of: id))
        expect(words.contains(after), "\(after) in \(words)")
        expect(after != before, "wrapped at another width: \(after), \(before)")
    },
    test("the same words at the same width are measured once, whatever the rows say, and again at another width") {
        let rows = Rows()
        let editor = try makeEditor(rows)
        let words = "Measured once \(UUID().uuidString)"
        let note = editor.add(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: MentionText(plain: words)))
        let start = NoteWordsCounts.measured
        editor.setRows(rows, rows96, for: note)
        _ = renderBitmap(editor, size: CGSize(width: 400, height: 300))
        expectEqual(NoteWordsCounts.measured, start + 1, "measured when first laid out")
        editor.setRows(rows, RowsExtent(minimumWidth: 320, height: 200), for: note)
        _ = renderBitmap(editor, size: CGSize(width: 400, height: 300))
        let height = try require(editor.words(of: note)).height
        expectEqual(editor.laidOut(note)?.height, padding + height + gap + 200 + padding, "laid out by the new rows")
        expectEqual(NoteWordsCounts.measured, start + 1, "the rows changed, the words were not measured again")
        editor.setRows(rows, RowsExtent(minimumWidth: 400, height: 200), for: note)
        expectEqual(editor.laidOut(note)?.width, 400)
        expectEqual(NoteWordsCounts.measured, start + 2, "another width")
    },
    test("a plain note drawn in full asks the provider and measures nothing") {
        let rows = Rows()
        let editor = try makeEditor(rows)
        _ = editor.add(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: MentionText(plain: "Plain \(UUID().uuidString)")))
        _ = renderBitmap(editor, size: CGSize(width: 400, height: 300))
        let asked = rows.asked, measured = NoteWordsCounts.measured
        _ = renderBitmap(editor, size: CGSize(width: 400, height: 300))
        expect(rows.asked > asked, "asked each time it is drawn")
        expectEqual(NoteWordsCounts.measured, measured)
    },
])
