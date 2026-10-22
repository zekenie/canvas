import AppKit
import Canvas
import CanvasTesting
import CanvasUI
import DetailPanel
import Selection
import SwiftUI
import TestKit
import TextEditing

// A box of a plugin's own text in the panel (`DetailTextBox`): a text view of its own class whose
// value isn't a string, as a plugin's text may be (mentions of shapes), and whose keys it may hold.

/// Text kept in a form of its own: a string, wrapped.
struct Keyed: Equatable {
    var text: String
}

/// A plugin's text view: its value is `Keyed`, it holds keys while `holds` says so (as a list it
/// shows over its text would), and it logs the commands its keys come to, its changes and what it
/// was shown.
final class KeyedTextView: EditingTextView, DetailTextContent {
    var holds = false
    override var holdsKeys: Bool { holds }
    /// Every command a key came to, in order.
    private(set) var commands: [String] = []
    /// How often it said its text changed (`didChangeText`).
    private(set) var changes = 0
    /// What its box showed it, in order.
    private(set) var shown: [Keyed] = []

    var value: Keyed { Keyed(text: string) }

    func show(_ value: Keyed) {
        shown.append(value)
        string = value.text
    }

    /// While it holds keys, Return and Escape are its list's: taken, as a pick and a close.
    override func doCommand(by selector: Selector) {
        commands.append(NSStringFromSelector(selector))
        if holds, selector == #selector(insertNewline(_:)) || selector == #selector(cancelOperation(_:)) { return }
        super.doCommand(by: selector)
    }

    override func didChangeText() {
        changes += 1
        super.didChangeText()
    }

    /// A text view's own completions go on screen: none here.
    override func complete(_ sender: Any?) {}
}

enum KeysTab {}
extension KeysTab: DetailTab { static var title: String { "Keys" } }

/// How often the Keyed box said its text was done.
@MainActor var keyedCommits = 0

/// A Keys tab for the gadget: its remark in a Keyed box that commits (read-only while the count
/// isn't 0, as a box a model is writing is), and its name in one that doesn't.
struct KeyedBoxesPlugin: CanvasPlugin {
    var id: PluginID { "keyed-boxes" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.details(Gadget.self) {
            DetailSection("Keyed", in: KeysTab.self) { $gadget in
                DetailTextBox(keyed($gadget.remark), placeholder: "Say it", onCommit: { keyedCommits += 1 }) { KeyedTextView(frame: .zero) }
                    .detailUpdating(gadget.count > 0)
            }
            DetailSection("Loose", in: KeysTab.self) { $gadget in
                DetailTextBox(keyed($gadget.name)) { KeyedTextView(frame: .zero) }
            }
        }
    }
}

/// A string's binding as a Keyed one.
@MainActor func keyed(_ text: Binding<String>) -> Binding<Keyed> {
    Binding(get: { Keyed(text: text.wrappedValue) }, set: { text.wrappedValue = $0.text })
}

extension PanelWindow {
    /// The Keys tab's boxes' text views: the one that commits (the remark's), and the one that
    /// doesn't (the name's).
    var committing: KeyedTextView? { hosting.descendants(KeyedTextView.self).first { $0.onCommit != nil } }
    var loose: KeyedTextView? { hosting.descendants(KeyedTextView.self).first { $0.onCommit == nil } }

    /// A gadget selected, on its Keys tab, the count at zero.
    func showKeys(_ gadget: Gadget = Gadget(gadgetFrame)) throws -> ShapeID {
        let id = editor.add(gadget)
        try require(editor.detailPanel).choose(.of(KeysTab.self), for: Gadget.kind)
        editor.selection = id
        window.spin { self.committing != nil && self.loose != nil }
        keyedCommits = 0
        return id
    }
}

let commandReturn = (characters: "\r", code: UInt16(36), modifiers: NSEvent.ModifierFlags.command)

