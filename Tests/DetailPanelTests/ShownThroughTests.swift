import Canvas
import CanvasTesting
import CoreGraphics
import DetailPanel
import Selection
import SwiftUI
import TestKit

// The panel of a stand-in that shows another shape (a mirror): its own tabs, then the shape's, bound to that shape on
// whichever board it is. CanvasTesting's lens is the stand-in.

enum LensTab {}
extension LensTab: DetailTab {
    static var title: String { "Lens" }
    static var order: Order<Self> { .first }
}

/// A Lens tab of the lens's own.
struct LensPanelPlugin: CanvasPlugin {
    var id: PluginID { "lens-panel" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.details(Lens.self, header: { _ in DetailHeader("Lens") }) {
            DetailSection("Shows", in: LensTab.self) { _ in Text("Shows") }
        }
    }
}

@MainActor private func lensEditor(shows: Bool) throws -> (editor: CanvasEditor, lens: ShapeID, gadget: ShapeID, pocket: ShapeID) {
    let pocket = ShapeID(), gadget = ShapeID(), lens = ShapeID(), empty = ShapeID()
    let file = CanvasFile(root: CanvasDocument(shapes: ShapeStack([
        AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: -300, y: 0, width: 100, height: 100)))),
        AnyShapeRecord(ShapeRecord(id: lens, Lens(CGRect(x: 200, y: 200, width: 100, height: 100), shows: shows ? gadget : empty))),
    ])), children: [pocket: CanvasDocument(shapes: ShapeStack([AnyShapeRecord(ShapeRecord(id: gadget, Gadget(gadgetFrame, name: "Old")))]))])
    let editor = try gadgetEditor([PocketsPlugin(), LensesPlugin(), LensPanelPlugin()], file: file)
    return (editor, lens, gadget, pocket)
}

@MainActor let shownThroughPanelTests = Suite("The panel of a stand-in that shows a shape", [
    test("a lens's own tab, then the shape's tabs, their sections bound to that shape") {
        let (editor, lens, gadget, _) = try lensEditor(shows: true)
        let state = try require(editor.detailPanel)
        let layout = try require(state.panelLayout(for: lens))
        expectEqual(layout.tabs.first, .of(LensTab.self))
        expect(layout.tabs.contains(.of(GadgetTab.self)) && layout.tabs.contains(.of(StyleTab.self)), "\(layout.tabs.map(\.title))")
        expect(layout.sectionsShownThrough(in: .of(LensTab.self)).isEmpty)
        expectEqual(layout.sectionsShownThrough(in: .of(GadgetTab.self)).count, 2)
        // A tab both have is the shape's alone, said once.
        let frame = layout.sections(in: .of(FrameTab.self))
        expectEqual(frame.count, 2)
        expectEqual(layout.sectionsShownThrough(in: .of(FrameTab.self)), frame)
        expectEqual(layout.tabs.filter { $0 == .of(FrameTab.self) }.count, 1)
        // Without a shape it shows, its own.
        let alone = try lensEditor(shows: false)
        let own = try require(try require(alone.editor.detailPanel).panelLayout(for: alone.lens))
        expectEqual(own.tabs.map(\.title), ["Lens", "Frame"])
        expect(own.tabs.allSatisfy { own.sectionsShownThrough(in: $0).isEmpty })
        _ = gadget
    },
    test("a write through the shape's binding lands on its board, the board shown stays, and undo stays too") {
        let (editor, lens, gadget, pocket) = try lensEditor(shows: true)
        editor.selection = lens
        let binding = try require(editor.shapeBinding(gadget, as: Gadget.self))
        binding.name.wrappedValue = "New"
        expectEqual(editor.board, .root)
        expectEqual(editor.file[BoardID(owner: pocket)][gadget]?.typed(as: Gadget.self)?.props.name, "New")
        try require(editor.frameBinding(gadget)).update { $0.size.width = 300 }
        expectEqual(editor.file[BoardID(owner: pocket)][gadget]?.box?.width, 300)
        editor.undo()
        editor.undo()
        expectEqual(editor.board, .root, "undone from where it was written")
        expectEqual(editor.file[BoardID(owner: pocket)][gadget]?.typed(as: Gadget.self)?.props.name, "Old")
        expectEqual(editor.file[BoardID(owner: pocket)][gadget]?.box?.width, gadgetFrame.width)
    },
])
