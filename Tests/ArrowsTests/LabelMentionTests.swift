import Adornments
import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Mentions
import Selection
import SlashCommands
import TableOfContents
import TestKit
import Titles
import Types

// An arrow's label is mention text: pills, drawn and edited as a note's are, `@` and slash commands
// in its editor, a rename drawing the shapes it mentions as they are called now. Fixtures only: boxes
// that are titled and mentioned (`LabelFixturesPlugin`), and a `head` command.

/// The most a pixel may differ, in any channel (0...255), between the render and the editor's text:
/// anti-aliasing. A line a point off differs by more than 200.
private let antiAliasing = 16
/// Where pills are: a quarter. A pill's edges are anti-aliased by string drawing on the canvas and by
/// TextKit 2 in the editor, each its own way.
private let pillAntiAliasing = 64

/// Where each pill in a text view's text is, in the view's coordinates: TextKit 2's frame for each
/// attachment, in text order.
@MainActor private func attachmentFrames(in view: NSTextView) -> [CGRect] {
    guard let layout = view.textLayoutManager, let content = layout.textContentManager, let storage = view.textStorage else { return [] }
    layout.ensureLayout(for: layout.documentRange)
    var frames: [CGRect] = []
    storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
        guard value is MentionAttachment,
              let location = content.location(content.documentRange.location, offsetBy: range.location),
              let fragment = layout.textLayoutFragment(for: location) else { return }
        let frame = fragment.frameForTextAttachment(at: location)
        guard !frame.isEmpty else { return }
        frames.append(frame.offsetBy(dx: fragment.layoutFragmentFrame.minX + view.textContainerOrigin.x,
                                     dy: fragment.layoutFragmentFrame.minY + view.textContainerOrigin.y))
    }
    return frames
}

/// The largest difference in any channel between two bitmaps within a rect of view points, but for
/// the pixels in `excluded`.
@MainActor private func largestDifference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, in rect: CGRect, excluding excluded: [CGRect],
                                          scale: CGFloat) -> Int {
    var p = [Int](repeating: 0, count: 4), q = [Int](repeating: 0, count: 4)
    var largest = 0
    for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
        for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
            let point = CGPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)
            guard !excluded.contains(where: { $0.contains(point) }) else { continue }
            a.getPixel(&p, atX: x, y: y)
            b.getPixel(&q, atX: x, y: y)
            largest = max(largest, zip(p, q).map { abs($0 - $1) }.max() ?? 0)
        }
    }
    return largest
}

private func isClose(_ a: CGRect, _ b: CGRect, within tolerance: CGFloat) -> Bool {
    abs(a.minX - b.minX) <= tolerance && abs(a.maxX - b.maxX) <= tolerance
        && abs(a.minY - b.minY) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
}

/// A free arrow from (100, 200) to (500, 200) labelled `text`, on a board with two titled boxes below it.
@MainActor private func mentionBoard(_ text: (ShapeID, ShapeID) -> MentionText, scale: CGFloat = 1)
    throws -> (h: EditorHarness, arrow: ShapeID, groceries: ShapeID, sam: ShapeID) {
    let h = try EditorHarness(plugins: labelPlugins())
    let groceries = h.editor.addBox("Groceries", at: CGRect(x: 100, y: 300, width: 100, height: 80))
    let sam = h.editor.addBox("Sam about the cake", at: CGRect(x: 300, y: 300, width: 100, height: 80))
    let arrow = h.add(Arrow(start: .free(CGPoint(x: 100, y: 200)), end: .free(CGPoint(x: 500, y: 200)), text: text(groceries, sam)))
    return (h, arrow, groceries, sam)
}

@MainActor private func said(_ h: EditorHarness, _ id: ShapeID) -> MentionText? { h.editor.document[id]?.typed(as: Arrow.self)?.props.text }

/// The arrow's label being edited in a window nothing shows (`MentionTextView` hosts slash commands
/// and the `@` picker for an owner): the editing view in a flipped view, its text view the first
/// responder, the caret at the end.
@MainActor final class EditedLabel {
    let h: EditorHarness
    let arrow: ShapeID
    let groceries: ShapeID
    /// A type called Person, on the board, and a relationship type called Employment: what an arrow's `/is-a` offers.
    let person: ShapeID
    let employment: ShapeID
    let window: NSWindow
    let textView: MentionTextView<AnyMentionable>

