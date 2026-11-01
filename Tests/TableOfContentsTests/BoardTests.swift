import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Selection
import SwiftUI
import TableOfContents
import TestKit

/// Widgets named `outside` and a pocket on the root, and widgets named `inside` on the pocket's
/// board.
@MainActor func pocketFile(outside: [String], inside: [String]) -> (file: CanvasFile, pocket: ShapeID) {
    let widget = { (i: Int, name: String) in AnyShapeRecord(ShapeRecord(Widget(CGRect(x: i * 150, y: 0, width: 100, height: 60), name: name))) }
    let pocket = ShapeRecord(Pocket(CGRect(x: 0, y: 200, width: 100, height: 60)))
    let file = CanvasFile(root: CanvasDocument(shapes: outside.enumerated().map(widget) + [AnyShapeRecord(pocket)]),
                          children: [pocket.id: CanvasDocument(shapes: inside.enumerated().map(widget))])
    return (file, pocket.id)
}

/// Opens a pocket by showing its board, as Subboards will.
@MainActor func openingPockets() -> Contributor {
    Contributor(id: "opening-pockets") { r in
        r.opens(Pocket.self, "Open") { pocket, editor in editor.showBoard(BoardID(owner: pocket.id)) }
    }
}

/// Goes up to the root, while there's a board above.
struct UpPlugin: CanvasPlugin {
    static let up: CanvasCommand = "test-up"
    var id: PluginID { "up" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.command(Self.up, title: "Up", isEnabled: { !$0.editor.board.isRoot }) { $0.editor.showBoard(.root) }
    }
}

/// The root is "Root"; any other board is "Inside", in a folder, with a way up.
@MainActor func testHeading(_ editor: CanvasEditor) -> ContentsHeading? {
    editor.board.isRoot ? ContentsHeading("Root") : ContentsHeading("Inside", systemImage: "folder", up: UpPlugin.up)
}

/// Names the board listed, as a plugin does (`registrar.contentsHeading`).
@MainActor func headingPlugin(id: PluginID = "heading", _ heading: @escaping @MainActor (CanvasEditor) -> ContentsHeading?) -> Contributor {
    Contributor(id: id) { $0.contentsHeading(heading) }
}

