import Boards
import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import DetailPanel
import Keyboard
import Mentions
import Selection
import Subboards
import SwiftUI
import TableOfContents
import TestKit
import Titles

@MainActor let subboardTests = Suite("Subboards", [
    test("B and a press place a 240 × 160 subboard that follows the pointer, selected, as one step") {
        let h = try EditorHarness(plugins: subboardPlugins())
        expect(h.key("b"))
        expectEqual(h.editor.currentToolID, ToolID(placing: Subboard.kind))
        h.press(at: CGPoint(x: 300, y: 200))
        h.drag(to: CGPoint(x: 310, y: 205))
        h.release()
        let sub = try require(h.editor.document.shapes.first)
        expectEqual(sub.kind, Subboard.kind)
        expectEqual(sub.box, CGRect(x: 190, y: 125, width: 240, height: 160))
        expectEqual(h.editor.selection, sub.id)
        expectEqual(h.editor.currentToolID, .select)
        expectEqual(h.editor.file.children.count, 0, "an empty board isn't kept")
        let tool = try require(h.editor.registry.tools.first { $0.id == ToolID(placing: Subboard.kind) })
        expectEqual(tool.label, "Subboard")
        expectEqual(tool.systemImage, "rectangle.stack")

        expectEqual(h.editor.undoHistory.undoName, "Add Subboard")
        h.editor.undo()
        expect(h.editor.document.shapes.isEmpty)
        expect(!h.editor.canUndo, "placing and following the pointer were one step")
    },
    test("its schema is its frame and its description, the title Titles adds and the color Colors adds, and says its shapes own boards") {
        let registry = try Registry(plugins: subboardPlugins())
        let schema = try require(registry.schema(for: Subboard.kind)).json
        expectEqual(schema["x-canvas-board"], true)
        expectEqual(schema["title"]?.stringValue, "Subboard")
        expectEqual(Set(schema["properties"]?.objectValue?.keys.map { $0 } ?? []), ["frame", "description", "title", "color"])
        expectEqual(schema["required"], ["frame"])
        expectEqual(schema["properties"]?["title"]?["x-canvas-owner"]?.stringValue, "titles")
        expectEqual(Set(registry.properties(for: Subboard.kind).map(\.rawValue)), ["title", "color"])
    },
    // What a board writes of one at its version (CompositionTests hold the shipped kinds to their
    // fixtures, Fixtures/kinds/subboard.v1.json among them).
    test("its props write its frame and its description, empty until written") {
        let codec = BoardCodec(registry: try Registry(plugins: subboardPlugins()))
        let json = String(decoding: try codec.encodeProps(Subboard(frame: CGRect(origin: .zero, size: Subboard.defaultSize))), as: UTF8.self)
        expectEqual(json.filter { !$0.isWhitespace }, #"{"description":"","frame":[[0,0],[240,160]]}"#)
        expectEqual(codec.version(of: Subboard.kind), 1, "the description is its one migration")
    },
    test("its ports are on all four sides, on its own channel first and then on every channel another plugin declares, whichever is declared first") {
        let wires = Contributor(id: "wires") { $0.channel(Wire.self) }
        let before: [any CanvasPlugin] = [wires] + subboardPlugins(), after: [any CanvasPlugin] = subboardPlugins() + [wires]
        for plugins in [before, after] {
            let registry = try Registry(plugins: plugins)
            expectEqual(registry.portChannels(of: Subboard.kind), [SubboardLink.id, Wire.id])
            for side in PortSide.allCases {
                expectEqual(registry.dotChannels(of: Subboard.kind, side: side), [SubboardLink.id, Wire.id], "\(side)")
            }
            for channel in [SubboardLink.id, Wire.id] {
                expectEqual(registry.portSides(of: Subboard.kind, on: channel, as: .both), PortSide.allCases, "\(channel)")
            }
        }
    },
    test("its row is its symbol and \"Untitled Subboard\", named by its title once it has one") {
        let nest = Nest()
        let h = try nestHarness(nest)
        let contents = try require(h.editor.tableOfContents)
        var label = try require(contents.entries.first { $0.id == nest.s }?.label)
        expectEqual(label.text, "Untitled Subboard")
        expect(label.isPlaceholder)
        expectEqual(label.systemImage, "rectangle.stack")
        expectEqual(label.badge, nil, "a row reads only its shape: no count")

        h.editor.transact("Rename") { $0.update(nest.s) { $0[TitleProperty.self] = "Kitchen" } }
        label = try require(contents.entries.first { $0.id == nest.s }?.label)
        expectEqual(label.text, "Kitchen")
        expect(!label.isPlaceholder)
        expectEqual(label.systemImage, "rectangle.stack")
    },
    test("it's mentioned by its title, else \"Untitled Subboard\", with its symbol; following a mention enters it, one step back, from its board or another") {
        let nest = Nest()
        let h = try nestHarness(nest)
        let mentions = try require(h.editor.mentions)
        let looks = try require(mentions.resolve(nest.s).appearance)
        expectEqual(looks.label, "Untitled Subboard")
        expect(looks.isPlaceholder)
        expectEqual(looks.systemImage, "rectangle.stack")
        let tint = try require(looks.tint, "tinted in the @ picker")
        let row = try require(h.editor.tableOfContents?.entries.first { $0.id == nest.s }?.label)
        expectEqual(row.color, Color(nsColor: tint), "the card's indigo, in its row too, where the list's accent was")
        h.editor.transact("Rename") { $0.update(nest.s) { $0[TitleProperty.self] = "Kitchen" } }
        expectEqual(mentions.resolve(nest.s).appearance?.label, "Kitchen")

        h.editor.selection = nest.a
        mentions.follow(nest.s)
        h.wait(0)
        expectEqual(h.editor.board, nest.sBoard, "entered")
        h.editor.goBack()
        expectEqual(h.editor.board, .root, "one step back")
        expectEqual(h.editor.selectedShapeIDs, [nest.a], "to what was selected where it was followed from")

        // T, inside S, from the root: through S's board into T's, still one step.
        mentions.follow(nest.t)
        h.wait(0)
        expectEqual(h.editor.boardPath, [.root, nest.sBoard, nest.tBoard])
        h.editor.goBack()
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.selectedShapeIDs, [nest.a])
    },
    test("its panel's header is a TitleHeader with its placeholder and symbol, over its own tab, Description") {
        let nest = Nest()
        let h = try nestHarness(nest, title: "Kitchen")
        let layout = try require(h.editor.detailPanel?.layout(for: try require(h.editor.document[nest.s])))
        let header = try require(layout.header(as: TitleHeader.self))
        expectEqual(header.title, "Kitchen")
        expectEqual(header.placeholder, "Untitled Subboard")
        expectEqual(header.systemImage, "rectangle.stack")
        expectEqual(layout.tabs.map(\.title), ["Description"])
    },
    test("a double-click, Return and ⌘↓ enter it; ⌘↑ comes back with it selected") {
        let nest = Nest()
        let h = try nestHarness(nest)
        h.click(at: nest.sPoint)
        h.click(at: nest.sPoint, clickCount: 2)
        expectEqual(h.editor.board, nest.sBoard, "double-click")
        expectEqual(h.editor.document.shapes.count, 3)

        expect(h.command(KeyChord.upArrow.key))
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.selection, nest.s, "⌘↑ selects the subboard it came out of")

        expect(h.key("\r"))
        expectEqual(h.editor.board, nest.sBoard, "Return")
        h.editor.goToEnclosingBoard()
        expect(h.command(KeyChord.downArrow.key))
        expectEqual(h.editor.board, nest.sBoard, "⌘↓")

        h.editor.selection = nest.t
        expect(h.key("\r"))
        expectEqual(h.editor.boardPath, [.root, nest.sBoard, nest.tBoard], "a subboard inside a subboard")
        expect(h.command(KeyChord.upArrow.key))
        expectEqual(h.editor.board, nest.sBoard)
        expectEqual(h.editor.selection, nest.t)
    },
    test("Open is first in its menu, and opens it") {
        let nest = Nest()
        let h = try nestHarness(nest)
        let menu = try require(h.secondaryClick(at: nest.sPoint))
        expectEqual(menu.outline.first, "Open")
        try menu.choose("Open")
        expectEqual(h.editor.board, nest.sBoard)
    },
    test("deleting it takes its board and every board under it, as one step, and undoing it brings them back") {
        let nest = Nest()
        let h = try nestHarness(nest, title: "Kitchen")
        let before = h.editor.file
        h.editor.selection = nest.s
        expect(h.key("\u{7f}"))
        expectEqual(h.editor.document.shapes.map(\.id), [nest.a])
        expectEqual(h.editor.file.children.count, 0, "S's board and T's")
        expectEqual(h.editor.undoHistory.undoName, "Delete")

        h.editor.undo()
        expectEqual(h.editor.file, before)
        expectEqual(h.editor.selection, nest.s)
        expect(h.enter(nest.s))
        expect(h.enter(nest.t))
        expectEqual(h.editor.document[nest.b]?.kind, Box.kind)
    },
])