    init(_ text: MentionText = "") throws {
        h = try EditorHarness(plugins: labelPlugins())
        groceries = h.editor.addBox("Groceries", at: CGRect(x: 100, y: 300, width: 100, height: 80))
        person = h.editor.addType("Person", at: CGRect(x: 300, y: 300, width: 100, height: 80))
        let marked = h.editor.addType("Employment", at: CGRect(x: 500, y: 300, width: 100, height: 80))
        h.editor.transact { $0.update(marked) { $0[RelationshipProperty.self] = true } }
        employment = marked
        arrow = h.add(Arrow(start: .free(CGPoint(x: 100, y: 200)), end: .free(CGPoint(x: 500, y: 200)), text: text))
        h.editor.selection = arrow
        expect(h.editor.beginEditing(arrow))
        let view = try require(h.editor.makeEditingView())
        window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = LabelCanvas(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        window.contentView = canvas
        // Room for the text to be typed, as the canvas would lay the view over the label that grows with it.
        view.view.frame = CGRect(x: 100, y: 100, width: 300, height: 120)
        canvas.addSubview(view.view)
        textView = try require(view.firstResponder as? MentionTextView<AnyMentionable>, "the label's editor is a mention text view")
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: textView.textStorage?.length ?? 0, length: 0))
    }

    /// The label's text on the board: what the editor last wrote.
    var committed: MentionText? { said(h, arrow) }
    var props: Arrow? { h.editor.document[arrow]?.typed(as: Arrow.self)?.props }
}

private final class LabelCanvas: NSView {
    override var isFlipped: Bool { true }
}