@MainActor let boardTests = Suite("Table of contents across boards", [
    test("the rows are the board shown's, and follow it there and back") {
        let (file, pocket) = pocketFile(outside: ["A", "B"], inside: ["C"])
        let editor = try contentsEditor([PocketsPlugin()], file: file)
        expectEqual(editor.contents.entries.outline, ["A", "B", "pocket"])
        editor.showBoard(BoardID(owner: pocket))
        expectEqual(editor.contents.entries.outline, ["C"])
        editor.add(Widget(name: "D"))
        expectEqual(editor.contents.entries.outline, ["C", "D"])
        editor.showBoard(.root)
        expectEqual(editor.contents.entries.outline, ["A", "B", "pocket"])
        editor.showBoard(BoardID(owner: pocket))
        expectEqual(editor.contents.entries.outline, ["C", "D"])
    },
    test("going back to a board as it was left makes none of its rows") {
        let (file, pocket) = pocketFile(outside: ["A", "B"], inside: ["C"])
        let editor = try contentsEditor([PocketsPlugin()], file: file)
        _ = editor.contents.entries
        editor.showBoard(BoardID(owner: pocket))
        _ = editor.contents.entries
        let made = editor.contents.rowsMade
        editor.showBoard(.root)
        expectEqual(editor.contents.entries.outline, ["A", "B", "pocket"])
        editor.showBoard(BoardID(owner: pocket))
        expectEqual(editor.contents.entries.outline, ["C"])
        expectEqual(editor.contents.rowsMade, made)
    },
    test("a board changed since it was left makes its rows again") {
        let (file, pocket) = pocketFile(outside: ["A", "B"], inside: ["C"])
        let editor = try contentsEditor([PocketsPlugin()], file: file)
        _ = editor.contents.entries
        editor.showBoard(BoardID(owner: pocket))
        let renamed = CanvasFile(root: CanvasDocument(shapes: editor.file.root.shapes.map { shape in
            guard var widget = shape.typed(as: Widget.self) else { return shape }
            widget.props.name += "′"
            return AnyShapeRecord(widget)
        }), children: [pocket: editor.file[BoardID(owner: pocket)]])
        editor.replaceFile(with: renamed)             // the pocket's board stays shown
        let made = editor.contents.rowsMade
        editor.showBoard(.root)
        expectEqual(editor.contents.entries.outline, ["A′", "B′", "pocket"])
        expectEqual(editor.contents.rowsMade, made + 3)
    },
    test("undo follows the board it shows: a step on the pocket's board, undone from the root, and a board a deletion took, put back") {
        let (file, pocket) = pocketFile(outside: ["A", "B"], inside: ["C"])
        let editor = try contentsEditor([PocketsPlugin()], file: file)
        editor.showBoard(BoardID(owner: pocket))
        let c = editor.document.shapes[0].id
        editor.transact("Rename") { $0.update(c, as: Widget.self) { $0.props.name = "C2" } }
        expectEqual(editor.contents.entries.outline, ["C2"])
        editor.showBoard(.root)
        _ = editor.contents.entries
        editor.undo()
        expectEqual(editor.board, BoardID(owner: pocket))
        expectEqual(editor.contents.entries.outline, ["C"], "the rows kept for the board, then the step undone on them")

        editor.showBoard(.root)
        editor.transact("Delete") { $0.delete([pocket]) }
        expectEqual(editor.contents.entries.outline, ["A", "B"])
        editor.undo()
        expectEqual(editor.contents.entries.outline, ["A", "B", "pocket"])
        let made = editor.contents.rowsMade
        editor.showBoard(BoardID(owner: pocket))
        expectEqual(editor.contents.entries.outline, ["C"])
        expectEqual(editor.contents.rowsMade, made + 1, "a board put back has a new revision: its rows are made again")
    },
    test("a row's primary action opens its shape, as Return does; several rows, or a shape that can't be opened, open nothing") {
        let (file, pocket) = pocketFile(outside: ["A", "B"], inside: ["C"])
        let editor = try contentsEditor([PocketsPlugin(), openingPockets()], file: file)
        let (a, b) = (editor.document.shapes[0].id, editor.document.shapes[1].id)
        editor.contents.open([a])
        expectEqual(editor.board, .root)
        expectEqual(editor.selectedShapeIDs, [], "a widget can't be opened: nothing selected")
        editor.contents.open([a, pocket])
        expectEqual(editor.board, .root)
        editor.selectedShapeIDs = [b]
        editor.contents.open([pocket])
        expectEqual(editor.board, BoardID(owner: pocket))
        expectEqual(editor.contents.entries.outline, ["C"])
        editor.goBack()
        expectEqual(editor.board, .root)
        expectEqual(editor.selectedShapeIDs, [pocket], "the row's shape, selected before it opened")
        editor.goBack()
        expectEqual(editor.selectedShapeIDs, [b], "a row picked is a step, as a link followed is")
    },
    test("the heading is what a plugin calls the board listed, else Board; two plugins naming it conflict") {
        let (file, pocket) = pocketFile(outside: ["A"], inside: ["C"])
        let plain = try contentsEditor([PocketsPlugin()], file: file)
        expectEqual(plain.contents.heading.title, "Board", "no plugin names it")
        let unnamed = try contentsEditor([headingPlugin { _ in nil }])
        expectEqual(unnamed.contents.heading.title, "Board", "nil is the list's own")
        let editor = try contentsEditor([PocketsPlugin(), UpPlugin(), headingPlugin(testHeading)], file: file)
        expectEqual(editor.contents.heading.title, "Root")
        expectEqual(editor.contents.heading.up, nil)
        editor.showBoard(BoardID(owner: pocket))
        let inside = editor.contents.heading
        expectEqual(inside.title, "Inside")
        expectEqual(inside.systemImage, "folder")
        expectEqual(inside.up, UpPlugin.up)
        expect(editor.registry.report.split(separator: "\n").contains { $0.hasPrefix("heading ") && $0.hasSuffix(" contents heading") }, editor.registry.report)
        expectThrows(RegistryError.conflict(point: "ContentsHeadings", key: "heading", plugins: ["heading", "again"])) {
            _ = try contentsRegistry([headingPlugin(testHeading), headingPlugin(id: "again", testHeading)])
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "ContentsHeadings", owner: .tableOfContents, contributor: "heading")) {
            _ = try Registry(plugins: [headingPlugin(testHeading)])
        }
    },
])

extension ContentsWindow {
    /// How many of the list's header's pixels differ from `other`'s (which lists the same board).
    func headerDiffers(from other: ContentsWindow) throws -> Int {
        let header = headerRect
        return changedPixels(snapshot(hosting), snapshot(other.hosting), in: header)
    }
}

