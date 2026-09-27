import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Checklists
import Composition
import CoreGraphics
import DetailPanel
import Geometry
import Selection
import StickyNotes
import SwiftUI
import TableOfContents
import TaskCards
import TestKit
import Titles
import Validation
import ValidationDetails

@MainActor let shippedTests = Suite("Shipped plugins", [
    test("the shipped plugin list registers without conflicts") {
        _ = try ShippedPlugins.registry()
    },
    test("the toolbar is Select V, Hand H, Arrow A, Note N, Ellipse O, Task T, Rectangle R, Line L, Eraser E") {
        let registry = try ShippedPlugins.registry()
        expectEqual(registry.tools.map { ShippedPlugins.help(for: $0, in: registry) }, ["Select (V)", "Hand (H)", "Arrow (A)", "Note (N)", "Ellipse (O)", "Task (T)", "Rectangle (R)", "Line (L)", "Eraser (E)"])
    },
    test("the registry report: who contributes what") {
        expectEqual(try ShippedPlugins.registry().report, """
        core                 tool hand
        keyboard             service KeyboardState · key strokes · shortcut H → tool hand · shortcut ⎋ → Cancel · shortcut ⌘. → Cancel
        selection            service SelectionState · tool select · shortcut V → tool select · default tool select · outlines · overlay HandlesOverlay · command delete · shortcut ⌫ → command delete · shortcut ⌦ → command delete · command selectAll · shortcut ⌘A → command selectAll · command goBack · shortcut ⌘[ → command goBack · shortcut ↩ → Edit Selection · shortcut ⌤ → Edit Selection
        arrows               shape arrow · ContentsRows → arrow · service ArrowTargeting · tool arrow · shortcut A → tool arrow · overlay BindingHintsOverlay
        sticky-notes         shape sticky-note v2 · tool sticky-note · shortcut N → tool sticky-note · DoubleClickPlacement → sticky-note · ValidationRules → sticky-note · property checklist → sticky-note · ShapeChecklists → sticky-note · ShapeDetails → sticky-note · ShapeContextMenus → sticky-note · property title → sticky-note · ShapeTitles → sticky-note · ContentsTitles → sticky-note · ShapeDetails → sticky-note · ContentsRows → sticky-note
        ellipses             shape ellipse · tool ellipse · shortcut O → tool ellipse
        task-cards           shape task-card v3 · tool task-card · shortcut T → tool task-card · ValidationRules → task-card · ShapeDetails → task-card · ShapeContextMenus → task-card · ContentsRows → task-card · property checklist → task-card · ShapeChecklists → task-card · ShapeDetails → task-card · ShapeContextMenus → task-card · property title → task-card · ShapeTitles → task-card · ContentsTitles → task-card
        validation           service ValidationEngine · overlay ValidationOverlay · ValidationRules
        detail-panel         service DetailPanelState · ShapeDetails
        context-menus        service ContextMenuState · secondary-click menu
        table-of-contents    service ContentsState
        checklists           property checklist · overlay ChecklistOverlay
        titles               property title · service TitleState · overlay TitleOverlay
        validation-details   DetailStatuses in Issues
        validation-contents  ContentsMarks
        clipboard            service ClipboardState · command cut · shortcut ⌘X → command cut · command copy · shortcut ⌘C → command copy · command paste · shortcut ⌘V → command paste · CanvasContextMenu
        locking              property locked · property locked → every shape · read-only shapes · service LockState · overlay LockOverlay · CanvasButtons · CanvasContextMenu
        rectangles           shape rectangle · tool rectangle · shortcut R → tool rectangle
        polylines            shape polyline · tool polyline · shortcut L → tool polyline
        eraser               tool eraser · shortcut E → tool eraser
        ellipse-titles       ShapeTitles → ellipse · ContentsTitles → ellipse
        reordering           ShapeContextMenus
        """)
    },
    test("every placed kind has a panel: a note its Checklist and Arrange (and Issues, empty), a task its own tabs too, other boxes Arrange, an arrow only its header") {
        let h = EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0) }
        let state = try require(h.editor.detailPanel)
        var panels: [String] = []
        for (shortcut, x) in [("o", 100.0), ("r", 400), ("a", 700), ("n", 1000), ("t", 1400)] {
            h.key(shortcut)
            h.press(at: CGPoint(x: x, y: 100))
            h.drag(to: CGPoint(x: x + 150, y: 300))
            h.release()
            let layout = state.layout(for: try require(h.editor.selection.flatMap { h.editor.document[$0] }))
            panels.append("\(layout.headerText): \(layout.tabs.map(\.title).joined(separator: ", "))")
        }
        // A note's and a task's headers rename them: an untitled note's shows the placeholder. A
        // note placed is empty, which is a warning, so it has Issues until it's written in.
        expectEqual(panels, ["Ellipse: Arrange", "Rectangle: Arrange", "Arrow: ", "(Note): Checklist, Arrange, Issues",
                             "New Task: Task, Checklist, Style, Arrange"])
    },
    test("a long title's pill stays clear of the checklist chip, though neither plugin knows the other's size") {
        // A note with its checklist (the chip, on its top-right corner), its long title (the pill,
        // above its top-left corner and as wide as the note), or neither; its text keeps it from
        // being empty, and outlined.
        @MainActor func render(checklist: Bool, title: Bool) -> NSBitmapImageRep {
            var note = AnyShapeRecord(ShapeRecord(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: "Buy milk")))
            note[TitleProperty.self] = title ? "A title much longer than the note is wide" : nil
            note[ChecklistProperty.self] = checklist ? [ChecklistItem(text: "oat milk")] : []
            let editor = ShippedPlugins.makeEditor(document: CanvasDocument(shapes: [note]), scheduler: ManualScheduler())
            return renderBitmap(editor, size: CGSize(width: 400, height: 340))
        }
        let plain = render(checklist: false, title: false)
        let chip = render(checklist: true, title: false), pill = render(checklist: false, title: true)
        expect(changedPixels(plain, chip, in: CGRect(x: 250, y: 90, width: 70, height: 20)) > 100, "the chip")
        expect(changedPixels(plain, pill, in: CGRect(x: 100, y: 75, width: 190, height: 12)) > 1000, "the pill, to the note's right edge")
        var both = 0
        for y in 60..<130 {
            for x in 90..<330 {
                let point = CGPoint(x: x, y: y), under = pixel(plain, at: point)
                if pixel(chip, at: point) != under && pixel(pill, at: point) != under { both += 1 }
            }
        }
        expectEqual(both, 0, "no pixel is both the pill's and the chip's")
    },
    test("a line drawn with L is a Line in the panel, with nothing but its header") {
        let h = EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0) }
        let state = try require(h.editor.detailPanel)
        h.key("l")
        h.press(at: CGPoint(x: 100, y: 100))
        h.drag(to: CGPoint(x: 300, y: 100))
        h.release()
        h.key("v")
        h.click(at: CGPoint(x: 300, y: 100))
        let layout = state.layout(for: try require(h.editor.selection.flatMap { h.editor.document[$0] }))
        expectEqual(layout.header?.title, "Line")
        expectEqual(layout.tabs.count, 0)
    },
    test("the table of contents lists the welcome board: each note by its text, each arrow under the note it starts from") {
        let editor = ShippedPlugins.makeEditor(scheduler: ManualScheduler())
        let entries = try require(editor.tableOfContents).entries
        expectEqual(entries.map { $0.label?.text }, WelcomeBoard.texts)
        expectEqual(entries.map(\.symbol), Array(repeating: "note.text", count: 6))
        expectEqual(entries.map { $0.children?.map { $0.label?.text } }, [["Arrow"], nil, nil, ["Arrow"], ["Arrow"], nil])
        expectEqual(entries[0].children?.first?.symbol, "arrow.up.right")
    },
    test("the table of contents marks each shape with issues in its outline's color: an empty note orange, an untitled task red") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler())
        let empty = editor.add(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200)))
        let untitled = editor.add(TaskCard(frame: CGRect(x: 300, y: 0, width: 240, height: 200)))
        let written = editor.add(StickyNote(frame: CGRect(x: 600, y: 0, width: 200, height: 200), text: "Hi"))
        let marks = Dictionary(uniqueKeysWithValues: try require(editor.tableOfContents).entries.map { ($0.id, $0.marks) })
        expectEqual(marks[empty], [ContentsMark(color: Color(nsColor: Severity.warning.color), help: "This note is empty.")])
        expectEqual(marks[untitled], [ContentsMark(color: Color(nsColor: Severity.error.color), help: "A task needs a title.")])
        expectEqual(marks[written], [])
    },
    test("a title past 80 characters breaks its schema, which is a warning: an orange outline, a line in Issues, an orange dot") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler())
        let long = String(repeating: "Groceries ", count: 9)       // 90 characters
        let note = editor.add(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: "Milk"), title: long)
        let task = editor.add(TaskCard(frame: CGRect(x: 400, y: 100, width: 240, height: 200)), title: long)
        let warning = ValidationIssue.warning("Title is 90 characters long, and should be at most 80.", field: "title")
        expectEqual(editor.validation?.result(for: note)?.issues, [warning])
        expectEqual(editor.validation?.result(for: task)?.issues, [warning], "a task's title is Titles' as a note's is")
        let panel = try require(editor.detailPanel)
        expectEqual(panel.layout(for: try require(editor.document[note])).statuses(in: .of(IssuesTab.self)),
                    [DetailStatus(warning.message, tone: .warning)])
        let marks = Dictionary(uniqueKeysWithValues: try require(editor.tableOfContents).entries.map { ($0.id, $0.marks) })
        expectEqual(marks[note], [ContentsMark(color: Color(nsColor: Severity.warning.color), help: warning.message)])
        // The note's top edge, 3 points out, clear of the pill above it.
        let outline = pixel(renderBitmap(editor, size: CGSize(width: 700, height: 340)), at: CGPoint(x: 200, y: 97))
        expect(outline[0] > 200 && outline[1] > 110 && outline[2] < 100, "orange: \(outline)")
        // Kept as typed, the title still shows (cut off); back within bounds, the warning goes.
        expectEqual(editor.document[note].flatMap(editor.registry.title(of:)), String(long.dropLast()))
        editor.transact { $0.update(note) { $0[TitleProperty.self] = "Groceries" } }
        expectEqual(editor.validation?.result(for: note), nil)
    },
    test("the welcome board: six notes, three arrows, no warnings") {
        let editor = ShippedPlugins.makeEditor(scheduler: ManualScheduler())
        expectEqual(editor.document.shapes.filter { $0.kind == StickyNote.kind }.count, 6)
        expectEqual(editor.document.shapes.filter { $0.kind == Arrow.kind }.count, 3)
        expectEqual(editor.validation?.results.count, 0)
    },
    test("the shipped welcome board differs from the POC's only in the third note, which mentions H and no longer says dragging the background pans") {
        let shipped = WelcomeBoard.texts
        expectEqual(shipped.count, pocWelcomeTexts.count)
        expectEqual(shipped.indices.filter { shipped[$0] != pocWelcomeTexts[$0] }, [2])
        expect(shipped[2].contains("Press H"))
        expect(!shipped[2].contains("pans too"))
        let notes = WelcomeBoard.document().shapes.compactMap { $0.typed(as: StickyNote.self)?.props.text }
        expectEqual(notes, shipped)
    },
    test("O then a drag places an ellipse and moves it into place") {
        let h = EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0) }
        h.key("o")
        h.press(at: CGPoint(x: 300, y: 300))
        h.drag(to: CGPoint(x: 340, y: 320))
        h.release()
        expectEqual(h.editor.document.shapes.first?.box, CGRect(x: 240, y: 250, width: 200, height: 140))
        expectEqual(h.editor.currentToolID, .select)
    },
])

extension DetailLayout {
    /// What the header reads: a `DetailHeader`'s title, a `TitleHeader`'s, or, while a title field
    /// is empty, its placeholder in parentheses.
    var headerText: String {
        if let header { return header.title }
        guard let titled = header(as: TitleHeader.self) else { return "?" }
        return titled.title.isEmpty ? "(\(titled.placeholder ?? kindName))" : titled.title
    }
}
