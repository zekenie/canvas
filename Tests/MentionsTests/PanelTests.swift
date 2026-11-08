import AppKit
import Canvas
import CanvasTesting
import CanvasUI
import DetailPanel
import Mentions
import Selection
import SwiftUI
import TestKit
import TextEditing

// Mention text in the panel (`MentionTextArea`): the jot's text, and the brief's Blocked By (which
// commits), in the detail panel in an unshown window, the editor keeping real time (the panel's
// updates, and going to a pill's target, land while the main run loop runs). Nothing goes on
// screen, and the pasteboards are private.

/// Where the jot's and the brief's mention text show in the panel.
enum FieldsTab {}
extension FieldsTab: DetailTab { static var title: String { "Fields" } }

/// How often the brief's Blocked By said it was done.
@MainActor var blockedByCommits = 0

/// The jot's text, as a field with a placeholder, and the brief's Blocked By, which commits (Return
/// says it's done), as the panel's fields.
struct MentionFieldsPlugin: CanvasPlugin {
    var id: PluginID { "mention-fields" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.details(Jot.self) {
            DetailSection("Text", in: FieldsTab.self) { $jot in
                MentionTextArea($jot, \.text, placeholder: "Say something")
            }
        }
        registrar.details(Brief.self) {
            DetailSection("Blocked By", in: FieldsTab.self) { $brief in
                MentionTextArea($brief, \.blockedBy, onCommit: { blockedByCommits += 1 })
            }
        }
    }
}

/// A view that takes the keyboard as the canvas does, where the panel gives it back.
final class KeyboardTaker: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// The detail panel beside a stand-in for the canvas, in an unshown window (a board's, when asked:
/// its Edit › Undo is the text's while text has the keyboard). The board has two plates, "Groceries"
/// (idA) and "Grocery List" (idB), as `EditedJot`'s has.
@MainActor
final class MentionPanel {
    let editor: CanvasEditor
    let window: NSWindow
    let canvas = KeyboardTaker(frame: CGRect(x: 0, y: 0, width: 540, height: 600))
    private(set) var hosting: NSView!
    /// How often the panel gave the keyboard back.
    private(set) var exits = 0
    private var time: TimeInterval = 10

    init(inBoardWindow: Bool = false, plugins more: [any CanvasPlugin] = []) throws {
        editor = CanvasEditor(registry: try Registry(plugins: mentionPlugins([MentionFieldsPlugin()] + more)), scheduler: TaskScheduler())
        editor.add(Plate(CGRect(x: 300, y: 0, width: 120, height: 80)), titled: "Groceries", id: idA)
        editor.add(Plate(CGRect(x: 300, y: 140, width: 120, height: 80)), titled: "Grocery List", id: idB)
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        if inBoardWindow {
            let board = BoardWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: true)
            board.editor = editor
            window = board
        } else {
            window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: true)
        }
        window.isReleasedWhenClosed = false
        // Weak: the panel may hand the keyboard back a turn after the test let this go.
        let exit: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            exits += 1
            window.makeFirstResponder(canvas)
        }
        hosting = NSHostingView(rootView: DetailPanelView(editor: editor, onExit: exit))
        hosting.frame = CGRect(x: 540, y: 0, width: DetailStyle.idealWidth, height: 600)
        let root = NSView(frame: frame)
        root.addSubview(canvas)
        root.addSubview(hosting)
        window.contentView = root
        window.makeFirstResponder(canvas)
        window.settle()
    }

    /// The panel's mention text views of text that may mention `Scope`.
    func textViews<Scope: MentionScope>(_: Scope.Type = AnyMentionable.self) -> [MentionTextView<Scope>] {
        hosting.descendants(MentionTextView<Scope>.self)
    }

    /// Selects the shape, and waits for the panel to show its mention text.
    func show<Scope: MentionScope>(_ id: ShapeID, _: Scope.Type = AnyMentionable.self) throws -> MentionTextView<Scope> {
        editor.selection = id
        window.spin { !textViews(Scope.self).isEmpty }
        return try require(textViews(Scope.self).first)
    }

    /// Gives a text view the keyboard, the caret at its end, as a click there does.
    func focus(_ view: NSTextView) {
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: view.textStorage?.length ?? 0, length: 0))
        window.settle()
    }

    func text(_ jot: ShapeID) -> MentionText? { editor.document[jot]?.typed(as: Jot.self)?.props.text }

    func down() { window.press("\u{F701}", code: 125, modifiers: [.numericPad, .function]) }

    /// The middle of the character at `location`, in the text view.
    func point(of location: Int, in view: NSTextView) -> CGPoint {
        let screen = view.firstRect(forCharacterRange: NSRange(location: location, length: 1), actualRange: nil)
        let rect = view.convert(window.convertFromScreen(screen), from: nil)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    func mouse(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView, clicks: Int = 1) -> NSEvent {
        time += 0.05
        return NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: time,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    /// A press on the text view and its release, as AppKit sends them.
    func click(_ view: NSTextView, at point: CGPoint, clicks: Int = 1) {
        view.mouseDown(with: mouse(.leftMouseDown, at: point, in: view, clicks: clicks))
        view.mouseUp(with: mouse(.leftMouseUp, at: point, in: view, clicks: clicks))
    }

    /// The view a click at a point in `view` lands on, as the window finds it: its hit test from
    /// the top, where SwiftUI takes the clicks over what it's disabled.
    func hit(_ point: CGPoint, in view: NSView) -> NSView? {
        guard let top = window.contentView?.superview else { return nil }
        return top.hitTest(view.convert(point, to: nil))
    }

    /// A press and its release where a click at a point in `view` lands, as the window sends them
    /// (`sendEvent`'s mouse-downs don't reach views in an unshown window, so they're handed over):
    /// the keyboard first, to a view that takes it, then the press.
    func clickThroughWindow(at point: CGPoint, in view: NSView, clicks: Int = 1) throws {
        let target = try require(hit(point, in: view))
        if target.acceptsFirstResponder { window.makeFirstResponder(target) }
        target.mouseDown(with: mouse(.leftMouseDown, at: point, in: view, clicks: clicks))
        target.mouseUp(with: mouse(.leftMouseUp, at: point, in: view, clicks: clicks))
    }
}

extension MentionTextView {
    var pickerTargets: [ShapeID] { picker?.rows.compactMap(\.candidate?.id) ?? [] }

    /// The pills in the text, with their characters' indexes.
    var pills: [(location: Int, pill: MentionAttachment)] {
        guard let storage = textStorage else { return [] }
        var found: [(Int, MentionAttachment)] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let pill = value as? MentionAttachment { found.append((range.location, pill)) }
        }
        return found
    }
}

