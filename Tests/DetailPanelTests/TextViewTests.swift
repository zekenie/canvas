import AppKit
import Canvas
import CanvasTesting
import DetailPanel
import Selection
import SwiftUI
import TestKit

enum CodeTab {}
extension CodeTab: DetailTab { static var title: String { "Code" } }

/// How often each box in the Code tab said it was done.
@MainActor var codeCommits = 0
@MainActor var wordCommits = 0
/// How often the code editor wrote its text.
@MainActor var codeWrites = 0
/// What the code editor said of its completion list, in order: open (true), closed (false).
@MainActor var codeCompleting: [Bool] = []

/// A Code tab for the gadget: its remark as code, which completes fruit (read-only while its count
/// isn't 0, as a box a model is writing is), and its name as words that commit.
struct CodeBoxesPlugin: CanvasPlugin {
    var id: PluginID { "code-boxes" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.details(Gadget.self) {
            DetailSection("Code", in: CodeTab.self) { $gadget in
                let remark = $gadget.remark
                DetailCodeEditor(Binding(get: { remark.wrappedValue }, set: { codeWrites += 1; remark.wrappedValue = $0 }),
                                 coloring: digitsAndXs, completions: fruitCompletions, onCompleting: { codeCompleting.append($0) },
                                 onCommit: { codeCommits += 1 })
                    .detailUpdating(gadget.count > 0)
            }
            DetailSection("Words", in: CodeTab.self) { $gadget in
                DetailTextArea($gadget.name, placeholder: "Name it", onCommit: { wordCommits += 1 })
            }
        }
    }
}

/// A language where digits are numbers and an x doesn't belong.
func digitsAndXs(_ text: String) -> [DetailCodeSpan] {
    let units = Array(text.utf16)
    return units.indices.compactMap { i in
        switch units[i] {
        case UInt16(UInt8(ascii: "0"))...UInt16(UInt8(ascii: "9")): DetailCodeSpan(.number, NSRange(location: i, length: 1))
        case UInt16(UInt8(ascii: "x")): DetailCodeSpan(.invalid, NSRange(location: i, length: 1))
        default: nil
        }
    }
}

extension PanelWindow {
    /// The Code tab's boxes: the code editor's text view (monospaced), and the words'.
    var code: NSTextView? { textViews.first { !$0.isFieldEditor && $0.font?.isFixedPitch == true } }
    var words: NSTextView? { textViews.first { !$0.isFieldEditor && $0.font?.isFixedPitch == false } }

    /// A gadget selected, on its Code tab, the counts at zero.
    func showCode(_ gadget: Gadget = Gadget(gadgetFrame)) throws -> ShapeID {
        let id = editor.add(gadget)
        try require(editor.detailPanel).choose(.of(CodeTab.self), for: Gadget.kind)
        editor.selection = id
        window.spin { self.code != nil && self.words != nil }
        codeCommits = 0
        wordCommits = 0
        codeWrites = 0
        codeCompleting = []
        return id
    }

    /// Gives a text view the keyboard, the caret at its end.
    func focus(_ view: NSTextView) {
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        window.settle()
    }
}

