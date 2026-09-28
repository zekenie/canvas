import Adornments
import AppKit
import Canvas
import CanvasTesting
import Checklists
import ContextMenus
import DetailPanel
import Geometry
import Keyboard
import Selection
import SwiftUI
import TestKit

@MainActor let itemTests = Suite("Checklist items", [
    test("doneCount and progress count the checked items; an empty list is 0% done") {
        expectEqual(laundry(done: 2).doneCount, 2)
        expectClose(laundry(done: 2).progress, 2.0 / 3)
        expectEqual([ChecklistItem]().doneCount, 0)
        expectEqual([ChecklistItem]().progress, 0)
    },
    test("setAllDone checks or unchecks every item; removeDone keeps the open ones, in order") {
        var list = laundry(done: 1)
        list.setAllDone(true)
        expectEqual(list.map(\.isDone), [true, true, true])
        list.setAllDone(false)
        expectEqual(list.map(\.isDone), [false, false, false])
        list = laundry(done: 1)
        list.removeDone()
        expectEqual(list.map(\.text), ["dry", "fold"])
    },
    test("the bulk actions, in menu order: each is on only when it has something to do, and does it") {
        expectEqual(ChecklistBulkAction.allCases.map(\.title), ["Check All", "Uncheck All", "Remove Checked"])
        /// Which actions are on for a list of three with `done` checked.
        func enabled(done: Int) -> [ChecklistBulkAction] { ChecklistBulkAction.allCases.filter { $0.isEnabled(for: laundry(done: done)) } }
        expectEqual(enabled(done: 0), [.checkAll])
        expectEqual(enabled(done: 1), [.checkAll, .uncheckAll, .removeChecked])
        expectEqual(enabled(done: 3), [.uncheckAll, .removeChecked])
        expectEqual(ChecklistBulkAction.allCases.filter { $0.isEnabled(for: []) }, [])
        /// The list of three with one checked, after `action`.
        func applied(_ action: ChecklistBulkAction) -> [ChecklistItem] {
            var list = laundry(done: 1)
            action.apply(to: &list)
            return list
        }
        expectEqual(applied(.checkAll).map(\.isDone), [true, true, true])
        expectEqual(applied(.uncheckAll).map(\.isDone), [false, false, false])
        expectEqual(applied(.removeChecked).map(\.text), ["dry", "fold"])
    },
    test("a new item is empty, open, and unique") {
        let a = ChecklistItem(), b = ChecklistItem()
        expectEqual(a.text, "")
        expect(!a.isDone)
        expect(a.id != b.id)
    },
])

/// A tab type titled like Checklists' own.
enum LookalikeChecklistTab {}
extension LookalikeChecklistTab: DetailTab { static var title: String { "Checklist" } }

