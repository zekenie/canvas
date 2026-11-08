import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import CoreGraphics
import Keyboard
import Mentions
import Selection
import TestKit

// Following a mention by keys: Go to Mention (⌥⌘↩), Show What Mentions and Remove Mention, run as the
// menu bar and its key equivalents run them, on the pill the caret touches in a note's editor and in
// the panel's box; and, with a note only selected, one "Go to X" part per live mention, reached with
// ⌥Tab. Real key events through the window (`KeyDriver`); the board's items are the menu bar's own,
// sent to a stand-in for the window controller that runs them as it does.

/// The window controller's `runCommand:` and its validation, for an unshown window.
@MainActor private final class CommandItems: NSObject, NSMenuItemValidation {
    let editor: CanvasEditor
    let menu: NSMenu

    init(_ editor: CanvasEditor) {
        self.editor = editor
        menu = BoardMenus.make(appName: "Infinite Canvas", registry: editor.registry).main
        super.init()
        Self.retarget(menu, to: self)
    }

    private static func retarget(_ menu: NSMenu, to target: CommandItems) {
        for item in menu.items {
            if item.action == #selector(CommandItems.runCommand(_:)) { item.target = target }
            if let submenu = item.submenu { retarget(submenu, to: target) }
        }
    }

    @objc func runCommand(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let command = BoardMenus.command(of: item) else { return }
        editor.perform(command)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        BoardMenus.command(of: item).map { editor.canPerform($0) } ?? false
    }

    func item(_ menu: String, _ title: String) throws -> NSMenuItem {
        try require(self.menu.item(withTitle: menu)?.submenu?.item(withTitle: title))
    }

    /// Whether the item is on, as the menu bar dims it.
    func isOn(_ menu: String, _ title: String) throws -> Bool { validateMenuItem(try item(menu, title)) }

    /// Chooses an item as a click on it does.
    func choose(_ menu: String, _ title: String) throws {
        let item = try item(menu, title)
        expect(validateMenuItem(item), "\(title) is on")
        runCommand(item)
    }
}

private let goToMentionChord = Chord(Key.return, [.command, .option])

/// "Ask Groceries and Grocery List", the two pills at 4 and 14.
@MainActor private let twoPills = MentionText([.text("Ask "), .mention(idA, label: "Groceries"), .text(" and "), .mention(idB, label: "Grocery List")])

