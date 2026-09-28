import AppKit
import Canvas
import CanvasTesting
import DetailPanel
import Selection
import SwiftUI
import TestKit

// A code editor's completions (`DetailCodeEditor`'s `completions:`) in the panel, in an unshown
// window: the keys that open, move through, pick from and close the list, what it lists as it's
// typed into, where it's placed, what closes it, and what a pick writes. The language is the
// fixture's own, a fruit bowl.

/// A fruit bowl, as offered: apple first, though it matters least; a basket that reopens where it
/// leaves the caret; a cherry with its count selected, to be typed over.
let bowl: [DetailCodeCompletion] = [
    DetailCodeCompletion(label: "apple", detail: "fruit", insert: "apple", isRelevant: false),
    DetailCodeCompletion(label: "apricot", detail: "fruit", insert: "apricot"),
    DetailCodeCompletion(label: "grape", detail: "fruit", insert: "grape"),
    DetailCodeCompletion(label: "pineapple", detail: "fruit", insert: "pineapple"),
    DetailCodeCompletion(label: "basket", detail: "holds fruit", insert: "basket()", selection: NSRange(location: 7, length: 0), reopens: true),
    DetailCodeCompletion(label: "cherry", insert: "cherry * 12", selection: NSRange(location: 9, length: 2)),
] + ["banana", "damson", "fig", "kiwi", "lemon", "mango", "plum"].map { DetailCodeCompletion(label: $0, detail: "fruit", insert: $0) }

/// What goes in a basket.
let fillings = [DetailCodeCompletion(label: "jam", detail: "sweet", insert: "jam"), DetailCodeCompletion(label: "honey", detail: "sweet", insert: "honey")]

/// Completes fruit at the caret: the letters around it are what a pick replaces, those before it
/// what's typed. At the start of a line, the bowl; just inside "(", a basket's fillings; after
/// anything else (a space, a digit), nothing. A word that starts with an x gets a range just past
/// it, as a provider that's wrong gives.
@MainActor func fruitCompletions(_ text: String, _ caret: Int) -> DetailCodeCompletions? {
    let units = Array(text.utf16)
    func isLetter(_ i: Int) -> Bool { units.indices.contains(i) && (UInt16(UInt8(ascii: "a"))...UInt16(UInt8(ascii: "z"))).contains(units[i]) }
    var start = caret, end = caret
    while isLetter(start - 1) { start -= 1 }
    while isLetter(end) { end += 1 }
    let query = String(decoding: units[start..<caret], as: UTF16.self)
    let range = NSRange(location: start, length: end - start)
    if query.hasPrefix("x") { return DetailCodeCompletions(range: NSRange(location: end + 1, length: 0), query: query, items: bowl) }
    switch start > 0 ? units[start - 1] : nil {
    case nil, UInt16(UInt8(ascii: "\n")): return DetailCodeCompletions(range: range, query: query, items: bowl)
    case UInt16(UInt8(ascii: "(")): return DetailCodeCompletions(range: range, query: query, items: fillings)
    default: return nil
    }
}

enum BareTab {}
extension BareTab: DetailTab { static var title: String { "Bare" } }

/// A Bare tab for the gadget: its remark as code with no completions.
struct BareCodePlugin: CanvasPlugin {
    var id: PluginID { "bare-code" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.details(Gadget.self) {
            DetailSection("Bare", in: BareTab.self) { $gadget in DetailCodeEditor($gadget.remark) }
        }
    }
}

extension PanelWindow {
    /// The code editor's list, while it's open.
    var completions: CaretListWindow? { (code as? DetailTextView)?.caretListWindow }
    /// What it lists, top to bottom.
    var listed: [String] { completions?.list.rows.compactMap { $0.item?.title } ?? [] }
    var highlighted: String? { completions?.list.highlightedItem?.title }

    /// A gadget with `remark`, selected, on its Code tab, its code editor with the keyboard and the
    /// caret at its end.
    func focusCode(_ remark: String = "") throws -> (id: ShapeID, code: NSTextView) {
        var gadget = Gadget(gadgetFrame)
        gadget.remark = remark
        let id = try showCode(gadget)
        let code = try require(self.code)
        focus(code)
        return (id, code)
    }

