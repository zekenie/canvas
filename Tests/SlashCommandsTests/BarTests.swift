import AppKit
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import CoreGraphics
import Geometry
import Keyboard
import Selection
import SlashCommands
import TestKit
import TextEditing

// The command bar: `/` on the canvas with shapes selected opens a line under them where a slash command
// is typed for them and run on them with Return. A canvas in an unshown window (the host's part is the
// real one: the card's view, its keyboard, its placing), keys as the keyboard sends them, fixtures only.

private let area = CGRect(x: 100, y: 100, width: 100, height: 60)

/// A canvas in an unshown window, 800 × 600, over the slash fixtures (cards with `CardCommandsPlugin`'s
/// and `ChoicePlugin`'s commands, and, unless left out, `TargetCommandsPlugin`'s), Keyboard, Selection,
/// Freezing and the bar.
@MainActor private final class BarRig {
    let h: EditorHarness
    let log = Reached()
    let commands = CommandLog()
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
    let canvas: CanvasView

    init(targets: Bool = true, more: [any CanvasPlugin] = []) throws {
        var plugins: [any CanvasPlugin] = [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), CardsPlugin(), ChoresPlugin(), PocketsPlugin(),
                                           FreezingPlugin(), SlashCommandsPlugin(), SlashBarPlugin(), CardCommandsPlugin(log: commands),
                                           ChoicePlugin(log: commands)]
        if targets { plugins += [LampsPlugin(), TargetCommandsPlugin(log: log)] }
        h = try EditorHarness(plugins: plugins + more)
        canvas = CanvasView(editor: h.editor)
        canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        window.makeFirstResponder(canvas)
    }

    var editor: CanvasEditor { h.editor }
    var bar: SlashBar? { editor.slashBar }
    var field: EditingTextView? { bar?.field }
    var typing: SlashCommandTyping? { bar?.typing }
    var isOpen: Bool { bar?.isOpen == true }
    var listed: [String] { typing?.picker?.listed.map(\.name) ?? [] }
    var choices: [String] { typing?.choices?.listed.map(\.title) ?? [] }
    /// The open list's rows: the name, and what it says after it, if anything.
    var rows: [String] {
        typing?.picker?.rows.compactMap(\.item).map { item in item.detail.map { "\(item.title) (\($0))" } ?? item.title } ?? []
    }
    var canvasHasKeyboard: Bool { window.firstResponder === canvas }
    func card(_ frame: CGRect = area, text: String = "x") -> ShapeID { h.add(Card(frame, text: text)) }
    func width(_ id: ShapeID) -> CGFloat { editor.document[id]?.box?.width ?? 0 }

    /// `/` on the canvas.
    func slash() { window.press("/") }

    /// The rect the bar hangs from for shapes, as the bar works it out: their bounds out to the outline.
    func anchor(of shapes: [ShapeID]) -> CGRect? {
        guard let bounds = editor.shapeContext.bounds(of: shapes) else { return nil }
        let gap = editor.drawsSkeletons ? 0 : editor.outlineGap / editor.cameraTarget.zoom
        return bounds.insetBy(dx: -gap, dy: -gap)
    }
}