@MainActor private let groceries = MentionText([.text("Buy "), .mention(idA, label: "Groceries"), .text(" today")])

@MainActor let panelTests = Suite("Mention text in the panel", [
    test("the jot's text in its panel: pills tinted, its owner the shape it writes; @gro, ↓, Return writes the canonical text, the typing and the pick one step") {
        let panel = try MentionPanel()
        let jot = panel.editor.add(Jot(CGRect(x: 0, y: 0, width: 200, height: 200)), titled: nil)
        let view = try panel.show(jot)
        expectEqual(view.style?.surface, .neutral, "on the panel's neutral surface, a pill's symbol takes its target's tint")
        expectEqual(view.style?.font, DetailStyle.textFont)
        expectEqual(view.owner, jot)
        expectEqual(view.placeholder, "Say something")
        expect(view.textLayoutManager != nil, "TextKit 2, as on the canvas")
        expect(view.spelling === Spelling.app, "its words' spelling checked as the app's is")
        expect(view.undoManager !== panel.window.undoManager, "typing's undo is the box's own")
        panel.focus(view)
        panel.window.type("Buy @gro")
        expectEqual(view.pickerTargets, [idA, idB])
        expect(view.holdsKeys, "the picker's keys are the view's own")
        panel.down()
        panel.window.pressReturn()
        expect(view.picker == nil && !view.holdsKeys)
        let expected = MentionText([.text("Buy "), .mention(idB, label: "Grocery List"), .text(" ")])
        expectEqual(panel.text(jot), expected)
        expectEqual(panel.text(jot)?.stored, "Buy @[Grocery List](shape:\(idB.rawValue.uuidString)) ")
        expectEqual(view.pills.first?.pill.style.surface, .neutral)
        panel.window.settle()
        expectEqual(view.mentionText, expected)
        expectEqual(panel.exits, 0, "Return picked: it didn't leave the panel")

        panel.editor.undoHistory.seal()
        expectEqual(panel.editor.undoHistory.undoName, "Change Text")
        panel.editor.undo()
        expectEqual(panel.text(jot), "", "one step: the typing and the pick")
        expect(panel.editor.document[jot] != nil)
    },

    test("Escape with the picker open closes only the picker; a second leaves the panel") {
        let panel = try MentionPanel()
        let jot = panel.editor.add(Jot(CGRect(x: 0, y: 0, width: 200, height: 200)), titled: nil)
        let view = try panel.show(jot)
        panel.focus(view)
        panel.window.type("@gro")
        expect(view.picker != nil)
        panel.window.pressEscape()
        panel.window.settle()
        expect(view.picker == nil)
        expectEqual(panel.exits, 0)
        expect(panel.window.firstResponder === view, "the text keeps the keyboard")
        expectEqual(view.string, "@gro")
        panel.window.pressEscape()
        panel.window.spin { panel.exits == 1 }
        expect(panel.window.firstResponder === panel.canvas)
        expectEqual(panel.text(jot), MentionText(plain: "@gro"))
    },

    test("in a field that commits, Return and Tab pick while the picker is open, and commit nothing; with it closed, Return commits") {
        let panel = try MentionPanel()
        let brief = panel.editor.add(Brief(CGRect(x: 0, y: 0, width: 200, height: 200)), titled: nil)
        let view = try panel.show(brief, Blockers.self)
        blockedByCommits = 0
        panel.focus(view)
        panel.window.type("@gro")
        expectEqual(view.pickerTargets, [idA, idB], "plates may block")
        panel.window.pressReturn()
        expect(view.picker == nil)
        expectEqual(blockedByCommits, 0, "Return picked")
        panel.window.type("and @gro")
        panel.window.press("\t", code: 48)
        expect(view.picker == nil)
        expectEqual(blockedByCommits, 0, "Tab picked")
        let written = panel.editor.document[brief]?.typed(as: Brief.self)?.props.blockedBy
        expectEqual(written?.mentioned, [idA, idA])
        panel.window.pressReturn()
        expectEqual(blockedByCommits, 1, "the picker closed, Return says the text is done")
        expectEqual(panel.editor.document[brief]?.typed(as: Brief.self)?.props.blockedBy, written, "and puts in no line")
    },

    test("a click on a pill selects it; Delete takes it; a double-click goes to its target on the next turn, and Back returns") {
        let panel = try MentionPanel()
        let jot = panel.editor.add(Jot(CGRect(x: 0, y: 0, width: 200, height: 200), text: groceries), titled: nil)
        let view = try panel.show(jot)
        let pill = panel.point(of: 4, in: view)
        panel.click(view, at: pill)
        expectEqual(view.selectedRange(), NSRange(location: 4, length: 1))
        expect(panel.window.firstResponder === view)
        expectEqual(panel.editor.selectedShapeIDs, [jot], "the shape stays selected")
        panel.click(view, at: pill, clicks: 2)
        expectEqual(panel.editor.selectedShapeIDs, [jot], "until the next turn")
        panel.window.spin { panel.editor.selectedShapeIDs == [idA] }
        panel.editor.goBack()
        expectEqual(panel.editor.selectedShapeIDs, [jot])

        let again = try panel.show(jot)
        panel.click(again, at: panel.point(of: 4, in: again))
        panel.window.pressDelete()
        expectEqual(panel.text(jot), MentionText(plain: "Buy  today"))
        expect(again.pills.isEmpty)
    },

    test("copy writes the pill's stored form, and paste makes another mention of its shape, which the field writes") {
        let panel = try MentionPanel()
        let jot = panel.editor.add(Jot(CGRect(x: 0, y: 0, width: 200, height: 200), text: groceries), titled: nil)
        let view = try panel.show(jot)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        panel.focus(view)
        view.setSelectedRange(NSRange(location: 4, length: 1))
        expect(view.writeSelection(to: board, types: view.writablePasteboardTypes))
        expectEqual(board.string(forType: .mentionText), MentionText([.mention(idA, label: "Groceries")]).stored)
        expectEqual(board.string(forType: .string), "@Groceries")
        view.setSelectedRange(NSRange(location: view.textStorage?.length ?? 0, length: 0))
        expect(view.readSelection(from: board))
        expectEqual(panel.text(jot), MentionText([.text("Buy "), .mention(idA, label: "Groceries"), .text(" today"), .mention(idA, label: "Groceries")]))
        expectEqual(view.pills.map(\.pill.target.shape), [idA, idA])
    },

    test("a rename of a pill's target redraws the pill, and writes nothing") {
        let panel = try MentionPanel()
        let jot = panel.editor.add(Jot(CGRect(x: 0, y: 0, width: 200, height: 200), text: groceries), titled: nil)
        let view = try panel.show(jot)
        let pill = try require(view.pills.first?.pill)
        let revision = panel.editor.revision
        panel.editor.rename(idA, "Food")
        panel.window.settle()
        expectEqual(panel.editor.revision, revision + 1, "only the rename")
        expectEqual(pill.shownLabel, "Food")
        expect(view.pills.first?.pill === pill, "the same pill, shown again: the text wasn't")
        expectEqual(panel.text(jot), groceries, "the board's text isn't written")
        expectEqual(view.mentionText, MentionText([.text("Buy "), .mention(idA, label: "Food"), .text(" today")]))
    },

    test("the board's undo shows the text it undid, pills and all, and writes nothing back, so redo stays") {
        let panel = try MentionPanel()
        let jot = panel.editor.add(Jot(CGRect(x: 0, y: 0, width: 200, height: 200), text: groceries), titled: nil)
        let view = try panel.show(jot)
        panel.focus(view)
        panel.window.type("!")
        panel.window.settle()
        panel.editor.undoHistory.seal()
        let revision = panel.editor.revision
        panel.editor.undo()
        panel.window.spin { view.string == "Buy \u{FFFC} today" }
        panel.window.settle()
        expectEqual(panel.editor.revision, revision + 1, "the undo, and nothing written back")
        expect(panel.editor.canRedo)
        expectEqual(view.pills.map(\.pill.target.shape), [idA])
        expect(view.pills.first?.pill.resolution.isLive == true)
        expectEqual(view.mentionText, groceries)
        panel.editor.redo()
        panel.window.spin { view.string == "Buy \u{FFFC} today!" }
        expect(view.undoManager?.canUndo == false, "typing's undo was for the text before")
    },

    test("in a board's window, Edit › Undo in the field is its own: a pick undone gives back the query, written once") {
        let panel = try MentionPanel(inBoardWindow: true)
        let window = try require(panel.window as? BoardWindow)
        let jot = panel.editor.add(Jot(CGRect(x: 0, y: 0, width: 200, height: 200)), titled: nil)
        let view = try panel.show(jot)
        panel.focus(view)
        panel.window.type("Buy @gro")
        panel.window.settle()
        panel.window.pressReturn()
        panel.window.settle()
        expectEqual(panel.text(jot)?.mentioned, [idA])
        let undo = NSMenuItem(title: "", action: #selector(BoardWindow.undo(_:)), keyEquivalent: "")
        expect(window.validateMenuItem(undo))
        expect(undo.title != "Undo Change Text", "the text's own, not the board's: \(undo.title)")
        let revision = panel.editor.revision
        window.undo(nil)
        expectEqual(view.string, "Buy @gro")
        expectEqual(panel.text(jot), MentionText(plain: "Buy @gro"))
        expectEqual(panel.editor.revision, revision + 1, "written once, however often the text says it changed")
        expect(view.picker == nil, "an undone @ opens nothing")
        panel.window.makeFirstResponder(panel.canvas)
        expect(view.undoManager?.canRedo == false, "forgotten once the keyboard left")
        panel.editor.undo()
        expectEqual(panel.text(jot), "", "the board's step for the field is what's left")
    },

    test("in a board's window, a pick with the mouse is part of the typing's step") {
        let panel = try MentionPanel(inBoardWindow: true)
        let jot = panel.editor.add(Jot(CGRect(x: 0, y: 0, width: 200, height: 200)), titled: nil)
        let view = try panel.show(jot)
        panel.focus(view)
        panel.window.type("Buy @")
        let pickerWindow = try require(Mirror(reflecting: view).children.first { $0.label == "pickerWindow" }?.value as? NSWindow)
        let rows = try require(pickerWindow.contentView?.descendants.first { $0.accessibilityRole() == .list })
        rows.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: rows.convert(CGPoint(x: 100, y: 36), to: nil), modifierFlags: [],
                                                timestamp: 1, windowNumber: pickerWindow.windowNumber, context: nil, eventNumber: 0,
                                                clickCount: 1, pressure: 1)!)
        expect(view.picker == nil)
        expectEqual(panel.text(jot)?.mentioned, [idA])
        panel.window.makeFirstResponder(panel.canvas)
        panel.editor.undo()
        expectEqual(panel.text(jot), "", "one step: the typing and the pick")
    },

    test("read-only: not editable, dimmed, no picker; a lock landing closes the picker; the window's clicks still reach it: a pill selected, then followed") {
        let panel = try MentionPanel(plugins: [FreezingPlugin()])
        let jot = panel.editor.add(Jot(CGRect(x: 0, y: 0, width: 200, height: 200), text: groceries), titled: nil)
        let view = try panel.show(jot)
        expect(view.isEditable)
        expectEqual(view.alphaValue, 1)
        let pill = panel.point(of: 4, in: view)
        expect(panel.hit(pill, in: view) === view, "the text view takes the window's clicks")
        panel.focus(view)
        panel.window.type(" @")
        expect(view.picker != nil)
        panel.editor.freeze([jot])
        panel.window.spin { !view.isEditable }
        expect(view.picker == nil, "made read-only, it closes its picker")
        expectEqual(view.alphaValue, 0.5, "the text and its pills dimmed together")
        panel.window.type("@")
        expect(view.picker == nil)
        expectEqual(panel.text(jot), MentionText([.text("Buy "), .mention(idA, label: "Groceries"), .text(" today @")]))

        panel.window.makeFirstResponder(panel.canvas)
        expect(panel.hit(pill, in: view) === view, "still the text view's, read-only: SwiftUI doesn't take them")
        expect(panel.hit(panel.point(of: 1, in: view), in: view) === view, "and its text's")
        try panel.clickThroughWindow(at: pill, in: view)
        expectEqual(view.selectedRange(), NSRange(location: 4, length: 1), "a click selects the pill")
        expect(panel.window.firstResponder === view, "so it can be copied")
        let menu = try require(view.menu(for: panel.mouse(.rightMouseDown, at: pill, in: view)))
        expectEqual(Array(menu.outline.prefix(3)), ["Go to “Groceries”", "Show What Mentions “Groceries”", "—"], "Remove Mention would change the text")
        try panel.clickThroughWindow(at: pill, in: view, clicks: 2)
        panel.window.spin { panel.editor.selectedShapeIDs == [idA] }
        panel.editor.goBack()
        expectEqual(panel.editor.selectedShapeIDs, [jot])
        panel.editor.freeze([jot], false)
        let thawed = try panel.show(jot)
        panel.window.spin { thawed.isEditable }
        expectEqual(thawed.alphaValue, 1)
        let editable = try require(thawed.menu(for: panel.mouse(.rightMouseDown, at: panel.point(of: 4, in: thawed), in: thawed)))
        expectEqual(Array(editable.outline.prefix(4)), ["Go to “Groceries”", "Show What Mentions “Groceries”", "Remove Mention", "—"])
    },

    test("⌘. with the picker open closes only the picker, as Escape does; a second leaves the panel") {
        let panel = try MentionPanel()
        let jot = panel.editor.add(Jot(CGRect(x: 0, y: 0, width: 200, height: 200)), titled: nil)
        let view = try panel.show(jot)
        panel.focus(view)
        panel.window.type("@gro")
        expect(view.picker != nil)
        panel.window.pressCommandPeriod()
        panel.window.settle()
        expect(view.picker == nil)
        expectEqual(panel.exits, 0)
        expect(panel.window.firstResponder === view, "the text keeps the keyboard")
        panel.window.pressCommandPeriod()
        panel.window.spin { panel.exits == 1 }
        expect(panel.window.firstResponder === panel.canvas)
        expectEqual(panel.text(jot), MentionText(plain: "@gro"))
    },

    test("the picker sits under its @ in the field, follows it as the panel scrolls, and closes once the @ scrolls out of the box") {
        let panel = try MentionPanel()
        let lines = (1...12).map { "Line \($0)" }.joined(separator: "\n") + "\n"
        let jot = panel.editor.add(Jot(CGRect(x: 0, y: 0, width: 200, height: 200), text: MentionText(plain: lines)), titled: nil)
        let view = try panel.show(jot)
        panel.focus(view)
        view.scrollRangeToVisible(view.selectedRange())
        panel.window.type("@")
        let frame = try require(view.pickerFrame)
        let at = view.firstRect(forCharacterRange: NSRange(location: view.selectedRange().location - 1, length: 1), actualRange: nil)
        expectEqual(frame.maxY, at.minY - 4)
        expect(frame.minX < at.minX && at.minX - frame.minX < 20, "its rows start under the @")
        // The panel's own scroll view (SwiftUI's), around the box's.
        let box = try require(view.enclosingScrollView)
        let panelScroll = try require(panel.hosting.descendants(NSScrollView.self).first { $0 !== box && box.isDescendant(of: $0) })
        panelScroll.contentView.scroll(to: CGPoint(x: 0, y: 30))
        let scrolled = try require(view.pickerFrame)
        expectEqual(scrolled.minY - frame.minY, 30, "on screen, 30 points higher with its @")
        box.contentView.scroll(to: .zero)
        expect(view.picker == nil, "its @ scrolled out of the box")
    },
])