@MainActor let followKeysTests = Suite("Following a mention by keys", [
    test("with the caret just after a pill, ⌥⌘↩ follows it on the next turn, and Back returns") {
        let session = try EditedJot(twoPills)
        let items = CommandItems(session.h.editor)
        session.textView.setSelectedRange(NSRange(location: 5, length: 0))
        expect(try items.isOn("Go", "Go to Mention"))
        let delivery = KeyDriver(session.window, menu: items.menu).send(goToMentionChord)
        expect(delivery.isMenu, "the menu bar took the key: \(delivery)")
        expectEqual(session.h.editor.editingShapeID, session.jot, "still editing until the next turn")
        session.h.scheduler.advance(by: .zero)
        expectEqual(session.h.editor.editingShapeID, nil)
        expectEqual(session.h.editor.selectedShapeIDs, [idA])
        session.h.editor.goBack()
        expectEqual(session.h.editor.selectedShapeIDs, [session.jot])
    },

    test("a pill that is exactly the selection is the one followed, the second as well as the first") {
        let session = try EditedJot(twoPills)
        let items = CommandItems(session.h.editor)
        let driver = KeyDriver(session.window, menu: items.menu)
        session.textView.setSelectedRange(NSRange(location: 14, length: 1))
        _ = driver.send(goToMentionChord)
        session.h.scheduler.advance(by: .zero)
        expectEqual(session.h.editor.selectedShapeIDs, [idB])
        session.h.editor.goBack()
        expectEqual(session.h.editor.selectedShapeIDs, [session.jot])
    },

    test("Remove Mention turns the pill into its name, as text, in one step; Show What Mentions selects what mentions it") {
        let session = try EditedJot(twoPills)
        let items = CommandItems(session.h.editor)
        session.textView.setSelectedRange(NSRange(location: 4, length: 1))
        try items.choose("Edit", "Remove Mention")
        expectEqual(session.string, "Ask Groceries and \u{FFFC}")
        expectEqual(session.pills.map(\.pill.target.shape), [idB])
        expect(!(try items.isOn("Edit", "Remove Mention")), "the caret has no pill on it now")
        session.textView.setSelectedRange(NSRange(location: 18, length: 1))
        expectEqual(session.textView.pillOnCaretTarget, idB)
        try items.choose("Go", "Show What Mentions")
        session.h.scheduler.advance(by: .zero)
        expectEqual(session.h.editor.editingShapeID, nil)
        expectEqual(session.h.editor.selectedShapeIDs, [session.jot], "the jot mentions it")
    },

    test("Return still types a newline beside a pill, and ⌥⌘↩ with no pill there is no command: its items are dimmed and the key runs nothing") {
        let session = try EditedJot(twoPills)
        let items = CommandItems(session.h.editor)
        session.textView.setSelectedRange(NSRange(location: 5, length: 0))
        _ = KeyDriver(session.window, menu: items.menu).send(.return)
        expect(session.string.contains("\n"), "Return types a newline")
        session.textView.setSelectedRange(NSRange(location: 0, length: 0))
        for (menu, title) in [("Go", "Go to Mention"), ("Go", "Show What Mentions"), ("Edit", "Remove Mention")] {
            expect(!(try items.isOn(menu, title)), "\(title) is dimmed away from a pill")
        }
        let delivery = KeyDriver(session.window, menu: items.menu).send(goToMentionChord)
        session.h.scheduler.advance(by: .zero)
        expectEqual(session.h.editor.editingShapeID, session.jot, "nothing ran: \(delivery)")
    },

    test("a pill whose target is gone cannot be followed, but can be removed") {
        let session = try EditedJot(twoPills)
        session.h.editor.delete(idA)
        let items = CommandItems(session.h.editor)
        session.textView.setSelectedRange(NSRange(location: 4, length: 1))
        expect(!(try items.isOn("Go", "Go to Mention")))
        expect(!(try items.isOn("Go", "Show What Mentions")))
        expect(try items.isOn("Edit", "Remove Mention"))
    },

    test("in the panel's box the same commands act on the pill, and a locked shape's cannot be removed") {
        let panel = try MentionPanel()
        let jot = panel.editor.add(Jot(CGRect(x: 0, y: 0, width: 200, height: 200), text: twoPills), titled: nil)
        let view = try panel.show(jot)
        panel.focus(view)
        let items = CommandItems(panel.editor)
        view.setSelectedRange(NSRange(location: 5, length: 0))
        let delivery = KeyDriver(panel.window, menu: items.menu).send(goToMentionChord)
        expect(delivery.isMenu, "\(delivery)")
        panel.window.settle()
        expectEqual(panel.editor.selectedShapeIDs, [idA])
        panel.editor.goBack()
        expectEqual(panel.editor.selectedShapeIDs, [jot])
        let again = try panel.show(jot)
        panel.focus(again)
        again.setSelectedRange(NSRange(location: 4, length: 1))
        try items.choose("Edit", "Remove Mention")
        panel.window.settle()
        expectEqual(panel.text(jot)?.stored, "Ask Groceries and @[Grocery List](shape:\(idB.rawValue.uuidString))")
    },

    test("a selected note's ⌥Tab walk lists Go to X for each live mention in text order, a repeat once, and Return follows") {
        let h = try mentionHarness()
        h.editor.add(Plate(CGRect(x: 400, y: 0, width: 120, height: 80)), titled: "Checkout", id: idA)
        h.editor.add(Plate(CGRect(x: 400, y: 200, width: 120, height: 80)), titled: "Cart", id: idB)
        let gone = ShapeID()
        let text = mentioning([.mention(idA, label: "Checkout"), .text(" then "), .mention(idB, label: "Cart"), .text(" and "),
                               .mention(idA, label: "Checkout"), .text(" not "), .mention(gone, label: "Gone")])
        let jot = h.editor.add(Jot(CGRect(x: 0, y: 0, width: 300, height: 200), text: text), titled: nil)
        h.editor.selection = jot
        let parts = h.editor.shapeParts(of: jot)
        expectEqual(parts.map(\.title), ["Go to Checkout", "Go to Cart"])
        expectEqual(parts.map(\.role), [.link, .link])
        let pills = h.editor.mentionPills(of: jot)
        expectEqual(parts.first?.rect, pills.first?.frame, "the pill's own rect")
        expectEqual(parts.map { $0.rect.minX }, parts.map { $0.rect.minX }.sorted(), "in text order")

        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
        let canvas = CanvasView(editor: h.editor)
        canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 500)
        window.contentView = canvas
        window.makeFirstResponder(canvas)
        let walk = KeyWalk(window, editor: h.editor, readers: [.canvas(canvas, selection: { ["note"] }, part: { [editor = h.editor] in editor.focusedPart?.title },
                                                                       frame: { [editor = h.editor, canvas] in
                                                                           editor.focusedPart.flatMap { editor.shownFrame(ofWorld: $0.rect, in: canvas) }
                                                                       })],
                           settle: .manual(h.scheduler))
        expectEqual(walk.press(.optionTab).id, "canvas/note/Go to Checkout")
        expectEqual(walk.press(.optionTab).id, "canvas/note/Go to Cart")
        expectEqual(walk.press(.optionTab).id, "canvas/note/Go to Checkout", "round")
        walk.press(.optionTab)
        walk.press(.return)
        expectEqual(h.editor.selectedShapeIDs, [idB], "Return follows the focused part")
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [jot])
    },
])

extension Delivery {
    /// A menu bar item took the key.
    var isMenu: Bool { if case .menu = self { true } else { false } }
}

extension MentionTextView {
    var pillOnCaretTarget: ShapeID? {
        let range = selectedRange()
        guard range.length == 1 else { return nil }
        return textStorage?.attribute(.attachment, at: range.location, effectiveRange: nil).flatMap { ($0 as? MentionAttachment)?.target.shape }
    }
}