@MainActor let labelMentionTests = Suite("Arrow labels: mention text", [
    test("a label holds pills: they're its edges, and measured as live pills by the names they hold") {
        let (h, id, groceries, sam) = try mentionBoard { groceries, sam in
            MentionText([.text("asks "), .mention(groceries, label: "Groceries"), .text(" for "), .mention(sam, label: "Sam about the cake")])
        }
        let plain = h.add(Arrow(start: .free(CGPoint(x: 100, y: 600)), end: .free(CGPoint(x: 500, y: 600)), text: "asks  for "))
        let pills = try require(h.editor.arrowLabelFrame(of: id)), bare = try require(h.editor.arrowLabelFrame(of: plain))
        expect(pills.width > bare.width + 60, "the pills are in the label: \(pills) against \(bare)")
        expectEqual(h.editor.mentionPills(of: id).map(\.isLive), [true, true])
        expectEqual(h.editor.mentionPills(of: id).map(\.target), [groceries, sam])
        for pill in h.editor.mentionPills(of: id) {
            expect(pills.insetBy(dx: LabelMetrics.padding, dy: LabelMetrics.padding).contains(pill.frame), "\(pill.frame) is inside the label \(pills)")
        }
        expectEqual(try require(h.editor.mentions).mentioners(of: groceries), [id], "what mentions the groceries is the arrow")
        expectEqual(h.editor.mentionPills(of: plain).count, 0)
    },
    test("with pills, the editor's lines and pills fall where the render draws them, at 1× and 2×: nothing moves when editing starts") {
        for scale: CGFloat in [1, 2] {
            // A pill among words, one on a line of its own, a long one, and a missing one.
            let (h, id, _, _) = try mentionBoard { groceries, sam in
                MentionText([.text("asks "), .mention(groceries, label: "Groceries"), .text(" for it\nthen "), .mention(sam, label: "Sam about the cake"),
                             .text("\n"), .mention(ShapeID(), label: "Gone"), .text(" too")])
            }
            let frame = try require(h.editor.arrowLabelFrame(of: id))
            let canvas = CGSize(width: 600, height: 450)
            let drawn = renderBitmap(h.editor, size: canvas, scale: scale)
            let pills = h.editor.mentionPills(of: id)
            expectEqual(pills.map(\.isLive), [true, true, false], "at \(scale)×: the canvas's pills")
            expect(h.editor.beginEditing(id))
            let editing = try require(h.editor.makeEditingView())
            let textView = try require(editing.firstResponder as? NSTextView)
            textView.setSelectedRange(NSRange(location: 0, length: 0))       // all of it is selected as editing begins
            let edited = renderBitmap(h.editor, size: canvas, scale: scale, editing: editing)
            let inEditor = attachmentFrames(in: textView).map { $0.offsetBy(dx: frame.minX, dy: frame.minY) }
            expectEqual(inEditor.count, pills.count, "at \(scale)×: the editor's pills")
            for (onCanvas, inText) in zip(pills.map(\.frame), inEditor) {
                expect(isClose(onCanvas, inText, within: 0.01), "at \(scale)×: a pill at \(onCanvas) on the canvas is at \(inText) in the editor")
            }
            let onPills = pills.map { h.editor.camera.toView($0.frame).insetBy(dx: -1, dy: -1) }
            let box = frame.insetBy(dx: 1, dy: 1)
            let offPills = largestDifference(drawn, edited, in: box, excluding: onPills, scale: scale)
            expect(offPills <= antiAliasing, "at \(scale)×: the text is where the render has it: a pixel differs by \(offPills); label \(frame)")
            let whole = largestDifference(drawn, edited, in: box, scale: scale)
            expect(whole <= pillAntiAliasing, "at \(scale)×: and the pills: \(whole)")
            h.editor.endEditing()
        }
    },
    test("what's typed is written to the arrow as mention text, the label grown with it, in one step; undo takes it back") {
        let (h, id, _, _) = try mentionBoard { _, _ in "scall" }
        h.editor.selection = id
        expect(h.editor.beginEditing(id))
        let view = try require(h.editor.makeEditingView())
        let textView = try require(view.firstResponder as? MentionTextView<AnyMentionable>)
        let before = try require(h.editor.arrowLabelFrame(of: id))
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        textView.insertText(" the cache, then \\@[x](shape:1)", replacementRange: textView.selectedRange())
        expectEqual(said(h, id), MentionText(plain: "scall the cache, then \\@[x](shape:1)"), "text that looks like a mention stays text")
        let after = try require(h.editor.editingFrame)
        expect(after.width > before.width + 30, "grown with it: \(after) against \(before)")
        expectEqual(after, h.editor.arrowLabelFrame(of: id), "laid over the label")
        h.editor.endEditing()
        expectEqual(h.editor.undoHistory.undoName, "Typing")
        h.editor.undo()
        expectEqual(said(h, id), "scall")
    },
    // The label is measured by the names its mentions show now: Mentions hands the arrow's geometry
    // those that differ from the names the text holds (a layout input), and tells the editor when a
    // rename, on any board, changes them, so the label is laid out again. Nothing is stored: no step,
    // no edit, the text still holds the names it was written with.
    test("a rename lays the label out by the names the pills show now, on the same board and on another, and undo takes it back") {
        let (h, id, groceries, sam) = try mentionBoard { groceries, sam in
            MentionText([.text("asks "), .mention(groceries, label: "Groceries"), .text(" for "), .mention(sam, label: "Sam about the cake")])
        }
        let frame = try require(h.editor.arrowLabelFrame(of: id))
        @MainActor func expectPillsInside(_ message: String) throws {
            let label = try require(h.editor.arrowLabelFrame(of: id))
            for pill in h.editor.mentionPills(of: id) {
                expect(label.insetBy(dx: LabelMetrics.padding, dy: LabelMetrics.padding).contains(pill.frame), "\(message): \(pill.frame) is inside \(label)")
            }
        }
        let long = "Errands and every other thing on the long list of things to buy"
        let held = said(h, id)
        let steps = h.editor.undoHistory.undoName
        h.editor.rename(groceries, to: "Errands")
        expectEqual(said(h, id), held, "a rename writes nothing to the text")
        let shorter = try require(h.editor.arrowLabelFrame(of: id))
        expect(shorter.width < frame.width, "a shorter name: a narrower label, \(shorter) against \(frame)")
        try expectPillsInside("after a rename to a shorter name")

        h.editor.rename(groceries, to: long)
        let longer = try require(h.editor.arrowLabelFrame(of: id))
        expect(longer.width > frame.width || longer.height > frame.height, "a longer name: a bigger label, \(longer) against \(frame)")
        try expectPillsInside("after a rename to a longer name, nothing wraps past the label")
        expectEqual(said(h, id), held, "still nothing written")

        h.editor.undo()
        expectEqual(h.editor.arrowLabelFrame(of: id), shorter, "undoing the rename lays it out as it was")
        h.editor.undo()
        expectEqual(h.editor.arrowLabelFrame(of: id), frame, "and back")
        expectEqual(h.editor.undoHistory.undoName, steps, "the layout was no step of its own")
        h.editor.redo()
        h.editor.redo()
        expectEqual(h.editor.arrowLabelFrame(of: id), longer, "redo")
        // An edit would write the names as they are now: the same label.
        let edited = h.add(Arrow(start: .free(CGPoint(x: 100, y: 200)), end: .free(CGPoint(x: 500, y: 200)),
                                 text: MentionText([.text("asks "), .mention(groceries, label: long), .text(" for "), .mention(sam, label: "Sam about the cake")])))
        expectEqual(h.editor.arrowLabelFrame(of: edited), longer, "as an edit would have it")

        // On another board.
        let a = ShapeRecord(Box(boxA)), pocket = ShapeRecord(Pocket(boxB))
        var inner = ShapeRecord(Box(boxA))
        inner[TitleProperty.self] = "Inside"
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(a), AnyShapeRecord(pocket)]),
                              children: [pocket.id: CanvasDocument(shapes: [AnyShapeRecord(inner)])])
        let across = try EditorHarness(plugins: labelPlugins(before: [PocketsPlugin()]), file: file)
        let arrow = across.add(Arrow(start: .free(CGPoint(x: 100, y: 500)), end: .free(CGPoint(x: 500, y: 500)),
                                     text: MentionText([.text("sees "), .mention(inner.id, label: "Inside")])))
        let pillBefore = try require(across.editor.mentionPills(of: arrow).first)
        expect(pillBefore.isLive, "a pill for a shape on another board is live")
        let labelBefore = try require(across.editor.arrowLabelFrame(of: arrow))
        across.editor.undoHistory.breakStep()
        across.editor.transact(on: BoardID(owner: pocket.id), "Rename") { $0.update(inner.id) { $0[TitleProperty.self] = "Out" } }
        expectEqual(across.editor.mentions?.resolve(inner.id).appearance?.label, "Out", "the name now, from the other board")
        let pillAfter = try require(across.editor.mentionPills(of: arrow).first)
        expect(pillAfter.frame.width < pillBefore.frame.width, "drawn by it: a pill narrower than it was, \(pillAfter.frame) against \(pillBefore.frame)")
        let labelAfter = try require(across.editor.arrowLabelFrame(of: arrow))
        expect(labelAfter.width < labelBefore.width, "and the label with it: \(labelAfter) against \(labelBefore)")
        // The undo takes the rename back on the board it was made on, which it shows; the arrow's board comes back.
        across.editor.undo()
        expect(across.editor.showBoard(.root))
        expectEqual(across.editor.arrowLabelFrame(of: arrow), labelBefore, "undone")
    },
    // The arrow's board is left, kept ready by the editor with its geometry; a rename made on the board
    // shown meanwhile must reach what's kept, or the board comes back with the label as it was.
    test("a rename made while the arrow's board is away lays its label out when the board is shown again") {
        let a = ShapeRecord(Box(boxA)), pocket = ShapeRecord(Pocket(boxB))
        var inner = ShapeRecord(Box(boxA))
        inner[TitleProperty.self] = "Inside the pocket of the long name"
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(a), AnyShapeRecord(pocket)]),
                              children: [pocket.id: CanvasDocument(shapes: [AnyShapeRecord(inner)])])
        let h = try EditorHarness(plugins: labelPlugins(before: [PocketsPlugin()]), file: file)
        let arrow = h.add(Arrow(start: .free(CGPoint(x: 100, y: 500)), end: .free(CGPoint(x: 500, y: 500)),
                                text: MentionText([.text("sees "), .mention(inner.id, label: "Inside the pocket of the long name")])))
        let before = try require(h.editor.arrowLabelFrame(of: arrow))
        let inside = BoardID(owner: pocket.id)
        expect(h.editor.showBoard(inside))
        h.editor.rename(inner.id, to: "Out")
        expect(h.editor.showBoard(.root))
        let after = try require(h.editor.arrowLabelFrame(of: arrow))
        expect(after.width < before.width, "the label on the board kept ready is laid out by the name now: \(after) against \(before)")
        expect(h.editor.showBoard(inside))
        h.editor.undo()
        expect(h.editor.showBoard(.root))
        expectEqual(h.editor.arrowLabelFrame(of: arrow), before, "undone")
    },
    test("a paste or an undo of an arrow whose text holds an old name is laid out by the name now") {
        let (h, id, groceries, _) = try mentionBoard { groceries, _ in MentionText([.text("asks "), .mention(groceries, label: "Groceries")]) }
        let held = try require(h.editor.arrowLabelFrame(of: id))
        h.editor.rename(groceries, to: "Errands")
        let renamed = try require(h.editor.arrowLabelFrame(of: id))
        expect(renamed.width < held.width)
        // Deleted and brought back, the text still holds "Groceries".
        h.editor.transact("Delete") { $0.delete([id]) }
        expectEqual(h.editor.arrowLabelFrame(of: id), nil)
        h.editor.undo()
        expectEqual(h.editor.arrowLabelFrame(of: id), renamed, "laid out by the name now")
    },
    test("an arrow's row reads the names its label mentions now, and a rename remakes the row") {
        let (h, id, groceries, _) = try mentionBoard { groceries, _ in MentionText([.text("\n asks "), .mention(groceries, label: "Groceries"), .text(" \nthen more")]) }
        @MainActor func row() -> ContentsLabel? { h.editor.tableOfContents?.entries.first { $0.id == id }?.label }
        expectEqual(row()?.text, "asks @Groceries")
        h.editor.rename(groceries, to: "Errands")
        expectEqual(row()?.text, "asks @Errands", "the name now, not the one the label holds")
        let lone = h.add(Arrow(start: .free(CGPoint(x: 100, y: 600)), end: .free(CGPoint(x: 500, y: 600)), text: MentionText([.mention(groceries, label: "Groceries")])))
        expectEqual(h.editor.tableOfContents?.entries.first { $0.id == lone }?.label?.text, "@Errands", "a label of a mention alone says something")
        expect(h.editor.arrowLabelFrame(of: lone) != nil, "and has a label")
    },
    test("text that reads as a mention is escaped by the arrow's migration; a label of whitespace and no mention says nothing") {
        let (h, id, _, _) = try mentionBoard { _, _ in MentionText(plain: " \n ") }
        expectEqual(h.editor.arrowLabelFrame(of: id), nil)
        let lookalike = h.add(Arrow(start: .free(CGPoint(x: 100, y: 600)), end: .free(CGPoint(x: 500, y: 600)), text: MentionText(plain: "@[x](shape:1234)")))
        expectEqual(h.editor.mentionPills(of: lookalike).count, 0)
        expectEqual(said(h, lookalike)?.runs, [.text("@[x](shape:1234)")])
    },
])

