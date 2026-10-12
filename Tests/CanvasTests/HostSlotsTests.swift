import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import SwiftUI
import TestKit

// The host's slots, with contributors of the tests' own: what a plugin says, and what the host
// reads back. No window here: CanvasUITests place them (`BoardChrome`, the tool picker, Settings,
// the command server's commands).

/// What a view was handed as it was made, and what a test's contributors note and are told.
@MainActor private final class Handed {
    var editor: CanvasEditor?
    var onExit: (@MainActor () -> Void)?
    var wanted = false
    var dismissed = 0
    var exits = 0
    var made: [String] = []
    func note(_ editor: CanvasEditor, _ onExit: @escaping @MainActor () -> Void) {
        self.editor = editor
        self.onExit = onExit
    }
}

/// The line the registry's report gives a plugin, less its id.
@MainActor private func report(_ registry: Registry, of plugin: String) -> String? {
    registry.report.split(separator: "\n").first { $0.hasPrefix(plugin + " ") }.map { String($0.dropFirst(plugin.count)).trimmingCharacters(in: .whitespaces) }
}

@MainActor let hostSlotsTests = Suite("Host slots", [
    test("views over the canvas come in plugin order, each with where it sits and what it covers; the most covered is what a fit leaves clear") {
        let top = Contributor(id: "top") { $0.hostOverlay(alignment: .top, coveredTop: { $0.isRoot ? 0 : 35 }) { _, _ in Text("top") } }
        let middle = Contributor(id: "middle") { $0.hostOverlay { _, _ in Text("middle") } }
        let low = Contributor(id: "low") { $0.hostOverlay(alignment: .top, coveredTop: { _ in 20 }) { _, _ in Text("low") } }
        let registry = try Registry(plugins: [top, middle, low])
        let inside = BoardID(owner: ShapeID())
        expectEqual(registry.hostOverlays.map(\.alignment), [.top, .center, .top])
        expectEqual(registry.hostOverlays.map { $0.coveredTop(inside) }, [35, 0, 20])
        expectEqual(registry.hostCoveredTop(on: inside), 35)
        expectEqual(registry.hostCoveredTop(on: .root), 20)
        expectEqual(report(registry, of: "middle"), "host overlay")
        let none = try Registry(plugins: [])
        expectEqual(none.hostOverlays.count, 0)
        expectEqual(none.hostCoveredTop(on: inside), 0, "nothing over the canvas covers nothing")
    },
    test("a view is made for a window's canvas: handed its editor, and the way to give the keyboard back") {
        let handed = Handed()
        let plugin = Contributor(id: "view") { registrar in
            registrar.hostOverlay { editor, onExit in
                let _ = handed.note(editor, onExit)
                Text("view")
            }
        }
        let registry = try Registry(plugins: [plugin])
        let editor = CanvasEditor(registry: registry, file: CanvasFile(), scheduler: ManualScheduler())
        expect(handed.editor == nil, "not made until the window asks")
        _ = try require(registry.hostOverlays.first).view(for: editor, onExit: { handed.exits += 1 })
        expect(handed.editor === editor)
        handed.onExit?()
        expectEqual(handed.exits, 1)
    },
    test("the inspector: none unless a plugin gives one, wanted only when it says, and a second is a conflict") {
        expect(try Registry(plugins: []).hostInspector == nil)
        let handed = Handed()
        let panel = Contributor(id: "panel") { registrar in
            registrar.hostInspector(isRequested: { _ in handed.wanted }, onDismiss: { _ in handed.dismissed += 1 }) { editor, onExit in
                let _ = handed.note(editor, onExit)
                Text("panel")
            }
        }
        let registry = try Registry(plugins: [panel])
        let editor = CanvasEditor(registry: registry, file: CanvasFile(), scheduler: ManualScheduler())
        let inspector = try require(registry.hostInspector)
        expect(!inspector.isRequested(editor))
        handed.wanted = true
        expect(inspector.isRequested(editor))
        inspector.onDismiss(editor)
        expectEqual(handed.dismissed, 1)
        _ = inspector.view(for: editor, onExit: {})
        expect(handed.editor === editor)
        expectEqual(report(registry, of: "panel"), "host inspector")
        let plain = Contributor(id: "plain") { $0.hostInspector { _, _ in Text("plain") } }
        let unasked = try require(try Registry(plugins: [plain]).hostInspector)
        expect(!unasked.isRequested(editor), "one that never says it's wanted is the person's to show")
        expectThrows(RegistryError.conflict(point: "HostInspectors", key: "inspector", plugins: ["panel", "plain"])) {
            _ = try Registry(plugins: [panel, plain])
        }
    },
    test("the window's subtitle is what one plugin says of the board shown, nil without one; a second is a conflict") {
        let bare = try Registry(plugins: [])
        let editor = CanvasEditor(registry: bare, file: CanvasFile(), scheduler: ManualScheduler())
        expectEqual(bare.windowSubtitle(for: editor), nil)
        let naming = Contributor(id: "naming") { $0.windowSubtitle { $0.board.isRoot ? nil : "Inside" } }
        let registry = try Registry(plugins: [PocketsPlugin(), naming])
        let pocket = ShapeRecord(Pocket(CGRect(x: 0, y: 0, width: 100, height: 60)))
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(pocket)]), children: [pocket.id: CanvasDocument()])
        let nested = CanvasEditor(registry: registry, file: file, scheduler: ManualScheduler())
        expectEqual(registry.windowSubtitle(for: nested), nil, "none on the root")
        expect(nested.showBoard(BoardID(owner: pocket.id)))
        expectEqual(registry.windowSubtitle(for: nested), "Inside")
        expectEqual(report(registry, of: "naming"), "window subtitle")
        let again = Contributor(id: "again") { $0.windowSubtitle { _ in "Again" } }
        expectThrows(RegistryError.conflict(point: "WindowSubtitles", key: "subtitle", plugins: ["naming", "again"])) {
            _ = try Registry(plugins: [naming, again])
        }
    },
    test("settings panes come in plugin order, each made when asked; a title once") {
        let handed = Handed()
        let keys = Contributor(id: "keys") { registrar in
            registrar.settingsPane("Keys") {
                let _ = handed.made.append("Keys")
                Text("keys")
            }
        }
        let looks = Contributor(id: "looks") { registrar in
            registrar.settingsPane("Looks") {
                let _ = handed.made.append("Looks")
                Text("looks")
            }
        }
        let registry = try Registry(plugins: [keys, looks])
        expectEqual(registry.settingsPanes.map(\.title), ["Keys", "Looks"])
        expectEqual(handed.made, [], "none made until the window opens")
        _ = registry.settingsPanes[1].view()
        expectEqual(handed.made, ["Looks"])
        expectEqual(report(registry, of: "keys"), "settings pane Keys")
        expectEqual(try Registry(plugins: []).settingsPanes.count, 0)
        let twice = Contributor(id: "twice") { $0.settingsPane("Keys") { Text("again") } }
        expectThrows(RegistryError.conflict(point: "SettingsPanes", key: "Keys", plugins: ["keys", "twice"])) {
            _ = try Registry(plugins: [keys, twice])
        }
    },
    test("a tool's tip is what one plugin says of it, else its label; a second is a conflict") {
        let tiles = try Registry(plugins: [TilesPlugin()])
        let tool = try require(tiles.tools.first { $0.id == ToolID(placing: Tile.kind) })
        expectEqual(tiles.toolTip(for: tool), tool.label)
        let tips = Contributor(id: "tips") { $0.toolTips { tool, registry in "\(tool.label), one of \(registry.tools.count)" } }
        let registry = try Registry(plugins: [TilesPlugin(), tips])
        expectEqual(registry.toolTip(for: tool), "\(tool.label), one of \(registry.tools.count)")
        expectEqual(report(registry, of: "tips"), "tool tips")
        let again = Contributor(id: "again") { $0.toolTips { tool, _ in tool.label } }
        expectThrows(RegistryError.conflict(point: "ToolTips", key: "tool tips", plugins: ["tips", "again"])) {
            _ = try Registry(plugins: [tips, again])
        }
    },
    test("the commands the app's server runs are one plugin's, read off the built registry: none without one, and a second is a conflict") {
        let none = try Registry(plugins: []).hostCommands
        expectEqual(none.specs, [])
        do {
            _ = try awaitResult { try await none.run("count", [:], nil) }
            expect(false, "a command nobody gives is unknown")
        } catch let error as RPCError {
            expectEqual(error.code, RPCError.methodNotFound)
            expectEqual(error.reason, "unknown_command")
        }
        let handed = Handed()
        let line = Contributor(id: "line") { registrar in
            registrar.hostCommands(specs: { registry in
                [CommandSpec(name: "count", summary: "Counts \(registry.tools.count) tools.", scope: .app)]
            }) { _, name, params, editor async throws(RPCError) in
                handed.editor = editor
                return ["name": .string(name), "asked": params]
            }
        }
        let registry = try Registry(plugins: [TilesPlugin(), line])
        let commands = registry.hostCommands
        expectEqual(commands.specs.map(\.name), ["count"])
        expectEqual(commands.specs.first?.summary, "Counts \(registry.tools.count) tools.", "its specs are read off the built registry")
        let editor = CanvasEditor(registry: registry, file: CanvasFile(), scheduler: ManualScheduler())
        let answer = try awaitResult { try await commands.run("count", ["n": 2], editor) }
        expectEqual(answer, ["name": "count", "asked": ["n": 2]])
        expect(handed.editor === editor, "run on the board's editor it's handed")
        expectEqual(report(registry, of: "line"), "host commands")
        let again = Contributor(id: "again") { $0.hostCommands(specs: { _ in [] }) { _, _, _, _ async throws(RPCError) in .null } }
        expectThrows(RegistryError.conflict(point: "HostCommands", key: "commands", plugins: ["line", "again"])) {
            _ = try Registry(plugins: [line, again])
        }
    },
])