@MainActor let boardWindowTests = Suite("Table of contents across boards, in a window", [
    test("the heading names the board, with a button up that runs its command while it can") {
        let (file, pocket) = pocketFile(outside: ["A"], inside: ["C"])
        let editor = try contentsEditor([PocketsPlugin(), UpPlugin(), headingPlugin(testHeading)], file: file, scheduler: TaskScheduler())
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 2 }
        expectEqual(w.headerButtons.count, 0, "nothing above the root")
        let root = snapshot(w.hosting), header = w.headerRect
        editor.showBoard(BoardID(owner: pocket))
        w.window.spin { w.rows == 1 && w.headerButtons.count == 1 }
        expect(changedPixels(root, snapshot(w.hosting), in: header) > 0, "another title")
        try require(w.headerButtons.first).performClick(nil)
        w.window.spin { editor.board == .root && w.rows == 2 }
        expectEqual(w.headerButtons.count, 0)
    },
    test("with no heading the header is Board's, whatever is selected") {
        let (file, _) = pocketFile(outside: ["A"], inside: [])
        let windows = try [nil, ContentsHeading("Board"), ContentsHeading("Board", systemImage: "folder"), ContentsHeading("Root")].map { heading in
            let w = ContentsWindow(try contentsEditor([PocketsPlugin(), headingPlugin { _ in heading }], file: file, scheduler: TaskScheduler()))
            w.window.spin { w.rows == 2 }
            return w
        }
        expectEqual(try windows[0].headerDiffers(from: windows[1]), 0, "no heading is \"Board\"")
        expect(try windows[0].headerDiffers(from: windows[2]) > 0, "a symbol shows before the title")
        expect(try windows[0].headerDiffers(from: windows[3]) > 0, "another title")
        let plain = snapshot(windows[3].hosting), header = windows[3].headerRect
        windows[3].editor.selectedShapeIDs = [windows[3].editor.document.shapes[0].id]
        windows[3].window.spin { windows[3].table?.selectedRowIndexes.count == 1 }
        expectEqual(windows[3].rows, 2)
        expectEqual(windows[3].headerButtons.count, 0)
        expectEqual(changedPixels(plain, snapshot(windows[3].hosting), in: header), 0, "the heading stays")
    },
    test("Return on a pocket's row, the list's primary action, enters its board") {
        let (file, pocket) = pocketFile(outside: ["A"], inside: ["C", "D"])
        let editor = try contentsEditor([PocketsPlugin(), openingPockets()], file: file, scheduler: TaskScheduler())
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 2 }
        editor.contents.select([pocket])
        w.window.spin { w.table?.selectedRowIndexes.count == 1 }
        try w.focusList()
        w.window.pressReturn()
        w.window.spin { editor.board == BoardID(owner: pocket) && w.rows == 2 }
        expectEqual(editor.selectedShapeIDs, [])
    },
    test("another board's rows replace this one's in one run: AppKit logs no reentrant update, whatever's selected") {
        let names = (0..<50).map { "Widget \($0)" }
        let (file, pocket) = pocketFile(outside: names, inside: names.map { $0 + " inside" })
        let editor = try contentsEditor([PocketsPlugin()], file: file, scheduler: TaskScheduler())
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 51 }
        let log = standardError {
            for _ in 0..<2 {
                editor.showBoard(BoardID(owner: pocket))
                w.window.spin { w.rows == 50 }
                editor.showBoard(.root)
                w.window.spin { w.rows == 51 }
            }
            editor.selectedShapeIDs = [editor.document.shapes[3].id]
            w.window.spin { w.table?.selectedRowIndexes.count == 1 }
            editor.showBoard(BoardID(owner: pocket))
            w.window.spin { w.rows == 50 }
        }
        expect(!log.contains(tableReentrancyWarning), "AppKit logged: \(log)")
    },
    test("a file put in place that shows another board holding some of the same shapes replaces the rows too, rather than slotting new ones between them") {
        let widget = { (i: Int, name: String) in ShapeRecord(Widget(CGRect(x: i * 150, y: 0, width: 100, height: 60), name: name)) }
        let inside = (0..<25).map { widget($0, "Inside \($0)") }, outside = (0..<25).map { widget($0, "Outside \($0)") }
        let pocket = ShapeRecord(Pocket(CGRect(x: 0, y: 200, width: 100, height: 60)))
        let file = CanvasFile(root: CanvasDocument(shapes: outside.map(AnyShapeRecord.init) + [AnyShapeRecord(pocket)]),
                              children: [pocket.id: CanvasDocument(shapes: inside.map(AnyShapeRecord.init))])
        let editor = try contentsEditor([PocketsPlugin()], file: file, scheduler: TaskScheduler())
        let w = ContentsWindow(editor)
        editor.showBoard(BoardID(owner: pocket.id))
        w.window.spin { w.rows == 25 }
        // The pocket gone, and its shapes on the root, each before one of the root's: the root is
        // shown, listing the pocket's rows with new ones between them and after the last.
        let merged = zip(inside, outside).flatMap { [AnyShapeRecord($0), AnyShapeRecord($1)] }
        let log = standardError {
            editor.replaceFile(with: CanvasFile(root: CanvasDocument(shapes: merged)))
            w.window.spin { w.rows == 50 }
        }
        expectEqual(editor.board, .root)
        expect(!log.contains(tableReentrancyWarning), "AppKit logged: \(log)")
    },
])