@MainActor let labelSlashTests = Suite("Arrow labels: commands and the picker", [
    test("a slash on a new line of a label lists the commands the arrow offers; Return on one runs it and takes the line out of the label") {
        let session = try EditedLabel("keep")
        let typing = try require(session.textView.slashCommands, "the label's editor hosts slash commands")
        session.window.type("/")
        expect(typing.picker == nil, "mid-line a slash is a slash")
        session.window.pressDelete()
        session.window.pressReturn()
        expectEqual(session.committed, "keep\n", "Return is a new line, as in tldraw")
        session.window.type("/")
        let picker = try require(typing.picker, "the list is open")
        expect(picker.listed.map(\.name).contains("head"), "\(picker.listed.map(\.name))")
        expect(session.textView.caretListWindow === typing.window)
        session.window.type("he")
        expectEqual(picker.highlightedCommand?.name, "head")
        session.window.settle()
        let heads = session.props?.endArrowhead
        session.window.pressReturn()
        session.window.settle()
        expectEqual(session.props?.endArrowhead, heads.map { !$0 }, "the command ran")
        expectEqual(session.committed, "keep\n", "the line is gone from the label, its line break is not")
        expect(typing.picker == nil)
        expectEqual(session.h.editor.undoHistory.undoName, "Head")
        session.h.editor.undo()
        expectEqual(session.props?.endArrowhead, heads, "Undo Head")
        expectEqual(session.h.editor.undoHistory.undoName, "Typing", "the step before it is the typing")
    },
    test("a command line that isn't one stays text: Return is a new line") {
        let session = try EditedLabel("keep")
        session.window.pressReturn()
        session.window.type("/head now")
        let heads = session.props?.endArrowhead
        session.window.pressReturn()
        expectEqual(session.props?.endArrowhead, heads, "/head takes no arguments")
        expectEqual(session.committed, "keep\n/head now\n")
    },
    test("an @ in a label lists the shapes to mention; Return picks one: a pill, in the label, the label grown with it") {
        let session = try EditedLabel("sees")
        let before = try require(session.h.editor.editingFrame)
        session.window.type(" @gro")
        let picker = try require(session.textView.picker, "the @ picker")
        expectEqual(picker.rows.compactMap(\.candidate?.id), [session.groceries])
        session.window.pressReturn()
        expect(session.textView.picker == nil)
        expectEqual(session.committed?.mentioned, [session.groceries])
        expectEqual(session.committed?.runs.first, .text("sees "))
        expect(try require(session.h.editor.editingFrame).width > before.width + 30, "grown with the pill")
        session.window.pressEscape()
    },
])

