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

// A note laid out by its words and what goes under them (`NoteLayout`): the stored box while it has no
// rows, and, with them (a note that is a type, or is one), as wide and taller from the same top-left, its
// words wrapping where they did with none. The stored box stays the note as it is with no rows. Types
// provides the rows (`RowBook`): a type of n text fields stands for them here.

/// A note's padding all round, and the gap between its words and the rows under them.
private let padding: CGFloat = 16, gap: CGFloat = 12

@MainActor private func makeEditor(zoom: CGFloat = 1) throws -> CanvasEditor {
    let editor = CanvasEditor(registry: try Registry(plugins: notePlugins), scheduler: ManualScheduler())
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

    /// A type note of `count` text fields (`FieldFixtures.wide`), far from the notes under test.
    @MainActor fileprivate func addType(fields count: Int, words: String = "", title: String = "Wide") -> ShapeID {
        var note = ShapeRecord(StickyNote(frame: CGRect(x: 4000, y: 4000, width: 200, height: 200), text: MentionText(plain: words)))
        note[TypeSchemaProperty.self] = SchemaText(FieldFixtures.wide(count).schema)
        note[TitleProperty.self] = title
        let record = AnyShapeRecord(note)
        transact { $0.insert(record) }
        return record.id
    }

    /// A note that is each of `types`.
    @MainActor fileprivate func addNote(of types: [ShapeID], frame: CGRect, text: MentionText = "") -> ShapeID {
        var note = ShapeRecord(StickyNote(frame: frame, text: text))
        note[IsAProperty.self] = types.map(TypeLink.init)
        let record = AnyShapeRecord(note)
        transact { $0.insert(record) }
        return record.id
    }
}

/// `count` short lines, each its own, so how tall they are doesn't depend on where they wrap.
private func lines(_ count: Int) -> String { (1...count).map { "x\($0)" }.joined(separator: "\n") }

/// What the rows of `count` rows take with words over them, and without.
@MainActor private func rowsHeight(_ count: Int, hasWords: Bool = true) -> CGFloat {
    (hasWords ? TypesStyle.rowsLead : 0) + CGFloat(count) * TypesStyle.rowHeight
}

/// How many lines of `text` a note stored 200 wide wraps to, with the rows of a four-field type if `typed`:
/// its words' height over the line.
@MainActor private func wrappedLines(of text: MentionText, typed: Bool) throws -> Int {
    let editor = try makeEditor()
    let type = editor.addType(fields: 4)
    let note = typed ? editor.addNote(of: [type], frame: CGRect(x: 20, y: 20, width: 200, height: 200), text: text)
                     : editor.add(StickyNote(frame: CGRect(x: 20, y: 20, width: 200, height: 200), text: text))
    let words = try require(editor.words(of: note))
    return Int((words.height / 19).rounded())
}

