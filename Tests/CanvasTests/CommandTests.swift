import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import TestKit

// Commands as the core holds them: declared once by a plugin (its title, its menu bar item, the standard
// action it answers, its moment and its rule over what it acts on), run by name. The core knows what a
// command is, never which commands exist: every command here is a fixture's.

/// What the commands below were run on, as they ran.
@MainActor private final class Runs {
    var log: [String] = []
    /// What commands act on from a key or the menu bar: the fixtures' selection.
    var picked: [ShapeID] = []
}

/// A plugin that keeps what commands act on from a key or the menu bar, as Selection keeps the
/// selection, and the commands: `scrap` on shapes (anytime), `nudge` between presses, `tidy` when idle,
/// `pin` where the subject's point is, and `wipe`, which answers the standard Delete.
@MainActor private func commands(_ runs: Runs) -> Contributor {
    Contributor(id: "commands") { r in
        r.commandShapes { _ in runs.picked }
        r.command("scrap", title: "Scrap", isEnabled: { !$0.shapes.isEmpty }) { runs.log.append("scrap \($0.shapes.count)") }
        r.command("nudge", title: "Nudge", runs: .betweenPresses, isEnabled: { !$0.shapes.isEmpty }) { _ in runs.log.append("nudge") }
        r.command("tidy", title: "Tidy", runs: .whenIdle, isEnabled: { !$0.shapes.isEmpty }) { _ in runs.log.append("tidy") }
        r.command("pin", title: "Pin", isEnabled: { $0.point != nil }) { runs.log.append("pin \(Int($0.point?.x ?? -1))") }
        r.command("wipe", title: "Wipe", answering: .delete, isEnabled: { !$0.shapes.isEmpty }) { runs.log.append("wipe \($0.shapes.count)") }
    }
}

