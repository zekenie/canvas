import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Observation
import Selection
import SwiftUI
import TableOfContents
import TestKit

// Sections (`ContentsSections`): a kind's rows gathered, at each level they're listed at, under one row
// of their own after the level's other rows, closed until it's opened, saying how many it holds.
// References gathers its pills' rows so; here, the aliases do, a fixture that knows no reference.

/// A box that stands in for another shape by name, as a reference does: its rows gather in "Aliases".
struct Alias: BoxShapeProps {
    static let kind: ShapeKind = "alias"
    static let properties = Properties<Alias> {
        Property("frame", \.frame).required()
        Property("name", \.name)
    }
    var frame: CGRect
    var name: String

    init(_ name: String = "", frame: CGRect = widgetFrame) {
        self.frame = frame
        self.name = name
    }
}

extension Alias {
    init() { self.init("") }
}

struct AliasDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Alias>, in context: RenderContext) {}
}

let aliasesSection = ContentsSection("Aliases", systemImage: "arrow.turn.up.right")

/// Aliases, whose rows gather in "Aliases".
struct AliasesPlugin: CanvasPlugin {
    var id: PluginID { "aliases" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(AliasDefinition()) { alias in
            alias.contentsRow { alias in ContentsLabel(alias.props.name, placeholder: "Alias", standsIn: true) }
            alias.contentsSection(aliasesSection)
        }
    }
}

/// Pins gather in a section of their own, after the aliases' in plugin order; gizmos with the aliases.
struct MoreSectionsPlugin: CanvasPlugin {
    var id: PluginID { "more-sections" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.contentsSection(Pin.self, ContentsSection("Pins", systemImage: "pin"))
        registrar.contentsSection(Gizmo.self, aliasesSection)
    }
}

/// An editor with widgets, aliases and corrals, and the table of contents, then `more`.
@MainActor func aliasEditor(_ more: [any CanvasPlugin] = [], file: CanvasFile = CanvasFile(), scheduler: any Scheduler = ManualScheduler()) throws -> CanvasEditor {
    try contentsEditor([CorralsPlugin(), AliasesPlugin()] + more, file: file, scheduler: scheduler)
}

/// Widget A, aliases X and Y, and widget B, on the board in that order (so listed front to back: B, A, then the section's Y, X).
@MainActor func aliasedWidgets(_ editor: CanvasEditor) -> (a: ShapeID, x: ShapeID, y: ShapeID, b: ShapeID) {
    (editor.add(Widget(CGRect(x: 0, y: 0, width: 100, height: 60), name: "A")),
     editor.add(Alias("X", frame: CGRect(x: 200, y: 0, width: 100, height: 30))),
     editor.add(Alias("Y", frame: CGRect(x: 400, y: 0, width: 100, height: 30))),
     editor.add(Widget(CGRect(x: 600, y: 0, width: 100, height: 60), name: "B")))
}

extension ContentsWindow {
    /// The list's rows as it shows them, top to bottom, less its header: a row's name, a section's row
    /// its title and count ("Aliases · 2"), each indented two spaces a level.
    var shown: [String] {
        guard let outline, outline.numberOfRows > 1 else { return [] }
        return (1..<outline.numberOfRows).map { row in
            String(repeating: "  ", count: outline.level(forRow: row)) + (outline.item(atRow: row).map { String(describing: $0) } ?? "?")
        }
    }

    /// The row (the header is 0) that shows `text` as `shown` has it, untrimmed of its indent; -1 for none.
    func row(_ text: String) -> Int {
        (shown.firstIndex { $0.trimmingCharacters(in: .whitespaces) == text } ?? -2) + 1
    }
}

