import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Clipboard
import ContextMenus
import Keyboard
import Selection
import SlashCommands
import Stickers
import TestKit

// Stickers, the example kit: off in a new file, its four tools, their Insert items, `/sticker`, Change Sticker ▸
// and its paste reader gone; turned on, back, in one step; and a sticker drawn while it was on staying drawn,
// resized and deleted while it's off.

private let tools: [ToolID] = [ToolID(placing: Sticker.kind), "emoji-sticker-heart", "emoji-sticker-star", "emoji-sticker-party"]

/// An editor with the kit's plugin, the plugins whose points it fills, and a pasteboard of the test's own.
@MainActor private func stickers(_ pasteboard: NSPasteboard) throws -> EditorHarness {
    let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), SlashCommandsPlugin(),
                                        ClipboardPlugin(pasteboard: pasteboard), StickersPlugin()])
    h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
    return h
}

/// The names `/` lists for the stickers selected, in the command bar.
@MainActor private func commands(_ h: EditorHarness, _ ids: [ShapeID]) -> [String] {
    h.editor.slashCommands?.commands(for: .selection(ids)).map(\.name) ?? []
}

@MainActor private func emoji(_ h: EditorHarness) -> [String] {
    h.editor.document.shapes.compactMap { $0.typed(as: Sticker.self)?.props.emoji }
}

