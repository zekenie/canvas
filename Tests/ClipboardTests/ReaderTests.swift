import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Clipboard
import CoreGraphics
import Draw
import Geometry
import Keyboard
import Selection
import TestKit

// Readers that give a draw program (`registrar.pasteReader(_, role:, sniff:, read:)`): what ⌘V, ⇧⌘V, the context menu's Paste and
// ⌥⇧⌘V (Paste as Note) do with them, with fixture readers over CanvasTesting's tiles and a private pasteboard. Draw's `put`
// has its own tests (AutomationTests' drawPutTests).

/// What the fixture readers were asked.
@MainActor private final class Reads {
    var recognizing = 0
    var plain = 0
    var texts: [String] = []
}

private func tiles(_ count: Int, finish: String? = nil, kind: String = "tile") -> DrawPut {
    DrawPut(rows: [(0..<count).map { _ in DrawPut.Shape(kind: kind, values: finish.map { [(key: "finish", text: $0)] } ?? []) }])
}

/// A recognizing reader of "tiles N" (N matte tiles in a row), named "tiles"; and a plain reader of any text, one glossy tile,
/// named "plain".
@MainActor private func readers(_ reads: Reads, id: PluginID = "readers", kind: (any Kit.Type)? = nil) -> Contributor {
    Contributor(id: id) { r in
        if let kind { r.join(kind) }
        r.pasteReader("tiles", sniff: { $0.text?.hasPrefix("tiles ") == true }) { content, _ in
            reads.recognizing += 1
            reads.texts.append(content.text ?? "")
            guard let text = content.text, let count = Int(text.dropFirst("tiles ".count)), count > 0 else { return nil }
            return tiles(count)
        }
        r.pasteReader("plain", role: .plain, sniff: { $0.plainText != nil }) { content, _ in
            reads.plain += 1
            return content.plainText.map { _ in tiles(1, finish: "glossy") }
        }
    }
}

@MainActor private func putHarness(_ pasteboard: NSPasteboard, _ reads: Reads, _ more: [any CanvasPlugin] = []) throws -> EditorHarness {
    let h = try harness(pasteboard, [DrawPlugin(), TilesPlugin(), readers(reads)] + more)
    h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
    return h
}

extension EditorHarness {
    /// ⌥⇧⌘V on the canvas: whether a shortcut took it.
    @discardableResult
    func pasteAsNoteKey() -> Bool {
        hold([.option, .shift, .command])
        defer { hold([]) }
        return key("v")
    }
}

@MainActor private func tilesOnBoard(_ editor: CanvasEditor) -> [AnyShapeRecord] { editor.document.shapes.filter { $0.kind == Tile.kind } }

