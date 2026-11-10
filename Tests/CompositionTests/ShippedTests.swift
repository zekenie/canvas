import AppKit
import Arrows
import Boards
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Clipboard
import CoreGraphics
import DecisionModels
import DetailPanel
import Geometry
import LanguageModels
import Mentions
import QueryTranslation
import References
import Selection
import ShippedTesting
import Engineering
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
        let plugins = try ShippedList.plugins(supplying: [ClipboardPlugin(pasteboard: ShippedPlugins.pasteboard), LanguageModelsPlugin(model: ScriptedLanguageModel()),
                                                          DecisionModelsPlugin(model: ScriptedDecisionModel())])
        expectEqual(plugins.map { String(reflecting: type(of: $0)) }, names, "every line a plugin of that type, in the list's order")
        expectEqual(ShippedPlugins.plugins(model: ScriptedLanguageModel()).map(\.id), plugins.map(\.id), "which is what every test here is given")
        _ = try Registry(plugins: plugins)
    },
    test("nothing but the app is made of the plugins that reach outside the process: the list won't load without a pasteboard's and two models' of the caller's own") {
        let outward = ["Clipboard.ClipboardPlugin", "LanguageModels.LanguageModelsPlugin", "DecisionModels.DecisionModelsPlugin"]
        let clipboard = ClipboardPlugin(pasteboard: ShippedPlugins.pasteboard)
        expectThrows(ShippedListError.notSupplied(outward)) { _ = try ShippedList.plugins(supplying: []) }
        expectThrows(ShippedListError.notSupplied(Array(outward[1...]))) { _ = try ShippedList.plugins(supplying: [clipboard]) }
        expectThrows(ShippedListError.notSupplied([outward[0], outward[2]])) { _ = try ShippedList.plugins(supplying: [LanguageModelsPlugin(model: ScriptedLanguageModel())]) }
        expectThrows(ShippedListError.notSupplied([outward[2]])) { _ = try ShippedList.plugins(supplying: [clipboard, LanguageModelsPlugin(model: ScriptedLanguageModel())]) }
        // The models handed over are the ones the editor asks: never the app's.
        let model = ScriptedLanguageModel()
        let decisions = ScriptedDecisionModel()
        let plugins = try ShippedList.plugins(supplying: [clipboard, LanguageModelsPlugin(model: model), DecisionModelsPlugin(model: decisions)])
        let editor = CanvasEditor(registry: try Registry(plugins: plugins), document: CanvasDocument(), scheduler: ManualScheduler())
        expect(editor.languageModel as? ScriptedLanguageModel === model)
        expect(editor.decisionModel as? ScriptedDecisionModel === decisions)
        // Any other listed plugin can be handed over too, and takes its place; one the list hasn't is refused.
        let asked = QueryTranslationPlugin(prompt: "Ask.", referenceRule: "")
        let swapped = try ShippedList.plugins(supplying: [clipboard, LanguageModelsPlugin(model: model), DecisionModelsPlugin(model: decisions), asked])
        expectEqual(swapped.map(\.id), plugins.map(\.id))
        expectThrows(ShippedListError.notInList(["CanvasTesting.Contributor"])) {
            _ = try ShippedList.plugins(supplying: [clipboard, LanguageModelsPlugin(model: model), DecisionModelsPlugin(model: decisions), Contributor(id: "more") { _ in }])
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
    test("the toolbar is Select V, Hand H, Note N, Subboard B, Frame F, Reference R: arrows are drawn from ports; the engineering kit's tools are its one segment while it's on") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        expectEqual(registry.tools.filter { registry.kit(ofTool: $0.id) == nil }.map { registry.toolTip(for: $0) },
                    ["Select (V)", "Hand (H)", "Note (N)", "Subboard (B)", "Frame (F)", "Reference (R)"])
        expectEqual(registry.tools.filter { registry.kit(ofTool: $0.id) == EngineeringKit.id }.map { registry.toolTip(for: $0) },
                    ["Table", "Enum", "API", "Database"])
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
        expectEqual(registry.settingsPanes.count, 0, "scripted models sign in to nothing")
        // The app's models bring their panes, the sign-in's first (made only when Settings opens: nothing reads a key or runs claude here).
        expectEqual(try Registry(plugins: [LanguageModelsPlugin(), DecisionModelsPlugin()]).settingsPanes.map(\.title), ["Claude", "TypeSafe"])
    },
    test("and what the app takes besides is the plugins' too: every plugin's command for its server") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        expectEqual(registry.hostCommands.specs.map(\.name), ["draw", "apply", "rehearse", "show", "capture", "kinds", "measure", "query", "query-vocabulary", "decide"])
    },
    test("a plugin that can't ask for want of a sign-in asks for Settings with the action the app's menu item sends") {
        expectEqual(AnthropicSettingsView.showSettingsAction, BoardMenus.showSettings)
    },
    test("the editor's language model is the one passed: the app's is Claude Haiku, asked the way Settings signs in") {
        let model = ScriptedLanguageModel()
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: model)
        expect(editor.languageModel as? ScriptedLanguageModel === model)
        // Made from nothing, as the app's list makes it (never asked here: nothing reads the key, runs claude or reaches the network).
        let app = CanvasEditor(registry: try Registry(plugins: [LanguageModelsPlugin()]), document: CanvasDocument(), scheduler: ManualScheduler())
        let shipped = try require(app.languageModel as? SignedInModel)
        expectEqual(shipped.model, AnthropicModel.haiku)
        expectEqual(shipped.withKey.keys, .standard)
        expectEqual(shipped.account.methodURL, AnthropicAccount.standard.methodURL)
        expectEqual(shipped.throughClaudeCode.claudeCode.configDirectory, ClaudeCode.standardConfigDirectory)
    },
    test("the editor's decision model is the one passed, a scripted one unless a test says: the app's is Jev with the key from Settings") {
        let decisions = ScriptedDecisionModel()
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel(), decisionModel: decisions)
        expect(editor.decisionModel as? ScriptedDecisionModel === decisions)
        expect(ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel()).decisionModel is ScriptedDecisionModel)
        // Made from nothing, as the app's list makes it (never asked here: nothing reads the key or reaches the network).
        let app = CanvasEditor(registry: try Registry(plugins: [DecisionModelsPlugin()]), document: CanvasDocument(), scheduler: ManualScheduler())
        let shipped = try require(app.decisionModel as? JevModel)
        expectEqual(shipped.model, JevModel.latest)
        expectEqual(shipped.keys, .standard)
    },
    test("the registry report: who contributes what") {
        expectEqual(try ShippedPlugins.registry(model: ScriptedLanguageModel()).report, """
        core                 tool hand · command undo · command redo · command insertBeside first in InsertMenu.Shapes · command zoomIn in ViewMenu.Zoom · command zoomOut in ViewMenu.Zoom · command zoomToActualSize in ViewMenu.Zoom · command zoomToFit in ViewMenu.Zoom · command pageUp · command pageDown · command scrollToStart · command scrollToEnd · file property kits · command kit:engineering in FileMenu.KitList
        keyboard             service KeyboardState · tool tips · menu keys · keyboard help · key strokes · key releases · shortcut H → tool hand · shortcut Space → Pan · shortcut ⎋ → Cancel · shortcut ⌘. → Cancel · shortcut ⌘Z → command undo · shortcut ⇧⌘Z → command redo · shortcut Q → Tool Lock · shortcut ⇧↩ → command insertBeside · shortcut ⌘= → command zoomIn · shortcut ⌘- → command zoomOut · shortcut = → command zoomIn · shortcut - → command zoomOut · shortcut ⌘0 → command zoomToActualSize · shortcut ⇧0 → command zoomToActualSize · shortcut ⇧1 → command zoomToFit · shortcut ⇞ → command pageUp · shortcut ⇟ → command pageDown · shortcut ↖ → command scrollToStart · shortcut ↘ → command scrollToEnd · key hint ⇧ Drag Move Along One Axis · key hint ⌘ Scroll Zoom
        selection            service SelectionState · service RefusalShake · tool select · shortcut V → tool select · default tool select · outlines · overlay GroupFocusOverlay · overlay HandlesOverlay · overlay PartFocusOverlay · overlay ItemsOverlay · key hint ⇧ or ⌘ Click Add or Remove From Selection · key hint ⌘ Drag Select Shapes Wholly in the Box · key hint ⌥ Drag Drag a Copy · key hint ⇧ Resize Keep Proportions · key hint ⌥ Resize Resize From the Center · command shapes · accessible order · accessible parts · command delete · shortcut ⌫ → command delete · shortcut ⌦ → command delete · command selectAll · shortcut ⌘A → command selectAll · command goBack in NavigationSection · shortcut ⌘[ → command goBack · shortcut ⌃- → command goBack · command goForward after goBack in NavigationSection · shortcut ⌘] → command goForward · shortcut ⌃_ → command goForward · command openSelection in NavigationSection · shortcut ⌘↓ → command openSelection · shortcut ↩ → Open Selection · shortcut ⌤ → Open Selection · shortcut ⌥↩ → Open Selection · press focused · command zoomToSelection in ViewMenu.Zoom · shortcut ⇧2 → command zoomToSelection · command smartMagnify · shortcut ← → Nudge, Pan or Step Rows · shortcut ⇧← → Nudge, Pan or Step Rows · shortcut → → Nudge, Pan or Step Rows · shortcut ⇧→ → Nudge, Pan or Step Rows · shortcut ↑ → Nudge, Pan or Step Rows · shortcut ⇧↑ → Nudge, Pan or Step Rows · shortcut ↓ → Nudge, Pan or Step Rows · shortcut ⇧↓ → Nudge, Pan or Step Rows · shortcut ⌥← → Resize or Move Rows · shortcut ⌥⇧← → Resize or Move Rows · shortcut ⌥→ → Resize or Move Rows · shortcut ⌥⇧→ → Resize or Move Rows · shortcut ⌥↑ → Resize or Move Rows · shortcut ⌥⇧↑ → Resize or Move Rows · shortcut ⌥↓ → Resize or Move Rows · shortcut ⌥⇧↓ → Resize or Move Rows · shortcut ⌥⇥ → Next Part · shortcut ⌥⇧⇥ → Previous Part · shortcut ⇥ → Next Shape · shortcut ⇧⇥ → Previous Shape · shortcut ⌥⌘← → Select Nearest Shape · shortcut ⌥⇧⌘← → Add Nearest Shape to Selection · shortcut ⌥⌘→ → Select Nearest Shape · shortcut ⌥⇧⌘→ → Add Nearest Shape to Selection · shortcut ⌥⌘↑ → Select Nearest Shape · shortcut ⌥⇧⌘↑ → Add Nearest Shape to Selection · shortcut ⌥⌘↓ → Select Nearest Shape · shortcut ⌥⇧⌘↓ → Add Nearest Shape to Selection
        topology             service TopologyIndex · edge type stands-for · stand-in lookup
        arrows               key hint ⌥ Drag an Arrow's End Bind It Exactly · key hint ⌘ or ⌃ Drag an Arrow's End Leave It Unbound · key hint ⇧ Drag an Arrow's End Snap Its Angle · shape arrow v3 · label Arrow → arrow · ContentsRows → arrow · mention layout → arrow · mention text → arrow · property color → arrow · colorable → arrow · property ignoredRules → arrow · type words → arrow · property is → arrow · property fieldValues → arrow · property autofill → arrow · property endRule → arrow · ShapeOpening → arrow · parts ArrowHandles → arrow · accessibility → arrow · ShapeContextMenus in ShapeMenuGroup first → arrow · service ArrowTargeting · service ArrowRowNesting · overlay BindingHintsOverlay · overlay ArrowUnderCardsOverlay
        sticky-notes         key hint ⌘↩ or ⎋ Finish Editing · key hint ⇧↩ in a Note New Note Beside It · key hint ⇥ or ⇧⇥ in a Note Next or Previous Note · service NoteHops · insert beside by default sticky-note · shape sticky-note v4 · tool sticky-note · command insert:sticky-note in InsertMenu.Shapes · shortcut N → tool sticky-note · made beside → sticky-note · property color → sticky-note · colorable (yellow) → sticky-note · property ignoredRules → sticky-note · tint → sticky-note · DoubleClickPlacement → sticky-note · ShapeResizing → sticky-note · parts resize handles → sticky-note · property title → sticky-note · ShapeTitles → sticky-note · ContentsTitles → sticky-note · title pill look → sticky-note · title cover surface → sticky-note · ShapeDetails in Schema after Connections → sticky-note · ContentsRows → sticky-note · ports note-link → sticky-note · mention text → sticky-note · mentionable → sticky-note · type words → sticky-note · property schema → sticky-note · keeps in step → sticky-note · keeps in step → sticky-note · property relationship → sticky-note · definition walk → sticky-note · property is → sticky-note · property fieldValues → sticky-note · property autofill → sticky-note · type rows → sticky-note · accessibility → sticky-note · channel note-link · edge type note-link · paste reader Note · /bulk-create → the command bar's target · key hint ⌥ Click or ⌥↩ Place Notes in a Row
        subboards            shape subboard v1 · tool subboard · command insert:subboard in InsertMenu.Shapes · shortcut B → tool subboard · tint → subboard · property title → subboard · ShapeTitles → subboard · ContentsTitles → subboard · title cover surface → subboard · board → subboard "Untitled Subboard" · ShapeOpening → subboard · ShapeContextMenus in BoardsMenuGroup before ShapeMenuGroup → subboard · property color → subboard · colorable (indigo) → subboard · mentionable → subboard · ContentsRows → subboard · ShapeDetails in Description first → subboard · ports subboard-link → subboard · ports on every channel → subboard · type words → subboard · property is → subboard · property fieldValues → subboard · property autofill → subboard · accessibility → subboard · channel subboard-link · edge type subboard-link · takes channel container → subboard · CanvasContextMenu in TransformMenuGroup after ActionsMenuGroup · /turn-into-subboard → every shape that can turn into subboard
        framing              key hint ⇧ Drag a Frame Draw It Square · key hint ⌥ Drag a Frame Draw It From the Center · shape frame · tool frame · command insert:frame in InsertMenu.Shapes · shortcut F → tool frame · property color → frame · colorable → frame · tint → frame · property title → frame · ShapeTitles → frame · ContentsTitles → frame · title tab → frame · mentionable → frame · ShapeResizing → frame · parts resize handles → frame · ContentsRows → frame · ShapeDetails → frame · offers channel container → frame · property is → frame · property fieldValues → frame · accessibility → frame · ports frame-link → frame · channel frame-link · edge type frame-link · command createFrame · shortcut ⇧⌘F → command createFrame · CanvasContextMenu in FramesMenuGroup after TransformMenuGroup
        references           service ReferenceState · overlay ReferenceButtonOverlay · CanvasButtons · command goToOriginal · command interpretReference · command expandReference · command collapseReference · layout input reference-mirror · ShapeFaces · DetailStatuses → reference · ShapePopovers · CanvasContextMenu in ReferencesMenuGroup before ShapeMenuGroup · parts moved · shape reference v3 · tool reference · command insert:reference in InsertMenu.Shapes · shortcut R → tool reference · ports on every channel → reference · ShapeResizing → reference · parts resize handles → reference · ShapeOpening → reference · /expand /collapse → reference · stands in → reference · parts go → reference · accessibility → reference · ContentsRows → reference · ContentsSections → reference · ShapeDetails in Reference first → reference · ShapeContextMenus in ReferencesMenuGroup before ShapeMenuGroup → reference · ValidationRules → reference
        validation           service ValidationEngine · overlay ValidationOverlay · ValidationRules → every shape · accessibility → every shape
        adornments           service AdornmentState · service ChipFade · layout input adornment-lead · overlay AdornmentOverlay · CanvasButtons · DecorationHits
        detail-panel         service DetailPanelState · host inspector · command nextInspectorTab in ViewMenu.Panels · shortcut ⌥⌘] → command nextInspectorTab · command previousInspectorTab in ViewMenu.Panels · shortcut ⌥⌘[ → command previousInspectorTab · key hint ⇥ or ⇧⇥ Next or Previous Control · key hint ⌥⇥ Type a Tab · key hint ⎋ Back to the Canvas · key hint ⌘↩ Commit · key hint ⌃Space Complete
        context-menus        service ContextMenuState · secondary-click menu · selection menu · command showContextMenu · shortcut ⌃↩ → command showContextMenu · shortcut Menu → command showContextMenu · CanvasContextMenu in SelectionMenuGroup last
        slash-commands       service SlashCommandState · key hint / at a Line's Start Run a Command
        slash-bar            service SlashBar · command runSlashCommand · shortcut / → command runSlashCommand · SelectionObservers
        table-of-contents    service ContentsState · host sidebar
        titles               property title · adornment TitlePill → every shape with a title pill · adornment TitleTab → every shape with a title tab · /title → every shape holding title · overlay TitleCoverOverlay · accessibility → every shape with a title · row zoomed out → every shape with a title pill
        mentions             service MentionState · key hint @ Mention a Shape · edge type mention · edges → every shape naming shapes · overlay MentionFrames · ShapeFaces · CanvasContextMenu in MentionsMenuGroup after ShapeMenuGroup · command goToMention in NavigationSection · shortcut ⌥⌘↩ → command goToMention · command showWhatMentionsOfPill in NavigationSection · command removeMention after selectAll in EditMenu.CutCopyPaste · parts mentions → every shape with mention text
        mention-slash-bar    slash bar field
        board-navigation     service BoardCrumbs · command enclosingBoard after goForward in NavigationSection · shortcut ⌘↑ → command enclosingBoard · command goUpBoard · command boardPath in PathSection · shortcut ⌥⌘P → command boardPath · host overlay · window subtitle
        board-contents       contents heading
        board-headings       board heading
        find-in-boards       service FindState · overlay FindOverlay · command find in FindSection · shortcut ⌘F → command find · command findNext in FindSection · shortcut ⌘G → command findNext · command findPrevious in FindSection · shortcut ⇧⌘G → command findPrevious
        find-panel           key hint ↩ or ⇧↩ in Find Next or Previous Hit · key hint ↑ or ↓ in Find Previous or Next Result · key hint ⌘↩ in Find Select Hit and Close · detail takeover
        title-find           findable title → every shape with a title
        mention-find         findable mention text → every shape with mention text · findable mention text over the canvas → every shape with mention text
        jump-to              service JumpToState · command jumpTo first in PathSection · shortcut ⌘K → command jumpTo · host overlay
        transform            service TransformState
        validation-details   DetailStatuses in Issues after Style → every shape
        issue-walk           service IssueWalk · command nextIssue in IssuesSection after NavigationSection · command previousIssue after nextIssue in IssuesSection after NavigationSection · shortcut ⌘' → command nextIssue · shortcut ⌘" → command previousIssue · command ignoreIssue after issueList in IssuesSection after NavigationSection · shortcut ⌥⌘' → command ignoreIssue · command endIssueWalk after ignoreIssue in IssuesSection after NavigationSection
        issue-walk-panel     detail band · detail takeover · command issueList after previousIssue in IssuesSection after NavigationSection · shortcut ⌃⌘' → command issueList · service IssueLights · outlines
        validation-contents  ContentsMarks → every shape
        mention-validation   ValidationRules → every shape naming shapes
        path-validation      service PathIndex · ValidationRules → every shape with a title
        grouping             property groups · property groups → every shape · service GroupIndex · SelectionGroups · command group in GroupingSection · shortcut ⌥⌘G → command group · command ungroup in GroupingSection · shortcut ⌥⇧⌘G → command ungroup · CanvasContextMenu in StateMenuGroup before SelectionMenuGroup
        clipboard            service ClipboardState · pasteboard · command cut · shortcut ⌘X → command cut · command copy · shortcut ⌘C → command copy · command paste · shortcut ⌘V → command paste · command pasteAtPointer after paste in EditMenu.CutCopyPaste · shortcut ⇧⌘V → command pasteAtPointer · image source · command pasteAsNote after pasteAtPointer in EditMenu.CutCopyPaste · shortcut ⌥⇧⌘V → command pasteAsNote · command duplicate after pasteAsNote in EditMenu.CutCopyPaste · shortcut ⌘D → command duplicate · DragCopies · CanvasContextMenu in ClipboardMenuGroup
        locking              property locked · property locked → every shape · read-only shapes · service LockState · command lock · command unlock · shortcut ⇧L → command lock or unlock · adornment LockChip last → every shape holding locked · parts LockChip → every shape holding locked · ContentsMarks → every shape holding locked · CanvasContextMenu in StateMenuGroup before SelectionMenuGroup → every shape holding locked · accessibility → every shape holding locked · /lock /unlock → every shape holding locked
        publishing           property private · property private → every shape · public dials · service PublishingState · command makePublic · command makePrivate · CanvasContextMenu in PublishMenuGroup after StateMenuGroup · adornment PrivateChip last → every shape holding private · parts PrivateChip → every shape holding private · ContentsMarks → every shape holding private · /public /private → every shape holding private
        types                property schema · key hint ⇥ or ⇧⇥ Next or Previous Field · property is · property fieldValues · property autofill · property relationship · property endRule · edge type is-a · edges → every shape holding is · service TypeIndex · service RelationshipIndex · service FieldBook · service TypeSync<TypeSchemaProperty> · service FieldWriter · service FieldFill · service FieldDefiner · service FieldChecks · service FieldCards · service DefinitionCards · service RelationshipHooks · service RowBook · layout input type-rows · layout input type-pill · service EndArrows · layout input end-arrow · CanvasContextMenu in ShapeMenuGroup first · DecorationHits · outlines · parts RowFace → every shape holding schema · parts RowFace → every shape holding is · ShapeFaces · parts DefinitionFace → every shape holding relationship · ShapeFaces · command openFields · CanvasContextMenu in ShapeMenuGroup first · command retryTypeSync · CanvasContextMenu in ShapeMenuGroup first → every shape holding schema · accessibility → every shape holding is · accessibility → every shape holding schema · ShapeFaces · parts RelateFace → every shape holding schema · willDelete · ShapePopovers · /is-a → every shape holding is · CanvasContextMenu in ShapeMenuGroup first · CanvasContextMenu in StateMenuGroup before SelectionMenuGroup → every shape holding is · CanvasContextMenu in StateMenuGroup before SelectionMenuGroup · adornment TypeChips after TitlePill → every shape holding is · parts TypeChips → every shape holding is · service RelationshipOffers · SelectionObservers · adornment RelationshipPill → every shape holding is · parts RelationshipPill → every shape holding is · adornment RelationshipOfferPill after RelationshipPill → every shape holding is · parts RelationshipOfferPill → every shape holding is · title pill look → every shape holding schema · title pill look → every shape holding is
        type-validation      ValidationRules → every shape holding schema · ValidationRules → every shape holding is · ValidationRules → every shape holding schema
        type-details         ShapeDetails in Schema after Connections → every shape holding schema · ShapeDetails in Types → every shape holding is · ShapeDetails in Types → every shape holding is · ShapeDetails in Types → every shape holding autofill · ShapeDetails in Schema after Connections → every shape holding schema · ShapeDetails in Types → every shape holding endRule
        issue-row-values     IssueRowValues → every shape holding fieldValues
        field-find           findable field value → every shape showing field values · findable relationship type name → every shape holding relationship
        colors               property color · file property colors · service ColorBook · shape tints · /color → every shape holding color · CanvasContextMenu in StateMenuGroup before SelectionMenuGroup → every shape holding color
        color-validation     service ColorWarnings · ValidationRules → every shape holding color
        color-details        ShapeDetails in Style last → every shape holding color
        type-colors          inherited color → every shape holding is
        snapping             service SnapState · translation adjuster · resize adjuster · key hint ⌘ or ⌃ Drag Move or Resize Without Snapping
        ports                property channel · service PortState · overlay PortOverlay · CanvasButtons · command connect in ConnectSection · shortcut ⌘L → command connect · connection made · parts arrows → every shape
        connect-menu         CanvasContextMenu in ShapeMenuGroup first
        connect-picker       service ConnectPickerHost · SelectionObservers
        connection-pills     adornment ChannelPill → every shape holding channel · accessibility → every shape holding channel
        arrow-ports          service ArrowTypeRows · property channel → arrow · edge type arrow · connector → arrow · edges → arrow · ArrowPartRules · ArrowBindingRules
        type-release         connection made
        language-models      service LanguageModelState
        decision-models      service Decisions
        language-rules       property ignoredRules · type directive $rules · service RuleChecks · service RuleWriter · service RuleChips
        rule-validation      ValidationRules → every shape holding ignoredRules · IssueScopes · ValidationRules → every shape holding schema
        rule-details         service RuleLights · outlines · ShapeDetails in Rules after Schema → every shape holding schema · ShapeDetails in Issues after Style → every shape holding ignoredRules · command retryRuleChecks · CanvasContextMenu in StateMenuGroup before SelectionMenuGroup, ShapeMenuGroup first → every shape holding ignoredRules · CanvasContextMenu in StateMenuGroup before SelectionMenuGroup → every shape holding schema · adornment RulesChip after TypeChips → every shape holding schema
        prose-maps           service ProseMapService · overlay ProseMapFrames
        draw-engine          draw engine · insertion spot
        automation           command line draw · command line apply · command line rehearse · command line show · command line capture · command line kinds · command line measure · host commands
        title-names          draw names
        port-edges           draw edges
        validation-checks    draw checks
        mention-texts        draw labels · draw text text/x-canvas-mentions
        type-names           draw text text/x-canvas-type · draw edge identity is · draw value schema
        draw-field-values    draw value fieldValues · draw value endRule · draw reports members is, endOf, fits, relates
        color-names          draw text text/x-canvas-color
        group-draw           draw groups
        drawings             file property drawings · draw records
        queries              service QueryState · query engine
        query-translation    service QueryTranslator · service Interpretations
        title-queries        query names
        board-queries        query board names
        mention-queries      query word :mentions · query word :mentioned-by · query text text/x-canvas-mentions
        validation-queries   query word :invalid · query word :warned · query word :incomplete
        type-queries         query word :is-a · query text text/x-canvas-type · query word :misfit · ask fact fields · ask fact instances · ask fact connections · query path fieldValues
        color-queries        query text text/x-canvas-color
        group-queries        query word :grouped-with
        selection-queries    query word :selected
        drawing-queries      query word :drawn-by("…") members key, in · query word :changed("…") members key, in, changed
        query-commands       command line query · command line query-vocabulary
        decision-commands    command line decide
        query-slash          /query → the command bar's target
        neighbors            service NeighborState · outlines
        arrow-lights         neighbor light · neighbor light · key hint ⌥ Hover Show What Points to It
        mention-lights       neighbor light · neighbor light · key hint ⌃⌥ Hover Show Mentions
        type-lights          neighbor light · neighbor light · key hint ⌥ Hover a Type Show Its Instances and Subtypes
        engineering-lights   neighbor light · neighbor light · neighbor light · neighbor light · neighbor light
        neighbor-details     service NeighborList · ShapeDetails in Connections → every shape · RowDetails in Connections → every shape with parts
        moving               /move-to /move-near → every shape with a box · CanvasContextMenu in MoveToMenuGroup before StateMenuGroup → every shape with a box · ContentsMoves
        reordering           command bringToFront in ReorderSection · shortcut ] → command bringToFront · command bringForward in ReorderSection · shortcut ⌥] → command bringForward · command sendBackward in ReorderSection · shortcut ⌥[ → command sendBackward · command sendToBack in ReorderSection · shortcut [ → command sendToBack · ShapeContextMenus in ReorderMenuGroup before StateMenuGroup → every shape painted in document order · /bring-to-front /send-to-back /bring-in-front-of /send-behind → every shape painted in document order
        line-rows            service LineRowsService · service RowFolds · service RowBundles · service RowCuts · layout input connection-bundle · selection units · outlines · layout input line-rows-shown · layout input line-rows-width · command foldRows in RowFoldsSection · shortcut ⌃⌘↑ → command foldRows · command unfoldRows in RowFoldsSection · shortcut ⌃⌘↓ → command unfoldRows · ShapeFaces · parts FoldLines → every shape written as lines · CanvasContextMenu in RowsMenuGroup after ShapeMenuGroup
        engineering          kit engineering · service KitNames · key hint ↩ in a Row Next Row; on an Empty Row, Finish · key hint Home or End in a Row First or Last Row · key hint ⌥↑ ⌥↓ in a Row Move the Row · key hint ⌘⌫ then ⌫ in a Row Delete the Row · key hint ⇧↩ in a Row New Shape Beside It · key hint ⌘L in a Row Connect the Row · key hint ⌘↓ in a Column Show the Column's Details · key hint ⌘↓ in an Endpoint Show the Endpoint's Details · key hint ⌥⇥ on a Table or API Select Its Rows · key hint Space on an Endpoint Change the Endpoint's Method · channel foreign-key · edge type foreign-key · channel calls · edge type calls · channel writes · edge type writes · channel reads · edge type reads · service KeyIndex · connection look · shape table · label Table → table · tool table · command insert:table in KitShapes<EngineeringKit> · tint → table · property title → table · ShapeTitles → table · ContentsTitles → table · mentionable → table · ShapeResizing → table · parts resize handles → table · ContentsRows → table · ShapeDetails → table · accessibility → table · line rows (columns) → table · row moves (columns) → table · items rows → table · ports foreign-key on rows → table · ports writes → table · ports reads → table · connect picks → table · RowDetails in Column first → table · shape enum-type · label Enum → enum-type · tool enum-type · command insert:enum-type in KitShapes<EngineeringKit> · tint → enum-type · property title → enum-type · ShapeTitles → enum-type · ContentsTitles → enum-type · title pill look → enum-type · mentionable → enum-type · ShapeResizing → enum-type · parts resize handles → enum-type · ContentsRows → enum-type · ShapeDetails → enum-type · accessibility → enum-type · line rows (values) → enum-type · row moves (values) → enum-type · items rows → enum-type · keeps in step → enum-type · shape api · label API → api · tool api · command insert:api in KitShapes<EngineeringKit> · tint → api · property title → api · ShapeTitles → api · ContentsTitles → api · mentionable → api · ShapeResizing → api · parts resize handles → api · ContentsRows → api · ShapeDetails → api · accessibility → api · line rows (endpoints) → api · row moves (endpoints) → api · items rows → api · ports calls on rows → api · ports writes on rows → api · ports reads on rows → api · connect picks → api · RowDetails in Endpoint first → api · shape endpoint · label Endpoint → endpoint · tint → endpoint · ShapeTitles → endpoint · ContentsTitles → endpoint · mentionable → endpoint · ShapeResizing → endpoint · parts resize handles → endpoint · ContentsRows → endpoint · ShapeDetails → endpoint · accessibility → endpoint · line rows (endpoints) → endpoint · row moves (endpoints) → endpoint · items rows → endpoint · ports calls on rows → endpoint · ports writes on rows → endpoint · ports reads on rows → endpoint · connect picks → endpoint · shape database · label Database → database · tool database · command insert:database in KitShapes<EngineeringKit> · tint → database · property title → database · ShapeTitles → database · ContentsTitles → database · title tab → database · mentionable → database · ShapeResizing → database · parts resize handles → database · ContentsRows → database · ShapeDetails → database · accessibility → database · command createDatabase · CanvasContextMenu in DatabaseMenuGroup after TransformMenuGroup · /database → the command bar's target · /table → the command bar's target · /api → the command bar's target · command newVersion · command groupByPrefix · CanvasContextMenu in APIMenuGroup after TransformMenuGroup, RowsMenuGroup after ShapeMenuGroup · /new-version → the command bar's target · /group-by-prefix → the command bar's target · draw value columns · draw value values · draw value server · draw value endpoints · paste reader SQL · paste reader OpenAPI
        engineering-find     service EnumUsers · findable rows → table · findable row pills → table · findable rows → enum-type · findable rows → api
        engineering-agents   query word :route("…") members routes · query part names of table · query part names of enum-type · query part names of api · query part names of endpoint · ask fact tables · ask fact apis
        """)
    },
    test("the guide shows the registry report as it is") {
        let guide = try String(contentsOf: URL(fileURLWithPath: "docs/plugin-system.md"), encoding: .utf8)
        let lead = "`registry.report` prints who contributes what: the runtime half of the graph, pinned by a test.\n\n```\n"
        let start = try require(guide.range(of: lead), "the guide's report is gone").upperBound
        let end = try require(guide.range(of: "\n```", range: start..<guide.endIndex)).lowerBound
        expectEqual(String(guide[start..<end]), try ShippedPlugins.registry(model: ScriptedLanguageModel()).report)
    },
    test("every placed kind has a panel: a note its header over the Connections and Style tabs, a subboard its Description tab before them, a frame and an arrow those two alone, a reference that tab alone; a type note its Schema and Rules tabs between them; every nameable kind's header renames it") {
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
        // A note that's a type has its schema's tab, after Connections.
        let type = h.editor.addTypeNote(TypeSchemaProperty.starter, frame: CGRect(x: 3400, y: 100, width: 200, height: 200))
        let typeLayout = state.layout(for: try require(h.editor.document[type]))
        panels.append("\(typeLayout.headerText): \(typeLayout.tabs.map(\.title).joined(separator: ", "))")
        expectEqual(panels, ["(Note): Connections, Style", "(Untitled Subboard): Description, Connections, Style", "(Untitled Frame): Connections, Style", "Arrow: Connections, Style", "Reference: Connections",
                         "(Note): Connections, Schema, Rules, Style"])
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
        // Another title: two shapes of one path are warned about that too (PathValidationPlugin).
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
    test("a note and a subboard of one title, in no container, each warn (PathValidationPlugin): a line in Issues, an orange dot; renamed apart, neither") {
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