@MainActor let slashBarTests = Suite("The command bar", [
    // MARK: Opening

    test("/ with a card selected opens the bar under it, 4 points below its outline, left edges together, its field with the keyboard and a / listing what the card offers") {
        let rig = try BarRig(targets: false)
        let card = rig.card()
        rig.editor.selection = card
        rig.slash()
        expect(rig.isOpen)
        expectEqual(rig.bar?.shapes, [card])
        let field = try require(rig.field)
        expect(rig.window.firstResponder === field, "the field has the keyboard")
        expectEqual(field.string, "/")
        expectEqual(rig.listed, ["grow", "width", "log", "ping", "any", "pick", "pick-else", "pick-none", "pick-chips"],
                    "what the card offers, less what takes a shape (stack): the field can't name one")
        let frame = try require(rig.canvas.cardFrame)
        let anchor = rig.editor.camera.toView(try require(rig.anchor(of: [card])))
        expectEqual(frame.minY, anchor.maxY + 4, "4 points under the outline")
        expectEqual(frame.minX, anchor.minX, "left edges together")
        expectEqual(frame.size, CGSize(width: 280, height: 28))
        expectEqual(rig.editor.card?.anchor, rig.anchor(of: [card]))
        expectEqual(rig.editor.undoHistory.undoName, nil, "opening it is no step")
    },

    test("/ passes on an empty board with nothing selected, a selection that offers nothing, or while a shape is edited, and opens where a German keyboard's ⇧7 types it") {
        let rig = try BarRig(targets: false)
        rig.slash()
        expect(!rig.isOpen, "nothing selected, and nothing on the board")
        let disc = rig.h.add(Disc(area))
        rig.editor.selection = disc
        rig.slash()
        expect(!rig.isOpen, "a disc offers nothing")
        let card = rig.card(area.offsetBy(dx: 200, dy: 0))
        rig.editor.selection = card
        expect(rig.editor.beginEditing(card))
        expect(!rig.editor.canPerform(.runSlashCommand), "while a shape is edited the key is the text's")
        rig.editor.endEditing()
        rig.window.makeFirstResponder(rig.canvas)
        rig.window.press("/", code: 26, modifiers: [.shift])
        expect(rig.isOpen, "⇧7, which types / on a German keyboard")
        expectEqual(rig.field?.string, "/")
    },

    test("a command about the target that runs at once opens the bar on an empty board, which says it acts on nothing; Return closes the bar and runs it with the target and what was typed, one step named for it") {
        let log = NowLog()
        let rig = try BarRig(targets: false, more: [NowPlugin(log: log)])
        rig.slash()
        expect(rig.isOpen, "an empty board offers stamp")
        expectEqual(rig.bar?.target, .everything([]))
        expectEqual(rig.bar?.label, "", "nothing to act on: no All shapes")
        expectEqual(rig.editor.card?.accessibilityLabel, "Command")
        expectEqual(rig.rows, ["stamp (words)"])
        rig.window.type("stamp a, b")
        rig.window.pressReturn()
        expect(!rig.isOpen)
        expect(rig.canvasHasKeyboard)
        expectEqual(log.ran.count, 1)
        expectEqual(log.ran.first?.target, .everything([]))
        expectEqual(log.ran.first?.arguments.text, "a, b")
        expectEqual(log.ran.first?.barOpen, false, "the bar closed first")
        expectEqual(rig.editor.undoHistory.undoName, "Stamp")
        let card = rig.card()
        rig.editor.selection = card
        rig.slash()
        expect(!rig.listed.contains("stamp"), "its rule: nothing selected only")
        rig.window.pressEscape()
        rig.window.pressEscape()
        rig.window.makeFirstResponder(rig.canvas)
        rig.editor.selectedShapeIDs = []
        rig.slash()
        expectEqual(rig.listed.last, "stamp", "after what the shapes offer")
        expectEqual(rig.bar?.label, "All shapes")
    },

    test("a command that runs at once names its step as it says (`step:`), where its own name isn't what a person would call it") {
        let log = NowLog()
        let rig = try BarRig(targets: false, more: [NowPlugin(log: log, step: "Add Stamp")])
        rig.slash()
        rig.window.type("stamp now")
        rig.window.pressReturn()
        expectEqual(log.ran.count, 1)
        expectEqual(rig.editor.undoHistory.undoName, "Add Stamp")
    },

    test("an offscreen selection is brought into view first, and the bar opens under it") {
        let rig = try BarRig(targets: false)
        let card = rig.card(CGRect(x: 4000, y: 3000, width: 100, height: 60))
        rig.editor.selection = card
        let view = rig.editor.unobscuredViewport
        expect(!rig.editor.camera.toWorld(view).contains(try require(rig.editor.shapeContext.bounds(of: [card]))))
        rig.slash()
        expect(rig.isOpen)
        expect(rig.editor.cameraTarget.toWorld(view).contains(try require(rig.editor.shapeContext.bounds(of: [card]))), "where the camera is headed")
        rig.h.wait(400)
        expect(rig.isOpen, "and it stays through the glide: closed \(String(describing: rig.bar?.lastClosing))")
    },

    test("/ with nothing selected opens it for every shape on the board, as if Select All had: at the top of the canvas's clear part, the camera where it was, saying All shapes; a command runs on them all in one step") {
        let rig = try BarRig(targets: false)
        let a = rig.card(), b = rig.card(area.offsetBy(dx: 200, dy: 100))
        let disc = rig.h.add(Disc(area.offsetBy(dx: 0, dy: 300)))
        let camera = rig.editor.cameraTarget
        rig.slash()
        expect(rig.isOpen)
        expectEqual(rig.bar?.target, .everything([a, b, disc]), "every shape on the board, in document order")
        expectEqual(rig.editor.selectedShapeIDs, [], "nothing is selected")
        expectEqual(rig.bar?.label, "All shapes")
        expectEqual(rig.editor.card?.accessibilityLabel, "Command for all shapes")
        expectEqual(rig.editor.cameraTarget, camera, "nothing brought into view")
        let frame = try require(rig.canvas.cardFrame), view = rig.editor.unobscuredViewport
        expectEqual(frame.size, CGSize(width: 280, height: 28))
        expectEqual(frame.midX, view.midX, "in the middle")
        expectEqual(frame.minY, view.minY + 12, "at the top")
        expectEqual(rig.rows, ["grow (2 of 3)", "width (points · 2 of 3)"], "what a selection of all three lists, counted: the disc offers nothing")
        rig.window.type("gro")
        rig.window.pressReturn()
        expect(!rig.isOpen)
        expectEqual([rig.width(a), rig.width(b)], [110, 110])
        expectEqual(rig.editor.undoHistory.undoName, "Grow")
        expectEqual(rig.editor.selectedShapeIDs, [], "still nothing selected")
        rig.h.scheduler.advance(by: .zero)
        expectEqual(rig.editor.announcements.last, "Grow, on 2 of 3 shapes")
    },

    test("a command that answers later keeps the bar open while it waits, its line in the field and a spinner in the label's place, VoiceOver told it waits; done, it closes") {
        let log = AskLog()
        let rig = try BarRig(targets: false, more: [AskPlugin(log: log)])
        let a = rig.card(), b = rig.card(area.offsetBy(dx: 200, dy: 0))
        rig.editor.selection = a
        rig.slash()
        expect(!rig.listed.contains("ask"), "not on one shape")
        rig.window.pressEscape()
        rig.window.pressEscape()
        rig.window.makeFirstResponder(rig.canvas)
        rig.editor.selectedShapeIDs = [a, b]
        rig.slash()
        expectEqual(rig.listed.last, "ask", "after what the shapes offer")
        rig.window.type("ask the red ones")
        rig.window.pressReturn()
        expect(rig.isOpen, "it waits")
        expect(rig.bar?.isWaiting == true)
        expectEqual(rig.field?.string, "/ask the red ones", "the line kept")
        expectEqual(log.asked.first?.target, .selection([a, b]))
        expectEqual(log.asked.first?.arguments.text, "the red ones")
        expectEqual(rig.editor.announcements.last, "Asking")
        expectEqual(rig.editor.undoHistory.undoName, nil, "starting it is no step")
        expect(spinRunLoop(until: { log.waitingCount == 1 }))
        log.answer(.done)
        expect(spinRunLoop(until: { !rig.isOpen }), "done: it closes")
        expect(rig.canvasHasKeyboard)
        expectEqual(rig.editor.selectedShapeIDs, [a, b])
    },

    test("failed, the bar says why in the label's place and VoiceOver hears it, the line still the person's; an edit says again what it acts on, and Return asks again") {
        let log = AskLog()
        let rig = try BarRig(targets: false, more: [AskPlugin(log: log)])
        let a = rig.card(), b = rig.card(area.offsetBy(dx: 200, dy: 0))
        rig.editor.selectedShapeIDs = [a, b]
        rig.slash()
        rig.window.type("ask the red ones")
        rig.window.pressReturn()
        expect(spinRunLoop(until: { log.waitingCount == 1 }))
        log.answer(.failed("No luck"))
        expect(spinRunLoop(until: { rig.bar?.isWaiting == false }))
        expect(rig.isOpen)
        expectEqual(rig.bar?.failure, "No luck")
        expectEqual(rig.bar?.label, "No luck")
        expectEqual(rig.editor.announcements.last, "No luck")
        expectEqual(rig.field?.string, "/ask the red ones")
        expect(rig.window.firstResponder === rig.field, "the field keeps the keyboard")
        rig.window.type("!")
        expectEqual(rig.bar?.failure, nil, "an edit")
        expectEqual(rig.bar?.label, "2 shapes")
        rig.window.pressReturn()
        expect(rig.bar?.isWaiting == true, "asked again")
        expectEqual(log.asked.count, 2)
        expectEqual(log.asked.last?.arguments.text, "the red ones!")
    },

    test("the editor going (its file closed) stops what the bar waits for, and nothing it waits for keeps the editor alive") {
        let log = AskLog()
        weak var gone: CanvasEditor?
        autoreleasepool {
            guard let rig = try? BarRig(targets: false, more: [AskPlugin(log: log)]) else { return }
            gone = rig.editor
            let a = rig.card(), b = rig.card(area.offsetBy(dx: 200, dy: 0))
            rig.editor.selectedShapeIDs = [a, b]
            rig.slash()
            rig.window.type("ask x")
            rig.window.pressReturn()
            _ = spinRunLoop(until: { log.waitingCount == 1 })
            rig.window.contentView = nil
        }
        expect(spinRunLoop(until: { gone == nil }), "the editor goes with its window")
        expect(spinRunLoop(until: { log.cancelled == 1 }), "and its bar stops the command")
    },

    test("what it waits for stops as it goes: Escape closes it, the selection changing closes it, and an edit stops it and keeps it open") {
        let log = AskLog()
        let rig = try BarRig(targets: false, more: [AskPlugin(log: log)])
        let a = rig.card(), b = rig.card(area.offsetBy(dx: 200, dy: 0)), c = rig.card(area.offsetBy(dx: 400, dy: 0))
        @MainActor func ask() {
            rig.window.makeFirstResponder(rig.canvas)
            rig.editor.selectedShapeIDs = [a, b]
            rig.slash()
            rig.window.type("ask x")
            rig.window.pressReturn()
            _ = spinRunLoop(until: { log.waitingCount == 1 })
        }
        ask()
        rig.window.pressEscape()
        expect(!rig.isOpen, "Escape, with no list open, closes it")
        expect(spinRunLoop(until: { log.cancelled == 1 }), "and stops the command")
        ask()
        rig.editor.selectedShapeIDs = [b, c]
        expect(!rig.isOpen, "the selection changed")
        expect(spinRunLoop(until: { log.cancelled == 2 }))
        ask()
        rig.window.press("\u{7f}", code: 51)
        expect(rig.isOpen, "an edit keeps it")
        expect(rig.bar?.isWaiting == false)
        expect(spinRunLoop(until: { log.cancelled == 3 }), "and stops what it waited for")
        expectEqual(rig.bar?.label, "2 shapes")
    },

    // MARK: The list

    test("its list is what the selection offers, a command on fewer than all counted; typing narrows it, Tab completes, and a choice's rows open after the name") {
        let rig = try BarRig(targets: false)
        let card = rig.card()
        let box = rig.h.add(Box(area.offsetBy(dx: 0, dy: 100)))
        rig.editor.selectedShapeIDs = [card, box]
        rig.slash()
        expectEqual(rig.rows, ["grow (1 of 2)", "width (points · 1 of 2)"], "a card's commands on several; the box offers none")
        rig.window.type("wi")
        expectEqual(rig.listed, ["width"])
        rig.window.press(.tab)
        expectEqual(rig.field?.string, "/width ", "completed, with its space")
        expect(rig.typing?.picker == nil)
        rig.editor.selection = card
        expect(!rig.isOpen, "the selection changed: the bar closed")
        rig.window.makeFirstResponder(rig.canvas)
        rig.slash()
        rig.window.type("pick")
        rig.window.press(.tab)
        expectEqual(rig.choices, ["Alpha", "Beta", "Gamma"], "a choice command's rows, after its name")
    },

    test("the command typed is marked as it is in a note, and a field that can't name a shape lists no command that takes one") {
        let rig = try BarRig(targets: false)
        let card = rig.card()
        rig.editor.selection = card
        rig.slash()
        rig.window.type("grow")
        expect(!(rig.field?.highlights.isEmpty ?? true), "the /name marked")
        expect(!rig.listed.contains("stack"))
        rig.window.pressEscape()
        rig.window.press("\u{7f}", code: 51)
        rig.window.type("w")
        expectEqual(rig.field?.string, "/grow")
        expect(!(rig.field?.highlights.isEmpty ?? true), "a closed line the selection offers, marked")
    },

    // MARK: Running

    test("Return runs the highlighted command on every shape it reaches, one step named for it; the bar is gone first, the canvas has the keyboard, the selection stays, and Undo takes it back whole") {
        let rig = try BarRig(targets: false)
        let a = rig.card(), b = rig.card(area.offsetBy(dx: 200, dy: 0))
        rig.editor.selectedShapeIDs = [a, b]
        rig.slash()
        rig.window.type("gro")
        rig.window.pressReturn()
        expect(!rig.isOpen)
        expect(rig.canvasHasKeyboard, "the canvas has the keyboard back")
        expectEqual(rig.editor.selectedShapeIDs, [a, b])
        expectEqual([rig.width(a), rig.width(b)], [110, 110])
        expectEqual(rig.editor.undoHistory.undoName, "Grow")
        rig.h.scheduler.advance(by: .zero)
        expectEqual(rig.editor.announcements.last, "Grow", "VoiceOver hears the step")
        rig.editor.undo()
        expectEqual([rig.width(a), rig.width(b)], [100, 100])
    },

    test("a whole line runs with Return once its list is closed, a pick runs at once, and a command on fewer than all is announced with how many") {
        let rig = try BarRig(targets: false)
        let a = rig.card(), box = rig.h.add(Box(area.offsetBy(dx: 0, dy: 120)))
        rig.editor.selectedShapeIDs = [a, box]
        rig.slash()
        rig.window.type("width 150")
        expect(rig.typing?.picker == nil, "the space ended the list")
        rig.window.pressReturn()
        expectEqual(rig.width(a), 150)
        expectEqual(rig.editor.undoHistory.undoName, "Width")
        rig.h.scheduler.advance(by: .zero)
        expectEqual(rig.editor.announcements.last, "Width, on 1 of 2 shapes")
        rig.window.makeFirstResponder(rig.canvas)
        rig.editor.selection = a
        rig.slash()
        rig.window.type("pick")
        rig.window.press(.tab)
        rig.window.pressReturn()
        expect(!rig.isOpen)
        expectEqual(rig.width(a), 151, "Beta, the preferred row, picked: the card one wider")
        expectEqual(rig.editor.undoHistory.undoName, "Pick Beta", "the row's step")
    },

    // MARK: Closing

    test("Escape closes the list, then the bar; ⌘. and the / deleted close it too, the selection as it was and the canvas with the keyboard") {
        let rig = try BarRig(targets: false)
        let card = rig.card()
        rig.editor.selection = card
        rig.slash()
        expect(rig.typing?.picker != nil)
        rig.window.pressEscape()
        expect(rig.isOpen, "the first Escape closes the list")
        expect(rig.typing?.picker == nil)
        rig.window.pressEscape()
        expect(!rig.isOpen, "the second, the bar")
        expect(rig.canvasHasKeyboard)
        expectEqual(rig.editor.selection, card)
        rig.slash()
        rig.window.pressEscape()
        rig.window.pressCommandPeriod()
        expect(!rig.isOpen, "⌘.")
        expect(rig.canvasHasKeyboard)
        rig.slash()
        rig.window.press("\u{7f}", code: 51)
        expect(!rig.isOpen, "the / deleted")
        expect(rig.canvasHasKeyboard)
        expectEqual(rig.editor.selection, card)
        expectEqual(rig.editor.undoHistory.undoName, nil, "and nothing ran")
    },

    test("a press on the canvas off it closes it; one on the selection, its own ground, closes it as the canvas takes the keyboard") {
        let rig = try BarRig(targets: false)
        let card = rig.card()
        rig.editor.selection = card
        rig.slash()
        rig.h.press(at: CGPoint(x: 700, y: 500))
        rig.h.release()
        expect(!rig.isOpen, "a press elsewhere")
        rig.window.makeFirstResponder(rig.canvas)
        rig.editor.selection = card
        rig.slash()
        rig.h.press(at: rig.h.view(CGPoint(x: area.midX, y: area.midY)))
        expect(rig.isOpen, "the rect it hangs from is the card's own ground")
        rig.window.makeFirstResponder(rig.canvas)
        expect(!rig.isOpen, "the field gave up the keyboard")
        rig.h.release()
    },

    test("it closes as the selection changes, another board shows, an undo, another card shows, or the keyboard goes to another view") {
        let cases: [(String, @MainActor (BarRig, ShapeID, ShapeID) -> Void)] = [
            ("the selection changed", { rig, _, other in rig.editor.selection = other }),
            ("another board", { rig, _, _ in
                let pocket = rig.h.add(Pocket(CGRect(x: 500, y: 400, width: 100, height: 100)))
                _ = rig.h.enter(pocket)
            }),
            ("an undo", { rig, _, _ in rig.editor.undo() }),
            ("another card", { rig, _, _ in
                _ = rig.editor.showCard(probeCard("other", anchor: area, probe: CardProbe(frame: .zero), closings: ClosingLog()))
            }),
            ("another view", { rig, _, _ in
                let other = NSTextView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
                rig.canvas.addSubview(other)
                rig.window.makeFirstResponder(other)
            }),
        ]
        for (going, happen) in cases {
            let rig = try BarRig(targets: false)
            let card = rig.card(), other = rig.card(area.offsetBy(dx: 300, dy: 0))
            rig.editor.transact("Nudge") { $0.update(other, as: Card.self) { $0.props.frame.origin.y += 1 } }
            rig.editor.selection = card
            rig.slash()
            expect(rig.isOpen, going)
            happen(rig, card, other)
            expect(!rig.isOpen, going)
            expect(rig.field == nil, going)
        }
    },

    test("Tab with nothing to complete does nothing, ⇧Tab closes the list, and keys the bar has no use for reach no shortcut: no tool, no note, no Delete") {
        let rig = try BarRig(targets: false)
        let card = rig.card()
        rig.editor.selection = card
        rig.slash()
        rig.window.type("zzz")
        expectEqual(rig.listed, [], "no matches")
        rig.window.press(.tab)
        expect(rig.isOpen)
        expectEqual(rig.editor.selection, card, "Tab moved nothing")
        rig.window.press(.delete)
        rig.window.press(.delete)
        rig.window.press(.delete)
        rig.window.press(.backTab)
        expect(rig.typing?.picker == nil, "⇧Tab closed the list")
        let revision = rig.editor.revision, tool = rig.editor.currentToolID
        rig.window.type("vnf1]")
        expectEqual(rig.field?.string, "/vnf1]", "typed, not the canvas's keys")
        expectEqual(rig.editor.revision, revision)
        expectEqual(rig.editor.currentToolID, tool)
        expect(rig.editor.document[card] != nil)
    },

    // MARK: Following

    test("a commit that moves what it acts on moves the bar under it; at the window's bottom it goes over the selection") {
        let rig = try BarRig(targets: false)
        let card = rig.card()
        rig.editor.selection = card
        rig.slash()
        rig.editor.transact { $0.update(card, as: Card.self) { $0.props.frame.origin = CGPoint(x: 300, y: 200) } }
        expectEqual(rig.editor.card?.anchor, rig.anchor(of: [card]), "it follows")
        expect(rig.isOpen)
        rig.window.pressEscape()
        rig.window.pressEscape()
        let low = rig.card(CGRect(x: 100, y: 560, width: 100, height: 30))
        rig.editor.selection = low
        rig.slash()
        let frame = try require(rig.canvas.cardFrame)
        let anchor = rig.editor.camera.toView(try require(rig.anchor(of: [low])))
        expectEqual(frame.maxY, anchor.minY - 4, "above, with no room below")
    },

    test("zoomed out, where shapes are skeletons, it opens and works, the same size") {
        let rig = try BarRig(targets: false)
        let a = rig.card(), b = rig.card(area.offsetBy(dx: 0, dy: 100))
        rig.editor.camera.setZoom(0.2, around: .zero)
        expect(rig.editor.drawsSkeletons)
        rig.editor.selectedShapeIDs = [a, b]
        rig.slash()
        expect(rig.isOpen)
        expectEqual(rig.canvas.cardFrame?.size, CGSize(width: 280, height: 28))
        rig.window.type("grow")
        rig.window.pressReturn()
        expectEqual([rig.width(a), rig.width(b)], [110, 110])
    },

    test("a frozen card's bar lists only what a declared command's rule lets act on it: thaw") {
        let rig = try BarRig()
        let card = rig.card()
        rig.editor.freeze([card])
        rig.editor.selection = card
        rig.slash()
        expectEqual(rig.listed, ["thaw"])
        rig.window.pressReturn()
        expect(rig.editor.document[card]?[Frozen.self] != true)
        expectEqual(rig.editor.undoHistory.undoName, "Thaw")
    },

    // MARK: VoiceOver, keys, what's listed

    test("VoiceOver: the bar is named for what it acts on, its field Command, a partial row says how many it acts on") {
        let rig = try BarRig(targets: false)
        let card = rig.card(), box = rig.h.add(Box(area.offsetBy(dx: 0, dy: 100)))
        rig.editor.selection = card
        rig.slash()
        expectEqual(rig.editor.card?.accessibilityLabel, "Command for Card")
        expectEqual(rig.field?.accessibilityLabel(), "Command")
        rig.window.pressEscape()
        rig.window.pressEscape()
        rig.editor.selectedShapeIDs = [card, box]
        rig.slash()
        expectEqual(rig.editor.card?.accessibilityLabel, "Command for 2 shapes")
        expectEqual(rig.typing?.picker?.rows.first?.item?.spoken, "grow, acts on 1 of 2 shapes")
    },

    test("the walk: / goes into the bar, Escape twice comes back out one level at a time to the canvas and the selection, and the field is named") {
        let rig = try BarRig(targets: false)
        let card = rig.card()
        rig.editor.selection = card
        let walk = KeyWalk(rig.window, editor: rig.editor,
                           readers: [.canvas(rig.canvas, selection: { [editor = rig.editor] in editor.selectedShapeIDs.map { _ in "A" } })],
                           settle: .both(rig.h.scheduler))
        expectEqual(walk.focus.id, "canvas/A")
        let field = walk.press(Chord("/"))
        expectEqual(field.id, "window/Command")
        expectEqual(field.label, "Command")
        expect(field.isMarked, "a caret")
        walk.expectEscapeLadder(["window/Command", "canvas/A"])
        expectEqual(walk.presses.count, 3, "one key in, two out")
    },

    test("the Keyboard Shortcuts window lists / once, as Run a Command, under the canvas; the report says the plugin") {
        let rig = try BarRig(targets: false)
        let rows = rig.editor.registry.keyboardHelpRows.filter { $0.keys.contains("/") }
        expectEqual(rows.map(\.title), ["Run a Command"])
        expectEqual(rows.first?.place, .command(.runSlashCommand))
        let line = rig.editor.registry.report.split(separator: "\n").map(String.init).first { $0.hasPrefix("slash-bar") }
        expect(line?.contains("service SlashBar") == true, line ?? "no line")
        expect(line?.contains("command runSlashCommand") == true, line ?? "no line")
    },
])