@MainActor let readerTests = Suite("Paste readers that give a draw program", [
    test("⌘V reads this app's shapes first, then the first recognizing reader on whose read gives something, in plugin order; else nothing") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let before = Reads(), reads = Reads()
        let h = try harness(pasteboard, [DrawPlugin(), TilesPlugin(),
                                         Contributor(id: "first") { r in
                                             // Sniffs it, reads it as none of its own: the reader after it is asked.
                                             r.pasteReader("first", sniff: { $0.text != nil }) { content, _ in
                                                 before.texts.append(content.text ?? "")
                                                 return nil
                                             }
                                         }, readers(reads)])
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        pasteboard.setString("tiles 2", forType: .string)
        expect(h.editor.canPaste, "a recognizing reader sniffs it")
        expect(h.command("v"))
        expectEqual(tilesOnBoard(h.editor).count, 2, "the second reader's")
        expectEqual(before.texts, ["tiles 2"], "the first was asked, and gave nothing")
        pasteboard.clearContents()
        pasteboard.setString("tiles zero", forType: .string)
        expect(h.editor.canPaste, "sniffed: it looks like its own")
        pasteboard.clearContents()
        pasteboard.setString("some prose", forType: .string)
        expect(h.editor.canPaste == true, "the first reader sniffs any text")
        let box = h.add(Box(slot(5)))
        h.editor.selection = box
        h.editor.copySelection()
        let shapes = h.editor.document.shapes.count
        expect(h.command("v"))
        expectEqual(h.editor.document.shapes.count, shapes + 1)
        expectEqual(h.editor.shapes(since: h.editor.document).count, 0)
        expect(h.editor.document.shapes.last?.copiedFrom == box, "this app's shape, not a reader's, though text is a reader's too")
        expectEqual(reads.recognizing, 1, "the reader after was not asked about the copy")
    },
    test("text no recognizing reader sniffs leaves Paste dimmed and ⌘V alone; each pasteboard change is read once") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let reads = Reads()
        let h = try putHarness(pasteboard, reads)
        pasteboard.setString("hello", forType: .string)
        expect(!h.editor.canPaste && !h.editor.canPerform(.paste))
        expect(!h.command("v"), "⌘V isn't taken")
        expectEqual(tilesOnBoard(h.editor).count, 0)
        pasteboard.clearContents()
        pasteboard.setString("tiles 1", forType: .string)
        expect(h.editor.canPaste)
        h.editor.paste()
        h.editor.paste()
        expect(h.editor.canPaste)
        expectEqual(reads.recognizing, 1, "read once for the change, however many times it's asked")
        expectEqual(tilesOnBoard(h.editor).count, 2, "pasted twice from the one read")
        pasteboard.clearContents()
        pasteboard.setString("tiles 3", forType: .string)
        h.editor.paste()
        expectEqual(reads.recognizing, 2, "a change is read again")
    },
    test("a paste lands beside the selection, selected, announced, in one step called Paste and the reader's name; the context menu's centers on its click and ⇧⌘V on the pointer") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try putHarness(pasteboard, Reads())
        let anchor = h.add(Tile(CGRect(x: 100, y: 100, width: 120, height: 80)))
        h.editor.selection = anchor
        pasteboard.setString("tiles 2", forType: .string)
        let before = h.editor.document
        expect(h.command("v"))
        let made = h.editor.shapes(since: before)
        expectEqual(made.count, 2)
        let first = try require(made.first?.box), second = try require(made.last?.box)
        expectEqual(first.minX, 220 + 80, "draw's normal gap from the anchor")
        expectEqual(first.midY, 140, "centered on it")
        expectEqual(second.minX, first.maxX + 80, "a row at the normal gap")
        expectEqual(second.minY, first.minY)
        expectEqual(Set(h.editor.selectedShapeIDs), Set(made.map(\.id)))
        expectEqual(h.editor.undoHistory.undoName, "Paste tiles")
        expect(h.editor.announcements.contains("Pasted 2 Tiles"), "\(h.editor.announcements)")
        h.editor.undo()
        expectEqual(h.editor.document, before, "one step takes it all")

        h.editor.paste(centeredAt: CGPoint(x: 600, y: 400))
        let clicked = h.editor.shapes(since: before)
        expectEqual(h.editor.shapeContext.bounds(of: clicked.map(\.id))?.center, CGPoint(x: 600, y: 400), "the middle of the block on the click")

        h.editor.undo()
        h.move(to: CGPoint(x: 300, y: 450))
        expect(h.pasteAtPointerKey())
        let pointed = h.editor.shapes(since: before)
        expectEqual(pointed.count, 2)
        expectEqual(h.editor.shapeContext.bounds(of: pointed.map(\.id))?.center, CGPoint(x: 300, y: 450), "the middle of the block on the pointer")
    },
    test("⌥⇧⌘V asks only the plain readers: Paste as Note, in one step with that name, beside the selection; ⌘V of the same text asks none of them") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let reads = Reads()
        let h = try putHarness(pasteboard, reads)
        let anchor = h.add(Tile(CGRect(x: 100, y: 100, width: 120, height: 80)))
        h.editor.selection = anchor
        pasteboard.setString("some prose", forType: .string)
        expect(!h.editor.canPaste, "no recognizing reader sniffs prose")
        expect(h.editor.canPasteAsNote && h.editor.canPerform(.pasteAsNote))
        let before = h.editor.document
        expect(h.pasteAsNoteKey())
        let made = try require(h.editor.shapes(since: before).first)
        expectEqual(made.typed(as: Tile.self)?.props.finish, .glossy, "the plain reader's")
        expectEqual(made.box?.minX, 220 + 80)
        expectEqual(h.editor.selectedShapeIDs, [made.id])
        expectEqual(h.editor.undoHistory.undoName, "Paste as Note")
        expectEqual(reads.recognizing, 0, "no recognizing reader was asked")
        pasteboard.clearContents()
        pasteboard.setString("tiles 1", forType: .string)
        expect(h.editor.canPaste)
        h.editor.paste()
        expectEqual(reads.plain, 1, "⌘V asked no plain reader")
        expectEqual(h.editor.undoHistory.undoName, "Paste tiles")
        pasteboard.clearContents()
        expect(!h.editor.canPasteAsNote && !h.editor.canPerform(.pasteAsNote), "an empty pasteboard")
        let steps = h.editor.undoHistory.undoName
        expect(!h.pasteAsNoteKey())
        expectEqual(h.editor.undoHistory.undoName, steps)
    },
    test("files come before text: a file's name is not its pasteboard text, and a reader is handed the file") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let reads = Reads(), seen = Reads()
        let h = try harness(pasteboard, [DrawPlugin(), TilesPlugin(), Contributor(id: "files") { r in
            r.pasteReader("texts", sniff: { _ in true }) { content, _ in
                reads.texts.append(content.text ?? "(none)")
                return nil
            }
            r.pasteReader("files", role: .plain, sniff: { !$0.files.isEmpty }) { content, _ in
                seen.texts.append(contentsOf: content.files.compactMap(\.text))
                seen.recognizing += content.files.count
                return content.files.first?.text.map { _ in tiles(1) }
            }
        }])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("paste-readers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("tiles.txt")
        try "tiles 4".write(to: file, atomically: true, encoding: .utf8)
        pasteboard.writeObjects([file as NSURL])
        pasteboard.setString("tiles.txt", forType: .string)
        expect(h.editor.canPaste, "the text reader sniffs")
        h.editor.paste()
        expectEqual(reads.texts, ["(none)"], "a text reader is handed no text where there are files: the file's name is not it")
        expect(h.editor.canPasteAsNote)
        h.editor.pasteAsNote()
        expectEqual(seen.texts, ["tiles 4"], "the file, with its small text")
        expectEqual(tilesOnBoard(h.editor).count, 1)
    },
    test("a put that is refused leaves no step and changes nothing; a board that takes no shapes takes no paste of either kind") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard, [DrawPlugin(), TilesPlugin(), PocketsPlugin(), FreezingPlugin(),
                                         Contributor(id: "bad") { r in
                                             r.pasteReader("bad", sniff: { $0.text == "bad" }) { _, _ in tiles(1, kind: "nonesuch") }
                                             r.pasteReader("note", role: .plain, sniff: { $0.plainText != nil }) { _, _ in tiles(1) }
                                         }])
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        let anchor = h.add(Tile(CGRect(x: 0, y: 0, width: 120, height: 80)))
        h.editor.selection = anchor
        pasteboard.setString("bad", forType: .string)
        let before = h.file, step = h.editor.undoHistory.undoName
        h.editor.paste()
        expectEqual(h.file, before, "a kind nothing draws: nothing changed")
        expectEqual(h.editor.undoHistory.undoName, step, "and no step")
        expectEqual(h.editor.selectedShapeIDs, [anchor], "the selection stays")
        pasteboard.clearContents()
        pasteboard.setString("words", forType: .string)
        let pocket = h.add(Pocket(CGRect(x: 400, y: 0, width: 100, height: 100)))
        h.editor.freeze([pocket], true)
        expect(h.editor.canPasteAsNote, "on the root, it reads")
        expect(h.enter(pocket))
        let frozen = h.file, frozenStep = h.editor.undoHistory.undoName
        expect(!h.editor.canPasteAsNote && !h.editor.canPerform(.pasteAsNote), "Paste as Note is off there")
        pasteboard.clearContents()
        pasteboard.setString("bad", forType: .string)
        expect(!h.editor.canPaste)
        expect(!h.pasteAsNoteKey())
        h.editor.pasteAsNote()
        h.editor.paste()
        expectEqual(h.file, frozen)
        expectEqual(h.editor.undoHistory.undoName, frozenStep, "no step")
    },
    test("a put beside a shape in a locked frame is refused as a shape paste is: nothing changes, no step, and the shape shakes") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let reads = Reads(), log = RefusalLog()
        let h = try putHarness(pasteboard, reads, [CorralsPlugin(), FreezingPlugin(log: log)])
        let pen = h.add(Corral(CGRect(x: 0, y: 0, width: 400, height: 300)))
        let tile = h.add(Tile(CGRect(x: 40, y: 40, width: 120, height: 80)))
        h.editor.transact { $0.setContainer([tile], to: pen) }
        h.editor.freeze([pen])
        h.editor.selection = tile
        pasteboard.setString("tiles 2", forType: .string)
        let before = h.file, step = h.editor.undoHistory.undoName
        h.editor.paste()
        expectEqual(h.file, before, "nothing put down")
        expectEqual(h.editor.undoHistory.undoName, step, "no step")
        expectEqual(log.refusals, [[tile]], "the shape it was beside shakes")
        expectEqual(h.editor.selectedShapeIDs, [tile])
    },
    test("a reader whose plugin's kit is off is never asked, and a plain one is no exception; on, it reads") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let reads = Reads()
        let h = try harness(pasteboard, [DrawPlugin(), TilesPlugin(), readers(reads, id: "workshop-readers", kind: Workshop.self)])
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        pasteboard.setString("tiles 2", forType: .string)
        expect(!h.editor.canPaste && !h.editor.canPasteAsNote)
        h.editor.paste()
        h.editor.pasteAsNote()
        expectEqual(reads.recognizing + reads.plain, 0, "never asked")
        h.editor.turn(Workshop.self, on: true)
        expect(h.editor.canPaste && h.editor.canPasteAsNote)
        h.editor.paste()
        expectEqual(tilesOnBoard(h.editor).count, 2)
    },
    test("Edit › Paste as Note sits after Paste at Pointer, before Duplicate, with ⌥⇧⌘V; the report names each reader") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try putHarness(pasteboard, Reads())
        let registry = h.editor.registry
        expect(registry.report.contains("paste reader tiles") && registry.report.contains("paste reader plain"), registry.report)
        for line in ["command pasteAsNote after pasteAtPointer in EditMenu.CutCopyPaste", "shortcut ⌥⇧⌘V → command pasteAsNote",
                     "command duplicate after pasteAsNote in EditMenu.CutCopyPaste"] {
            expect(registry.report.contains(line), line)
        }
    },
])