@MainActor let optInTests = Suite("Checklist opt-in", [
    test("opting in brings the Checklist tab, after the kind's own, and only to the kinds that opt in") {
        let editor = try choreEditor()
        expectEqual(editor.registry.contributions(to: ShapeChecklists.self).map(\.target), [.kind(Chore.kind), .kind(Errand.kind)])
        expectEqual(try editor.layout(editor.add(Chore(choreFrame))).outline, ["Chore: main", "Checklist: Items", "Arrange: Size, Position"])
        expectEqual(try editor.layout(editor.add(Errand(frame: choreFrame))).outline, ["Checklist: Items", "Arrange: Size, Position"])
        expectEqual(try editor.layout(editor.add(Box(choreFrame))).outline, ["Arrange: Size, Position"])
    },
    test("Progress shows once the checklist has items") {
        let editor = try choreEditor()
        let id = editor.add(Chore(choreFrame))
        editor.transact { $0.update(id) { $0[ChecklistProperty.self] = laundry() } }
        expectEqual(try editor.layout(id).outline, ["Chore: main", "Checklist: Items, Progress", "Arrange: Size, Position"])
    },
    test("the registry reads a shape's checklist; a kind without one has none") {
        let editor = try choreEditor()
        let choreID = editor.add(Chore(choreFrame), items: laundry(done: 1)), boxID = editor.add(Box(choreFrame))
        let chore = try require(editor.document[choreID]), box = try require(editor.document[boxID])
        expectEqual(editor.registry.checklist(of: chore)?.map(\.text), ["wash", "dry", "fold"])
        expectEqual(editor.registry.checklist(of: chore)?.doneCount, 1)
        expectEqual(editor.registry.checklist(of: box), nil)
    },
    test("a bulk action is one transaction, on the live list") {
        let editor = try choreEditor()
        let id = editor.add(Chore(choreFrame), items: laundry(done: 1))
        let binding = try require(editor.propertyBinding(id, ChecklistProperty.self))
        // An item added after the panel drew still gets checked, then removed.
        editor.transact { $0.update(id) { $0[ChecklistProperty.self]?.append(ChecklistItem(text: "iron")) } }
        let revision = editor.revision
        // As the menu applies one.
        binding.update { ChecklistBulkAction.checkAll.apply(to: &$0) }
        expectEqual(editor.items(id)?.map(\.isDone), [true, true, true, true])
        expectEqual(editor.revision, revision + 1)
        binding.update { ChecklistBulkAction.removeChecked.apply(to: &$0) }
        expectEqual(editor.items(id), [])
        expectEqual(editor.revision, revision + 2)
    },
    test("opting in is one line: the kind's checklist, its panel and its menu items, in the report") {
        let registry = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), AdornmentsPlugin(), ChecklistsPlugin(), DetailPanelPlugin(),
                                              ContextMenusPlugin(), Contributor(id: "p") { r in
            r.shape(ChoreDefinition()) { $0.checklist() }
        }])
        expectEqual(registry.report, """
        core           tool hand · command undo · command redo
        keyboard       service KeyboardState · key strokes · shortcut H → tool hand · shortcut ⎋ → Cancel · shortcut ⌘. → Cancel · shortcut ⌘Z → command undo · shortcut ⇧⌘Z → command redo
        selection      service SelectionState · tool select · shortcut V → tool select · default tool select · outlines · overlay HandlesOverlay · command delete · shortcut ⌫ → command delete · shortcut ⌦ → command delete · command selectAll · shortcut ⌘A → command selectAll · command goBack · shortcut ⌘[ → command goBack · shortcut ↩ → Edit Selection · shortcut ⌤ → Edit Selection
        adornments     service AdornmentState · overlay AdornmentOverlay · CanvasButtons · DecorationHits
        checklists     property checklist · adornment ChecklistChip → every shape
        detail-panel   service DetailPanelState · ShapeDetails
        context-menus  service ContextMenuState · secondary-click menu
        p              shape chore · property checklist → chore · ShapeChecklists → chore · ShapeDetails → chore · ShapeContextMenus → chore
        """)
    },
    test("the opt-in needs Checklists installed, the panel and context menus; Checklists needs Adornments, which lays out its chip") {
        expectThrows(RegistryError.ownerNotInstalled(point: "ShapeChecklists", owner: .checklists, contributor: "chores")) {
            _ = try Registry(plugins: [ChoresPlugin(), DetailPanelPlugin()])
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "ShapeDetails", owner: .detailPanel, contributor: "chores")) {
            _ = try Registry(plugins: [ChoresPlugin(), ChecklistsPlugin()])
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "ShapeContextMenus", owner: .contextMenus, contributor: "chores")) {
            _ = try Registry(plugins: [ChoresPlugin(), ChecklistsPlugin(), DetailPanelPlugin()])
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "ShapeAdornments", owner: .adornments, contributor: .checklists)) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), ChoresPlugin(), ChecklistsPlugin(), DetailPanelPlugin(), ContextMenusPlugin()])
        }
    },
    test("another tab titled Checklist is invalid") {
        expectEqual(DetailTabID.of(ChecklistTab.self).name, "Checklists.ChecklistTab")
        expectThrows(RegistryError.invalid(point: "ShapeDetails", reason: "Checklists.ChecklistTab (from chores) and "
                                           + "ChecklistsTests.LookalikeChecklistTab (from more) are both tabs titled \"Checklist\"; share one, or retitle one")) {
            _ = try choreEditor([Contributor(id: "more") { r in
                r.details(Box.self) { DetailSection(in: LookalikeChecklistTab.self) { _ in Text("Mine") } }
            }])
        }
    },
    test("opting in brings the bulk actions to the context menu, each only where it has something to do") {
        let h = try EditorHarness { try choreEditor(scheduler: $0) }
        let chore = h.editor.add(Chore(choreFrame), items: laundry(done: 1))
        let menu = try require(h.secondaryClick(at: CGPoint(x: choreFrame.midX, y: choreFrame.midY)))
        expectEqual(menu.outline, ["Check All", "Uncheck All", "Remove Checked"])
        let revision = h.editor.revision
        try menu.choose("Check All")
        expectEqual(h.editor.items(chore)?.map(\.isDone), [true, true, true])
        expectEqual(h.editor.revision, revision + 1)
        expectEqual(try require(h.secondaryClick()).outline, ["Uncheck All", "Remove Checked"])
        try require(h.secondaryClick()).choose("Remove Checked")
        expectEqual(h.editor.items(chore), [])
        expect(h.secondaryClick() == nil, "an empty checklist offers nothing, and the chore nothing else")
    },
    test("two kinds selected together share the actions, each on its own list") {
        let h = try EditorHarness { try choreEditor(scheduler: $0) }
        let chore = h.editor.add(Chore(choreFrame), items: laundry(done: 1))
        let errand = h.editor.add(Errand(frame: choreFrame.offsetBy(dx: 300, dy: 0)), items: [ChecklistItem(text: "post office")])
        h.editor.selectedShapeIDs = [chore, errand]
        let menu = try require(h.secondaryClick(at: CGPoint(x: choreFrame.midX, y: choreFrame.midY)))
        expectEqual(menu.outline, ["Check All"], "the errand has nothing checked to uncheck or remove")
        try menu.choose("Check All")
        expectEqual(h.editor.items(chore)?.map(\.isDone), [true, true, true])
        expectEqual(h.editor.items(errand)?.map(\.isDone), [true])
    },
])