@MainActor let stickersTests = Suite("Stickers", [
    test("the kit is Stickers; every way in it gives is its own, its sticker is the registry's") {
        let registry = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), SlashCommandsPlugin(),
                                              ClipboardPlugin(pasteboard: NSPasteboard.withUniqueName()), StickersPlugin()])
        expectEqual(registry.kits.map(\.id), [StickersKit.id])
        expectEqual(registry.kits.map(\.title), ["Stickers"])
        expectEqual(registry.kit(of: .stickers), StickersKit.id)
        expectEqual(tools.map { registry.kit(ofTool: $0) }, Array(repeating: StickersKit.id, count: 4))
        expectEqual(registry.tools.filter { registry.kit(ofTool: $0.id) != nil }.map(\.label), ["Thumbs Up", "Heart", "Star", "Party"])
        expectEqual(registry.menuBarCommands.filter { tools.map(CanvasCommand.insert).contains($0.command) }.map(\.menu.description),
                    Array(repeating: "Insert › Stickers", count: 4), "Insert ▸ Stickers")
        expectEqual(registry.label(of: Sticker.kind).name, "Sticker")
        expect(registry.report.contains("paste reader emoji"))
    },
    test("off in a new file: no tool, no Insert item, no /sticker, no Change Sticker ▸, and emoji pasted is nothing") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = try stickers(pasteboard)
        expect(!h.editor.isOn(StickersKit.self))
        for tool in tools {
            expect(!h.editor.isToolEnabled(tool), "\(tool)")
            expect(!h.editor.claims(.insert(tool)), "Insert's \(tool)")
        }
        let sticker = h.add(Sticker(frame: CGRect(x: 0, y: 0, width: 96, height: 96), emoji: "🎉"))
        h.editor.selectedShapeIDs = [sticker]
        expect(!commands(h, [sticker]).contains("sticker"), "/sticker isn't listed")
        let menu = try require(h.secondaryClick(at: CGPoint(x: 48, y: 48)))
        expect(!menu.outline.contains("Change Sticker ▸"), "\(menu.outline)")
        pasteboard.clearContents()
        pasteboard.setString("🎉", forType: .string)
        expect(!h.editor.canPaste, "⌘V reads no emoji through the kit's reader")
    },
    test("Turn On Stickers is one step: the tools, Insert, /sticker, Change Sticker ▸ and the reader come; undone, they go") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = try stickers(pasteboard)
        let sticker = h.add(Sticker(frame: CGRect(x: 0, y: 0, width: 96, height: 96), emoji: "🎉"))
        expect(h.editor.perform(.kit(StickersKit.id)))
        expectEqual(h.editor.undoHistory.undoName, "Turn On Stickers")
        expect(tools.allSatisfy(h.editor.isToolEnabled))
        expect(tools.allSatisfy { h.editor.claims(.insert($0)) })
        h.editor.selectedShapeIDs = [sticker]
        expect(commands(h, [sticker]).contains("sticker"))
        expect(try require(h.secondaryClick(at: CGPoint(x: 48, y: 48))).outline.contains("Change Sticker ▸"))
        pasteboard.clearContents()
        pasteboard.setString("🎉", forType: .string)
        expect(h.editor.canPaste)
        h.editor.undo()
        expect(!h.editor.isOn(StickersKit.self))
        expect(!tools.contains(where: h.editor.isToolEnabled))
        expect(!commands(h, [sticker]).contains("sticker"))
        expect(!h.editor.canPaste)
    },
    test("Insert ▸ Stickers ▸ Party puts a party sticker down in the middle of the view, one step") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = try stickers(pasteboard)
        h.editor.turn(StickersKit.self, on: true)
        expect(h.editor.perform(.insert("emoji-sticker-party")))
        expectEqual(emoji(h), ["🎉"])
        expectEqual(h.editor.document.shapes.first?.box?.size, CGSize(width: 96, height: 96))
        expectEqual(h.editor.undoHistory.undoName, "Add Party")
    },
    test("/sticker on two stickers: the four rows, an emoji typed a row of its own, a word none; a pick changes both, one Change Sticker step") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = try stickers(pasteboard)
        h.editor.turn(StickersKit.self, on: true)
        let a = h.add(Sticker(frame: CGRect(x: 0, y: 0, width: 96, height: 96), emoji: "👍"))
        let b = h.add(Sticker(frame: CGRect(x: 200, y: 0, width: 96, height: 96), emoji: "⭐"))
        let command = try require(h.editor.slashCommands?.commands(for: .selection([a, b])).first { $0.name == "sticker" })
        expectEqual(command.choices().map(\.title), ["Thumbs Up", "Heart", "Star", "Party"])
        expectEqual(command.choice(otherwise: "🦊")?.id, "🦊")
        expectEqual(command.choice(otherwise: "fox")?.id, nil)
        expect(h.editor.slashCommands?.run(command, choosing: try require(command.choice(otherwise: "🦊"))) == true)
        expectEqual(emoji(h), ["🦊", "🦊"])
        expectEqual(h.editor.undoHistory.undoName, "Change Sticker")
    },
    test("Change Sticker ▸ in a sticker's menu lists the four, its own checked; a pick is one Change Sticker step") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = try stickers(pasteboard)
        h.editor.turn(StickersKit.self, on: true)
        _ = h.add(Sticker(frame: CGRect(x: 0, y: 0, width: 96, height: 96), emoji: "❤️"))
        let menu = try require(h.secondaryClick(at: CGPoint(x: 48, y: 48)))
        let changing = menu.outline.drop { $0 != "Change Sticker ▸" }.prefix(5)
        expectEqual(Array(changing), ["Change Sticker ▸", "  Thumbs Up", "  ✓ Heart", "  Star", "  Party"])
        try menu.choose("Change Sticker", "Star")
        expectEqual(emoji(h), ["⭐"])
        expectEqual(h.editor.undoHistory.undoName, "Change Sticker")
    },
    test("pasted text that is nothing but emoji is a sticker each, in a row, selected, one Paste step; any other text, or more than twelve, nothing") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = try stickers(pasteboard)
        h.editor.turn(StickersKit.self, on: true)
        pasteboard.clearContents()
        pasteboard.setString("👍 ❤️\n⭐", forType: .string)
        h.editor.paste()
        expectEqual(emoji(h), ["👍", "❤️", "⭐"])
        let boxes = h.editor.document.shapes.compactMap(\.box)
        expectEqual(boxes.map(\.minY), [boxes[0].minY, boxes[0].minY, boxes[0].minY], "in a row")
        expectEqual(boxes.map(\.minX), [boxes[0].minX, boxes[0].minX + 112, boxes[0].minX + 224], "96 wide and 16 apart")
        expectEqual(Set(h.editor.selectedShapeIDs), Set(h.editor.document.shapes.map(\.id)), "selected")
        expectEqual(h.editor.undoHistory.undoName, "Paste")
        expect(h.editor.document.shapes.allSatisfy { $0.copiedFrom == nil }, "new shapes, not copies")
        for text in ["fox", "🦊 fox", "1", String(repeating: "🦊", count: 13)] {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            expect(!h.editor.canPaste, "\(text) reads as no stickers")
        }
    },
    test("a sticker drawn while the kit was on stays while it's off: drawn, selected, resized and deleted as any shape") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = try stickers(pasteboard)
        h.editor.turn(StickersKit.self, on: true)
        h.editor.perform(.insert(tools[0]))
        let sticker = try require(h.editor.document.shapes.first?.id)
        h.editor.turn(StickersKit.self, on: false)
        expectEqual(emoji(h), ["👍"], "still there")
        h.editor.selectedShapeIDs = [sticker]
        expect(h.key(Chord(Key.right, .option)), "⌥→ resizes it")
        expectEqual(h.editor.document[sticker]?.box?.width, 97)
        expect(h.editor.perform(.delete))
        expectEqual(h.editor.document.shapes.count, 0, "deleted")
    },
])