@MainActor let textBoxTests = Suite("A plugin's text box", [
    test("its text view with nothing set is a plain text view: Return, ⌘↩ and Escape go on to its commands as a text view's do") {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        let view = KeyedTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView?.addSubview(view)
        window.makeFirstResponder(view)
        window.type("a")
        window.pressReturn()
        expectEqual(view.string, "a\n")
        expect(!view.performKeyEquivalent(with: window.keyEvent(commandReturn.characters, code: commandReturn.code, modifiers: commandReturn.modifiers)))
        window.press(commandReturn.characters, code: commandReturn.code, modifiers: commandReturn.modifiers)
        window.pressEscape()
        expectEqual(view.commands.count, 3, "\(view.commands)")
        expectEqual([view.commands.first, view.commands.last], ["insertNewline:", "cancelOperation:"])
        expect(!view.responds(to: #selector(NSResponder.cancelOperation(_:))), "Escape's command is answered as NSTextView answers it")
        expect(window.firstResponder === view)
    },
    test("its own text view, laid out as the panel's boxes are, writes its value on every keystroke; typing ahead of the panel isn't lost") {
        let editor = try gadgetEditor([KeyedBoxesPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let id = try panel.showKeys()
        let view = try require(panel.committing)
        let scroll = try require(view.enclosingScrollView)
        expect(!view.drawsBackground && view.allowsUndo && view.textContainerInset == .zero, "the box's own settings")
        expect(scroll.hasVerticalScroller && !scroll.drawsBackground && scroll.borderType == .noBorder)
        expectEqual(view.textContainer?.widthTracksTextView, true, "lines wrap in the box")
        expectEqual(view.frame.width, scroll.contentSize.width)
        expectEqual(view.placeholder, "Say it")
        expect(view.undoManager !== panel.window.undoManager, "typing's undo is the box's own")
        panel.focus(view)
        let revision = editor.revision
        panel.window.type("abc")                    // with no turn of the run loop between keys
        expectEqual(editor.props(id, as: Gadget.self)?.remark, "abc")
        expectEqual(editor.revision, revision + 3, "a write a keystroke")
        panel.window.settle()
        expectEqual(view.string, "abc")
        expectEqual(view.shown, [], "what it wrote isn't shown back to it")
        expectEqual(view.changes, 3)
    },
    test("text from elsewhere is shown, never written back, and drops typing's undo") {
        let editor = try gadgetEditor([KeyedBoxesPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let id = try panel.showKeys()
        let view = try require(panel.committing)
        panel.focus(view)
        panel.window.type("abc")
        panel.window.settle()
        expect(view.undoManager?.canUndo == true)
        editor.transact { $0.update(id, as: Gadget.self) { $0.props.remark = "elsewhere" } }
        let revision = editor.revision
        panel.window.spin { view.string == "elsewhere" }
        panel.window.settle()
        expectEqual(view.shown, [Keyed(text: "elsewhere")])
        expectEqual(view.changes, 3, "showing isn't a change")
        expectEqual(editor.revision, revision, "nothing written back")
        expect(view.undoManager?.canUndo == false, "typing's undo was for the old text")
        expectEqual(keyedCommits, 0)
    },
    test("the board's undo shows the text it undid and writes nothing back, so redo stays") {
        let editor = try gadgetEditor([KeyedBoxesPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let id = try panel.showKeys()
        let view = try require(panel.committing)
        panel.focus(view)
        panel.window.type("abc")
        panel.window.settle()
        editor.undoHistory.seal()
        expectEqual(editor.undoHistory.undoName, "Change Keyed")
        editor.undo()
        expectEqual(editor.props(id, as: Gadget.self)?.remark, "")
        panel.window.spin { view.string.isEmpty }
        panel.window.settle()
        expect(editor.canRedo, "nothing committed after the undo")
        expectEqual(view.shown, [Keyed(text: "")])
        expectEqual(view.changes, 3)
        editor.redo()
        panel.window.spin { view.string == "abc" }
        expectEqual(view.shown, [Keyed(text: ""), Keyed(text: "abc")])
    },
    test("Escape leaves the panel, before the text view hears it; while the view holds keys, it's the view's own and the panel stays") {
        let editor = try gadgetEditor([KeyedBoxesPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        _ = try panel.showKeys()
        let view = try require(panel.committing)
        panel.focus(view)
        view.holds = true
        panel.window.pressEscape()
        panel.window.settle()
        expectEqual(view.commands, ["cancelOperation:"], "the panel let it through to the view")
        expectEqual(panel.exits, 0)
        expect(panel.window.firstResponder === view, "the view keeps the keyboard")
        expectEqual(keyedCommits, 0)
        view.holds = false
        panel.window.pressEscape()
        panel.window.spin { panel.canvasHasKeyboard }
        expectEqual(panel.exits, 1)
        expectEqual(view.commands, ["cancelOperation:"], "the panel took it first: the view never heard it")
        expectEqual(keyedCommits, 1, "the keyboard leaving is done")
    },
    test("⌘. leaves the panel as Escape does, though it comes to the view as no key, from a box or a field; while the view holds keys, the panel stays") {
        let editor = try gadgetEditor([KeyedBoxesPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        _ = try panel.showKeys()
        let view = try require(panel.committing)
        panel.focus(view)
        view.holds = true
        panel.window.pressCommandPeriod()
        panel.window.settle()
        expectEqual(panel.exits, 0)
        expect(panel.window.firstResponder === view, "the view keeps the keyboard")
        expectEqual(keyedCommits, 0)
        view.holds = false
        panel.window.pressCommandPeriod()
        panel.window.spin { panel.canvasHasKeyboard }
        expectEqual(panel.exits, 1)
        expectEqual(keyedCommits, 1, "the keyboard leaving is done")
        expectEqual(view.commands, [], "none of it came to the view as a command")

        try require(editor.detailPanel).choose(.of(GadgetTab.self), for: Gadget.kind)
        panel.window.spin { panel.fields.contains { $0.placeholderString == "Name" } }
        panel.window.focus(try panel.field("Name"))
        panel.window.pressCommandPeriod()
        panel.window.spin { panel.canvasHasKeyboard }
        expectEqual(panel.exits, 2, "and from a field")
    },
    test("disabled (a read-only shape's), a box is dimmed and not editable, but the window's clicks still reach its text: it's selected and copied") {
        let editor = try gadgetEditor([KeyedBoxesPlugin(), FreezingPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let id = try panel.showKeys(Gadget(gadgetFrame, name: "hello there"))
        let view = try require(panel.loose)
        let point = CGPoint(x: 8, y: 8)
        expect(panel.hit(point, in: view) === view)
        editor.freeze([id])
        panel.window.spin { !view.isEditable }
        expectEqual(view.textColor, .secondaryLabelColor, "dimmed")
        expect(panel.hit(point, in: view) === view, "SwiftUI doesn't take its clicks")
        try panel.clickThroughWindow(at: point, in: view, clicks: 2)
        expect(panel.window.firstResponder === view, "it has the keyboard, to copy from")
        expectEqual(view.selectedRange(), NSRange(location: 0, length: 5), "a double-click selects a word")
        panel.window.type("x")
        expectEqual(view.string, "hello there", "typing changes nothing")
        expectEqual(editor.props(id, as: Gadget.self)?.name, "hello there")
        panel.window.pressEscape()
        panel.window.spin { panel.canvasHasKeyboard }
        editor.freeze([id], false)
        panel.window.spin { view.isEditable }
        expectEqual(view.textColor, .labelColor)
    },
    test("clicked into, a read-only box never says its text is done: not on Return, ⌘↩, nor the keyboard leaving") {
        let editor = try gadgetEditor([KeyedBoxesPlugin(), FreezingPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        var gadget = Gadget(gadgetFrame)
        gadget.remark = "hello there"
        let id = try panel.showKeys(gadget)
        let view = try require(panel.committing)
        editor.freeze([id])
        panel.window.spin { !view.isEditable }
        try panel.clickThroughWindow(at: CGPoint(x: 8, y: 8), in: view, clicks: 1)
        expect(panel.window.firstResponder === view, "it has the keyboard, to copy from")
        panel.window.pressReturn()
        panel.window.press(commandReturn.characters, code: commandReturn.code, modifiers: commandReturn.modifiers)
        expect(panel.window.makeFirstResponder(panel.canvas), "the keyboard leaves it")
        panel.window.settle()
        expectEqual(keyedCommits, 0, "nothing was written, so nothing is done")
        expectEqual(editor.props(id, as: Gadget.self)?.remark, "hello there")
        editor.freeze([id], false)
        panel.window.spin { view.isEditable }
        panel.focus(view)
        panel.window.pressReturn()
        expectEqual(keyedCommits, 1, "editable again, Return says it's done")
    },
    test("while the view holds keys, Return and ⌘↩ are its own: nothing commits; then Return commits and ⇧↩ is a new line") {
        let editor = try gadgetEditor([KeyedBoxesPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let id = try panel.showKeys()
        let view = try require(panel.committing)
        panel.focus(view)
        panel.window.type("a")
        view.holds = true
        panel.window.pressReturn()
        expectEqual(view.commands, ["insertNewline:"])
        expect(!view.performKeyEquivalent(with: panel.window.keyEvent(commandReturn.characters, code: commandReturn.code, modifiers: commandReturn.modifiers)),
               "⌘↩ isn't taken as a key equivalent")
        panel.window.press(commandReturn.characters, code: commandReturn.code, modifiers: commandReturn.modifiers)
        expectEqual(view.commands.count, 2, "⌘↩ came to a command of the view's: \(view.commands)")
        expectEqual(keyedCommits, 0)
        expectEqual(editor.props(id, as: Gadget.self)?.remark, "a", "the view took Return, as a pick would")
        view.holds = false
        panel.window.pressReturn()
        expectEqual(keyedCommits, 1)
        panel.window.press(commandReturn.characters, code: commandReturn.code, modifiers: commandReturn.modifiers)
        expectEqual(keyedCommits, 2)
        panel.window.press("\r", code: 36, modifiers: .shift)
        panel.window.type("b")
        expectEqual(editor.props(id, as: Gadget.self)?.remark, "a\nb")
        expectEqual(keyedCommits, 2)
        expectEqual(view.commands.count, 2, "Return and ⌘↩ commit before they come to commands")
    },
    test("without a commit, Return is a new line and ⌘↩ leaves the panel, keeping what was typed") {
        let editor = try gadgetEditor([KeyedBoxesPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let id = try panel.showKeys()
        let view = try require(panel.loose)
        expectEqual(view.onCommit == nil && !view.commitsOnReturn, true)
        panel.focus(view)
        panel.window.type("a")
        panel.window.pressReturn()
        panel.window.type("b")
        expectEqual(editor.props(id, as: Gadget.self)?.name, "a\nb")
        expectEqual(panel.exits, 0)
        panel.window.press(commandReturn.characters, code: commandReturn.code, modifiers: commandReturn.modifiers)
        expectEqual(panel.exits, 1, "⌘↩ is the panel's: the keyboard goes back to the canvas")
        expectEqual(editor.props(id, as: Gadget.self)?.name, "a\nb", "and what was typed stays")
        expectEqual(keyedCommits, 0)
    },
    test("a disabled box (something else writing it) is read-only and dimmed; enabled again, it's editable in the label's color") {
        let editor = try gadgetEditor([KeyedBoxesPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let id = try panel.showKeys(Gadget(gadgetFrame, name: "n"))
        let view = try require(panel.committing), loose = try require(panel.loose)
        editor.transact { $0.update(id, as: Gadget.self) { $0.props.remark = "r" } }
        panel.window.spin { view.string == "r" }
        expect(view.isEditable)
        expectEqual(view.textColor, .labelColor)
        editor.transact { $0.update(id, as: Gadget.self) { $0.props.count = 1 } }
        panel.window.spin { !view.isEditable }
        expectEqual(view.textColor, .secondaryLabelColor)
        expect(panel.hit(CGPoint(x: 8, y: 8), in: view) === view, "its clicks still land")
        expect(loose.isEditable && loose.textColor == .labelColor, "the other box is as it was")
        panel.window.makeFirstResponder(view)
        panel.window.type("x")
        expectEqual(view.string, "r")
        editor.transact { $0.update(id, as: Gadget.self) { $0.props.count = 0 } }
        panel.window.spin { view.isEditable }
        expectEqual(view.textColor, .labelColor)
    },
    test("in a board's window, Edit › Undo is the box's own: named for typing, written once, and forgotten when the keyboard moves") {
        let editor = try gadgetEditor([KeyedBoxesPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor, inBoardWindow: true)
        let window = try require(panel.window as? BoardWindow)
        let id = try panel.showKeys()
        let view = try require(panel.committing)
        panel.focus(view)
        panel.window.type("abc")
        panel.window.settle()
        let undo = NSMenuItem(title: "", action: #selector(BoardWindow.undo(_:)), keyEquivalent: "")
        expect(window.validateMenuItem(undo))
        expectEqual(undo.title, "Undo Typing", "the text's own, not the board's Change Keyed")
        let revision = editor.revision
        window.undo(nil)
        expectEqual(view.string, "")
        expectEqual(editor.props(id, as: Gadget.self)?.remark, "")
        expectEqual(editor.revision, revision + 1, "written once, however often the text says it changed")
        panel.window.settle()
        expectEqual(view.shown, [], "what the undo wrote isn't shown back")
        expect(view.undoManager?.canRedo == true)
        panel.window.makeFirstResponder(panel.canvas)
        expect(view.undoManager?.canRedo == false, "forgotten once the keyboard left")
        expect(editor.canUndo, "the board's step for the typing is what's left")
    },
])