@MainActor let sectionTests = Suite("Table of contents: sections", [
    test("a kind that declares a section has it on every row; what's listed and where it nests are as without it") {
        let editor = try aliasEditor()
        let (a, x, _, _) = aliasedWidgets(editor)
        let corral = editor.add(Corral(CGRect(x: 0, y: 200, width: 600, height: 400)))
        let z = editor.add(Alias("Z", frame: CGRect(x: 20, y: 220, width: 100, height: 30)))
        editor.put([z], in: corral)
        let entries = editor.contents.entries
        expectEqual(entries.outline, ["A", "X", "Y", "B", "corral", "  Z"])
        expectEqual(entries.first { $0.id == x }?.section, aliasesSection)
        expectEqual(entries.first { $0.id == a }?.section, nil)
        expectEqual(entries.last?.children?.first?.section, aliasesSection, "nested, still gathered")
    },
    test("a kind's second section is a conflict, and a section needs the table of contents") {
        expectThrows(RegistryError.conflict(point: "ContentsSections", key: "alias", plugins: ["aliases", "twice"])) {
            _ = try aliasEditor([Contributor(id: "twice") { $0.contentsSection(Alias.self, ContentsSection("Other", systemImage: "circle")) }])
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "ContentsSections", owner: .tableOfContents, contributor: "boxes")) {
            _ = try Registry(plugins: [FixturesPlugin(), Contributor(id: "boxes") { $0.contentsSection(Box.self, aliasesSection) }])
        }
    },
    test("a section starts closed, and stays as the person turns it, at its level alone; observing it hears its own turns") {
        let editor = try aliasEditor()
        _ = aliasedWidgets(editor)
        let top = ContentsSectionKey(aliasesSection, at: .top(.root))
        let elsewhere = ContentsSectionKey(aliasesSection, at: .under(ShapeID()))
        expect(!editor.contents.isExpanded(top))
        let elsewhereHeard = Flag(), topHeard = Flag()
        withObservationTracking { _ = editor.contents.isExpanded(elsewhere) } onChange: { elsewhereHeard.set() }
        editor.contents.setExpanded(top, true)
        expect(editor.contents.isExpanded(top))
        expect(!editor.contents.isExpanded(elsewhere), "another level's: closed")
        expect(!elsewhereHeard.isSet, "another level's turn tells nobody watching this one")
        withObservationTracking { _ = editor.contents.isExpanded(top) } onChange: { topHeard.set() }
        editor.contents.setExpanded(top, false)
        expect(topHeard.isSet)
        expect(!editor.contents.isExpanded(top))
    },
    test("a drag of selected rows takes those that show: none of a closed section's") {
        let editor = try aliasEditor()
        let (a, x, _, _) = aliasedWidgets(editor)
        _ = editor.contents.entries                      // as the list reads them
        editor.selectedShapeIDs = [a, x]
        expectEqual(editor.contents.dragged(from: a), [a], "X's row is in its closed section")
        editor.contents.setExpanded(ContentsSectionKey(aliasesSection, at: .top(.root)), true)
        expectEqual(editor.contents.dragged(from: a), [a, x])
    },
    test("in a window: a level's rows, then its section's row, closed, with its count; open, its rows front to back") {
        let editor = try aliasEditor(scheduler: TaskScheduler())
        _ = aliasedWidgets(editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 3 }
        expectEqual(w.shown, ["B", "A", "Aliases · 2"])
        expect(try w.isExpandable(3))
        try w.expand(3)
        w.window.spin { w.rows == 5 }
        expectEqual(w.shown, ["B", "A", "Aliases · 2", "  Y", "  X"])
        expect(editor.contents.isExpanded(ContentsSectionKey(aliasesSection, at: .top(.root))), "the person's turn, kept")
    },
    test("in a container, what it holds, then its section; sections in plugin order, two kinds of one section in one; a row's own rows gather too") {
        let editor = try aliasEditor([MoreSectionsPlugin()], scheduler: TaskScheduler())
        let corral = editor.add(Corral(CGRect(x: 0, y: 0, width: 800, height: 600)))
        let w1 = editor.add(Widget(CGRect(x: 20, y: 20, width: 100, height: 60), name: "W"))
        let x = editor.add(Alias("X", frame: CGRect(x: 200, y: 20, width: 100, height: 30)))
        let gizmo = editor.add(Gizmo(CGRect(x: 400, y: 20, width: 100, height: 60)))
        editor.put([w1, x, gizmo], in: corral)
        editor.add(Pin("P", on: w1))
        editor.add(Pin("Q", on: w1))
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 3 }
        expectEqual(w.shown, ["corral", "  W", "  Aliases · 2"], "the corral open from the start; the pins under W, closed")
        try w.expand(2)
        w.window.spin { w.rows == 4 }
        expectEqual(w.shown, ["corral", "  W", "    Pins · 2", "  Aliases · 2"], "W's pins in a section of their own")
        try w.expand(4)
        w.window.spin { w.rows == 6 }
        expectEqual(w.shown, ["corral", "  W", "    Pins · 2", "  Aliases · 2", "    Gizmo", "    X"], "a gizmo with the aliases, front to back")
    },
    test("rows come and go row by row: a section's row comes with its first row and goes with its last, its count follows, open or closed, and AppKit logs no reentrant update") {
        let editor = try aliasEditor(scheduler: TaskScheduler())
        let (a, _, _) = threeWidgets(editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 3 }
        try w.focusList()
        let log = standardError {
            let x = editor.add(Alias("X"))
            w.window.spin { w.shown == ["C", "B", "A", "Aliases · 1"] }
            let y = editor.add(Alias("Y"))
            w.window.spin { w.shown == ["C", "B", "A", "Aliases · 2"] }
            try? w.expand(4)
            w.window.spin { w.shown == ["C", "B", "A", "Aliases · 2", "  Y", "  X"] }
            let z = editor.add(Alias("Z"))
            w.window.spin { w.shown == ["C", "B", "A", "Aliases · 3", "  Z", "  Y", "  X"] }
            editor.transact { $0.delete([y]) }
            w.window.spin { w.shown == ["C", "B", "A", "Aliases · 2", "  Z", "  X"] }
            try? w.collapse(4)
            editor.transact { $0.delete([x]) }
            w.window.spin { w.shown == ["C", "B", "A", "Aliases · 1"] }
            editor.transact { $0.delete([z, a]) }
            w.window.spin { w.shown == ["C", "B"] }
            editor.undo()
            w.window.spin { w.shown == ["C", "B", "A", "Aliases · 1"] }
            w.window.settle()
        }
        expect(!log.contains(tableReentrancyWarning), "AppKit logged: \(log)")
        expect(w.window.firstResponder === w.table, "the rows are new, the list isn't: it keeps the keyboard")
    },
    test("a section's count is redrawn as it changes, and only the rows that changed are") {
        let editor = try aliasEditor(scheduler: TaskScheduler())
        _ = aliasedWidgets(editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 3 }
        w.window.settle()
        let before = editor.contents.rowsRedrawn
        editor.add(Alias("Z"))
        w.window.spin { w.shown == ["B", "A", "Aliases · 3"] }
        w.window.settle()
        expectEqual(editor.contents.rowsRedrawn, before + 1, "the section's row, with its new count")
    },
    test("selecting a section's row selects its rows' shapes; a selection of them all shows on its row while it's closed") {
        let editor = try aliasEditor(scheduler: TaskScheduler())
        let (a, x, y, _) = aliasedWidgets(editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 3 }
        try w.click(row: 3)
        expectEqual(editor.selectedShapeIDs, [x, y], "every alias, in document order")
        w.window.spin { w.canvasHasKeyboard }
        expectEqual(w.table?.selectedRowIndexes, [3])
        editor.selectedShapeIDs = [a]
        w.window.spin { w.table?.selectedRowIndexes == [2] }
        editor.selectedShapeIDs = [a, x, y]
        w.window.spin { w.table?.selectedRowIndexes == [2, 3] }
        expect(!editor.contents.isExpanded(ContentsSectionKey(aliasesSection, at: .top(.root))), "several selected open nothing")
    },
    test("one shape selected elsewhere opens its section and the rows above, kept open, and its row shows selected") {
        let editor = try aliasEditor(scheduler: TaskScheduler())
        let corral = editor.add(Corral(CGRect(x: 0, y: 0, width: 800, height: 600)))
        let x = editor.add(Alias("X", frame: CGRect(x: 20, y: 20, width: 100, height: 30)))
        editor.put([x], in: corral)
        _ = widgets(40, in: editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 42 }
        let corralRow = w.row("corral")
        try w.collapse(corralRow)
        w.window.spin { w.rows == 41 }
        editor.selectedShapeIDs = [x]
        w.window.spin { w.table?.selectedRowIndexes.count == 1 }
        let selected = try require(w.table?.selectedRow)
        expectEqual(w.shown[selected - 1], "    X")
        expect(editor.contents.isExpanded(ContentsSectionKey(aliasesSection, at: .under(corral))), "opened, and stays open")
        let outline = try require(w.outline)
        expect(outline.visibleRect.intersects(outline.rect(ofRow: selected)), "scrolled to")
    },
    test("by keys: ↓ reaches the section's row, → opens it and goes into it, ← comes back and closes it, Return opens and closes it; the list keeps the keyboard; its triangle is named by its title") {
        let editor = try aliasEditor(scheduler: TaskScheduler())
        let (a, x, y, b) = aliasedWidgets(editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 3 }
        @MainActor func triangles() -> [String?] {
            (w.table?.descendants(NSButton.self) ?? []).filter { $0.identifier == NSOutlineView.disclosureButtonIdentifier }
                .map { $0.cell.map(AccessibilityProbe.label(of:)) ?? nil }
        }
        w.window.spin { triangles() == ["Aliases"] }
        try w.focusList()
        let keys = KeyDriver(w.window)
        keys.send(.down)                                // B
        keys.send(.down)                                // A
        expectEqual(editor.selectedShapeIDs, [a])
        keys.send(.down)                                // the section's row: its rows selected
        expectEqual(editor.selectedShapeIDs, [x, y])
        keys.send(.right)                               // before the list caught up with the ↓, as a quick → is
        w.window.spin { w.rows == 5 }
        w.window.settle()
        expectEqual(w.table?.selectedRowIndexes, [3], "the section's row still the selection of its rows, open")
        keys.send(.down)                                // into it
        expectEqual(editor.selectedShapeIDs, [y])
        keys.send(.up)                                  // back to the section's row
        expectEqual(editor.selectedShapeIDs, [x, y])
        keys.send(.left)
        w.window.spin { w.rows == 3 }
        keys.send(.return)
        w.window.spin { w.rows == 5 }
        expect(editor.contents.isExpanded(ContentsSectionKey(aliasesSection, at: .top(.root))))
        keys.send(.return)
        w.window.spin { w.rows == 3 }
        keys.send(.up)
        expectEqual(editor.selectedShapeIDs, [a])
        keys.send(.up)
        expectEqual(editor.selectedShapeIDs, [b])
        expect(w.window.firstResponder === w.table, "keys keep it in the list")
    },
    test("Delete on the section's row deletes its rows' shapes, as selecting it selects them") {
        let editor = try aliasEditor(scheduler: TaskScheduler())
        let (a, _, _, b) = aliasedWidgets(editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 3 }
        try w.focusList()
        let keys = KeyDriver(w.window)
        for _ in 0..<3 { keys.send(.down) }
        keys.send(.delete)
        expectEqual(editor.document.shapes.map(\.id), [a, b])
        w.window.spin { w.shown == ["B", "A"] }
    },
    test("a section's row doesn't drag, and a drag over it points nowhere") {
        let editor = try aliasEditor(scheduler: TaskScheduler())
        _ = aliasedWidgets(editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 3 }
        expect(try w.writer(ofRow: 3) == nil, "the section's row")
        expect(try w.writer(ofRow: 1) != nil, "B's")
        let (target, drag) = try w.drag(rows: [1], over: 3, at: 0.5)
        defer { drag.pasteboard.releaseGlobally() }
        expectEqual(target.draggingEntered(drag), [])
        expect(editor.document.shapes.allSatisfy { editor.contents.dropZone(for: $0.id) == nil }, "no row ringed or lined")
    },
    test("what the person turns a section to stays: another board shown and back, the list made again") {
        let editor = try aliasEditor([PocketsPlugin()], scheduler: TaskScheduler())
        _ = aliasedWidgets(editor)
        let pocket = editor.add(Pocket(CGRect(x: 0, y: 300, width: 100, height: 60)))
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 4 }
        try w.expand(w.row("Aliases · 2"))
        w.window.spin { w.rows == 6 }
        editor.showBoard(BoardID(owner: pocket))
        w.window.spin { w.table == nil }
        editor.showBoard(.root)
        w.window.spin { w.rows == 6 }
        expectEqual(w.shown, ["pocket", "B", "A", "Aliases · 2", "  Y", "  X"])
    },
    test("under a pocket's row: its board's aliases gather in a section of the pocket's level, and follow that board") {
        let x = ShapeRecord(Alias("X", frame: CGRect(x: 200, y: 0, width: 100, height: 30)))
        let y = ShapeRecord(Alias("Y", frame: CGRect(x: 400, y: 0, width: 100, height: 30)))
        let c = ShapeRecord(Widget(CGRect(x: 0, y: 0, width: 100, height: 60), name: "C"))
        let pocket = ShapeRecord(Pocket(CGRect(x: 0, y: 0, width: 100, height: 60)))
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(pocket)]),
                              children: [pocket.id: CanvasDocument(shapes: [AnyShapeRecord(c), AnyShapeRecord(x)])])
        let editor = try aliasEditor([PocketsPlugin()], file: file, scheduler: TaskScheduler())
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 1 }
        try w.expand(1)
        w.window.spin { w.rows == 3 }
        expectEqual(w.shown, ["pocket", "  C", "  Aliases · 1"])
        let inside = BoardID(owner: pocket.id)
        let log = standardError {
            editor.transact(on: inside, "Add") { $0.insert(y) }
            w.window.spin { w.shown == ["pocket", "  C", "  Aliases · 2"] }
            try? w.expand(3)
            w.window.spin { w.shown == ["pocket", "  C", "  Aliases · 2", "    Y", "    X"] }
            expect(editor.contents.isExpanded(ContentsSectionKey(aliasesSection, at: .under(pocket.id))))
            editor.transact(on: inside, "Delete") { $0.delete([x.id]) }
            w.window.spin { w.shown == ["pocket", "  C", "  Aliases · 1", "    Y"] }
            editor.transact(on: inside, "Delete") { $0.delete([y.id]) }
            w.window.spin { w.shown == ["pocket", "  C"] }
            w.window.settle()
        }
        expect(!log.contains(tableReentrancyWarning), "AppKit logged: \(log)")
    },
    test("a section closed and opened again reads what came under its rows meanwhile") {
        let editor = try aliasEditor(scheduler: TaskScheduler())
        let x = editor.add(Alias("X"))
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 1 }
        try w.expand(1)
        w.window.spin { w.rows == 2 }
        editor.add(Pin("on X", on: x))
        w.window.spin { (try? w.isExpandable(2)) == true }
        try w.expand(2)
        w.window.spin { w.shown == ["Aliases · 1", "  X", "    on X"] }
        try w.collapse(1)
        w.window.spin { w.rows == 1 }
        editor.add(Pin("also on X", on: x))
        try w.expand(1)
        w.window.spin { w.shown == ["Aliases · 1", "  X", "    also on X", "    on X"] }
    },
])

