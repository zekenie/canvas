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

/// Commands for jots and briefs: `ping` takes nothing, `near` takes shapes (a pill in the line, any
/// shape), `stack` takes one shape, a plate and no other (by its rule alone), and `shelve` one plate
/// or token (by its kinds) but the one called "Grocery List" (by its rule).
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
            SlashCommand("stack", shapes: { target, _, editor in editor.shape(inFile: target)?.kind == Plate.kind }) { _, arguments, _ in
                log.runs.append("stack \(arguments.shapes.map { $0 == idA ? "A" : $0 == idB ? "B" : "?" }.joined()) \(arguments.text)")
            }
            SlashCommand("shelve", kinds: { _ in [Plate.kind, Token.kind] }, shapes: { target, _, _ in target != idB }) { _, arguments, _ in
                log.runs.append("shelve \(arguments.shapes.map { $0 == idA ? "A" : $0 == idB ? "B" : $0 == idC ? "C" : "?" }.joined()) \(arguments.text)")
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
        expectEqual(picker.listed.map(\.name), ["ping", "near", "stack", "shelve", "title"], "the jot's own, then Titles' for every shape that has a title")
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

    test("on the line of a command that takes one shape the @ picker lists only the shapes it admits: the empty query's Nearby and a typed query's matches; on any other line, everything") {
        let log = SlashLog()
        @MainActor func jot() throws -> EditedJot { try EditedJot("", plugins: [SlashFixturesPlugin(log: log)], board: addCoin) }
        let command = try jot()
        command.type("/stack ")
        expect(command.textView.picker == nil)
        command.type("@")
        expect(command.textView.picker != nil, "the @ picker opens on a command line")
        expectEqual(command.pickerTargets, [idA, idB], "the plates; the coin, nearer than either, is left out")
        expectEqual(described(command.textView.picker), ["# Nearby", "Groceries", "Grocery List"])
        command.type("gro")
        expectEqual(command.pickerTargets, [idA, idB], "the matches: the plates, though the coin matches too")

        let coin = try jot()
        coin.type("/stack @run")
        expectEqual(described(coin.textView.picker), ["- No matches"], "\"run\" is the coin's alone, which the command doesn't take")
        expectEqual(coin.highlighted, nil)

        let plain = try jot()
        plain.type("@")
        expectEqual(plain.pickerTargets, [idC, idA, idB], "on a plain line, everything, the coin first")
        plain.type("gro")
        expectEqual(Set(plain.pickerTargets), [idA, idB, idC])
        let run = try jot()
        run.type("@run")
        expectEqual(run.pickerTargets, [idC])

        // The same shapes, on a command line that takes shapes by `accepts`, which has no rule for which.
        let near = try jot()
        near.type("/near @")
        expectEqual(Set(near.pickerTargets), [idA, idB, idC], "a rule is the shapes form's: `near` takes any shape")

        // On a later line, after one that isn't a command.
        let later = try jot()
        later.type("keep @")
        expect(later.textView.picker != nil)
        expectEqual(later.pickerTargets.count, 3)
        later.window.pressEscape()
        later.window.pressReturn()
        later.type("/stack @")
        expectEqual(later.pickerTargets, [idA, idB])
    },

    test("what's recent on the command's line is what the command admits: the plate picked before, not the coin") {
        let log = SlashLog()
        let session = try EditedJot("", plugins: [SlashFixturesPlugin(log: log)], board: addCoin)
        session.pick("groceries")
        session.window.pressReturn()
        session.pick("grocery run")
        expectEqual(session.pills.map(\.pill.target), [idA, idC])
        session.window.pressReturn()
        session.type("@")
        expectEqual(described(session.textView.picker), ["# Recent", "Grocery run", "Groceries", "# Nearby", "Grocery List"], "a plain line: the latest pick first")
        session.window.pressEscape()
        session.window.pressReturn()
        session.type("/stack @")
        expectEqual(described(session.textView.picker), ["# Recent", "Groceries", "# Nearby", "Grocery List"], "the command's line: the plate")
    },

    test("a plate picked on the command's line is its one shape: Return picks it, a second Return runs the line, and the pill is what's marked") {
        let log = SlashLog()
        let session = try EditedJot("", plugins: [SlashFixturesPlugin(log: log)])
        let view = session.textView
        session.type("/stack @gro")
        expectEqual(session.pickerTargets, [idA, idB])
        session.window.pressReturn()
        expect(view.picker == nil)
        expectEqual(session.pills.map(\.pill.target), [idA])
        expectEqual(log.runs, [], "Return picked the shape, it didn't run the line")
        expectEqual(view.highlights.map(\.range), [NSRange(location: 0, length: 6), NSRange(location: 7, length: 1)], "the name, and the plate it takes")
        session.window.pressReturn()
        expectEqual(log.runs, ["stack A @Groceries"])
        expectEqual(session.string, "")
        expectEqual(session.committed, MentionText(plain: ""))
    },

    test("a pill the command doesn't admit, put there some other way, leaves the line text: only the name is marked and Return is a new line; a plate there runs") {
        let log = SlashLog()
        let refused = try EditedJot(MentionText([.text("/stack "), .mention(idC, label: "Grocery run")]), plugins: [SlashFixturesPlugin(log: log)], board: addCoin)
        expectEqual(refused.pills.map(\.pill.target), [idC])
        refused.textView.slashCommands?.didChange(isEdit: false)
        expectEqual(refused.textView.highlights.map(\.range), [NSRange(location: 0, length: 6)], "the name alone: the coin is text to it")
        refused.window.pressReturn()
        expectEqual(log.runs, [])
        expect(refused.string.hasPrefix("/stack ") && refused.string.hasSuffix("\n"), "Return was a new line")

        let admitted = try EditedJot(MentionText([.text("/stack "), .mention(idA, label: "Groceries")]), plugins: [SlashFixturesPlugin(log: log)], board: addCoin)
        admitted.window.pressReturn()
        expectEqual(log.runs, ["stack A @Groceries"])
        expectEqual(admitted.string, "")
    },

    test("a command that names kinds lists those kinds' shapes the rule admits: plates and tokens but not the plate the rule refuses, and no endpoint though the rule would take it") {
        let log = SlashLog()
        @MainActor func jot(_ text: MentionText = "") throws -> EditedJot { try EditedJot(text, plugins: [SlashFixturesPlugin(log: log)], board: addShelf) }
        let shelve = try jot()
        shelve.type("/shelve @")
        expectEqual(described(shelve.textView.picker), ["# Nearby", "Grocery run", "Groceries"], "the token and the plate, the endpoint nearer than either left out by its kind, \"Grocery List\" by the rule")
        shelve.type("gro")
        expectEqual(shelve.pickerTargets, [idC, idA], "the matches: the same")
        let status = try jot()
        status.type("/shelve @status")
        expectEqual(described(status.textView.picker), ["- No matches"], "\"status\" is the endpoint's alone")
        let list = try jot()
        list.type("/shelve @list")
        expectEqual(described(list.textView.picker), ["- No matches"], "and \"list\" the plate the rule refuses")

        let plain = try jot()
        plain.type("@gro")
        expectEqual(Set(plain.pickerTargets).count, 4, "on a plain line the plates, the token and the endpoint")
        expect(Set(plain.pickerTargets).isSuperset(of: [idA, idB, idC]))

        // A pick, and the line it makes.
        let pick = try jot()
        pick.type("/shelve @gro")
        pick.down()
        pick.window.pressReturn()
        expectEqual(pick.pills.map(\.pill.target), [idA])
        pick.window.pressReturn()
        expectEqual(log.runs, ["shelve A @Groceries"])
        expectEqual(pick.string, "")
    },

    test("a pill put on the line some other way is taken if its kind is one the command names and the rule admits it, and is text if not: an endpoint, the plate the rule refuses") {
        let log = SlashLog()
        @MainActor func line(_ pill: MentionRun) throws -> EditedJot {
            try EditedJot(MentionText([.text("/shelve "), pill]), plugins: [SlashFixturesPlugin(log: log)], board: addShelf)
        }
        for (what, pill) in [("an endpoint", MentionRun.mention(idE, label: "Grocery status")), ("the plate the rule refuses", .mention(idB, label: "Grocery List"))] {
            let refused = try line(pill)
            refused.textView.slashCommands?.didChange(isEdit: false)
            expectEqual(refused.textView.highlights.map(\.range), [NSRange(location: 0, length: 7)], "\(what): the name alone")
            refused.window.pressReturn()
            expectEqual(log.runs, [], what)
            expect(refused.string.hasPrefix("/shelve ") && refused.string.hasSuffix("\n"), "\(what): Return was a new line")
        }
        let token = try line(.mention(idC, label: "Grocery run"))
        token.textView.slashCommands?.didChange(isEdit: false)
        expectEqual(token.textView.highlights.map(\.range), [NSRange(location: 0, length: 7), NSRange(location: 8, length: 1)], "a token: the name and the pill")
        token.window.pressReturn()
        expectEqual(log.runs, ["shelve C @Grocery run"])
        expectEqual(token.string, "")
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

/// A token, "Grocery run", nearer to the jot than either plate (the plates are 267 and 272 away, it 232).
@MainActor private func addCoin(_ editor: CanvasEditor) {
    editor.add(Token(CGRect(x: 100, y: 300, width: 60, height: 60), caption: "Grocery run"), titled: nil, id: idC)
}

/// The token, and an endpoint, "Grocery status", nearer than either (206 away): a kind a command may not name.
@MainActor private func addShelf(_ editor: CanvasEditor) {
    addCoin(editor)
    editor.add(Endpoint(CGRect(x: 100, y: 260, width: 160, height: 60), path: "Grocery status"), titled: nil, id: idE)
}

private let idE = ShapeID(UUID(uuidString: "EEEEEEEE-1111-4222-8333-444444444444")!)

/// What a picker's rows say, one string each: headers with a "#", the one row of an empty state with a
/// "-", a shape by its label.
@MainActor private func described(_ picker: MentionPicker?) -> [String] {
    picker?.rows.map { row in
        switch row {
        case .header(let words): "# \(words)"
        case .empty(let words): "- \(words)"
        case .candidate(let candidate): candidate.appearance.label
        }
    } ?? []
}