/// The canvas with one shape, with these checklist items, drawn at `zoom`.
@MainActor func render<P: ShapeProps>(_ shape: P, items: [ChecklistItem] = [], zoom: CGFloat = 1) throws -> NSBitmapImageRep {
    let editor = try choreEditor()
    editor.add(shape, items: items)
    editor.camera = Camera(zoom: zoom)
    return renderBitmap(editor, size: CGSize(width: 400, height: 300) * zoom)
}

extension NSBitmapImageRep {
    var bytes: Data { Data(bytes: bitmapData!, count: bytesPerRow * pixelsHigh) }
}

extension CGSize {
    static func * (size: CGSize, scale: CGFloat) -> CGSize { CGSize(width: size.width * scale, height: size.height * scale) }
}

/// Just inside the chip's right end: the chore's top-right corner is (320, 40).
let chipPoint = CGPoint(x: 323, y: 40)

@MainActor let badgeTests = Suite("Checklist badge", [
    test("a checklist with items shows a dark chip on the shape's top-right corner") {
        let color = pixel(try render(Chore(choreFrame), items: laundry(done: 1)), at: chipPoint)
        expect(color[0..<3].allSatisfy { $0 < 100 }, "\(color)")
    },
    test("the chip turns green once every item is done") {
        let color = pixel(try render(Chore(choreFrame), items: laundry(done: 3)), at: chipPoint)
        expect(color[1] > color[0] + 80 && color[1] > color[2] + 60, "\(color)")
    },
    test("an empty checklist draws nothing, and neither does a kind that opted in with badge: false") {
        let bare = try render(Chore(choreFrame)).bytes
        // An errand draws just as a chore does.
        expectEqual(try render(Errand(frame: choreFrame), items: laundry()).bytes, bare)
        expect(try render(Chore(choreFrame), items: laundry()).bytes != bare)
    },
    test("the chip is sized in view points: as tall at 200% as at 100% and 25%; shorter when zoomed out further") {
        /// How many view points tall the chip is: the dark rows, drawn at 4x, around the chore's
        /// top-right corner.
        @MainActor func height(zoom: CGFloat) throws -> CGFloat {
            let editor = try choreEditor()
            editor.add(Chore(choreFrame), items: laundry(done: 1))
            editor.camera = Camera(zoom: zoom)
            let rep = renderBitmap(editor, size: CGSize(width: 400, height: 300) * zoom, scale: 4)
            let corner = CGPoint(x: 320 * zoom, y: 40 * zoom)
            let dark = stride(from: max(0, corner.y - 12), to: corner.y + 12, by: 0.25).filter { y in
                stride(from: corner.x - 12, to: min(400 * zoom, corner.x + 8), by: 0.25).contains { x in
                    pixel(rep, at: CGPoint(x: x, y: y), scale: 4)[0..<3].allSatisfy { $0 < 100 }
                }
            }
            return (dark.max() ?? 0) - (dark.min() ?? 0) + 0.25
        }
        let full = try height(zoom: 1)
        expectClose(full, 16, within: 0.5)
        expectEqual(try height(zoom: 2), full)
        expectEqual(try height(zoom: 0.25), full)
        // As the selection's handles do: at 10%, 0.4 of full size.
        expectClose(try height(zoom: 0.1), full * 0.4, within: 0.5)
    },
    test("the chip goes where its shape is drawn (a shake)") {
        let editor = try choreEditor()
        let id = editor.add(Chore(choreFrame), items: laundry(done: 1))
        let still = renderBitmap(editor, size: CGSize(width: 400, height: 300))
        editor.setDrawingOffset(CGPoint(x: 7, y: 0), for: id)
        let moved = renderBitmap(editor, size: CGSize(width: 400, height: 300))
        for x in stride(from: 300, through: 324, by: 3) {
            for y in stride(from: 34, through: 46, by: 3) {
                expectEqual(pixel(moved, at: CGPoint(x: x + 7, y: y)), pixel(still, at: CGPoint(x: x, y: y)), "(\(x), \(y))")
            }
        }
    },
])