    func controlSpace() { window.press(" ", code: 49, modifiers: .control) }
    /// ⌘↩, as the app hands a key with ⌘ on: to the window's key equivalents first, then, if none
    /// took it, to the window, as a key.
    func commandReturn(code: UInt16 = 36) {
        let event = window.keyEvent(code == 76 ? "\u{3}" : "\r", code: code, modifiers: .command)
        if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
    }
    func optionEscape() { window.press("\u{1b}", code: 53, modifiers: .option) }
    func f5() { window.press("\u{F708}", code: 96, modifiers: .function) }
    func up() { window.press("\u{F700}", code: 126, modifiers: [.numericPad, .function]) }
    func down() { window.press("\u{F701}", code: 125, modifiers: [.numericPad, .function]) }
    func left() { window.press("\u{F702}", code: 123, modifiers: [.numericPad, .function]) }
    func tab() { window.press("\t", code: 48) }
    func control(_ letter: Character, code: UInt16) {
        let character = String(UnicodeScalar(letter.asciiValue! - 0x60))
        window.sendEvent(window.keyEvent(character, ignoringModifiers: String(letter), code: code, modifiers: .control))
    }

    /// A click on the list's row, as its rows view hears it (an unshown window's clicks don't reach
    /// its views).
    func click(row: Int) throws {
        let listWindow = try require(completions)
        let rows = try require(listWindow.contentView?.descendants.first { $0.accessibilityRole() == .list })
        let event = try require(NSEvent.mouseEvent(with: .leftMouseDown, location: rows.convert(CGPoint(x: 100, y: CGFloat(row) * 20 + 10), to: nil),
                                                   modifierFlags: [], timestamp: 1, windowNumber: listWindow.windowNumber, context: nil,
                                                   eventNumber: 0, clickCount: 1, pressure: 1))
        rows.mouseDown(with: event)
    }
}

