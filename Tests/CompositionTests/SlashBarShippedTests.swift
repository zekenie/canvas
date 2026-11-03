import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Colors
import CoreGraphics
import Frames
import LanguageModels
import Locking
import Mentions
import References
import Selection
import ShippedTesting
import SlashCommands
import StickyNotes
import Subboards
import TestKit
import TextEditing
import Titles
import Types

// The command bar as shipped: `/` on the canvas with shapes selected opens a line under them, where a
// slash command is typed for them and run on them with Return, in the app's canvas view. Its field is
// Mentions' text, so a pill typed in it is a shape a command takes: `/move-to @Groceries`.

/// The shipped plugins in an editor over an empty board, in the app's canvas view in an unshown window,
/// the canvas with the keyboard, the test's own pasteboard (`ShippedPlugins.pasteboard`).
@MainActor private final class ShippedBar {
    let editor: CanvasEditor
    let window: NSWindow
    let canvas: CanvasView

    init(model: ScriptedLanguageModel = ScriptedLanguageModel()) {
        editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: model)
        (window, canvas) = windowed(editor)
        window.makeFirstResponder(canvas)
    }

    var bar: SlashBar? { editor.slashBar }
    var field: EditingTextView? { bar?.field }
    var typing: SlashCommandTyping? { bar?.typing }
    var listed: [String] { typing?.picker?.listed.map(\.name) ?? [] }
    var rows: [String] {
        typing?.picker?.rows.compactMap(\.item).map { item in item.detail.map { "\(item.title) (\($0))" } ?? item.title } ?? []
    }

    func note(_ x: CGFloat, _ y: CGFloat, _ text: MentionText = "") -> ShapeID {
        editor.add(StickyNote(frame: CGRect(x: x, y: y, width: 200, height: 200), text: text))
    }

    /// The bar's field, Mentions' text view.
    var mentionField: MentionTextView<AnyMentionable>? { field as? MentionTextView<AnyMentionable> }
    /// What the field's `@` picker lists, in order.
    var pickerTargets: [ShapeID] { mentionField?.picker?.rows.compactMap(\.candidate?.id) ?? [] }
    func box(_ id: ShapeID) -> CGRect? { editor.file.record(id)?.box }
    func container(of id: ShapeID) -> ShapeID? { editor.document.container(of: id, containingKinds: editor.registry.containingKinds) }

    /// `/` on the canvas, the canvas with the keyboard.
    func slash() {
        window.makeFirstResponder(canvas)
        window.type("/")
    }
}

