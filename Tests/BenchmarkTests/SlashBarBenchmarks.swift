import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import CoreGraphics
import Foundation
import Frames
import LanguageModels
import Mentions
import Selection
import ShippedTesting
import SlashCommands
import StickyNotes
import TestKit
import Titles

// The command bar (`SlashBarBenchmarks.swift`): `/` on a selection of every note of a board, the list the bar opens
// with made from their records once and the card shown, and a keystroke in its field, which ranks the list kept for
// the selection and reads no record; and the `@` on `/move-to`'s line with a thousand notes selected, which asks
// the command's rule of each frame for them all. The shipped list, in the app's canvas view in an unshown window.

extension Budget {
    /// `/` with every one of 10,000 notes selected, the file changed since the bar last looked (a commit between opens),
    /// so what the selection offers is made again from their records: the bar's card and field made, its list opened
    /// (the thread's CPU, release). A first figure, to be set from a quiet run.
    static let slashBarOpen = 50.0
    /// A keystroke in the bar's field over 10,000 selected notes: the list kept for the selection ranked again, and
    /// the line marked, with no record read (the thread's CPU, release). A first figure, to be set from a quiet run.
    static let slashBarKeystroke = 2.0
    /// The `@` typed on `/move-to`'s line in the bar with 1,000 notes selected, on a board of 10,000 notes and five
    /// frames that take them: the picker listing the frames, each asked of `Drop` for the 1,000, which makes their
    /// block twice and asks each whether it can change (the thread's CPU, release: some 28 to 30 ms at a load of 6, 42
    /// to 48 at a load of 14; once an `@`). A keystroke after it is the picker's (`pickerKeystroke`, some 0.8 ms): the
    /// rule's answers are kept while the file stands (`OfferedSlashCommand`'s), where asking again took as long as the `@`.
    static let slashBarPickerOpen = 50.0
}

/// `count` plain notes in rows of a hundred.
@MainActor private func plainNotes(_ count: Int) -> (CanvasDocument, [ShapeID]) {
    var records: [AnyShapeRecord] = []
    for index in 0..<count {
        let origin = CGPoint(x: CGFloat(index % 100) * 220, y: CGFloat(index / 100) * 220)
        let note = StickyNote(frame: CGRect(origin: origin, size: CGSize(width: 200, height: 200)), text: MentionText(plain: "note \(index)"))
        records.append(AnyShapeRecord(ShapeRecord(note)))
    }
    return (CanvasDocument(shapes: records), records.map { $0.id })
}

/// Five titled frames under the notes of `plainNotes(count)`, each big enough for the block of its first `selected`.
@MainActor private func framesUnder(_ count: Int, holding selected: Int) -> [AnyShapeRecord] {
    let rows = (count + 99) / 100, blockRows = (selected + 99) / 100
    let size = CGSize(width: CGFloat(min(selected, 100)) * 220 + 200, height: CGFloat(blockRows) * 220 + 200)
    return (0..<5).map { index in
        var frame = ShapeRecord(Frame(frame: CGRect(origin: CGPoint(x: 0, y: CGFloat(rows) * 220 + 500 + CGFloat(index) * (size.height + 500)), size: size)))
        frame[TitleProperty.self] = "Frame \(index)"
        return AnyShapeRecord(frame)
    }
}