@MainActor let noteLayoutTests = Suite("Note layout", [
    test("with no rows a note is its stored frame, its words that inset by the padding, and nothing is measured") {
        let editor = try makeEditor()
        let measured = NoteWordsCounts.measured
        let id = editor.add(StickyNote(frame: CGRect(x: 40, y: 30, width: 200, height: 200), text: MentionText(plain: lines(3))))
        _ = renderBitmap(editor, size: CGSize(width: 400, height: 300))
        expectEqual(editor.laidOut(id), CGRect(x: 40, y: 30, width: 200, height: 200))
        expectEqual(editor.words(of: id), CGRect(x: 56, y: 46, width: 168, height: 168))
        expectEqual(NoteWordsCounts.block(of: id, in: editor), nil)
        expectEqual(editor.shapeContext.geometry(of: id)?.bounds, editor.stored(id))
        expectEqual(NoteWordsCounts.measured, measured, "and no measure")
    },
    test("a new note of a four-field type keeps its width: 260 wide, 200 tall, the words at 228 and the rows right under them") {
        let editor = try makeEditor()
        let type = editor.addType(fields: 4)
        let new = CGRect(origin: CGPoint(x: 40, y: 30), size: StickyNote.defaultSize)
        expectEqual(new.size, CGSize(width: 260, height: 200), "a new note's size")
        let id = editor.addNote(of: [type], frame: new, text: MentionText(plain: lines(3)))
        let frame = try require(editor.laidOut(id))
        expectEqual(frame, new)
        let words = try require(editor.words(of: id))
        expectEqual(words.minX, 56)
        expectEqual(words.minY, 46)
        expectEqual(words.width, 260 - 2 * padding)
        expect(abs(words.height - 3 * 19) <= 1.5, "three lines tall: \(words.height)")
        let block = try require(NoteWordsCounts.block(of: id, in: editor))
        expectEqual(block, CGRect(x: 56, y: words.maxY + gap, width: 260 - 2 * padding, height: rowsHeight(4)))
        expect(frame.maxY >= block.maxY + padding, "the paper holds its rows and the padding")
        expectEqual(editor.stored(id), new, "what is stored is the note with no rows")
        expectEqual(editor.shapeContext.geometry(of: id)?.bounds, frame, "its geometry is the paper")
    },
    test("as tall as the padding, the words, the gap, the rows and the padding need; paper left over is under the rows") {
        let editor = try makeEditor()
        let type = editor.addType(fields: 4)
        let tall = editor.addNote(of: [type], frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: MentionText(plain: lines(20)))
        let short = editor.addNote(of: [type], frame: CGRect(x: 600, y: 0, width: 200, height: 600), text: MentionText(plain: lines(3)))
        let words = try require(editor.words(of: tall))
        expect(abs(words.height - 20 * 19) <= 1.5, "twenty lines: \(words.height)")
        expectEqual(editor.laidOut(tall)?.height, padding + words.height + gap + rowsHeight(4) + padding)
        expectEqual(editor.laidOut(tall)?.width, 200, "as wide as it stores")
        let block = try require(NoteWordsCounts.block(of: tall, in: editor))
        expectEqual(block.minY, words.maxY + gap, "the rows right under the words")
        expectEqual(editor.laidOut(tall)?.maxY, block.maxY + padding)
        // Stored taller than it needs: its height stays, and the paper is under the rows.
        expectEqual(editor.laidOut(short)?.height, 600)
        let shortBlock = try require(NoteWordsCounts.block(of: short, in: editor))
        expect(shortBlock.maxY + padding < 600, "paper under the rows: \(shortBlock)")
    },
    test("no words, no gap: the rows start at the padding, and no lead opens them") {
        let editor = try makeEditor()
        let type = editor.addType(fields: 10)
        let id = editor.addNote(of: [type], frame: CGRect(x: 10, y: 10, width: 200, height: 200))
        // Ten fields: eight rows and `+2 more`.
        let rows = rowsHeight(9, hasWords: false)
        expectEqual(editor.words(of: id)?.height, 0)
        expectEqual(NoteWordsCounts.block(of: id, in: editor), CGRect(x: 26, y: 26, width: 200 - 2 * padding, height: rows))
        expectEqual(editor.laidOut(id), CGRect(x: 10, y: 10, width: 200, height: padding + rows + padding))
    },
    test("as wide as it stores, wide or narrow: rows never widen a note") {
        let editor = try makeEditor()
        let type = editor.addType(fields: 2)
        let wide = editor.addNote(of: [type], frame: CGRect(x: 0, y: 0, width: 500, height: 200))
        let narrow = editor.addNote(of: [type], frame: CGRect(x: 0, y: 300, width: 120, height: 200))
        expectEqual(editor.laidOut(wide)?.width, 500)
        expectEqual(editor.words(of: wide)?.width, 468)
        expectEqual(editor.laidOut(narrow)?.width, 120)
        expectEqual(editor.words(of: narrow)?.width, 88)
    },
    test("its words wrap where they do with no rows: a type moves no word") {
        let editor = try makeEditor()
        let type = editor.addType(fields: 4)
        let text = MentionText(plain: "Ask about the cake and the candles and then the plates for the party tomorrow at noon")
        let plain = editor.add(StickyNote(frame: CGRect(x: 20, y: 20, width: 200, height: 200), text: text))
        let typed = editor.addNote(of: [type], frame: CGRect(x: 20, y: 400, width: 200, height: 200), text: text)
        let plainWords = try require(editor.words(of: plain)), typedWords = try require(editor.words(of: typed))
        expectEqual(typedWords.width, plainWords.width, "the same width to wrap at")
        expect(try wrappedLines(of: text, typed: true) > 1, "and it wraps there")
    },
    test("the editor's lines fall on the render's at the width the note stores, at 1× and 2×, zoomed in and out, and its view is laid over the paper") {
        for (scale, zoom) in [(1, 1), (2, 1), (1, 2), (2, 0.6)] as [(CGFloat, CGFloat)] {
            let editor = try makeEditor(zoom: zoom)
            let type = editor.addType(fields: 4)
            let note = editor.addNote(of: [type], frame: CGRect(origin: CGPoint(x: 20, y: 15), size: StickyNote.defaultSize), text: MentionText(plain: multiLineText))
            let paper = try require(editor.laidOut(note))
            expectEqual(paper.width, StickyNote.defaultSize.width)
            let size = CGSize(width: 360 * zoom, height: 300 * zoom), inView = editor.camera.toView(paper)
            let drawn = renderBitmap(editor, size: size, scale: scale)
            expect(editor.beginEditing(note))
            expectEqual(editor.editingFrame, paper, "at \(scale)×, zoom \(zoom): the view lies over the paper")
            let fill = renderBitmap(editor, size: size, scale: scale)
            let editing = try require(editor.makeEditingView())
            let edited = renderBitmap(editor, size: size, scale: scale, editing: editing)
            let tops = lineTops(drawn, over: fill, in: inView, scale: scale)
            expect(tops.count >= 5, "at \(scale)×, zoom \(zoom): the render's lines, \(tops)")
            expectEqual(lineTops(edited, over: fill, in: inView, scale: scale), tops, "at \(scale)×, zoom \(zoom): the editor's lines")
            // The words' lines are held; the rows under them are drawn under the editor and not compared here.
            let words = editor.camera.toView(try require(editor.words(of: note)))
            let difference = largestDifference(drawn, edited, in: words, scale: scale)
            expect(difference <= antiAliasing, "at \(scale)×, zoom \(zoom): a pixel differs by \(difference)")
            editor.endEditing()
        }
    },
    test("typing stores the height the words need at the stored width, and nothing of the rows") {
        let editor = try makeEditor()
        let type = editor.addType(fields: 4)
        let note = editor.addNote(of: [type], frame: CGRect(x: 20, y: 15, width: 200, height: 200))
        expect(editor.beginEditing(note))
        let editing = try require(editor.makeEditingView())
        let textView = try require(editing.firstResponder as? NSTextView)
        textView.insertText(lines(14), replacementRange: textView.selectedRange())
        // Fourteen lines of 19 points, half a point spare, rounded up, and the padding: 299.
        expectEqual(editor.stored(note), CGRect(x: 20, y: 15, width: 200, height: 14 * 19 + 1 + 32))
        let paper = try require(editor.laidOut(note))
        expectEqual(paper.width, 200)
        expectEqual(paper.height, padding + (14 * 19 + 1) + gap + rowsHeight(4) + padding, "laid out by the rows beside the words")
        editor.endEditing()
    },
    test("the type removed, announced: the note that was one is its stored size again, as wide as it was, and the type's own note too") {
        let editor = try makeEditor()
        let type = editor.addType(fields: 4, words: "A wide type")
        let note = editor.addNote(of: [type], frame: CGRect(x: 0, y: 0, width: 200, height: 100), text: MentionText(plain: "A line of words"))
        let stored = CGRect(x: 0, y: 0, width: 200, height: 100)
        // Never shorter than a new note while it has rows, and never wider than it stores.
        expectEqual(editor.laidOut(note), CGRect(x: 0, y: 0, width: 200, height: 200))
        expectEqual(editor.laidOut(type)?.width, 200)
        expectEqual(editor.stored(note), stored)
        editor.removeType(type)
        expectEqual(editor.laidOut(note), stored, "its type is no type, so it has no rows")
        expectEqual(editor.laidOut(type)?.size, CGSize(width: 200, height: 200))
        editor.undo()
        expectEqual(editor.laidOut(note)?.size, CGSize(width: 200, height: 200), "and back")
    },
    test("zoomed out, the skeleton's paper is the laid-out frame") {
        let editor = try makeEditor(zoom: 0.3)
        let type = editor.addType(fields: 10)
        let note = editor.addNote(of: [type], frame: CGRect(x: 50, y: 50, width: 200, height: 200))
        let paper = try require(editor.laidOut(note))
        // Ten fields: nine rows, 16 above and below.
        expectEqual(paper, CGRect(x: 50, y: 50, width: 200, height: padding + rowsHeight(9, hasWords: false) + padding))
        let drawn = renderBitmap(editor, size: CGSize(width: 200, height: 200))
        let yellow = [255, 222, 115, 255]
        @MainActor func isYellow(_ point: CGPoint) -> Bool { zip(pixel(drawn, at: point), yellow).allSatisfy { abs($0 - $1) <= 3 } }
        // Past the stored frame (below its 250) and inside the paper, and outside it.
        let inside = editor.camera.toView(CGPoint(x: paper.maxX - 2, y: paper.maxY - 2)), pastStored = editor.camera.toView(CGPoint(x: 150, y: 265))
        let right = editor.camera.toView(CGPoint(x: paper.maxX + 14, y: 150)), below = editor.camera.toView(CGPoint(x: 150, y: paper.maxY + 14))
        expect(isYellow(pastStored), "paper past the stored frame: \(pixel(drawn, at: pastStored))")
        expect(isYellow(inside), "paper at its far corner")
        expect(!isYellow(right), "none past it")
        expect(!isYellow(below), "none below it")
    },
    test("a pill lies in the words' box, on the line it has with no rows") {
        let editor = try makeEditor()
        let type = editor.addType(fields: 4)
        var groceries = ShapeRecord(StickyNote(frame: CGRect(x: 600, y: 15, width: 200, height: 200), text: "Milk"))
        groceries[TitleProperty.self] = "Groceries"
        let text = MentionText([.text("Ask about the cake with "), .mention(groceries.id, label: "Groceries"), .text(" tomorrow")])
        let plain = ShapeRecord(StickyNote(frame: CGRect(x: 20, y: 15, width: 200, height: 200), text: text))
        var typed = ShapeRecord(StickyNote(frame: CGRect(x: 20, y: 515, width: 200, height: 200), text: text))
        typed[IsAProperty.self] = [TypeLink(type)]
        editor.transact { $0.insert(groceries); $0.insert(plain); $0.insert(typed) }
        let before = try require(editor.mentionPills(of: plain.id).first)
        let pill = try require(editor.mentionPills(of: typed.id).first)
        let words = try require(editor.words(of: typed.id))
        expect(words.contains(pill.frame), "\(pill.frame) in \(words)")
        let plainWords = try require(editor.words(of: plain.id))
        expect(abs((pill.frame.minY - words.minY) - (before.frame.minY - plainWords.minY)) < 0.5,
               "on the same line typed as plain: \(pill.frame), \(before.frame)")
    },
    test("a type's highlights fall on its words where the note lays them out") {
        let b = try TypeNoteBench()
        let id = b.add(jiraSchema, words: jiraWords, width: 200)
        b.frame()
        let after = try b.line(of: "link to it", on: id)
        let words = try require(b.editor.words(of: id))
        expectEqual(words.width, 200 - 2 * padding, "laid out at the width it stores")
        expect(words.contains(after), "\(after) in \(words)")
    },
    test("the same words at the same width are measured once, whatever the rows say, and again at another width") {
        let editor = try makeEditor()
        let type = editor.addType(fields: 4)
        let words = "Measured once \(UUID().uuidString)"
        let note = editor.addNote(of: [type], frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: MentionText(plain: words))
        let start = NoteWordsCounts.measured
        _ = renderBitmap(editor, size: CGSize(width: 400, height: 300))
        expectEqual(NoteWordsCounts.measured, start + 1, "measured when first laid out")
        let before = try require(editor.words(of: note)).height
        // A field added to the type: the rows change, the words are not measured again.
        editor.transact { $0.update(type) { $0[TypeSchemaProperty.self] = SchemaText(FieldFixtures.wide(6).schema) } }
        _ = renderBitmap(editor, size: CGSize(width: 400, height: 300))
        let height = try require(editor.words(of: note)).height
        expectEqual(height, before)
        expectEqual(editor.laidOut(note)?.height, max(200, padding + height + gap + rowsHeight(6) + padding), "laid out by the new rows")
        expectEqual(NoteWordsCounts.measured, start + 1, "the rows changed, the words were not measured again")
        let wider = editor.addNote(of: [type], frame: CGRect(x: 0, y: 500, width: 400, height: 200), text: MentionText(plain: words))
        expectEqual(editor.laidOut(wider)?.width, 400)
        expectEqual(NoteWordsCounts.measured, start + 2, "another width")
    },
    test("a plain note drawn in full measures nothing, and a typed note's words are measured once however often it is drawn") {
        let editor = try makeEditor()
        _ = editor.add(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: MentionText(plain: "Plain \(UUID().uuidString)")))
        _ = renderBitmap(editor, size: CGSize(width: 400, height: 300))
        let measured = NoteWordsCounts.measured
        _ = renderBitmap(editor, size: CGSize(width: 400, height: 300))
        expectEqual(NoteWordsCounts.measured, measured)
    },
])