@MainActor let slashBarShippedTests = Suite("The command bar, as shipped", [
    test("/query: with nothing selected / opens for every note, query last; Return asks the model and selects what its query finds, the bar gone; on those two it narrows them; on one it isn't offered") {
        let model = ScriptedLanguageModel()
        let s = ShippedBar(model: model)
        let milk = s.note(100, 100, "Buy milk"), eggs = s.note(400, 100, "Buy eggs")
        _ = s.note(700, 100, "Call Sam")
        s.slash()
        expect(s.bar?.isOpen == true, "nothing selected: every note")
        expectEqual(s.bar?.label, "All shapes")
        expectEqual(s.listed, ["lock", "public", "is-a", "color", "move-to", "move-near", "bring-to-front", "send-to-back", "bring-in-front-of", "send-behind", "bulk-create", "query"],
                    "what three notes offer, then the commands about every shape: /bulk-create, /query")
        model.queue(#":contains("buy")"#)
        s.window.type("query the shopping")
        s.window.pressReturn()
        expect(s.bar?.isWaiting == true, "it waits for the model")
        expect(spinRunLoop(until: { s.bar?.isOpen != true }), "and closes once it has selected")
        expectEqual(s.editor.selectedShapeIDs, [milk, eggs])
        expectEqual(s.editor.announcements.last, "2 shapes selected")
        expect(message(of: model.requests.last).contains("Nothing is selected."), "asked as --ask asks")
        s.slash()
        model.queue(#":contains("milk")"#)
        s.window.type("query the milk one")
        s.window.pressReturn()
        expect(spinRunLoop(until: { s.bar?.isOpen != true }))
        expectEqual(s.editor.selectedShapeIDs, [milk], "narrowed")
        expect(message(of: model.requests.last).contains("The question picks out some of the selected shapes"))
        s.slash()
        expect(!s.listed.contains("query"), "one note: no /query")
        expectEqual(s.editor.undoHistory.undoName, nil, "selecting is no step")
    },

    test("a note selected: / lists what the bar can run on it, col and Return open the colors, bl and Return color it blue in one step, the bar gone and the canvas with the keyboard") {
        let s = ShippedBar()
        let note = s.note(100, 100, "Groceries")
        s.editor.selection = note
        s.slash()
        expect(s.bar?.isOpen == true)
        expectEqual(s.listed, ["title", "lock", "public", "is-a", "color", "move-to", "move-near", "bring-to-front", "send-to-back", "bring-in-front-of", "send-behind"], "Moving's two, then Reordering's four")
        s.window.type("col")
        s.window.pressReturn()
        expectEqual(s.field?.string, "/color ")
        expect(s.typing?.choices != nil, "the colors")
        s.window.type("bl")
        s.window.pressReturn()
        expect(s.bar?.isOpen != true)
        expect(s.window.firstResponder === s.canvas)
        expectEqual(s.editor.document[note]?.ownColor, .blue)
        expectEqual(s.editor.selection, note)
        expectEqual(s.editor.undoHistory.undoName, "Change Color")
        s.editor.undo()
        expectEqual(s.editor.document[note]?.ownColor, nil)
    },

    test("two notes and a frame selected: /color's pick colors all three in one step; a note and a reference list it as color · 1 of 2, a reference having no color") {
        let s = ShippedBar()
        let shapes = [s.note(100, 100, "one"), s.note(320, 100, "two"),
                      s.editor.add(Frame(frame: CGRect(x: 100, y: 400, width: 500, height: 300)), title: "Group")]
        s.editor.selectedShapeIDs = shapes
        s.slash()
        s.window.type("color")
        s.window.pressReturn()
        s.window.type("teal")
        s.window.pressReturn()
        expect(s.bar?.isOpen != true)
        expectEqual(shapes.map { s.editor.document[$0]?.ownColor }, [.teal, .teal, .teal])
        expectEqual(s.editor.undoHistory.undoName, "Change Color")
        s.editor.undo()
        expectEqual(shapes.map { s.editor.document[$0]?.ownColor }, [nil, nil, nil], "one step")

        let reference = s.editor.add(Reference(frame: CGRect(x: 700, y: 100, width: 120, height: 32)))
        s.editor.selectedShapeIDs = [shapes[0], reference]
        s.slash()
        expect(s.rows.contains("color (color · 1 of 2)"), "\(s.rows)")
    },

    test("ten notes selected: /is-a feat lists New type “Feat”, and Return puts one type note beside them, makes all ten Feats in one step and edits the new note's name, the bar gone") {
        let s = ShippedBar()
        let notes = (0..<10).map { index in s.note(100 + CGFloat(index % 5) * 240, 100 + CGFloat(index / 5) * 240, MentionText(plain: "Note \(index)")) }
        s.editor.selectedShapeIDs = notes
        s.slash()
        s.window.type("is-a feat")
        expectEqual(s.typing?.choices?.listed.map(\.title), ["New type “Feat”"], "no type is called that: the new one, alone and highlighted")
        s.window.pressReturn()
        expect(s.bar?.isOpen != true, "the bar closed before it ran")
        let feat = try require(s.editor.document.shapes.map(\.id).first { !notes.contains($0) }, "the new note")
        expectEqual(s.editor.document[feat]?[TitleProperty.self], "Feat")
        expect(notes.allSatisfy { s.editor.document[$0]?[IsAProperty.self]?.map(\.shape) == [feat] }, "all ten are Feats")
        expectEqual(s.editor.editingShapeID, feat, "the new type is edited, as a placed note is")
        expectEqual(s.editor.undoHistory.undoName, "New Type")
        s.editor.endEditing()
        s.editor.undo()
        expectEqual(s.editor.document[feat], nil, "one step: the note goes")
        expect(notes.allSatisfy { s.editor.document[$0]?[IsAProperty.self] == nil }, "and the ten links")
    },

    test("a frame selected: / lists turn-into-subboard first, and Return turns it into a subboard whose board holds what it held, one step") {
        let s = ShippedBar()
        var frameRecord = ShapeRecord(Frame(frame: CGRect(x: 100, y: 100, width: 600, height: 400)))
        frameRecord[TitleProperty.self] = "Sprint"
        let frame = frameRecord.id
        s.editor.transact { $0.insert(frameRecord) }
        let a = s.note(130, 150, "One"), b = s.note(400, 150, "Two")
        s.editor.put([a, b], in: frame)
        s.editor.selection = frame
        s.slash()
        expectEqual(s.listed.first, "turn-into-subboard", "typeable nowhere before: a frame has no text")
        s.window.type("turn")
        s.window.pressReturn()
        expect(s.bar?.isOpen != true)
        expectEqual(s.editor.document[frame]?.kind, Subboard.kind)
        expectEqual(Set(s.editor.file[BoardID(owner: frame)].shapes.map(\.id)), [a, b])
        expectEqual(s.editor.undoHistory.undoName, "Turn into Subboard")
        s.editor.undo()
        expectEqual(s.editor.document[frame]?.kind, Frame.kind)
    },

    test("a locked note selected: / lists unlock alone, and Return unlocks it in one step, Unlock") {
        let s = ShippedBar()
        let note = s.note(100, 100, "Locked away")
        s.editor.lock([note])
        s.editor.selection = note
        s.slash()
        expectEqual(s.listed, ["unlock"])
        s.window.pressReturn()
        expect(!s.editor.isLocked(note))
        expectEqual(s.editor.undoHistory.undoName, "Unlock")
    },

    test("three notes selected: /move-to @ lists the titled frames and subboards that take all three, nearest first, not a frame too small for them; Return picks Groceries, a second moves the three into it as one block, 40 in, one step, and Undo Move takes it back") {
        let s = ShippedBar()
        let notes = [s.note(100, 100, "one"), s.note(320, 100, "two"), s.note(100, 320, "three")]
        let groceries = s.editor.add(Frame(frame: CGRect(x: 600, y: 100, width: 600, height: 500)), title: "Groceries")
        s.editor.add(Frame(frame: CGRect(x: 100, y: 700, width: 300, height: 300)), title: "Tiny")
        let plans = s.editor.add(Subboard(frame: CGRect(x: 1400, y: 100, width: 240, height: 160)), title: "Plans")
        s.editor.add(Frame(frame: CGRect(x: 600, y: 1400, width: 600, height: 500)))
        s.editor.selectedShapeIDs = notes
        s.slash()
        expect(s.listed.contains("move-to") && s.listed.contains("move-near"))
        s.window.type("move-to @")
        expectEqual(s.pickerTargets, [groceries, plans], "Tiny is nearer but too small for the three, and the frame with no title has no name")
        s.window.pressReturn()
        expect(s.mentionField?.picker == nil, "Return picked Groceries")
        expect(s.bar?.isOpen == true)
        s.window.pressReturn()
        expect(s.bar?.isOpen != true, "the bar closed before it ran")
        expectEqual(notes.map { s.box($0)?.origin }, [CGPoint(x: 640, y: 140), CGPoint(x: 860, y: 140), CGPoint(x: 640, y: 360)],
                    "one block, 40 in from the frame's top-left, each where it was to the others")
        expectEqual(notes.map(s.container(of:)), [groceries, groceries, groceries])
        expectEqual(s.editor.selectedShapeIDs, notes, "the selection kept")
        expect(s.window.firstResponder === s.canvas)
        expectEqual(s.editor.undoHistory.undoName, "Move")
        s.editor.undo()
        expectEqual(notes.map { s.box($0)?.origin }, [CGPoint(x: 100, y: 100), CGPoint(x: 320, y: 100), CGPoint(x: 100, y: 320)], "all three back in one step")
    },

    test("two notes selected: /move-near @mil puts them beside Milk as one block, 80 away, kept where they were to each other") {
        let s = ShippedBar()
        let one = s.note(100, 100, "one"), two = s.note(320, 100, "two")
        let milk = s.note(100, 1000, "Milk")
        s.editor.selectedShapeIDs = [one, two]
        s.slash()
        s.window.type("move-near @mil")
        expectEqual(s.pickerTargets.first, milk)
        s.window.pressReturn()
        s.window.pressReturn()
        let beside = try require(s.box(milk)), first = try require(s.box(one)), second = try require(s.box(two))
        expectEqual(first.origin, CGPoint(x: beside.maxX + 80, y: beside.midY - 100), "the block's left edge 80 off, centered on Milk")
        expectEqual(second.minX - first.minX, 220)
        expectEqual(second.minY, first.minY)
        expectEqual(s.editor.undoHistory.undoName, "Move")
    },

    test("two notes selected: /move-to @pla moves them onto the subboard's board, and the window goes after them, both selected there") {
        let s = ShippedBar()
        let notes = [s.note(100, 100, "one"), s.note(320, 100, "two")]
        let plans = s.editor.add(Subboard(frame: CGRect(x: 1400, y: 100, width: 240, height: 160)), title: "Plans")
        s.editor.selectedShapeIDs = notes
        s.slash()
        s.window.type("move-to @pla")
        expectEqual(s.pickerTargets, [plans])
        s.window.pressReturn()
        s.window.pressReturn()
        expectEqual(Set(s.editor.file[BoardID(owner: plans)].shapes.map(\.id)), Set(notes), "both on the subboard's board")
        expectEqual(s.editor.board, BoardID(owner: plans), "the window shows the board they went to")
        expectEqual(s.editor.selectedShapeIDs, notes)
        expectEqual(s.editor.undoHistory.undoName, "Move")
        s.editor.undo()
        expectEqual(s.editor.board, .root, "Undo Move shows the board it was made on")
        expect(notes.allSatisfy { s.editor.document[$0] != nil }, "and brings them back")
    },

    test("two notes and the arrow between them selected: move-to acts on the notes, 2 of 3, and the arrow rides along, both its ends following") {
        let s = ShippedBar()
        let one = s.note(100, 100, "one"), two = s.note(500, 100, "two")
        let groceries = s.editor.add(Frame(frame: CGRect(x: 100, y: 500, width: 800, height: 500)), title: "Groceries")
        func bound(_ id: ShapeID) -> ArrowTerminal {
            .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
        }
        let arrow = s.editor.add(Arrow(start: bound(one), end: bound(two)))
        let before = try require(s.editor.shapeContext.geometry(of: arrow)?.bounds)
        s.editor.selectedShapeIDs = [one, two, arrow]
        s.slash()
        expectEqual(s.rows.first { $0.hasPrefix("move-to") }, "move-to (@frame or subboard · 2 of 3)", "an arrow has no box to move")
        s.window.type("move-to @gro")
        s.window.pressReturn()
        s.window.pressReturn()
        expectEqual([one, two].map(s.container(of:)), [groceries, groceries])
        let moved = try require(s.box(one)).origin
        let delta = CGPoint(x: moved.x - 100, y: moved.y - 100)
        let after = try require(s.editor.shapeContext.geometry(of: arrow)?.bounds)
        expectEqual(after.origin, CGPoint(x: before.minX + delta.x, y: before.minY + delta.y), "the arrow went with its ends")
        expectEqual(after.size, before.size)
        expectEqual(s.editor.undoHistory.undoName, "Move")
    },

    test("a note being edited keeps its own /: on a new line it lists in the note, and no bar opens") {
        let s = ShippedBar()
        let note = s.note(100, 100, "keep")
        s.editor.selection = note
        expect(s.editor.beginEditing(note))
        let editing = try require(s.window.firstResponder as? MentionTextView<AnyMentionable>, "the note's editor has the keyboard")
        editing.setSelectedRange(NSRange(location: 4, length: 0))
        s.window.pressReturn()
        s.window.type("/")
        expect(editing.slashCommands?.picker != nil, "the note's own list")
        expect(s.bar?.isOpen != true, "and no bar")
        s.window.pressEscape()
        s.editor.endEditing()
    },
])

/// A request's one user message.
private func message(of request: ModelRequest?) -> String { request?.messages.first?.text ?? "" }