@MainActor let completionTests = Suite("Code completions", [
    test("⌃Space opens the list under what's typed, placed though the window isn't shown: as offered while nothing's typed, ranked by what is") {
        let editor = try gadgetEditor([CodeBoxesPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let (id, code) = try panel.focusCode()
        panel.controlSpace()
        let list = try require(panel.completions, "open")
        expectEqual(panel.listed, bowl.map(\.label), "nothing typed: every item, as offered")
        expectEqual(panel.highlighted, "apple")
        expect((code as? DetailTextView)?.holdsKeys == true)
        expect(!list.isVisible, "never shown while the text's window isn't")
        let anchor = code.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        expectEqual(list.frame.width, 410)
        expectClose(list.frame.maxY, anchor.minY - 3)
        expectClose(list.frame.minX, anchor.minX - 12, within: 1)
        expectClose(list.frame.height, 10 * 20 + 10, within: 0.001)
        panel.window.type("ap")
        expectEqual(editor.props(id, as: Gadget.self)?.remark, "ap", "typing is the text's")
        expectEqual(panel.listed, ["apricot", "apple", "grape", "pineapple"], "prefixes, what matters first, then substrings, each as offered")
        expectEqual(list.list.rows.map { $0.item?.matched ?? [] }, [[0..<2], [0..<2], [2..<4], [4..<6]])
        expectEqual(list.list.rows.first?.item?.font, NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), "in the code's font")
        expectClose(list.frame.maxY, anchor.minY - 3)
        expectClose(list.frame.minX, anchor.minX - 12, within: 1)
        expectClose(list.frame.height, 4 * 20 + 10, within: 0.001)
        let rows = try require(list.contentView?.descendants.first { $0.accessibilityRole() == .list })
        expectEqual(rows.accessibilityLabel(), "Completions")
        let spoken = (rows.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }
        expectEqual(spoken, ["apricot, fruit", "apple, fruit", "grape, fruit", "pineapple, fruit"])
    },
    test("↓ moves, Return picks: the text written once, the caret where the item says, and one undo of the text takes it back; Enter picks too") {
        let editor = try gadgetEditor([CodeBoxesPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let (id, code) = try panel.focusCode()
        panel.window.type("ap")
        panel.window.settle()       // typing's own step of the text's undo
        panel.controlSpace()
        panel.down()
        expectEqual(panel.highlighted, "apple")
        codeWrites = 0
        panel.window.pressReturn()
        expectEqual(code.string, "apple")
        expectEqual(editor.props(id, as: Gadget.self)?.remark, "apple")
        expectEqual(codeWrites, 1, "one edit")
        expectEqual(code.selectedRange(), NSRange(location: 5, length: 0))
        expect(panel.completions == nil && (code as? DetailTextView)?.holdsKeys == false, "closed")
        panel.window.settle()
        try require(code.undoManager).undo()
        expectEqual(code.string, "ap", "what was typed, as it was")
        code.setSelectedRange(NSRange(location: 2, length: 0))
        panel.controlSpace()
        panel.window.press("\u{3}", code: 76)       // Enter
        expectEqual(code.string, "apricot")
        expectEqual(codeCommits, 0, "a pick is no commit")
    },
    test("Tab picks; what an item selects is left selected; a pick that reopens asks again at once, where it left the caret") {
        let editor = try gadgetEditor([CodeBoxesPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let (id, code) = try panel.focusCode()
        panel.window.type("bas")
        panel.controlSpace()
        expectEqual(panel.listed, ["basket"])
        panel.tab()
        expectEqual(code.string, "basket()")
        expectEqual(code.selectedRange(), NSRange(location: 7, length: 0))
        expectEqual(panel.listed, ["jam", "honey"], "open again, with a basket's fillings")
        panel.window.pressReturn()
        expectEqual(code.string, "basket(jam)")
        expect(panel.completions == nil, "nothing to ask again")
        panel.window.press("\u{F703}", code: 124, modifiers: [.numericPad, .function])       // →, past the ")"
        panel.window.pressReturn()
        panel.window.type("che")
        panel.controlSpace()
        panel.tab()
        expectEqual(code.string, "basket(jam)\ncherry * 12")
        expectEqual(code.selectedRange(), NSRange(location: 12 + 9, length: 2), "its count, to be typed over")
        expectEqual(editor.props(id, as: Gadget.self)?.remark, "basket(jam)\ncherry * 12")
    },
    test("while it's open ↑ ↓ ⌃P ⌃N move, wrapping, and Page Up and Down a page, stopping at the ends; ← and → are the text's; closed, Return and Tab indent") {
        let editor = try gadgetEditor([CodeBoxesPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let (_, code) = try panel.focusCode()
        panel.controlSpace()
        panel.up()
        expectEqual(panel.highlighted, "plum", "↑ from the first wraps to the last")
        panel.control("n", code: 45)
        expectEqual(panel.highlighted, "apple")
        panel.control("p", code: 35)
        expectEqual(panel.highlighted, "plum")
        panel.down()
        panel.window.press("\u{F72D}", code: 121, modifiers: .function)       // Page Down
        expectEqual(panel.highlighted, "lemon", "ten rows on")
        panel.window.press("\u{F72D}", code: 121, modifiers: .function)
        expectEqual(panel.highlighted, "plum", "the last, no further")
        panel.window.press("\u{F72C}", code: 116, modifiers: .function)       // Page Up
        expectEqual(panel.highlighted, "grape")
        expectEqual(code.string, "", "none of it typed")
        panel.window.type("ap")
        panel.left()
        expectEqual(code.selectedRange(), NSRange(location: 1, length: 0), "← moves the caret")
        expect(panel.listed.contains("banana") && panel.listed.first == "apricot", "and the list asks again for what's typed before it: a")
        panel.left()
        expectEqual(panel.listed, bowl.map(\.label), "nothing typed before it")
        panel.window.press("\u{1b}", code: 53)
        expect(panel.completions == nil)
        panel.window.pressReturn()
        panel.tab()
        expectEqual(code.string, "\n  ap", "closed: a new line, then two spaces")
    },
    test("typing asks again: the list follows what's typed, and closes once nothing matches, nothing's offered, or the caret leaves what it opened for") {
        let editor = try gadgetEditor([CodeBoxesPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let (_, code) = try panel.focusCode()
        panel.controlSpace()
        panel.window.type("apr")
        expectEqual(panel.listed, ["apricot"])
        panel.window.press("\u{7f}", code: 51)       // Delete
        expectEqual(panel.listed, ["apricot", "apple", "grape", "pineapple"])
        panel.window.type("q")
        expect(panel.completions == nil, "nothing matches: closed, with no row saying so")
        expectEqual(code.string, "apq")
        panel.controlSpace()
        expect(panel.completions == nil, "and nothing opens")
        panel.window.pressReturn()
        panel.controlSpace()
        panel.window.type("gr")
        expectEqual(panel.listed, ["grape"])
        panel.window.type("1")
        expect(panel.completions == nil, "nothing's offered after a digit")
        panel.window.pressReturn()
        panel.controlSpace()
        expect(panel.completions != nil)
        panel.window.type("x")
        expect(panel.completions == nil, "the range doesn't hold the caret")
        panel.controlSpace()
        expect(panel.completions == nil)
        panel.window.pressReturn()
        panel.controlSpace()
        panel.window.type("fi")
        expectEqual(panel.listed, ["fig"])
        code.setSelectedRange(NSRange(location: 1, length: 0))
        expect(panel.completions == nil, "the caret left for another place, where something else is offered")
        expectEqual(code.string, "apq\ngr1\nx\nfi", "no key of the list's was typed")
    },
    test("Escape closes the list and the panel stays; a second leaves the panel, committing once") {
        let editor = try gadgetEditor([CodeBoxesPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let (_, code) = try panel.focusCode("ap")
        panel.controlSpace()
        panel.window.pressEscape()
        panel.window.settle()
        expect(panel.completions == nil)
        expectEqual(panel.exits, 0)
        expect(panel.window.firstResponder === code, "the editor keeps the keyboard")
        expectEqual(codeCommits, 0)
        panel.window.pressEscape()
        panel.window.spin { panel.canvasHasKeyboard }
        expectEqual(panel.exits, 1)
        expectEqual(codeCommits, 1)
        expectEqual(code.string, "ap")
    },
    test("⌥⎋ and F5 open the same list, and close it, as ⌃Space does; the panel lets ⌥⎋ through, and Escape still leaves") {
        let editor = try gadgetEditor([CodeBoxesPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let (_, code) = try panel.focusCode("ap")
        panel.optionEscape()
        panel.window.settle()
        expectEqual(panel.listed, ["apricot", "apple", "grape", "pineapple"])
        expectEqual(panel.exits, 0)
        panel.optionEscape()
        expect(panel.completions == nil)
        panel.f5()
        expectEqual(panel.listed, ["apricot", "apple", "grape", "pineapple"])
        panel.f5()
        expect(panel.completions == nil)
        panel.controlSpace()
        expect(panel.completions != nil)
        panel.controlSpace()
        expect(panel.completions == nil)
        panel.window.settle()
        expectEqual([code.string, "\(panel.exits)"], ["ap", "0"])
        panel.window.pressEscape()
        panel.window.spin { panel.canvasHasKeyboard }
        expectEqual(panel.exits, 1)
    },
    test("without completions, ⌃Space, ⌥⎋ and F5 open nothing and change no text: ⌥⎋ leaves the panel, as Escape does") {
        let editor = try gadgetEditor([BareCodePlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let id = editor.add(Gadget(gadgetFrame))
        try require(editor.detailPanel).choose(.of(BareTab.self), for: Gadget.kind)
        editor.selection = id
        panel.window.spin { panel.code != nil }
        let code = try require(panel.code)
        panel.focus(code)
        panel.window.type("app")
        panel.f5()
        panel.controlSpace()
        panel.window.settle()
        expectEqual(code.string, "app")
        expect(panel.completions == nil && (code as? DetailTextView)?.holdsKeys == false)
        expect(panel.window.childWindows?.isEmpty ?? true)
        expectEqual(panel.exits, 0)
        panel.optionEscape()
        panel.window.spin { panel.canvasHasKeyboard }
        expectEqual(panel.exits, 1)
        expectEqual(editor.props(id, as: Gadget.self)?.remark, "app")
    },
    test("⌘↩ with the list open closes it and commits, as with it closed: as a key equivalent, as a key, and as ⌘Enter") {
        let editor = try gadgetEditor([CodeBoxesPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let (id, code) = try panel.focusCode("ap")
        panel.controlSpace()
        panel.commandReturn()
        expect(panel.completions == nil && (code as? DetailTextView)?.holdsKeys == false, "closed")
        expectEqual(codeCommits, 1, "committed")
        panel.controlSpace()
        panel.window.press("\r", code: 36, modifiers: .command)       // a key down alone
        expect(panel.completions == nil)
        expectEqual(codeCommits, 2)
        panel.controlSpace()
        panel.commandReturn(code: 76)
        expect(panel.completions == nil)
        expectEqual(codeCommits, 3)
        expectEqual(code.string, "ap", "nothing picked, no new line")
        expectEqual(editor.props(id, as: Gadget.self)?.remark, "ap")
        expect(panel.window.firstResponder === code, "the editor keeps the keyboard")
        expectEqual(panel.exits, 0)
    },
    test("onCompleting hears the list open and close, and a pick that opens it again not at all: it's still open") {
        let editor = try gadgetEditor([CodeBoxesPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let (_, code) = try panel.focusCode("bas")
        panel.controlSpace()
        expectEqual(codeCompleting, [true])
        panel.window.type("k")
        panel.tab()
        expectEqual(code.string, "basket()")
        expectEqual(panel.listed, ["jam", "honey"])
        expectEqual(codeCompleting, [true], "open again at once")
        panel.window.pressReturn()
        expectEqual(code.string, "basket(jam)")
        expectEqual(codeCompleting, [true, false], "nothing to ask again: closed")
        panel.window.pressReturn()
        panel.controlSpace()
        panel.window.pressEscape()
        panel.controlSpace()
        panel.window.makeFirstResponder(panel.canvas)
        expectEqual(codeCompleting, [true, false, true, false, true, false], "Escape, and the keyboard leaving")
    },
    test("⌘. closes the open list and the panel stays; with it closed, ⌘. leaves") {
        let editor = try gadgetEditor([CodeBoxesPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let (_, code) = try panel.focusCode("ap")
        panel.controlSpace()
        panel.window.pressCommandPeriod()
        panel.window.settle()
        expect(panel.completions == nil)
        expectEqual(panel.exits, 0)
        expect(panel.window.firstResponder === code)
        panel.window.pressCommandPeriod()
        panel.window.spin { panel.canvasHasKeyboard }
        expectEqual(panel.exits, 1)
    },
    test("read-only, it opens nothing; made read-only, or shown text from elsewhere, the open list closes") {
        let editor = try gadgetEditor([CodeBoxesPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let (id, code) = try panel.focusCode("ap")
        editor.transact { $0.update(id, as: Gadget.self) { $0.props.count = 1 } }
        panel.window.spin { !code.isEditable }
        panel.controlSpace()
        panel.f5()
        expect(panel.completions == nil)
        expectEqual(code.string, "ap")
        panel.window.pressEscape()      // not its key: the panel leaves
        panel.window.spin { panel.canvasHasKeyboard }
        editor.transact { $0.update(id, as: Gadget.self) { $0.props.count = 0 } }
        panel.window.spin { code.isEditable }
        panel.focus(code)
        panel.controlSpace()
        expect(panel.completions != nil)
        editor.transact { $0.update(id, as: Gadget.self) { $0.props.count = 1 } }
        panel.window.spin { panel.completions == nil }
        expect(!code.isEditable)
        editor.transact { $0.update(id, as: Gadget.self) { $0.props.count = 0 } }
        panel.window.spin { code.isEditable }
        panel.focus(code)
        panel.controlSpace()
        expect(panel.completions != nil)
        editor.transact { $0.update(id, as: Gadget.self) { $0.props.remark = "fig" } }
        panel.window.spin { code.string == "fig" }
        expect(panel.completions == nil, "text shown from outside closes it")
    },
    test("the keyboard leaving closes it, and commits once; so does the panel showing another shape") {
        let editor = try gadgetEditor([CodeBoxesPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let (_, code) = try panel.focusCode("ap")
        panel.controlSpace()
        panel.window.makeFirstResponder(panel.canvas)
        expect(panel.completions == nil && (code as? DetailTextView)?.holdsKeys == false)
        expectEqual(codeCommits, 1)
        panel.focus(code)
        panel.controlSpace()
        let open = try require(panel.completions)
        editor.selection = nil
        panel.window.spin { panel.code == nil && panel.canvasHasKeyboard }
        expect((code as? DetailTextView)?.caretListWindow == nil, "closed as its view left the window")
        expect(open.list.onChange == nil)
    },
    test("a click on a row picks its item") {
        let editor = try gadgetEditor([CodeBoxesPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let (id, code) = try panel.focusCode("ap")
        panel.controlSpace()
        codeWrites = 0
        try panel.click(row: 2)
        expectEqual(code.string, "grape")
        expectEqual(editor.props(id, as: Gadget.self)?.remark, "grape")
        expectEqual(codeWrites, 1)
        expect(panel.completions == nil)
        expect(panel.window.firstResponder === code, "the editor keeps the keyboard")
    },
])