@MainActor let commandTests = Suite("Commands", [
    test("from a key or the menu bar a command acts on what the plugin that claims command shapes says, with no point; with none, on no shapes; two claims conflict") {
        let runs = Runs()
        let h = try EditorHarness(plugins: [CardsPlugin(), commands(runs)])
        let card = h.add(Card(CGRect(x: 0, y: 0, width: 100, height: 60)))
        expectEqual(h.editor.commandSubject.shapes, [])
        expect(!h.editor.canPerform("scrap") && !h.editor.perform("scrap"), "nothing picked: its rule says no")
        runs.picked = [card]
        expectEqual(h.editor.commandSubject.shapes, [card])
        expect(h.editor.commandSubject.point == nil)
        expect(h.editor.perform("scrap"))
        expect(!h.editor.perform("pin"), "no point from a key")
        expectEqual(runs.log, ["scrap 1"])
        expectEqual(try EditorHarness(plugins: [Contributor(id: "x") { $0.command("scrap", title: "Scrap") { _ in } }]).editor.commandSubject.shapes, [])
        expectThrows(RegistryError.conflict(point: "CommandShapes", key: "the shapes commands act on", plugins: ["x", "y"])) {
            _ = try Registry(plugins: [Contributor(id: "x") { $0.commandShapes { _ in [] } }, Contributor(id: "y") { $0.commandShapes { _ in [] } }])
        }
    },
    test("from a key or the menu bar a command runs at its moment: anytime, between presses, or when idle, with no press under way and no shape edited") {
        let runs = Runs()
        let h = try EditorHarness(plugins: [CardsPlugin(), commands(runs)])
        let card = h.add(Card(CGRect(x: 0, y: 0, width: 100, height: 60)))
        runs.picked = [card]
        expect(h.editor.canPerform("scrap") && h.editor.canPerform("nudge") && h.editor.canPerform("tidy"))
        h.press(at: CGPoint(x: 400, y: 400))
        expect(h.editor.session != nil)
        expect(h.editor.canPerform("scrap"), "anytime: mid-press too")
        expect(!h.editor.canPerform("nudge") && !h.editor.perform("nudge"), "between presses: not mid-press")
        expect(!h.editor.canPerform("tidy"), "when idle: not mid-press")
        h.release()
        expect(h.editor.beginEditing(card))
        expect(h.editor.canPerform("nudge"), "between presses: while a shape is edited too")
        expect(!h.editor.canPerform("tidy") && !h.editor.perform("tidy"), "when idle: not while a shape is edited")
        expectEqual(h.editor.registry.moment(of: "tidy"), .whenIdle)
        expectEqual(h.editor.registry.moment(of: "scrap"), .anytime)
        expectEqual(h.editor.registry.moment(of: "nobody"), nil)
        expectEqual(runs.log, [])
    },
    test("a surface that brings its own shapes asks the rule alone (its moment is its own), and passes its point; a try asks neither") {
        let runs = Runs()
        let h = try EditorHarness(plugins: [CardsPlugin(), commands(runs)])
        let card = h.add(Card(CGRect(x: 0, y: 0, width: 100, height: 60)))
        expect(h.editor.beginEditing(card))
        expect(h.editor.canPerform("tidy", on: [card]), "the rule alone: a menu ends editing as it opens")
        expect(!h.editor.canPerform("tidy", on: []), "but the rule, with its shapes")
        expect(h.editor.perform("tidy", on: [card]))
        expect(!h.editor.perform("scrap", on: []))
        expect(h.editor.perform("pin", on: [], at: CGPoint(x: 42, y: 7)))
        expect(h.editor.attempt("scrap", on: []), "a try runs whatever the rule says")
        expect(!h.editor.attempt("nobody", on: [card]), "but only a command a plugin claims")
        expectEqual(runs.log, ["tidy", "pin 42", "scrap 0"])
    },
    test("what a command commits from any surface is one undo step") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), Contributor(id: "x") { r in
            r.command("spread", title: "Spread") { subject in
                for _ in 0..<2 {
                    subject.editor.transact("Spread") { $0.translate(Set(subject.shapes), by: CGPoint(x: 1, y: 0)) }
                }
            }
        }])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        h.editor.undoHistory.clear()
        expect(h.editor.perform("spread", on: [box]))
        expect(h.editor.attempt("spread", on: [box]))
        expectEqual(h.editor.document[box]?.box?.minX, 4)
        h.editor.undo()
        expectEqual(h.editor.document[box]?.box?.minX, 2, "the try's two commits, one step")
        h.editor.undo()
        expectEqual(h.editor.document[box]?.box?.minX, 0)
    },
    test("a command that answers a standard action is what the window's item runs on the board; one command an action, two a conflict; the core's undo and redo answer undo and redo") {
        let runs = Runs()
        let h = try EditorHarness(plugins: [CardsPlugin(), commands(runs)])
        let card = h.add(Card(CGRect(x: 0, y: 0, width: 100, height: 60)))
        expectEqual(h.editor.registry.command(answering: .delete), "wipe")
        expectEqual(h.editor.registry.command(answering: .undo), .undo)
        expectEqual(h.editor.registry.command(answering: .redo), .redo)
        expectEqual(h.editor.registry.command(answering: .cut), nil)
        expect(!h.editor.canPerform(answering: .delete) && !h.editor.canPerform(answering: .cut))
        runs.picked = [card]
        expect(h.editor.canPerform(answering: .delete))
        expect(h.editor.perform(answering: .delete))
        expect(!h.editor.perform(answering: .cut), "none answers Cut")
        expectEqual(runs.log, ["wipe 1"])
        expectThrows(RegistryError.conflict(point: "Commands", key: "the standard action cut", plugins: ["x", "y"])) {
            _ = try Registry(plugins: [Contributor(id: "x") { $0.command("snip", title: "Snip", answering: .cut) { _ in } },
                                       Contributor(id: "y") { $0.command("clip", title: "Clip", answering: .cut) { _ in } }])
        }
    },
    test("the menu bar's commands: each placed in a menu, in plugin order, with its title, place, order and the key the menu keys slot gives; none without a slot; a second slot a conflict") {
        let placed = Contributor(id: "placed") { r in
            r.command("tidy", title: "Tidy", menu: "Arrange", order: 100, runs: .whenIdle) { _ in }
            r.command("seek", title: "Seek…", menu: "Edit › Find", order: 200) { _ in }
            r.command("hidden", title: "Hidden") { _ in }
        }
        let keys = Contributor(id: "keys") { r in
            r.menuKeys { command, registry in command == "seek" ? MenuKey(key: "f", modifiers: [.command, .option]) : nil }
        }
        let registry = try Registry(plugins: [placed, keys])
        let bar = registry.menuBarCommands.filter { $0.menu.titles[0] != "View" }
        expectEqual(bar.map(\.command), ["tidy", "seek"], "the core's zooms aside; a command with no menu has no item")
        expectEqual(bar.map(\.title), ["Tidy", "Seek…"])
        expectEqual(bar.map(\.menu.titles), [["Arrange"], ["Edit", "Find"]])
        expectEqual(bar.map(\.order), [100, 200])
        expectEqual(bar.map(\.key), [nil, MenuKey(key: "f", modifiers: [.command, .option])])
        expectEqual(registry.menuKey(of: "seek")?.modifierFlags, [.command, .option])
        expectEqual(try Registry(plugins: [placed]).menuKey(of: "seek"), nil, "no slot, no key")
        expectEqual(try Registry(plugins: []).menuBarCommands.map(\.title), ["Zoom In", "Zoom Out", "Actual Size", "Zoom to Fit"], "the core's own, in View")
        expectThrows(RegistryError.conflict(point: "MenuKeys", key: "menu keys", plugins: ["keys", "more"])) {
            _ = try Registry(plugins: [keys, Contributor(id: "more") { $0.menuKeys { _, _ in nil } }])
        }
        let report = registry.report
        expect(report.contains("command tidy in Arrange · command seek in Edit › Find · command hidden"), report)
        expect(report.contains("keys          menu keys"), report)
    },
    test("a menu path is a menu and the submenus under it, written as a path is") {
        let path: MenuPath = "Edit › Find"
        expectEqual(path.titles, ["Edit", "Find"])
        expectEqual(path.description, "Edit › Find")
        expectEqual(MenuPath(["Arrange"]).titles, ["Arrange"])
    },
])