@MainActor let labelTypeTests = Suite("Arrow labels: /is-a", [
    test("an arrow offers /is-a, taking one choice: the list on its line holds the relationship types and no Type row, Groceries and Person being none; Return picks one and runs the line") {
        let session = try EditedLabel("keep")
        let typing = try require(session.textView.slashCommands)
        session.window.pressReturn()
        session.window.type("/is")
        expectEqual(typing.picker?.highlightedCommand?.name, "is-a")
        session.window.press("\t", code: 48)
        let choices = try require(typing.choices, "the choices")
        expectEqual(choices.listed.map(\.title), ["Employment"], "Groceries is no type, Person is a plain one, and an arrow's label has no Type row")
        session.window.pressReturn()
        session.window.settle()
        expectEqual(session.h.editor.document[session.arrow]?[IsAProperty.self]?.map(\.shape), [session.employment], "the arrow is an Employment")
        expectEqual(session.committed, "keep\n", "the line is gone from the label, its line break is not")
        expectEqual(session.h.editor.undoHistory.undoName, "Add Type")
        session.h.editor.undo()
        expectEqual(session.h.editor.document[session.arrow]?[IsAProperty.self], nil)
        expectEqual(session.h.editor.undoHistory.undoName, "Typing")
        session.window.pressEscape()
    },
    test("the arrow's chips sit above its label, in a row from its left: the title's pill's place, then one for each type") {
        let session = try EditedLabel("keep")
        session.window.pressEscape()
        session.h.editor.addTypeLink(session.person, to: session.arrow)
        let label = try require(session.h.editor.arrowLabelFrame(of: session.arrow))
        let chip = try require(session.h.editor.adornmentFrames(of: session.arrow).first { $0.adornment == .of(TypeChips.self) })
        expectEqual(chip.label.text, "Person")
        expect(chip.rect.maxY < label.minY, "above the label: \(chip.rect) against \(label)")
        expect(chip.rect.minX >= label.minX - 70 && chip.rect.minX <= label.maxX, "at the label, not at the body's bounds: \(chip.rect) against \(label)")
        session.h.editor.transact("Rename") { $0.update(session.person) { $0[TitleProperty.self] = "Human" } }
        expectEqual(session.h.editor.adornmentFrames(of: session.arrow).first { $0.adornment == .of(TypeChips.self) }?.label.text, "Human")
    },
])

/// What the tests above measure a label against: the padding between its text and its edge.
private enum LabelMetrics {
    static let padding: CGFloat = 4
}