/// A board's outline in its own panel (the path's crumb menus), with a keyboard of its own, in an
/// unshown window.
@MainActor
final class OutlineWindow {
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let hosting: NSHostingView<ContentsOutline>
    let keyboard = OutlineKeyboard()
    private let picks = Picks()

    /// The shapes clicks picked, in order.
    @MainActor final class Picks {
        var ids: [ShapeID] = []
    }

    init(_ editor: CanvasEditor, highlighted: ShapeID? = nil) {
        let picks = picks
        hosting = NSHostingView(rootView: ContentsOutline(editor: editor, board: .root, highlighted: highlighted, maxHeight: 360,
                                                          keyboard: keyboard) { picks.ids.append($0) })
        hosting.frame = CGRect(x: 0, y: 0, width: 300, height: 400)
        window.contentView = hosting
        window.settle()
    }

    var picked: [ShapeID] { picks.ids }

    /// Its buttons, top to bottom, then left to right: each row's, after its triangle if it has one.
    var buttons: [NSButton] {
        hosting.descendants(NSButton.self).map { ($0, hosting.convert($0.bounds, from: $0)) }
            .sorted { (hosting.isFlipped ? $0.1.minY : -$0.1.maxY, $0.1.minX) < (hosting.isFlipped ? $1.1.minY : -$1.1.maxY, $1.1.minX) }
            .map(\.0)
    }
}

