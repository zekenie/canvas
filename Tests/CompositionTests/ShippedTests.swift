import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Composition
import Connections
import CoreGraphics
import DetailPanel
import Geometry
import LanguageModels
import Mentions
import References
import Selection
import StickyNotes
import Subboards
import SwiftUI
import TableOfContents
import TestKit
import Titles
import Types
import Validation

@MainActor let shippedTests = Suite("Shipped plugins", [
    test("the shipped plugin list registers without conflicts") {
        _ = try ShippedPlugins.registry(model: ScriptedLanguageModel())
    },
    test("the toolbar is Select V, Hand H, Note N, Subboard B, Frame F, Reference R: arrows are drawn from ports") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        expectEqual(registry.tools.map { ShippedPlugins.help(for: $0, in: registry) },
                    ["Select (V)", "Hand (H)", "Note (N)", "Subboard (B)", "Frame (F)", "Reference (R)"])
    },
    test("a plugin that needs the key asks for Settings with the action the app's menu item sends") {
        expectEqual(AnthropicSettingsView.showSettingsAction, BoardMenus.showSettings)
    },
    test("the editor's language model is the one passed: the app's is Claude Haiku with the key from Settings") {
        let model = ScriptedLanguageModel()
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: model)
        expect(editor.languageModel as? ScriptedLanguageModel === model)
        let shipped = try require(ShippedPlugins.anthropicModel as? AnthropicModel)
        expectEqual(shipped.model, AnthropicModel.haiku)
        expectEqual(shipped.keys, .standard)
    },
    test("the registry report: who contributes what") {
        expectEqual(try ShippedPlugins.registry(model: ScriptedLanguageModel()).report, """
        core                 tool hand · command undo · command redo · command zoomIn · command zoomOut · command zoomToActualSize · command zoomToFit
        keyboard             service KeyboardState · key strokes · key releases · shortcut H → tool hand · shortcut Space → Pan · shortcut ⎋ → Cancel · shortcut ⌘. → Cancel · shortcut ⌘Z → command undo · shortcut ⇧⌘Z → command redo · shortcut ⌘= → command zoomIn · shortcut ⌘- → command zoomOut · shortcut ⌘0 → command zoomToActualSize · shortcut ⇧1 → command zoomToFit
        selection            service SelectionState · service RefusalShake · tool select · shortcut V → tool select · default tool select · outlines · overlay HandlesOverlay · command delete · shortcut ⌫ → command delete · shortcut ⌦ → command delete · command selectAll · shortcut ⌘A → command selectAll · command goBack · shortcut ⌘[ → command goBack · command openSelection · shortcut ⌘↓ → command openSelection · shortcut ↩ → Open Selection · shortcut ⌤ → Open Selection · command zoomToSelection · shortcut ⇧2 → command zoomToSelection · command smartMagnify · shortcut ← → Nudge · shortcut ⇧← → Nudge · shortcut → → Nudge · shortcut ⇧→ → Nudge · shortcut ↑ → Nudge · shortcut ⇧↑ → Nudge · shortcut ↓ → Nudge · shortcut ⇧↓ → Nudge
        topology             service TopologyIndex · edge type stands-for
        arrows               shape arrow v2 · label Arrow → arrow · ContentsRows → arrow · mention layout → arrow · mention text → arrow · type words → arrow · property is → arrow · service ArrowTargeting · service ArrowRowNesting · overlay BindingHintsOverlay
        sticky-notes         shape sticky-note v3 · tool sticky-note · shortcut N → tool sticky-note · tint → sticky-note · DoubleClickPlacement → sticky-note · property title → sticky-note · ShapeTitles → sticky-note · ContentsTitles → sticky-note · ShapeDetails → sticky-note · ContentsRows → sticky-note · ports note-link → sticky-note · mention text → sticky-note · mentionable → sticky-note · ShapeDetails → sticky-note · type words → sticky-note · property schema → sticky-note · property is → sticky-note · channel note-link · edge type note-link
        subboards            shape subboard · tool subboard · shortcut B → tool subboard · tint → subboard · property title → subboard · ShapeTitles → subboard · ContentsTitles → subboard · board → subboard "Untitled Subboard" · ShapeOpening → subboard · ShapeContextMenus → subboard · ShapeDetails → subboard · mentionable → subboard · ShapeDetails → subboard · ContentsRows → subboard · ShapeDetails → subboard · ports subboard-link → subboard · ports on every channel → subboard · channel subboard-link · edge type subboard-link · takes channel container → subboard · CanvasContextMenu · /turn-into-subboard → every shape
        framing              shape frame · tool frame · shortcut F → tool frame · tint → frame · property title → frame · ShapeTitles → frame · ContentsTitles → frame · mentionable → frame · ShapeDetails → frame · ShapeResizing → frame · ContentsRows → frame · ShapeDetails → frame · offers channel container → frame · CanvasContextMenu
        references           service ReferenceState · overlay ReferenceButtonOverlay · CanvasButtons · command goToOriginal · command interpretReference · DetailStatuses · ShapePopovers · CanvasContextMenu · shape reference · tool reference · shortcut R → tool reference · ports on every channel → reference · stands in → reference · referenced-in row → reference · ContentsRows → reference · ShapeDetails → reference · ShapeContextMenus → reference · ValidationRules → reference
        validation           service ValidationEngine · overlay ValidationOverlay · ValidationRules
        adornments           service AdornmentState · service ChipFade · overlay AdornmentOverlay · CanvasButtons · DecorationHits
        detail-panel         service DetailPanelState
        context-menus        service ContextMenuState · secondary-click menu · CanvasContextMenu
        slash-commands       service SlashCommandState
        table-of-contents    service ContentsState
        titles               property title · adornment TitlePill → every shape · /title → every shape · overlay TitleCoverOverlay
        mentions             service MentionState · edge type mention · edges → every shape · overlay MentionFrames · ShapeFaces · CanvasContextMenu
        board-navigation     service BoardCrumbs · command enclosingBoard · shortcut ⌘↑ → command enclosingBoard
        find-in-boards       service FindState · overlay FindOverlay · command find · shortcut ⌘F → command find · command findNext · shortcut ⌘G → command findNext · command findPrevious · shortcut ⇧⌘G → command findPrevious
        title-find           findable title → every shape
        mention-find         findable mention text → every shape · findable mention text over the canvas → every shape
        jump-to              service JumpToState · command jumpTo · shortcut ⌘K → command jumpTo
        transform            service TransformState
        validation-details   DetailStatuses in Issues
        validation-contents  ContentsMarks
        mention-validation   ValidationRules
        title-validation     service TitleIndex · ValidationRules
        clipboard            service ClipboardState · command cut · shortcut ⌘X → command cut · command copy · shortcut ⌘C → command copy · command paste · shortcut ⌘V → command paste · command duplicate · shortcut ⌘D → command duplicate · DragCopies · CanvasContextMenu
        locking              property locked · property locked → every shape · read-only shapes · service LockState · adornment LockChip → every shape · ContentsMarks · CanvasContextMenu · /lock → every shape
        publishing           property public · property public → every shape · public dials · service PublishingState · adornment PublicChip → every shape · CanvasContextMenu · /public /private → every shape · ShapeDetails · ContentsMarks
        types                property schema · property is · edge type is-a · edges → every shape · service TypeIndex · service TypeSync<TypeSchemaProperty> · ShapePopovers · /type → every shape · /is-a → every shape · adornment TypeChips → every shape
        type-validation      ValidationRules
        type-details         ShapeDetails · ShapeDetails
        snapping             service SnapState · translation adjuster
        ports                property channel · service PortState · overlay PortOverlay · CanvasButtons
        arrow-ports          property channel → arrow · edge type arrow · connector → arrow · edges → arrow · ArrowBindingRules
        language-models      service LanguageModelState
        prose-maps           service ProseMapService · overlay ProseMapFrames
        automation           command line draw · command line show · command line kinds · command line measure
        title-names          draw names
        port-edges           draw edges
        validation-checks    draw checks
        mention-texts        draw text text/x-canvas-mentions
        type-names           draw text text/x-canvas-type
        queries              service QueryState · query engine
        query-translation    service QueryTranslator
        title-queries        query names
        board-queries        query board names
        mention-queries      query word :mentions · query word :mentioned-by · query text text/x-canvas-mentions
        validation-queries   query word :invalid · query word :warned
        type-queries         query word :is-a · query text text/x-canvas-type
        selection-queries    query word :selected
        query-commands       command line query · command line query-vocabulary
        neighbors            service NeighborState · outlines
        arrow-lights         neighbor light · neighbor light
        mention-lights       neighbor light · neighbor light
        moving               /move-to /move-near → every shape · ContentsMoves
        reordering           ShapeContextMenus
        """)
    },
    test("the guide shows the registry report as it is") {
        let guide = try String(contentsOf: URL(fileURLWithPath: "docs/plugin-system.md"), encoding: .utf8)
        let lead = "`registry.report` prints who contributes what: the runtime half of the graph, pinned by a test.\n\n```\n"
        let start = try require(guide.range(of: lead), "the guide's report is gone").upperBound
        let end = try require(guide.range(of: "\n```", range: start..<guide.endIndex)).lowerBound
        expectEqual(String(guide[start..<end]), try ShippedPlugins.registry(model: ScriptedLanguageModel()).report)
    },
    test("every placed kind has a panel: a note its header, a subboard its own tab, a frame, an arrow and a reference only their headers; a type note its Schema tab; every nameable kind's header renames it") {
        let h = EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0, model: ScriptedLanguageModel()) }
        let state = try require(h.editor.detailPanel)
        var panels: [String] = []
        for (shortcut, x) in [("n", 1000.0), ("b", 2200), ("f", 2600)] {
            h.key(shortcut)
            h.press(at: CGPoint(x: x, y: 100))
            h.drag(to: CGPoint(x: x + 150, y: 300))
            h.release()
            let layout = state.layout(for: try require(h.editor.selection.flatMap { h.editor.document[$0] }))
            panels.append("\(layout.headerText): \(layout.tabs.map(\.title).joined(separator: ", "))")
        }
        // No tool places an arrow (a port's drag draws one): its header is its kind's label.
        let arrow = h.add(Arrow(start: .free(CGPoint(x: 700, y: 100)), end: .free(CGPoint(x: 850, y: 300))))
        let layout = state.layout(for: try require(h.editor.document[arrow]))
        panels.append("\(layout.headerText): \(layout.tabs.map(\.title).joined(separator: ", "))")
        // A reference's header says what it stands for: an empty pill, nothing yet; the Reference tool places one.
        h.key("r")
        h.press(at: CGPoint(x: 3000, y: 100))
        h.release()
        let reference = try require(h.editor.editingShapeID)
        let referenceLayout = state.layout(for: try require(h.editor.document[reference]))
        panels.append("\(referenceLayout.headerText): \(referenceLayout.tabs.map(\.title).joined(separator: ", "))")
        // Every header of a kind that can be named renames it: an untitled shape's shows the
        // placeholder. A note placed empty has no issue: its row says Empty Note.
        // A note that's a type has its schema's tab.
        let type = h.editor.addTypeNote(TypeSchemaProperty.starter, frame: CGRect(x: 3400, y: 100, width: 200, height: 200))
        let typeLayout = state.layout(for: try require(h.editor.document[type]))
        panels.append("\(typeLayout.headerText): \(typeLayout.tabs.map(\.title).joined(separator: ", "))")
        expectEqual(panels, ["(Note): ", "(Untitled Subboard): Board", "(Untitled Frame): ", "Arrow: ", "Reference: ", "(Note): Schema"])
    },
    test("the table of contents lists the welcome board: each note by its text, each arrow under the note it starts from") {
        let editor = ShippedPlugins.makeEditor(scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        let entries = try require(editor.tableOfContents).entries
        expectEqual(entries.map { $0.label?.text }, WelcomeBoard.texts)
        expectEqual(entries.map(\.symbol), Array(repeating: "note.text", count: 6))
        expectEqual(entries.map { $0.children?.map { $0.label?.text } }, [["Arrow"], nil, nil, ["Arrow"], ["Arrow"], nil])
        expectEqual(entries[0].children?.first?.symbol, "arrow.up.right")
    },
    test("the table of contents marks each shape with issues in its outline's color: a note with too long a title orange, a type note whose schema isn't JSON red") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        let long = editor.add(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: "Milk"), title: String(repeating: "Groceries ", count: 9))
        let broken = editor.addTypeNote("", frame: CGRect(x: 300, y: 0, width: 200, height: 200))
        let written = editor.add(StickyNote(frame: CGRect(x: 600, y: 0, width: 200, height: 200), text: "Hi"))
        let empty = editor.add(StickyNote(frame: CGRect(x: 900, y: 0, width: 200, height: 200)))
        let marks = Dictionary(uniqueKeysWithValues: try require(editor.tableOfContents).entries.map { ($0.id, $0.marks) })
        expectEqual(marks[long], [ContentsMark(color: Color(nsColor: Severity.warning.color), help: "Title is 90 characters long, and should be at most 80.")])
        expectEqual(marks[empty], [], "an empty note is no issue: its row says Empty Note")
        expectEqual(marks[broken], [ContentsMark(color: Color(nsColor: Severity.error.color), help: "Invalid JSON: expected a value at line 1, column 1.")])
        expectEqual(marks[written], [])
    },
    test("a title past 80 characters breaks its schema, which is a warning: an orange outline, a line in Issues, an orange dot") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        let long = String(repeating: "Groceries ", count: 9)       // 90 characters
        let note = editor.add(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: "Milk"), title: long)
        // Another title: two shapes of one title are warned about that too (TitleValidationPlugin).
        let subboard = editor.add(Subboard(frame: CGRect(x: 400, y: 100, width: 240, height: 160)), title: String(repeating: "Errands!! ", count: 9))
        let warning = ValidationIssue.warning("Title is 90 characters long, and should be at most 80.", field: "title")
        expectEqual(editor.validation?.result(for: note)?.issues, [warning])
        expectEqual(editor.validation?.result(for: subboard)?.issues, [warning], "a subboard's title is Titles' as a note's is")
        let panel = try require(editor.detailPanel)
        expectEqual(panel.layout(for: try require(editor.document[note])).statuses(in: .of(IssuesTab.self)),
                    [DetailStatus(warning.message, tone: .warning)])
        let marks = Dictionary(uniqueKeysWithValues: try require(editor.tableOfContents).entries.map { ($0.id, $0.marks) })
        expectEqual(marks[note], [ContentsMark(color: Color(nsColor: Severity.warning.color), help: warning.message)])
        // The note's top edge, 7 points out: the 4 the outlines stand off the shape by, and the ring's 3
        // beyond them, clear of the pill above it. Where the ring would be on the edge's 3 is clear.
        let rep = renderBitmap(editor, size: CGSize(width: 700, height: 340))
        let outline = pixel(rep, at: CGPoint(x: 200, y: 93))
        expect(outline[0] > 200 && outline[1] > 110 && outline[2] < 100, "orange: \(outline)")
        expect(pixel(rep, at: CGPoint(x: 200, y: 97))[2] > 150, "clear of the shape, between it and its ring: \(pixel(rep, at: CGPoint(x: 200, y: 97)))")
        // Kept as typed, the title still shows (cut off); back within bounds, the warning goes.
        expectEqual(editor.document[note].flatMap(editor.registry.title(of:)), String(long.dropLast()))
        editor.transact { $0.update(note) { $0[TitleProperty.self] = "Groceries" } }
        expectEqual(editor.validation?.result(for: note), nil)
    },
    test("a note and a subboard of one title each warn (TitleValidationPlugin): a line in Issues, an orange dot; renamed apart, neither") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        let note = editor.add(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: "Milk"), title: "Kitchen")
        let subboard = editor.add(Subboard(frame: CGRect(x: 400, y: 100, width: 240, height: 160)), title: "Kitchen")
        let untitled = editor.add(StickyNote(frame: CGRect(x: 700, y: 100, width: 200, height: 200), text: "Kitchen"))
        let shared = ValidationIssue.warning("“Kitchen” is another shape’s title too.", field: "title")
        expectEqual(editor.validation?.result(for: note)?.issues, [shared])
        expectEqual(editor.validation?.result(for: subboard)?.issues, [shared])
        expectEqual(editor.validation?.result(for: untitled), nil, "a note's first line is no title")
        let panel = try require(editor.detailPanel)
        expectEqual(panel.layout(for: try require(editor.document[note])).statuses(in: .of(IssuesTab.self)),
                    [DetailStatus(shared.message, tone: .warning)])
        let marks = Dictionary(uniqueKeysWithValues: try require(editor.tableOfContents).entries.map { ($0.id, $0.marks) })
        expectEqual(marks[subboard], [ContentsMark(color: Color(nsColor: Severity.warning.color), help: shared.message)])
        editor.transact { $0.update(note) { $0[TitleProperty.self] = "Pantry" } }
        expectEqual(editor.validation?.result(for: note), nil)
        expectEqual(editor.validation?.result(for: subboard), nil)
        let after = Dictionary(uniqueKeysWithValues: try require(editor.tableOfContents).entries.map { ($0.id, $0.marks) })
        expectEqual(after[subboard], [], "the subboard's dot goes though the commit didn't change it")
    },
    test("a note that mentions an arrow, or holds what looks like a mention and isn't, warns (MentionValidationPlugin): a line in Issues, an orange dot") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        let arrow = editor.add(Arrow(start: .free(CGPoint(x: 100, y: 400)), end: .free(CGPoint(x: 300, y: 400))))
        let groceries = editor.add(Subboard(frame: CGRect(x: 400, y: 100, width: 240, height: 160)), title: "Buy milk")
        let note = editor.add(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200),
                                         text: MentionText([.text("See "), .mention(arrow, label: "Arrow"), .text(" before "), .mention(groceries, label: "Buy milk"),
                                                            .text(" and "), .mention(ShapeID(), label: "Gone")])))
        let unmentionable = ValidationIssue.warning("“Arrow” can’t be mentioned.", field: "text")
        expectEqual(editor.validation?.result(for: note)?.issues, [unmentionable], "a subboard can be mentioned, and a missing shape's pill says so")
        let panel = try require(editor.detailPanel)
        expectEqual(panel.layout(for: try require(editor.document[note])).statuses(in: .of(IssuesTab.self)),
                    [DetailStatus(unmentionable.message, tone: .warning)])
        let marks = Dictionary(uniqueKeysWithValues: try require(editor.tableOfContents).entries.map { ($0.id, $0.marks) })
        expectEqual(marks[note], [ContentsMark(color: Color(nsColor: Severity.warning.color), help: unmentionable.message)])
        // Deleting the arrow takes the warning with it; the pill is missing, which says so.
        editor.transact { $0.delete([arrow]) }
        expectEqual(editor.validation?.result(for: note), nil)
        editor.transact { $0.update(note, as: StickyNote.self) { $0.props.text = MentionText(stored: "Ask @[Buy milk](shape: \(groceries.rawValue.uuidString))") } }
        expectEqual(editor.validation?.result(for: note)?.issues, [.warning("“@[Buy milk](shape: \(groceries.rawValue.uuidString.prefix(11))…” isn’t a mention.", field: "text")])
    },
    test("the welcome board: six notes, three arrows, no warnings") {
        let editor = ShippedPlugins.makeEditor(scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        expectEqual(editor.document.shapes.filter { $0.kind == StickyNote.kind }.count, 6)
        expectEqual(editor.document.shapes.filter { $0.kind == Arrow.kind }.count, 3)
        expectEqual(editor.validation?.results.count, 0)
    },
    test("the shipped welcome board differs from the POC's only in the third note, which mentions H and no longer says dragging the background pans, and the fourth and fifth, which link notes from their dots, the arrow tool gone") {
        let shipped = WelcomeBoard.texts
        expectEqual(shipped.count, pocWelcomeTexts.count)
        expectEqual(shipped.indices.filter { shipped[$0] != pocWelcomeTexts[$0] }, [2, 3, 4])
        expect(shipped[2].contains("Press H"))
        expect(!shipped[2].contains("pans too"))
        expect(!shipped[3].contains("Press A") && shipped[3].contains("dots"))
        expect(!shipped[3].contains("Press O"))
        expect(!shipped[4].contains("⌘"), "a connection released on nothing isn't drawn, so there's nothing not to attach")
        let notes = WelcomeBoard.document().shapes.compactMap { $0.typed(as: StickyNote.self)?.props.text.stored }
        expectEqual(notes, shipped)
    },
    test("going to a note, or a type note, in view at 70% leaves the camera: a note's text reads there") {
        let h = EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0, model: ScriptedLanguageModel()) }
        h.editor.viewportDidResize(to: CGSize(width: 1200, height: 800))
        let note = h.editor.add(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: "Hi"))
        let type = h.editor.addTypeNote(TypeSchemaProperty.starter, text: "A pet", frame: CGRect(x: 400, y: 100, width: 200, height: 200))
        h.editor.camera = Camera(zoom: 0.7)
        for id in [note, type] {
            h.editor.goTo([id])
            h.wait(300)
            expectEqual(h.editor.camera.zoom, 0.7)
        }
    },
])

extension DetailLayout {
    /// What the header reads: a `DetailHeader`'s title, a `TitleHeader`'s, or, while a title field
    /// is empty, its placeholder in parentheses.
    var headerText: String {
        if let header { return header.title }
        if let reference = header(as: ReferenceHeader.self) { return reference.content.title }
        guard let titled = header(as: TitleHeader.self) else { return "?" }
        return titled.title.isEmpty ? "(\(titled.placeholder ?? kindName))" : titled.title
    }
}
