import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import DetailPanel
import Mentions
import SlashCommands
import TestKit
import TextEditing

// Slash commands in a mention text view: the jot's editor on the canvas and the brief's box in the
// panel host `SlashCommandTyping` (SlashCommandsTests hold it whole over a text view of its own),
// and a pill in a command line is a shape it's given. Fixture commands only.

/// What the fixture commands that `perform` did.
@MainActor final class SlashLog {
    var runs: [String] = []
}

/// Commands for jots and briefs: `ping` takes nothing, `near` takes shapes (a pill in the line).
struct SlashFixturesPlugin: CanvasPlugin {
    let log: SlashLog
    var id: PluginID { "slash-fixtures" }

    func register(into registrar: inout PluginRegistrar) {
        let log = log
        registrar.slashCommands(Jot.self) {
            SlashCommand("ping") { _, _, _ in log.runs.append("ping") }
            SlashCommand("near", argument: "@shape", accepts: { !$0.shapes.isEmpty }) { _, arguments, _ in
                log.runs.append("near \(arguments.shapes.map { $0 == idA ? "A" : $0 == idB ? "B" : "?" }.joined()) \(arguments.text)")
            }
        }
        registrar.slashCommands(Brief.self) {
            SlashCommand("ping") { _, _, _ in log.runs.append("brief ping") }
        }
    }
}