@MainActor let outlineSectionTests = Suite("Table of contents: sections in a board's outline", [
    test("a board's outline gathers a section after its level's rows, closed; a click on it opens and closes it, picking nothing") {
        let editor = try aliasEditor(scheduler: TaskScheduler())
        _ = aliasedWidgets(editor)
        let o = OutlineWindow(editor)
        // B, A, the section's triangle and row.
        o.window.spin { o.buttons.count == 4 }
        o.buttons[3].performClick(nil)                      // the section's row
        o.window.spin { o.buttons.count == 6 }               // and Y, X
        expectEqual(o.picked, [])
        o.buttons[2].performClick(nil)                      // its triangle
        o.window.spin { o.buttons.count == 4 }
    },
    test("by keys: a section's row takes the keyboard with no shape, called by its title; → and .activate open it, ← closes it") {
        let editor = try aliasEditor(scheduler: TaskScheduler())
        let (_, x, y, _) = aliasedWidgets(editor)
        let o = OutlineWindow(editor)
        o.window.spin { o.buttons.count == 4 }
        o.keyboard.take()
        o.window.spin { o.keyboard.rowName != nil }
        o.keyboard.press(.down)
        o.keyboard.press(.down)
        o.window.settle()
        expectEqual(o.keyboard.row, nil, "the section's row has no shape")
        expectEqual(o.keyboard.rowName, "Aliases")
        expect(o.keyboard.isTaken)
        o.keyboard.press(.activate)
        o.window.spin { o.buttons.count == 6 }
        o.keyboard.press(.down)
        o.window.settle()
        expectEqual(o.keyboard.row, y)
        o.keyboard.press(.down)
        expectEqual(o.keyboard.row, x)
        o.keyboard.press(.left)                             // to the row it's under: the section's
        o.window.settle()
        expectEqual(o.keyboard.rowName, "Aliases")
        o.keyboard.press(.left)
        o.window.spin { o.buttons.count == 4 }
        o.keyboard.press(.right)
        o.window.spin { o.buttons.count == 6 }
        o.keyboard.press(.right)                            // into it
        o.window.settle()
        expectEqual(o.keyboard.row, y)
        o.keyboard.press(.activate)                         // a row's is the host's: nothing here
        o.window.settle()
        expectEqual(o.keyboard.row, y)
        expectEqual(o.picked, [])
    },
    test("a section holding the highlighted row (the way you came) starts open") {
        let editor = try aliasEditor(scheduler: TaskScheduler())
        let (_, x, _, _) = aliasedWidgets(editor)
        let o = OutlineWindow(editor, highlighted: x)
        o.window.spin { o.buttons.count == 6 }
        o.keyboard.take()
        o.window.spin { o.keyboard.row != nil }
        expectEqual(o.keyboard.row, x, "the keyboard on the way you came")
    },
])
