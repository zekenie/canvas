import Canvas
import CanvasTesting
import CoreGraphics
import DetailPanel
import Keyboard
import Observation
import TestKit

// What heads a board's rows in the lists that group shapes by board: a plugin's to say, else "Board"
// for the root and no name for any other. The plugin that really names boards (Boards') is its own
// tests'; here a contributor written inline does.

/// A root holding a pocket, whose board holds a box.
@MainActor private func pocketFile() -> (file: CanvasFile, board: BoardID) {
    let pocket = ShapeRecord(Pocket(CGRect(x: 100, y: 100, width: 100, height: 100)))
    let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(pocket)]),
                          children: [pocket.id: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(Box(gadgetFrame)))])])
    return (file, BoardID(owner: pocket.id))
}

@MainActor private func headingEditor(_ more: [any CanvasPlugin] = [], file: CanvasFile) throws -> CanvasEditor {
    try gadgetEditor([PocketsPlugin()] + more, file: file)
}

@MainActor let boardHeadingTests = Suite("Board headings", [
    test("with no plugin naming boards, the root is headed Board and any other board has no name") {
        let (file, pocket) = pocketFile()
        let editor = try headingEditor(file: file)
        expectEqual(editor.boardHeading(of: .root), BoardHeading("Board"))
        expectEqual(editor.boardHeading(of: pocket), BoardHeading(""))
        expectEqual(editor.boardHeading(of: pocket).systemImage, nil)
    },
    test("a plugin heads each board with a title and a symbol, and the editor reads what it says each time") {
        let name = Name()
        let naming = Contributor(id: "naming") { registrar in
            registrar.boardHeading { board, _ in board.isRoot ? BoardHeading(name.text) : BoardHeading("Pocket", systemImage: "tray") }
        }
        let (file, pocket) = pocketFile()
        let editor = try headingEditor([naming], file: file)
        expectEqual(editor.boardHeading(of: .root), BoardHeading("Top"))
        expectEqual(editor.boardHeading(of: pocket), BoardHeading("Pocket", systemImage: "tray"))
        name.text = "Roof"
        expectEqual(editor.boardHeading(of: .root), BoardHeading("Roof"))
        let line = try require(editor.registry.report.split(separator: "\n").first { $0.hasPrefix("naming ") })
        expect(line.hasSuffix(" board heading"), String(line))
    },
    test("a heading reads observable state, so a list redraws when a board is renamed") {
        let name = Name()
        let naming = Contributor(id: "naming") { registrar in registrar.boardHeading { _, _ in BoardHeading(name.text) } }
        let (file, _) = pocketFile()
        let editor = try headingEditor([naming], file: file)
        let changed = Flag()
        withObservationTracking { _ = editor.boardHeading(of: .root) } onChange: { changed.set() }
        name.text = "Roof"
        expect(changed.isSet)
    },
    test("two plugins naming boards conflict, and a plugin naming them needs the detail panel") {
        let naming = Contributor(id: "naming") { $0.boardHeading { _, _ in BoardHeading("One") } }
        let again = Contributor(id: "again") { $0.boardHeading { _, _ in BoardHeading("Two") } }
        expectThrows(RegistryError.conflict(point: "BoardHeadings", key: "heading", plugins: ["naming", "again"])) {
            _ = try Registry(plugins: [KeyboardPlugin(), DetailPanelPlugin(), naming, again])
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "BoardHeadings", owner: .detailPanel, contributor: "naming")) {
            _ = try Registry(plugins: [naming])
        }
    },
])

/// What a contributor's heading reads, observable as a title is.
@Observable @MainActor private final class Name {
    var text = "Top"
}
