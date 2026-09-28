import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import DetailPanel
import Selection
import SwiftUI
import TestKit

/// Counts its command's runs.
@MainActor final class RunCount {
    var runs = 0
}

/// A Run button in every box's panel, whose command can run while the board holds more than one
/// shape.
struct RunButtonPlugin: CanvasPlugin {
    static let run: CanvasCommand = "test-run"
    let count: RunCount
    var id: PluginID { "run-button" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.command(Self.run, isEnabled: { $0.document.shapes.count > 1 }) { [count] _ in count.runs += 1 }
        registrar.detailsForEveryBox {
            DetailSection("Run", in: FrameTab.self) { _ in
                DetailCommandButton("Run", systemImage: "play", command: Self.run)
            }
        }
    }
}

@MainActor let boardPanelTests = Suite("The panel across boards", [
    test("a command button runs its command, dimmed while it can't run") {
        let count = RunCount()
        let editor = try gadgetEditor([RunButtonPlugin(count: count)], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let id = editor.add(Box(gadgetFrame))
        editor.selection = id
        panel.window.spin { !panel.checkboxes.isEmpty }
        let button = try require(panel.checkboxes.last)
        expect(!button.isEnabled, "one shape on the board")
        editor.add(Box(gadgetFrame.offsetBy(dx: 400, dy: 0)))
        panel.window.spin { button.isEnabled }
        button.performClick(nil)
        expectEqual(count.runs, 1)
    },
    test("a number being typed is written to its shape before another board is shown") {
        let pocket = ShapeRecord(Pocket(CGRect(x: 600, y: 40, width: 100, height: 60)))
        let box = ShapeRecord(Box(gadgetFrame))
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(box), AnyShapeRecord(pocket)]))
        let editor = try gadgetEditor([PocketsPlugin()], file: file, scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        editor.selection = box.id
        panel.window.spin { !panel.fields.isEmpty }
        panel.window.focus(try panel.field("240 pt"))
        panel.window.type("300")
        expectEqual(editor.document[box.id]?.box?.width, 240, "a draft")
        editor.showBoard(BoardID(owner: pocket.id))
        expectEqual(editor.file.root[box.id]?.box?.width, 300, "written on its board, before it was left")
        panel.window.settle()
        expectEqual(editor.file.root[box.id]?.box?.width, 300)
    },
])
