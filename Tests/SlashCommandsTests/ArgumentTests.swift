import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import SlashCommands
import TestKit
import TextEditing

// What's typed after a `/` finds what the commands take, besides their names: a choice of a choice
// command's list, and a shape the host finds that a command taking one admits, each a row that is the
// line it stands for and runs as it's picked. The list's model headless, then typed in the text view of
// TypingTests', over fixture commands on cards (`CardCommandsPlugin`'s and `ChoicePlugin`'s) and the
// host's search the tests stand in for (`namedShapes`). Nothing goes on screen.

private let area = CGRect(x: 0, y: 0, width: 100, height: 60)

/// A card's commands, `CardCommandsPlugin`'s and `ChoicePlugin`'s, and the board's discs named for the host's search.
@MainActor private final class Rig {
    let h: EditorHarness
    let log = CommandLog()
    let card: ShapeID
    private(set) var named: [(id: ShapeID, label: String)] = []

    init(_ more: [any CanvasPlugin] = []) throws {
        h = try slashHarness([CardCommandsPlugin(log: log), ChoicePlugin(log: log)] + more)
        card = h.add(Card(area))
    }

    /// A disc called `label`, as the host's search finds it; with `box`, a box (which `stack` refuses).
    @discardableResult
    func shape(_ label: String, box: Bool = false) -> ShapeID {
        let id = box ? h.add(Box(area)) : h.add(Disc(area))
        named.append((id, label))
        return id
    }

    /// The list at a `/` in the card's text; with `searching`, one that finds the shapes named.
    func picker(searching: Bool = true) throws -> SlashCommandPicker {
        SlashCommandPicker(at: 0, offering: try require(h.editor.slashCommands).commands(for: card), findingShapes: searching ? namedShapes(named) : nil)
    }
}

/// Reads `typed` after a `/` at the start of the text, the caret at its end, as typing it does.
@MainActor @discardableResult
private func type(_ typed: String, into picker: SlashCommandPicker) -> SlashCommandPicker.Closing? {
    let text = "/" + typed
    return picker.read(text as NSString, selection: NSRange(location: (text as NSString).length, length: 0), isEdit: true)
}

private func rowText(_ row: CaretListRow) -> String {
    switch row {
    case .item(let item): item.detail.map { "\(item.title) (\($0))" } ?? item.title
    case .header(let words): "# \(words)"
    case .empty(let words): "- \(words)"
    }
}

/// What a row gives its command: `choice:<id>`, `shape:<label>`, or nil for the command alone.
private func given(_ entry: SlashCommandPicker.Entry) -> String? {
    switch entry.argument {
    case .choice(let choice)?: "choice:\(choice.id)"
    case .shape(let shape)?: "shape:\(shape.label)"
    case nil: nil
    }
}

/// The shapes `point`'s rule was asked of, in order.
@MainActor private final class PointLog {
    var shapes: [ShapeID] = []
}

/// `point`, for cards: takes one shape, any but the card itself, and logs each its rule is asked of.
private struct PointPlugin: CanvasPlugin {
    let log: PointLog
    var id: PluginID { "point-command" }

    func register(into registrar: inout PluginRegistrar) {
        let log = log
        registrar.slashCommands(Card.self) {
            SlashCommand("point", shapes: { target, owner, _ in
                log.shapes.append(target)
                return target != owner
            }) { _, _, _ in }
        }
    }
}

@MainActor private func session(_ text: String = "", board: (@MainActor (CanvasEditor) -> SlashShapeSearch?)? = nil) throws -> SlashSession {
    let log = CommandLog()
    return try SlashSession(text, plugins: [ChoicePlugin(log: log)], log: log, board: board)
}