@MainActor let textViewTests = Suite("Text boxes", [
    test("a code editor types exactly what's keyed: monospaced, no substitutions; Tab is two spaces, Return keeps the indentation") {
        let editor = try gadgetEditor([CodeBoxesPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let id = try panel.showCode()
        let code = try require(panel.code)
        expect(code.font?.isFixedPitch == true)
        expectEqual([code.isAutomaticQuoteSubstitutionEnabled, code.isAutomaticDashSubstitutionEnabled, code.isAutomaticTextReplacementEnabled,
                     code.isAutomaticSpellingCorrectionEnabled, code.isContinuousSpellCheckingEnabled, code.isGrammarCheckingEnabled,
                     code.isAutomaticLinkDetectionEnabled, code.isAutomaticDataDetectionEnabled, code.isAutomaticTextCompletionEnabled,
                     code.smartInsertDeleteEnabled],
                    [false, false, false, false, false, false, false, false, false, false])
        expectEqual(code.inlinePredictionType, .no, "no predicted words in the code")
        if #available(macOS 15.0, *) {
            expectEqual(code.mathExpressionCompletionType, .no)
            expectEqual(code.writingToolsBehavior, .none, "no Writing Tools rewriting a selection of it")
        }
        expectEqual(code.textContainer?.widthTracksTextView, false, "lines don't wrap")
        expect(code.isHorizontallyResizable && code.enclosingScrollView?.hasHorizontalScroller == true, "a long one scrolls sideways")
        panel.focus(code)
        panel.window.type("{")
        panel.window.pressReturn()
        panel.window.type(#""a": "x -- y","#)
        panel.window.pressReturn()
        panel.window.press("\t", code: 48)
        panel.window.type("[]")
        panel.window.press("\u{F702}", code: 123)       // ←, between the brackets
        panel.window.pressReturn()
        let expected = "{\n  \"a\": \"x -- y\",\n    [\n      \n    ]"
        code.checkTextInDocument(nil)       // what AppKit does a moment after typing, where substitutions are on
        expectEqual(code.string, expected)
        expectEqual(editor.props(id, as: Gadget.self)?.remark, expected, "written as typed, key by key")
        expectEqual(codeCommits, 0)
    },
    test("⌘↩, the keyboard leaving and Escape commit a code editor; Return doesn't") {
        let editor = try gadgetEditor([CodeBoxesPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let id = try panel.showCode()
        let code = try require(panel.code)
        panel.focus(code)
        panel.window.type("ok")
        panel.window.pressReturn()
        expectEqual(codeCommits, 0)
        panel.window.press("\r", code: 36, modifiers: .command)
        expectEqual(codeCommits, 1)
        expectEqual(editor.props(id, as: Gadget.self)?.remark, "ok\n", "⌘↩ is no new line")
        panel.window.makeFirstResponder(panel.canvas)
        expectEqual(codeCommits, 2)
        panel.focus(code)
        panel.window.pressEscape()
        panel.window.spin { panel.canvasHasKeyboard }
        expectEqual(codeCommits, 3)
        expectEqual(panel.exits, 1)
    },
    test("text from elsewhere replaces a code editor's; typing ahead of the panel isn't lost; updating makes it read-only") {
        let editor = try gadgetEditor([CodeBoxesPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let id = try panel.showCode()
        let code = try require(panel.code)
        panel.focus(code)
        panel.window.type("abc")                    // with no turn of the run loop between keys
        expectEqual(editor.props(id, as: Gadget.self)?.remark, "abc")
        panel.window.settle()
        expectEqual(code.string, "abc")
        editor.transact { $0.update(id, as: Gadget.self) { $0.props.remark = "{}" } }
        panel.window.spin { code.string == "{}" }
        editor.transact { $0.update(id, as: Gadget.self) { $0.props.count = 1 } }
        panel.window.spin { !code.isEditable }
        panel.window.type("x")
        expectEqual(code.string, "{}")
        editor.transact { $0.update(id, as: Gadget.self) { $0.props.count = 0 } }
        panel.window.spin { code.isEditable }
    },
    test("a code editor colors the runs its coloring names, as they're typed and written from elsewhere; read-only, it's dimmed") {
        let editor = try gadgetEditor([CodeBoxesPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let id = try panel.showCode()
        let code = try require(panel.code)
        @MainActor func color(at i: Int) -> NSColor? { code.textStorage?.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor }
        @MainActor func underlined(at i: Int) -> Bool { (code.textStorage?.attribute(.underlineStyle, at: i, effectiveRange: nil) as? Int ?? 0) != 0 }
        panel.focus(code)
        panel.window.type("a 12 x")
        expectEqual(color(at: 0), .labelColor)
        let number = try require(color(at: 2))
        expect(number != .labelColor)
        expectEqual(color(at: 3), number)
        expect(underlined(at: 5) && !underlined(at: 2), "what doesn't belong is underlined")
        editor.transact { $0.update(id, as: Gadget.self) { $0.props.remark = "é 7" } }
        panel.window.spin { code.string == "é 7" }
        expectEqual([color(at: 0), color(at: 2)], [.labelColor, number], "counted in UTF-16, as the spans are")
        editor.transact { $0.update(id, as: Gadget.self) { $0.props.remark = "7 x"; $0.props.count = 1 } }
        panel.window.spin { !code.isEditable }
        expectEqual([color(at: 0), color(at: 2)], [.secondaryLabelColor, .secondaryLabelColor])
        expect(!underlined(at: 2))
        editor.transact { $0.update(id, as: Gadget.self) { $0.props.count = 0 } }
        panel.window.spin { code.isEditable }
        expectEqual(color(at: 0), number)
    },
    test("a text area with a commit: Return commits and is no new line, ⇧↩ is one, and the keyboard leaving commits") {
        let editor = try gadgetEditor([CodeBoxesPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let id = try panel.showCode()
        let words = try require(panel.words)
        panel.focus(words)
        panel.window.type("a")
        panel.window.press("\r", code: 36, modifiers: .shift)
        panel.window.type("b")
        expectEqual(editor.props(id, as: Gadget.self)?.name, "a\nb")
        expectEqual(wordCommits, 0)
        panel.window.pressReturn()
        expectEqual(wordCommits, 1)
        expectEqual(editor.props(id, as: Gadget.self)?.name, "a\nb")
        expect(panel.window.firstResponder === words, "it keeps the keyboard")
        panel.window.makeFirstResponder(panel.canvas)
        expectEqual(wordCommits, 2)
        expectEqual(codeCommits, 0)
    },
    test("a text area without a commit is as it was: Return is a new line") {
        let editor = try gadgetEditor(scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let id = editor.add(Gadget(gadgetFrame))
        try require(editor.detailPanel).choose(.of(RemarksTab.self), for: Gadget.kind)
        editor.selection = id
        panel.window.spin { !panel.textViews.isEmpty }
        let area = try require(panel.textViews.first)
        panel.window.makeFirstResponder(area)
        panel.window.settle()
        panel.window.type("a")
        panel.window.pressReturn()
        panel.window.type("b")
        expectEqual(editor.props(id, as: Gadget.self)?.remark, "a\nb")
    },
    test("a status line of a section's own: its buttons run their actions") {
        final class Pressed { var titles: [String] = [] }
        let pressed = Pressed()
        let line = DetailStatusLine(DetailStatus("It failed.", tone: .error), actions: [
            DetailStatusAction("Again") { pressed.titles.append("Again") },
        ])
        let host = NSHostingView(rootView: line.frame(width: 240))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.settle()
        try require(host.descendants(NSButton.self).first).performClick(nil)
        expectEqual(pressed.titles, ["Again"])
    },
])