@MainActor let slashTests = Suite("Slash commands in mention text", [
    test("in a jot's editor a slash on a new line lists its commands in the view's own list, and Return runs one: its line goes from the text the jot commits") {
        let log = SlashLog()
        let session = try EditedJot("keep", plugins: [SlashFixturesPlugin(log: log)])
        let view = session.textView
        let typing = try require(view.slashCommands)
        session.window.pressReturn()
        session.type("/")
        let picker = try require(typing.picker)
        expectEqual(picker.listed.map(\.name), ["ping", "near", "title"], "the jot's own, then Titles' for every shape that has a title")
        expect(view.caretListWindow === typing.window, "the slash list is the view's list")
        expect(view.holdsKeys && view.picker == nil)
        session.type("pi")
        expectEqual(picker.highlightedCommand?.name, "ping")
        session.window.settle()
        session.window.pressReturn()
        expectEqual(log.runs, ["ping"])
        expectEqual(session.string, "keep\n")
        expectEqual(session.committed, MentionText(plain: "keep\n"), "the jot's committed text has lost the line")
        expect(typing.picker == nil && view.caretListWindow == nil)
    },

    test("a pill in a command line is a shape it's given: @ in the line opens the mention picker, whose Return picks the shape; Return then runs the line") {
        let log = SlashLog()
        let session = try EditedJot("", plugins: [SlashFixturesPlugin(log: log)])
        let view = session.textView
        session.type("/near ")
        expect(view.slashCommands?.picker == nil, "a space ends the name")
        session.type("@gro")
        expect(view.picker != nil, "the @ picker, in a command line")
        expectEqual(session.pickerTargets, [idA, idB])
        session.window.pressReturn()
        expect(view.picker == nil)
        expectEqual(log.runs, [], "Return picked the shape, it didn't run the line")
        expectEqual(session.pills.map(\.pill.target), [idA])
        session.window.pressReturn()
        expectEqual(log.runs, ["near A @Groceries"])
        expectEqual(session.string, "")
        expectEqual(session.committed, MentionText(plain: ""))
    },

    test("a command typed in a jot's editor is marked under the text, and a pill it's given in a lighter shade; the mark goes with the line") {
        let log = SlashLog()
        let session = try EditedJot("", plugins: [SlashFixturesPlugin(log: log)])
        let view = session.textView
        session.type("/ne")
        expectEqual(view.highlights.map(\.range), [NSRange(location: 0, length: 3)], "the name so far, while the list is open")
        session.type("ar ")
        expectEqual(view.highlights.map(\.range), [NSRange(location: 0, length: 5)], "the name; nothing is given yet")
        session.type("@gro")
        expect(view.picker != nil)
        expectEqual(view.highlights.map(\.range), [NSRange(location: 0, length: 5)], "@gro isn't a shape yet, and /near needs one")
        session.window.pressReturn()
        expectEqual(session.pills.map(\.pill.target), [idA])
        expectEqual(view.highlights.map(\.range), [NSRange(location: 0, length: 5), NSRange(location: 6, length: 1)], "the pill is what it's given")
        session.window.pressReturn()
        expectEqual(log.runs, ["near A @Groceries"])
        expectEqual(view.highlights, [], "the line is gone")
    },

    test("a line without the shape a command needs is a new line, pill or no pill; ⇧↩ doesn't run it") {
        let log = SlashLog()
        let session = try EditedJot("", plugins: [SlashFixturesPlugin(log: log)])
        session.type("/near later ")
        session.window.pressReturn()
        expectEqual(log.runs, [])
        expectEqual(session.string, "/near later \n")
        let shift = try EditedJot("", plugins: [SlashFixturesPlugin(log: log)])
        shift.type("/ping ")
        shift.window.press("\r", code: 36, modifiers: .shift)
        expectEqual(log.runs, [])
    },

    test("a text shown from outside closes the list; the keyboard leaving does too") {
        let log = SlashLog()
        let shown = try EditedJot("", plugins: [SlashFixturesPlugin(log: log)])
        shown.type("/")
        expect(shown.textView.slashCommands?.picker != nil)
        shown.textView.show("elsewhere")
        expect(shown.textView.slashCommands?.picker == nil && shown.textView.caretListWindow == nil)

        let blurred = try EditedJot("", plugins: [SlashFixturesPlugin(log: log)])
        blurred.type("/")
        expect(blurred.window.makeFirstResponder(nil))
        expect(blurred.textView.caretListWindow == nil)
    },

    // Every list here has Titles, whose `/title` needs SlashCommandsPlugin, so a text view with an owner
    // always hosts slash commands; what its shape offers decides whether a slash lists any. A brief isn't
    // titled, and no fixture command is installed: it offers nothing.
    test("where the shape offers no command a slash is a slash: the brief's box hosts slash commands and lists none") {
        let panel = try MentionPanel()
        let brief = panel.editor.add(Brief(CGRect(x: 0, y: 0, width: 200, height: 200)), titled: nil)
        let view = try panel.show(brief, Blockers.self)
        expect(view.slashCommands != nil)
        expectEqual(try require(panel.editor.slashCommands).commands(for: brief).map(\.name), [])
        panel.focus(view)
        panel.window.type("/")
        expectEqual(view.string, "/")
        expect(view.slashCommands?.picker == nil && view.caretListWindow == nil, "nothing offered")
    },

    test("a text with no owner hosts none") {
        let style = MentionTextStyle(font: .systemFont(ofSize: 16), color: .black, lineHeight: 19)
        let h = try mentionHarness()
        let view = MentionTextView<AnyMentionable>(frame: CGRect(x: 0, y: 0, width: 200, height: 100), text: "", style: style,
                                                   owner: nil, mentions: h.editor.mentionState)
        expect(view.slashCommands == nil)
    },

    test("in the panel's box that commits on Return, a command line runs and doesn't commit; Return elsewhere commits") {
        let log = SlashLog()
        let panel = try MentionPanel(plugins: [SlashFixturesPlugin(log: log)])
        let brief = panel.editor.add(Brief(CGRect(x: 0, y: 0, width: 200, height: 200)), titled: nil)
        let view = try panel.show(brief, Blockers.self)
        expect(view.slashCommands != nil)
        blockedByCommits = 0
        panel.focus(view)
        panel.window.type("/ping ")
        panel.window.pressReturn()
        expectEqual(log.runs, ["brief ping"])
        expectEqual(blockedByCommits, 0, "it ran, it didn't commit")
        expectEqual(panel.editor.document[brief]?.typed(as: Brief.self)?.props.blockedBy, "", "and the line is gone from the field")
        panel.window.type("/pi")
        expect(view.holdsKeys, "the list is open")
        panel.window.pressReturn()
        expectEqual(log.runs, ["brief ping", "brief ping"])
        expectEqual(blockedByCommits, 0)
        panel.window.type("plain")
        panel.window.pressReturn()
        expectEqual(blockedByCommits, 1, "Return anywhere else commits")
    },
])