@MainActor let slashArgumentListTests = Suite("Slash command list: what the commands take", [
    test("what's typed finds a choice of a choice command's list: a row that is the line it stands for, the typed letters matched in the choice, its detail after it") {
        let rig = try Rig()
        let picker = try rig.picker()
        expectEqual(type("ga", into: picker), nil)
        expectEqual(picker.rows.map(rowText), ["pick Gamma (last)"])
        expectEqual(picker.rows.compactMap(\.item?.matched), [[5..<7]], "\"ga\" in Gamma, after `pick `")
        expectEqual(picker.entries.map(given), ["choice:gamma"])
        expectEqual(picker.highlightedCommand?.name, "pick")
        expectEqual(picker.rows.first?.item?.spoken, "pick Gamma, last")
        type("al", into: picker)
        expectEqual(picker.rows.map(rowText), ["pick Alpha"])
        expectEqual(picker.rows.first?.item?.spoken, "pick Alpha")
    },

    test("the best match comes first, whichever command it is; a name comes before what a command takes of the same tier") {
        let rig = try Rig()
        rig.shape("Ping")
        let picker = try rig.picker()
        type("red", into: picker)
        expectEqual(picker.rows.map(rowText), ["pick-chips Red", "pick-else Red Panda"], "Red is exact, Red Panda a prefix, though pick-else is offered first")
        type("ping", into: picker)
        expectEqual(picker.rows.map(rowText), ["ping", "stack Ping (Disc)"], "both exact: the name first")
        expectEqual(picker.entries.map(given), [nil, "shape:Ping"])
        type("", into: picker)
        expectEqual(picker.listed.map(\.name), ["grow", "width", "log", "ping", "stack", "any", "pick", "pick-else", "pick-none", "pick-chips"],
                    "an empty query lists the commands alone, as ever")
    },

    test("the host's search is asked once a query, by name, and its best four are offered to each command that takes a shape, each shape's rows together in the commands' order; with no host, none; a command that takes words lists nothing") {
        let pointed = PointLog()
        let rig = try Rig([PointPlugin(log: pointed)])
        let moon1 = rig.shape("Moon 1"), box = rig.shape("Moon box", box: true), moon2 = rig.shape("Moon 2"), moon3 = rig.shape("Moon 3")
        rig.shape("Moon 4")
        let asked = SearchCount()
        let picker = SlashCommandPicker(at: 0, offering: try require(rig.h.editor.slashCommands).commands(for: rig.card),
                                        findingShapes: namedShapes(rig.named, asked: asked))
        expectEqual(asked.count, 0, "nothing typed, nothing searched")
        type("moon", into: picker)
        expectEqual(picker.rows.map(rowText), ["stack Moon 1 (Disc)", "point Moon 1 (Disc)", "point Moon box (Disc)", "stack Moon 2 (Disc)",
                                               "point Moon 2 (Disc)", "stack Moon 3 (Disc)", "point Moon 3 (Disc)"],
                    "the first four the host found, each with the commands that take it: not the box for stack, nothing of Moon 4, nothing for log or any, which take words")
        expectEqual(asked.count, 1, "one search a query, whatever the commands")
        expectEqual(Set(pointed.shapes), [moon1, box, moon2, moon3], "point's rule asked of the four alone")
        expectEqual(picker.rows.first?.item?.matched, [6..<10])
        expectEqual(picker.rows.first?.item?.spoken, "stack Moon 1, a disc")
        type("moon 2", into: picker)
        expectEqual(picker.rows.map(rowText), ["stack Moon 2 (Disc)", "point Moon 2 (Disc)"])
        expectEqual(asked.count, 2)
        let none = try rig.picker(searching: false)
        type("moon", into: none)
        expectEqual(none.rows, [.empty("No matches")])
    },

    test("whitespace and punctuation keep the list while something still matches; nothing matching, a command's name and a space, a line break, a pill and a query past 80 characters close it") {
        let rig = try Rig()
        let picker = try rig.picker()
        expectEqual(type("red pa", into: picker), nil)
        expectEqual(picker.rows.map(rowText), ["pick-else Red Panda"])
        expectEqual(picker.nameRange, NSRange(location: 0, length: 7), "the slash and all that's typed")
        expectEqual(type("red pa ", into: picker), nil, "a space after it, still matching")
        expectEqual(type("red zz", into: picker), .nameEnded, "nothing matches")
        expectEqual(type("zz.", into: picker), .nameEnded, "punctuation, matching nothing")
        expectEqual(try rig.picker().read("/zz" as NSString, selection: NSRange(location: 3, length: 0), isEdit: true), nil,
                    "a name that matches nothing stays, saying so, as ever")
        expectEqual(type("pick ", into: try rig.picker()), .nameEnded, "a command's name and a space: its own list opens there")
        expectEqual(type("PICK al", into: try rig.picker()), .nameEnded, "in any case, with more after it")
        expectEqual(type("red\n", into: try rig.picker()), .nameEnded)
        expectEqual(type("red\u{FFFC}", into: try rig.picker()), .nameEnded)
        let long = String(repeating: "g", count: 80)
        expectEqual(type(long, into: try rig.picker()), nil, "a query of a title's longest")
        expectEqual(type(long + "g", into: try rig.picker()), .tooLong)
    },

    test("the choices are asked for once, when something is first typed, and not for an empty query") {
        let rig = try Rig()
        let picker = try rig.picker()
        expectEqual(rig.log.choicesAsked, 0)
        type("r", into: picker)
        expectEqual(rig.log.choicesAsked, 2, "pick's and pick-else's rows, which count")
        type("red pa", into: picker)
        type("", into: picker)
        type("gam", into: picker)
        expectEqual(rig.log.choicesAsked, 2)
    },

    test("for several shapes a row says how many it acts on where that's fewer than all, after what the choice says") {
        let h = try slashHarness([LampsPlugin(), FreezingPlugin(), TargetCommandsPlugin(log: Reached())])
        let card = h.add(Card(area)), lamp = h.add(Lamp(area))
        let picker = SlashCommandPicker(at: 0, offering: try require(h.editor.slashCommands).commands(for: .selection([card, lamp])))
        type("all", into: picker)
        expectEqual(picker.rows.first.map(rowText), "pick-all All 1 (1 of 2)", "made for the card it acts on")
        expectEqual(picker.rows.first?.item?.spoken, "pick-all All 1, acts on 1 of 2 shapes")
    },
])