@MainActor let slashBarBenchmarks = Suite("Command bar benchmarks", [
    test("/ on every note of a board selected opens the bar, its list made once from their records; a keystroke in it ranks the kept list") {
        for size in sizes {
            let (document, ids) = plainNotes(size)
            let editor = ShippedPlugins.makeEditor(document: document, scheduler: ManualScheduler(), model: ScriptedLanguageModel())
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            let canvas = CanvasView(editor: editor)
            canvas.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
            window.contentView = canvas
            editor.selectedShapeIDs = ids
            let bar = try require(editor.slashBar)
            var nudge: CGFloat = 1
            let open = median(runs: 11, prepare: {
                bar.close()
                window.makeFirstResponder(canvas)
                editor.transact { $0.update(ids[0], as: StickyNote.self) { $0.props.frame.origin.x += nudge } }
                nudge = -nudge
            }, onThread: true) { bar.open(on: ids) }
            expect(bar.isOpen, "the bar opened")
            let field = try require(bar.field)
            expect(bar.typing?.picker?.listed.isEmpty == false, "its list")
            #if DEBUG
            let read = editor.slashCommands?.recordsRead ?? 0
            #endif
            let keystroke = median(runs: 21, prepare: {
                if field.string == "/c" { field.deleteBackward(nil) }
            }, onThread: true) { field.insertText("c", replacementRange: field.selectedRange()) }
            #if DEBUG
            expectEqual(editor.slashCommands?.recordsRead, read, "a keystroke reads no record: the selection's list is kept")
            #endif
            expect(bar.isOpen)
            report(String(format: "%6d notes selected, the command bar: / %6.3f ms (budget %.0f), a keystroke %6.3f ms (budget %.0f)",
                          size, open, Budget.slashBarOpen, keystroke, Budget.slashBarKeystroke))
            if holdsToBudgets {
                expect(open < Budget.slashBarOpen, "/ on \(size) selected notes took \(open) ms")
                expect(keystroke < Budget.slashBarKeystroke, "a keystroke in the bar over \(size) selected notes took \(keystroke) ms")
            }
            bar.close()
        }
    },

    test("the @ on /move-to's line in the bar with a thousand notes selected lists the five frames that take them all, and a keystroke after it ranks them") {
        for size in sizes {
            let selected = min(1_000, size)
            let (notes, ids) = plainNotes(size)
            let frames = framesUnder(size, holding: selected)
            let editor = ShippedPlugins.makeEditor(document: CanvasDocument(shapes: notes.shapes + frames), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            let canvas = CanvasView(editor: editor)
            canvas.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
            window.contentView = canvas
            let chosen = Array(ids.prefix(selected))
            editor.selectedShapeIDs = chosen
            let bar = try require(editor.slashBar)
            bar.open(on: chosen)
            let field = try require(bar.field as? MentionTextView<AnyMentionable>, "Mentions' field")
            field.insertText("move-to ", replacementRange: field.selectedRange())
            // A commit between opens, so the rule is asked afresh: its answers are kept while the file stands.
            var nudge: CGFloat = 1
            let at = median(runs: 11, prepare: {
                field.closePicker()
                if field.string.hasSuffix("@") { field.deleteBackward(nil) }
                editor.transact { $0.update(frames[4].id, as: Frame.self) { $0.props.frame.origin.x += nudge } }
                nudge = -nudge
            }, onThread: true) { field.insertText("@", replacementRange: field.selectedRange()) }
            expect(bar.isOpen, "the bar stays through the commits")
            expectEqual(field.picker?.rows.compactMap(\.candidate?.id), frames.map(\.id), "the five frames, nearest first")
            let keystroke = median(runs: 11, prepare: {
                if field.string.hasSuffix("@f") { field.deleteBackward(nil) }
            }, onThread: true) { field.insertText("f", replacementRange: field.selectedRange()) }
            expectEqual(field.picker?.rows.compactMap(\.candidate?.id).count, 5, "the five frames match")
            report(String(format: "%6d notes, %5d selected, /move-to's @ in the bar: the @ %6.3f ms (budget %.0f), a keystroke %6.3f ms (budget %.0f)",
                          size, selected, at, Budget.slashBarPickerOpen, keystroke, Budget.pickerKeystroke))
            if holdsToBudgets {
                expect(at < Budget.slashBarPickerOpen, "the @ on /move-to's line with \(selected) notes selected took \(at) ms")
                expect(keystroke < Budget.pickerKeystroke, "a keystroke there took \(keystroke) ms")
            }
            bar.close()
        }
    },
])
