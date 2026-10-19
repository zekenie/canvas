import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Colors
import Mentions
import Palette
import Selection
import StickyNotes
import TestKit

// Edit › Copy as Image (⇧⌘C) in the app's window, over the nested file, on a pasteboard of the test's
// own: a PNG of the selection, or of the board shown, drawn as the canvas draws it.

/// The PNG on a pasteboard, if there is one.
@MainActor private func picture(on pasteboard: NSPasteboard) -> NSBitmapImageRep? {
    pasteboard.data(forType: .png).flatMap { NSBitmapImageRep(data: $0) }
}

/// The Edit menu's Copy as Image, pointed at the window's controller.
@MainActor private func copyAsImageItem(_ w: NestedWindow) throws -> NSMenuItem {
    let edit = try require(BoardMenus.make(appName: "Infinite Canvas", registry: w.editor.registry).main.item(withTitle: "Edit")?.submenu)
    let item = try require(edit.item(withTitle: "Copy as Image"))
    item.target = w.controller
    return item
}

/// The brightness of the pixel at the top left, 0 for black to 1 for white.
@MainActor private func cornerBrightness(_ picture: NSBitmapImageRep) throws -> CGFloat {
    try require(picture.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB)).brightnessComponent
}

@MainActor let copyAsImageShippedTests = Suite("Copy as Image, shipped", [
    test("it puts a PNG of the selection on the pasteboard, two pixels to a point: a note's 200 points and a margin") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let w = try NestedWindow(pasteboard: pasteboard)
        w.editor.selection = w.nest.notes(on: 1).0
        w.controller.copyAsImage(nil)
        let image = try require(picture(on: pasteboard), "a PNG")
        // The note, 200 points at 100%, and a margin of 32 in all (`ImageCopyStyle.inset`), at 2×.
        expectEqual([image.pixelsWide, image.pixelsHigh], [464, 464])
        expectEqual([image.size.width, image.size.height], [232, 232], "and says so by its resolution")
        expectEqual(pasteboard.types?.contains(.png), true)
    },
    test("a note in a color of the file's own is drawn in it: the picture is of the board's own file, not of a copy that lacks the file's colors") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let w = try NestedWindow(pasteboard: pasteboard)
        defer { w.board.close() }
        let note = w.nest.notes(on: 1).0
        expect(w.editor.defineColor(named: "Grass", value: RGB(hex: 0x22AA22)))
        w.editor.setColor(.named("Grass"), of: [note])
        w.editor.selection = note
        w.controller.copyAsImage(nil)
        let image = try require(picture(on: pasteboard))
        let middle = try require(image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        expect(middle.greenComponent - middle.redComponent > 0.06, "green paper, not a note's yellow: \(middle)")
    },
    test("with nothing selected it's the whole board shown: both notes, the arrow and the subboard's card") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let w = try NestedWindow(pasteboard: pasteboard)
        expectEqual(w.editor.selectedShapeIDs, [])
        w.controller.copyAsImage(nil)
        let image = try require(picture(on: pasteboard))
        // From (80, 80) to (660, 580): 580 × 500 points, and the margin.
        expectEqual([image.pixelsWide, image.pixelsHigh], [1224, 1064])
        // Another board is its own picture: S's, inside the subboard.
        pasteboard.clearContents()
        expect(w.editor.showBoard(w.nest.sBoard))
        w.controller.copyAsImage(nil)
        expect(picture(on: pasteboard) != nil)
    },
    test("it's drawn in the window's appearance, and replaces what was on the pasteboard") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let w = try NestedWindow(pasteboard: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)
        w.window.appearance = NSAppearance(named: .aqua)
        w.controller.copyAsImage(nil)
        let light = try require(picture(on: pasteboard))
        expectEqual(pasteboard.string(forType: .string), nil, "the pasteboard is the picture's alone")
        w.window.appearance = NSAppearance(named: .darkAqua)
        w.controller.copyAsImage(nil)
        let dark = try require(picture(on: pasteboard))
        let (bright, dim) = (try cornerBrightness(light), try cornerBrightness(dark))
        expect(bright > 0.8 && dim < 0.3, "the canvas's light ground, \(bright), and its dark one, \(dim)")
    },
    test("the item is dimmed with nothing to draw (an empty board), and on again once there's a shape; the window does nothing then") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = BoardDocument()
        defer { board.close() }
        board.makeWindowControllers()
        let controller = try require(board.windowControllers.first as? BoardWindowController)
        let edit = try require(BoardMenus.make(appName: "Infinite Canvas", registry: board.editor.registry).main.item(withTitle: "Edit")?.submenu)
        let item = try require(edit.item(withTitle: "Copy as Image"))
        expectEqual(KeyboardShortcutSection.key(of: item), "⇧⌘C")
        expect(!controller.validateMenuItem(item))
        controller.copyAsImage(nil)
        expectEqual(pasteboard.data(forType: .png), nil)
        _ = board.editor.add(StickyNote(frame: CGRect(x: 0, y: 0, width: 100, height: 100), text: MentionText(plain: "")))
        expect(controller.validateMenuItem(item))
    },
    test("the item follows the selection: on for a note, and for the board with nothing selected") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let w = try NestedWindow(pasteboard: pasteboard)
        let item = try copyAsImageItem(w)
        expect(w.controller.validateMenuItem(item))
        w.editor.selection = w.nest.notes(on: 1).0
        expect(w.controller.validateMenuItem(item))
    },
])