@MainActor let slashArgumentPickTests = Suite("Slash command list: picking what a command takes", [
    test("Return on a choice's row runs it at once: the line goes, editing goes on, one undo step named for the row, else the command") {
        let s = try session("keep")
        s.newLine()
        s.type("/gam")
        expectEqual(s.rows, ["pick Gamma (last)"])
        let width = s.width
        s.returnKey()
        expectEqual(s.string, "keep\n")
        expectEqual(s.cardText, "keep\n", "the host heard it go")
        expectEqual(s.log.runs, ["pick gamma"])
        expectEqual(s.width, width + 1)
        expect(s.list == nil && s.choiceList == nil && s.view.slashCommands?.window == nil)
        expectEqual(s.h.editor.undoHistory.undoName, "Pick")
        expect(s.h.editor.editingShapeID == s.card, "editing goes on")

        let beta = try session()
        beta.type("/bet")
        let before = beta.width
        beta.returnKey()
        expectEqual(beta.log.runs, ["pick beta"])
        expectEqual(beta.h.editor.undoHistory.undoName, "Pick Beta", "the row's own step")
        beta.h.editor.undo()
        expectEqual(beta.width, before, "the board's undo takes it back")
    },

    test("Tab and a click run it too; ↓ reaches the next row; Tab on a name still completes it") {
        let tab = try session()
        tab.type("/gam")
        tab.tab()
        expectEqual(tab.log.runs, ["pick gamma"])
        expectEqual(tab.string, "")

        let click = try session()
        click.type("/red")
        expectEqual(click.rows, ["pick-chips Red", "pick-else Red Panda"])
        click.down()
        click.view.slashCommands?.window?.pickHighlighted()
        expectEqual(click.log.runs, ["pick red-panda"])
        expectEqual(click.string, "")

        let keys = try session()
        keys.type("/red")
        keys.down()
        keys.up()
        keys.returnKey()
        expectEqual(keys.log.runs, ["pick red"], "↑ undoes ↓")

        let name = try session()
        name.type("/pi")
        expectEqual(name.highlighted, "ping")
        name.tab()
        expectEqual(name.string, "/ping")
        expectEqual(name.log.runs, [])
    },

    test("a space keeps the list while something matches, and Return runs the row; with nothing matching the list goes, and Return is a new line") {
        let s = try session()
        s.type("/red pa")
        expectEqual(s.rows, ["pick-else Red Panda"])
        s.returnKey()
        expectEqual(s.log.runs, ["pick red-panda"])
        expectEqual(s.string, "")

        let none = try session()
        none.type("/red zz")
        expect(none.list == nil)
        none.returnKey()
        expectEqual(none.string, "/red zz\n")
        expectEqual(none.log.runs, [])
    },

    test("what's typed is marked while the list lists something for it, and not while it says nothing matches") {
        let s = try session()
        s.type("/red")
        expectEqual(s.view.highlights.map(\.range), [NSRange(location: 0, length: 4)])
        s.type(" pa")
        expectEqual(s.view.highlights.map(\.range), [NSRange(location: 0, length: 7)])
        let none = try session()
        none.type("/zzz")
        expectEqual(none.rows, ["- No matches"])
        expectEqual(none.view.highlights.map(\.range), [])
    },

    test("a shape's row runs the command with the shape, as its pill on the line would: the line goes, editing goes on") {
        let s = try session { editor in
            let moon = editor.add(Disc(area)), box = editor.add(Box(area))
            return namedShapes([(moon, "Moon"), (box, "Moon box")])
        }
        s.type("/moo")
        expectEqual(s.rows, ["stack Moon (Disc)"], "the disc `stack` takes, not the box")
        s.returnKey()
        expectEqual(s.log.runs, ["stack @Moon"])
        expectEqual(s.string, "")
        expect(s.list == nil && s.h.editor.editingShapeID == s.card)
    },

    test("a field that can't name a shape lists no shape, whatever search it's given") {
        let h = try slashHarness([CardCommandsPlugin(log: CommandLog())])
        let card = h.add(Card(area)), moon = h.add(Disc(area))
        let view = SlashTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 40), target: .selection([card]),
                                 commands: try require(h.editor.slashCommands), shapes: namedShapes([(moon, "Moon")]), takesShapes: false)
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeFirstResponder(view)
        window.type("/moon")
        expectEqual(view.slashCommands?.picker?.rows, [.empty("No matches")])
    },
])
