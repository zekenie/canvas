import AppKit
import Arrows
import Boards
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Clipboard
import CoreGraphics
import DetailPanel
import Geometry
import LanguageModels
import Mentions
import QueryTranslation
import References
import Selection
import ShippedTesting
import StickyNotes
import Subboards
import SwiftUI
import TableOfContents
import TestKit
import Titles
import Types
import Validation

@MainActor let shippedTests = Suite("Shipped plugins", [
    test("the product's list loads: each plugin it names is found in this executable and made, in its order, and the list registers without conflicts") {
        let names = try require(ShippedList.names, "the build puts the list in an executable whose line ends + shipped")
        expectEqual(names.first, "Keyboard.KeyboardPlugin")
        expectEqual(Set(names).count, names.count, "each once")
        let plugins = try ShippedList.plugins(supplying: [ClipboardPlugin(pasteboard: ShippedPlugins.pasteboard), LanguageModelsPlugin(model: ScriptedLanguageModel())])
        expectEqual(plugins.map { String(reflecting: type(of: $0)) }, names, "every line a plugin of that type, in the list's order")
        expectEqual(ShippedPlugins.plugins(model: ScriptedLanguageModel()).map(\.id), plugins.map(\.id), "which is what every test here is given")
        _ = try Registry(plugins: plugins)
    },
    test("nothing but the app is made of the plugins that reach outside the process: the list won't load without a pasteboard's and a model's of the caller's own") {
        let outward = ["Clipboard.ClipboardPlugin", "LanguageModels.LanguageModelsPlugin"]
        expectThrows(ShippedListError.notSupplied(outward)) { _ = try ShippedList.plugins(supplying: []) }
        expectThrows(ShippedListError.notSupplied([outward[1]])) { _ = try ShippedList.plugins(supplying: [ClipboardPlugin(pasteboard: ShippedPlugins.pasteboard)]) }
        expectThrows(ShippedListError.notSupplied([outward[0]])) { _ = try ShippedList.plugins(supplying: [LanguageModelsPlugin(model: ScriptedLanguageModel())]) }
        // The model handed over is the one the editor asks: never the app's.
        let model = ScriptedLanguageModel()
        let plugins = try ShippedList.plugins(supplying: [ClipboardPlugin(pasteboard: ShippedPlugins.pasteboard), LanguageModelsPlugin(model: model)])
        let editor = CanvasEditor(registry: try Registry(plugins: plugins), document: CanvasDocument(), scheduler: ManualScheduler())
        expect(editor.languageModel as? ScriptedLanguageModel === model)
        // Any other listed plugin can be handed over too, and takes its place; one the list hasn't is refused.
        let asked = QueryTranslationPlugin(prompt: "Ask.", referenceRule: "")
        let swapped = try ShippedList.plugins(supplying: [ClipboardPlugin(pasteboard: ShippedPlugins.pasteboard), LanguageModelsPlugin(model: model), asked])
        expectEqual(swapped.map(\.id), plugins.map(\.id))
        expectThrows(ShippedListError.notInList(["CanvasTesting.Contributor"])) {
            _ = try ShippedList.plugins(supplying: [ClipboardPlugin(pasteboard: ShippedPlugins.pasteboard), LanguageModelsPlugin(model: model), Contributor(id: "more") { _ in }])
        }
    },
    test("a test that names no pasteboard copies to one of its own, never the user's: its editors share it, and it goes as the test ends") {
        var taken: NSPasteboard?
        var log: [String] = []
        let failures = runAsTest({
            let first = ShippedPlugins.makeEditor(model: ScriptedLanguageModel())
            let second = ShippedPlugins.makeEditor(document: CanvasDocument(), model: ScriptedLanguageModel())
            let note = try require(first.document.shapes.first { $0.kind == StickyNote.kind }?.id)
            expectEqual(first.copy([note]), [note])
            second.paste()
            expectEqual(second.document.shapes.count, 1, "pasted from where the first editor copied to")
            taken = ShippedPlugins.pasteboard
            expect(taken?.name != .general, "never the user's")
            expect(!(taken?.types ?? []).isEmpty, "the copy is on it")
            afterThisTest { log.append("ended") }
        }, afterEach: { log.append("afterEach") })
        expectEqual(failures, [])
        expectEqual(log, ["afterEach", "ended"], "what a test asks to run as it ends runs after afterEach")
        let pasteboard = try require(taken)
        expectEqual(pasteboard.types ?? [], [], "released as its test ended")
        expect(ShippedPlugins.pasteboard !== pasteboard, "the next test's is another")
    },
    test("the toolbar is Select V, Hand H, Note N, Subboard B, Frame F, Reference R: arrows are drawn from ports") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        expectEqual(registry.tools.map { registry.toolTip(for: $0) },
                    ["Select (V)", "Hand (H)", "Note (N)", "Subboard (B)", "Frame (F)", "Reference (R)"])
    },
    test("what the window puts around the canvas is the plugins': the path, then the palette over it, the panel as the inspector, the board's name as the subtitle, and the key's pane in Settings") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        expectEqual(registry.hostOverlays.map(\.alignment), [.top, .center], "Boards' path at the top, Jump To's palette over the whole canvas")
        let inside = BoardID(owner: ShapeID())
        expectEqual(registry.hostCoveredTop(on: inside), BoardPath.coveredHeight(on: inside), "a fit leaves the path's pill clear")
        expectEqual(registry.hostCoveredTop(on: .root), 0)
        expect(registry.hostInspector != nil, "the detail panel")
        let nest = NestedFile()
        let editor = CanvasEditor(registry: registry, file: nest.file, scheduler: ManualScheduler())
        expectEqual(registry.windowSubtitle(for: editor), nil, "the root is the window's title's to name")
        expect(editor.showBoard(nest.sBoard))
        expectEqual(registry.windowSubtitle(for: editor), "Plans", "Boards' name for the board shown")
        expectEqual(registry.settingsPanes.count, 0, "a scripted model needs no key")
        // The app's model brings the key's pane (made only when Settings opens: nothing reads the key here).
        expectEqual(try Registry(plugins: [LanguageModelsPlugin()]).settingsPanes.map(\.title), ["Anthropic"])
    },
    test("and what the app takes besides is the plugins' too: every plugin's command for its server") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        expectEqual(registry.hostCommands.specs.map(\.name), ["draw", "show", "kinds", "measure", "query", "query-vocabulary"])
    },
    test("a plugin that needs the key asks for Settings with the action the app's menu item sends") {
        expectEqual(AnthropicSettingsView.showSettingsAction, BoardMenus.showSettings)
    },
    test("the editor's language model is the one passed: the app's is Claude Haiku with the key from Settings") {
        let model = ScriptedLanguageModel()
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: model)
        expect(editor.languageModel as? ScriptedLanguageModel === model)
        // Made from nothing, as the app's list makes it (never asked here: nothing reads the key or reaches the network).
        let app = CanvasEditor(registry: try Registry(plugins: [LanguageModelsPlugin()]), document: CanvasDocument(), scheduler: ManualScheduler())
        let shipped = try require(app.languageModel as? AnthropicModel)
        expectEqual(shipped.model, AnthropicModel.haiku)
        expectEqual(shipped.keys, .standard)
    },
    test("the registry report: who contributes what") {
        expectEqual(try ShippedPlugins.registry(model: ScriptedLanguageModel()).report, """
        core                 tool hand · command undo · command redo · command zoomIn in View · command zoomOut in View · command zoomToActualSize in View · command zoomToFit in View
        keyboard             service KeyboardState · tool tips · menu keys · keyboard help · key strokes · key releases · shortcut H → tool hand · shortcut Space → Pan · shortcut ⎋ → Cancel · shortcut ⌘. → Cancel · shortcut ⌘Z → command undo · shortcut ⇧⌘Z → command redo · shortcut Q → Tool Lock · shortcut ⌘= → command zoomIn · shortcut ⌘- → command zoomOut · shortcut = → command zoomIn · shortcut - → command zoomOut · shortcut ⌘0 → command zoomToActualSize · shortcut ⇧0 → command zoomToActualSize · shortcut ⇧1 → command zoomToFit · key hint ⇧ Drag Move Along One Axis · key hint ⌘ Scroll Zoom
        selection            service SelectionState · service RefusalShake · tool select · shortcut V → tool select · default tool select · outlines · overlay GroupFocusOverlay · overlay HandlesOverlay · key hint ⇧ or ⌘ Click Add or Remove From Selection · key hint ⌘ Drag Select Shapes Wholly in the Box · key hint ⌥ Drag Drag a Copy · key hint ⇧ Resize Keep Proportions · key hint ⌥ Resize Resize From the Center · command shapes · command delete · shortcut ⌫ → command delete · shortcut ⌦ → command delete · command selectAll · shortcut ⌘A → command selectAll · command goBack in Go · shortcut ⌘[ → command goBack · command openSelection in Go · shortcut ⌘↓ → command openSelection · shortcut ↩ → Open Selection · shortcut ⌤ → Open Selection · command zoomToSelection in View · shortcut ⇧2 → command zoomToSelection · command smartMagnify · shortcut ← → Nudge · shortcut ⇧← → Nudge · shortcut → → Nudge · shortcut ⇧→ → Nudge · shortcut ↑ → Nudge · shortcut ⇧↑ → Nudge · shortcut ↓ → Nudge · shortcut ⇧↓ → Nudge · shortcut ⇥ → Next Shape · shortcut ⇧⇥ → Previous Shape · shortcut ⌥⌘← → Select Nearest Shape · shortcut ⌥⇧⌘← → Add Nearest Shape to Selection · shortcut ⌥⌘→ → Select Nearest Shape · shortcut ⌥⇧⌘→ → Add Nearest Shape to Selection · shortcut ⌥⌘↑ → Select Nearest Shape · shortcut ⌥⇧⌘↑ → Add Nearest Shape to Selection · shortcut ⌥⌘↓ → Select Nearest Shape · shortcut ⌥⇧⌘↓ → Add Nearest Shape to Selection
        topology             service TopologyIndex · edge type stands-for
        arrows               key hint ⌥ Drag an Arrow's End Bind It Exactly · key hint ⌘ or ⌃ Drag an Arrow's End Leave It Unbound · key hint ⇧ Drag an Arrow's End Snap Its Angle · shape arrow v2 · label Arrow → arrow · ContentsRows → arrow · mention layout → arrow · mention text → arrow · property color → arrow · colorable → arrow · type words → arrow · property is → arrow · property fieldValues → arrow · property endRule → arrow · ShapeOpening → arrow · service ArrowTargeting · service ArrowRowNesting · overlay BindingHintsOverlay
        sticky-notes         key hint ⌘↩ or ⎋ Finish Editing · key hint ⇧↩ in a Note New Note Beside It · key hint ⇥ or ⇧⇥ in a Note Next or Previous Note · service NoteHops · shape sticky-note v3 · tool sticky-note · shortcut N → tool sticky-note · property color → sticky-note · colorable (yellow) → sticky-note · tint → sticky-note · DoubleClickPlacement → sticky-note · property title → sticky-note · ShapeTitles → sticky-note · ContentsTitles → sticky-note · title pill look → sticky-note · title cover surface → sticky-note · ShapeDetails → sticky-note · ContentsRows → sticky-note · ports note-link → sticky-note · mention text → sticky-note · mentionable → sticky-note · type words → sticky-note · property schema → sticky-note · keeps in step → sticky-note · property relationship → sticky-note · property is → sticky-note · property fieldValues → sticky-note · type rows → sticky-note · channel note-link · edge type note-link
        subboards            shape subboard v1 · tool subboard · shortcut B → tool subboard · tint → subboard · property title → subboard · ShapeTitles → subboard · ContentsTitles → subboard · title cover surface → subboard · board → subboard "Untitled Subboard" · ShapeOpening → subboard · ShapeContextMenus → subboard · property color → subboard · colorable (indigo) → subboard · mentionable → subboard · ContentsRows → subboard · ShapeDetails → subboard · ports subboard-link → subboard · ports on every channel → subboard · channel subboard-link · edge type subboard-link · takes channel container → subboard · CanvasContextMenu · /turn-into-subboard → every shape that can turn into subboard
        framing              key hint ⇧ Drag a Frame Draw It Square · key hint ⌥ Drag a Frame Draw It From the Center · shape frame · tool frame · shortcut F → tool frame · property color → frame · colorable → frame · tint → frame · property title → frame · ShapeTitles → frame · ContentsTitles → frame · title cover surface → frame · mentionable → frame · ShapeResizing → frame · ContentsRows → frame · ShapeDetails → frame · offers channel container → frame · command createFrame · shortcut ⇧⌘F → command createFrame · CanvasContextMenu
        references           service ReferenceState · overlay ReferenceButtonOverlay · CanvasButtons · command goToOriginal · command interpretReference · DetailStatuses → reference · ShapePopovers · CanvasContextMenu · shape reference · tool reference · shortcut R → tool reference · ports on every channel → reference · stands in → reference · ContentsRows → reference · ShapeDetails → reference · ShapeContextMenus → reference · ValidationRules → reference
        validation           service ValidationEngine · overlay ValidationOverlay · ValidationRules → every shape
        adornments           service AdornmentState · service ChipFade · layout input adornment-lead · overlay AdornmentOverlay · CanvasButtons · DecorationHits
        detail-panel         service DetailPanelState · host inspector
        context-menus        service ContextMenuState · secondary-click menu · selection menu · CanvasContextMenu
        slash-commands       service SlashCommandState · key hint / at a Line's Start Run a Command
        table-of-contents    service ContentsState
        contents-overview    detail overview
        titles               property title · adornment TitlePill → every shape with a title pill · /title → every shape holding title · overlay TitleCoverOverlay
        mentions             service MentionState · key hint @ Mention a Shape · edge type mention · edges → every shape naming shapes · overlay MentionFrames · ShapeFaces · CanvasContextMenu
        board-navigation     service BoardCrumbs · command enclosingBoard in Go · shortcut ⌘↑ → command enclosingBoard · command goUpBoard · host overlay · window subtitle
        board-contents       contents heading
        find-in-boards       service FindState · overlay FindOverlay · command find in Edit › Find · shortcut ⌘F → command find · command findNext in Edit › Find · shortcut ⌘G → command findNext · command findPrevious in Edit › Find · shortcut ⇧⌘G → command findPrevious
        find-panel           detail takeover
        board-find           find heading
        title-find           findable title → every shape with a title
        mention-find         findable mention text → every shape with mention text · findable mention text over the canvas → every shape with mention text
        jump-to              service JumpToState · command jumpTo in Go · shortcut ⌘K → command jumpTo · host overlay
        transform            service TransformState
        validation-details   DetailStatuses in Issues → every shape
        validation-contents  ContentsMarks → every shape
        mention-validation   ValidationRules → every shape naming shapes
        title-validation     service TitleIndex · ValidationRules → every shape with a title
        grouping             property groups · property groups → every shape · service GroupIndex · SelectionGroups · command group in Arrange · shortcut ⌥⌘G → command group · command ungroup in Arrange · shortcut ⌥⇧⌘G → command ungroup · CanvasContextMenu
        clipboard            service ClipboardState · command cut · shortcut ⌘X → command cut · command copy · shortcut ⌘C → command copy · command paste · shortcut ⌘V → command paste · command pasteAtPointer in Edit · shortcut ⇧⌘V → command pasteAtPointer · image source · command duplicate in Edit · shortcut ⌘D → command duplicate · DragCopies · CanvasContextMenu
        locking              property locked · property locked → every shape · read-only shapes · service LockState · command lock · command unlock · shortcut ⇧L → command lock or unlock · adornment LockChip → every shape holding locked · ContentsMarks → every shape holding locked · CanvasContextMenu → every shape holding locked · /lock → every shape holding locked
        publishing           property public · property public → every shape · public dials · service PublishingState · command makePublic · command makePrivate · CanvasContextMenu · adornment PublicChip → every shape holding public · ContentsMarks → every shape holding public · /public /private → every shape holding public
        types                property schema · key hint ⇥ or ⇧⇥ Next or Previous Field · property is · property fieldValues · property relationship · property endRule · edge type is-a · edges → every shape holding is · service TypeIndex · service RelationshipIndex · service FieldBook · service TypeSync<TypeSchemaProperty> · service FieldWriter · service FieldDefiner · service FieldChecks · service FieldCards · service DefinitionCards · service RelationshipHooks · service RowBook · layout input type-rows · layout input type-pill · service EndArrows · layout input end-arrow · CanvasContextMenu · DecorationHits · outlines · ShapeFaces · ShapeFaces · ShapeFaces · willDelete · ShapePopovers · /is-a → every shape holding is · CanvasContextMenu · CanvasContextMenu → every shape holding is · CanvasContextMenu · adornment TypeChips → every shape holding is · service RelationshipOffers · SelectionObservers · adornment RelationshipPill → every shape holding is · adornment RelationshipOfferPill → every shape holding is · title pill look → every shape holding schema · title pill look → every shape holding is
        type-validation      ValidationRules → every shape holding schema · ValidationRules → every shape holding is · ValidationRules → every shape holding schema
        type-details         ShapeDetails → every shape holding schema · ShapeDetails → every shape holding is · ShapeDetails → every shape holding is · ShapeDetails → every shape holding endRule
        field-find           findable field value → every shape showing field values · findable relationship type name → every shape holding relationship
        colors               property color · file property colors · service ColorBook · shape tints · /color → every shape holding color · CanvasContextMenu → every shape holding color
        color-validation     service ColorWarnings · ValidationRules → every shape holding color
        color-details        ShapeDetails → every shape holding color
        snapping             service SnapState · translation adjuster · key hint ⌘ or ⌃ Drag Move Without Snapping
        ports                property channel · service PortState · overlay PortOverlay · CanvasButtons · command connect · shortcut ⌘L → command connect
        connect-menu         CanvasContextMenu
        arrow-ports          service ArrowTypeRows · property channel → arrow · edge type arrow · connector → arrow · edges → arrow · ArrowBindingRules
        language-models      service LanguageModelState
        prose-maps           service ProseMapService · overlay ProseMapFrames
        draw-engine          draw engine
        automation           command line draw · command line show · command line kinds · command line measure · host commands
        title-names          draw names
        port-edges           draw edges
        validation-checks    draw checks
        mention-texts        draw labels · draw text text/x-canvas-mentions
        type-names           draw text text/x-canvas-type · draw value schema
        draw-field-values    draw value fieldValues · draw value endRule · draw reports members is, endOf, fits, relates
        color-names          draw text text/x-canvas-color
        group-draw           draw groups
        queries              service QueryState · query engine
        query-translation    service QueryTranslator
        title-queries        query names
        board-queries        query board names
        mention-queries      query word :mentions · query word :mentioned-by · query text text/x-canvas-mentions
        validation-queries   query word :invalid · query word :warned · query word :incomplete
        type-queries         query word :is-a · query text text/x-canvas-type · query word :misfit · ask fact fields · query path fieldValues
        color-queries        query text text/x-canvas-color
        group-queries        query word :grouped-with
        selection-queries    query word :selected
        query-commands       command line query · command line query-vocabulary
        neighbors            service NeighborState · outlines
        arrow-lights         neighbor light · neighbor light
        mention-lights       neighbor light · neighbor light
        type-lights          neighbor light
        neighbor-details     service NeighborList · ShapeDetails → every shape
        moving               /move-to /move-near → every shape with a box · ContentsMoves
        reordering           command bringToFront in Arrange · shortcut ] → command bringToFront · command bringForward in Arrange · shortcut ⌥] → command bringForward · command sendBackward in Arrange · shortcut ⌥[ → command sendBackward · command sendToBack in Arrange · shortcut [ → command sendToBack · ShapeContextMenus → every shape painted in document order
        """)
    },
    test("the guide shows the registry report as it is") {
        let guide = try String(contentsOf: URL(fileURLWithPath: "docs/plugin-system.md"), encoding: .utf8)
        let lead = "`registry.report` prints who contributes what: the runtime half of the graph, pinned by a test.\n\n```\n"
        let start = try require(guide.range(of: lead), "the guide's report is gone").upperBound
        let end = try require(guide.range(of: "\n```", range: start..<guide.endIndex)).lowerBound
        expectEqual(String(guide[start..<end]), try ShippedPlugins.registry(model: ScriptedLanguageModel()).report)
    },
    test("every placed kind has a panel: a note its header over the Connections and Style tabs, a subboard its Description tab before them, a frame and an arrow those two alone, a reference that tab alone; a type note its Schema tab before them; every nameable kind's header renames it") {
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
        expectEqual(panels, ["(Note): Connections, Style", "(Untitled Subboard): Description, Connections, Style", "(Untitled Frame): Connections, Style", "Arrow: Connections, Style", "Reference: Connections",
                         "(Note): Schema, Connections, Style"])
    },
    test("the table of contents lists the sample board: each note by its text, each arrow under the note it starts from") {
        let editor = ShippedPlugins.makeEditor(scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        let entries = try require(editor.tableOfContents).entries
        expectEqual(entries.map { $0.label?.text }, SampleBoard.texts)
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
    test("the sample board: six notes, three arrows, no warnings") {
        let editor = ShippedPlugins.makeEditor(scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        expectEqual(editor.document.shapes.filter { $0.kind == StickyNote.kind }.count, 6)
        expectEqual(editor.document.shapes.filter { $0.kind == Arrow.kind }.count, 3)
        expectEqual(editor.validation?.results.count, 0)
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
