import Adornments
import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import Colors
import ContextMenus
import CoreGraphics
import Keyboard
import LanguageRules
import Mentions
import Reordering
import Selection
import SlashCommands
import TableOfContents
import TestKit
import Titles
import Topology
import Types

/// The Color ▸ items an arrow's menu holds, with None checked: an arrow has no color yet.
private let arrowColorItems = ["Color ▸", "  Gray", "  Red", "  Orange", "  Yellow", "  Green", "  Teal", "  Blue", "  Indigo", "  Purple", "  Pink", "  —", "  ✓ None", "  —", "  Edit Colors…"]

/// The examples' tests: each works on CanvasTesting's boxes, so none depends on a shipped kind.
@MainActor let examplesTests = Suite("Examples", [
    test("the examples' report: who contributes what") {
        let registry = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), SlashCommandsPlugin(), ReorderingPlugin()])
        expectEqual(registry.report, """
        core            tool hand · command undo · command redo · command insertBeside first in InsertMenu.Shapes · command zoomIn in ViewMenu.Zoom · command zoomOut in ViewMenu.Zoom · command zoomToActualSize in ViewMenu.Zoom · command zoomToFit in ViewMenu.Zoom · command pageUp · command pageDown · command scrollToStart · command scrollToEnd
        keyboard        service KeyboardState · tool tips · menu keys · keyboard help · key strokes · key releases · shortcut H → tool hand · shortcut Space → Pan · shortcut ⎋ → Cancel · shortcut ⌘. → Cancel · shortcut ⌘Z → command undo · shortcut ⇧⌘Z → command redo · shortcut Q → Tool Lock · shortcut ⇧↩ → command insertBeside · shortcut ⌘= → command zoomIn · shortcut ⌘- → command zoomOut · shortcut = → command zoomIn · shortcut - → command zoomOut · shortcut ⌘0 → command zoomToActualSize · shortcut ⇧0 → command zoomToActualSize · shortcut ⇧1 → command zoomToFit · shortcut ⇞ → command pageUp · shortcut ⇟ → command pageDown · shortcut ↖ → command scrollToStart · shortcut ↘ → command scrollToEnd · key hint ⇧ Drag Move Along One Axis · key hint ⌘ Scroll Zoom
        selection       service SelectionState · service RefusalShake · tool select · shortcut V → tool select · default tool select · outlines · overlay GroupFocusOverlay · overlay HandlesOverlay · overlay PartFocusOverlay · overlay ItemsOverlay · key hint ⇧ or ⌘ Click Add or Remove From Selection · key hint ⌘ Drag Select Shapes Wholly in the Box · key hint ⌥ Drag Drag a Copy · key hint ⇧ Resize Keep Proportions · key hint ⌥ Resize Resize From the Center · command shapes · accessible order · accessible parts · command delete · shortcut ⌫ → command delete · shortcut ⌦ → command delete · command selectAll · shortcut ⌘A → command selectAll · command goBack in NavigationSection · shortcut ⌘[ → command goBack · shortcut ⌃- → command goBack · command goForward after goBack in NavigationSection · shortcut ⌘] → command goForward · shortcut ⌃_ → command goForward · command openSelection in NavigationSection · shortcut ⌘↓ → command openSelection · shortcut ↩ → Open Selection · shortcut ⌤ → Open Selection · shortcut ⌥↩ → Open Selection · press focused · command zoomToSelection in ViewMenu.Zoom · shortcut ⇧2 → command zoomToSelection · command smartMagnify · shortcut ← → Nudge, Pan or Step Rows · shortcut ⇧← → Nudge, Pan or Step Rows · shortcut → → Nudge, Pan or Step Rows · shortcut ⇧→ → Nudge, Pan or Step Rows · shortcut ↑ → Nudge, Pan or Step Rows · shortcut ⇧↑ → Nudge, Pan or Step Rows · shortcut ↓ → Nudge, Pan or Step Rows · shortcut ⇧↓ → Nudge, Pan or Step Rows · shortcut ⌥← → Resize or Move Rows · shortcut ⌥⇧← → Resize or Move Rows · shortcut ⌥→ → Resize or Move Rows · shortcut ⌥⇧→ → Resize or Move Rows · shortcut ⌥↑ → Resize or Move Rows · shortcut ⌥⇧↑ → Resize or Move Rows · shortcut ⌥↓ → Resize or Move Rows · shortcut ⌥⇧↓ → Resize or Move Rows · shortcut ⌥⇥ → Next Part · shortcut ⌥⇧⇥ → Previous Part · shortcut ⇥ → Next Shape · shortcut ⇧⇥ → Previous Shape · shortcut ⌥⌘← → Select Nearest Shape · shortcut ⌥⇧⌘← → Add Nearest Shape to Selection · shortcut ⌥⌘→ → Select Nearest Shape · shortcut ⌥⇧⌘→ → Add Nearest Shape to Selection · shortcut ⌥⌘↑ → Select Nearest Shape · shortcut ⌥⇧⌘↑ → Add Nearest Shape to Selection · shortcut ⌥⌘↓ → Select Nearest Shape · shortcut ⌥⇧⌘↓ → Add Nearest Shape to Selection
        context-menus   service ContextMenuState · secondary-click menu · selection menu · command showContextMenu · shortcut ⌃↩ → command showContextMenu · shortcut Menu → command showContextMenu · CanvasContextMenu in SelectionMenuGroup last
        slash-commands  service SlashCommandState · key hint / at a Line's Start Run a Command
        reordering      command bringToFront in ReorderSection · shortcut ] → command bringToFront · command bringForward in ReorderSection · shortcut ⌥] → command bringForward · command sendBackward in ReorderSection · shortcut ⌥[ → command sendBackward · command sendToBack in ReorderSection · shortcut [ → command sendToBack · ShapeContextMenus in ReorderMenuGroup before StateMenuGroup → every shape painted in document order · /bring-to-front /send-to-back /bring-in-front-of /send-behind → every shape painted in document order
        """)
    },
    test("Reordering: every kind but those painted by anchor gets Arrange; to front and to back keep the selection's order") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), ContextMenusPlugin(), ArrowsPlugin(), TableOfContentsPlugin(), AdornmentsPlugin(),
                                            SlashCommandsPlugin(), ColorsPlugin(), TitlesPlugin(), MentionsPlugin(), TypesPlugin(), LanguageRulesPlugin(),
                                            FixturesPlugin(), ReorderingPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        let c = h.add(Box(CGRect(x: 400, y: 0, width: 100, height: 100)))
        h.editor.selectedShapeIDs = [c, a]
        let menu = try require(h.secondaryClick(at: CGPoint(x: 50, y: 50)))
        expectEqual(menu.outline, ["Arrange ▸", "  Bring to Front", "  Bring Forward", "  Send Backward", "  Send to Back", "—", "Delete"])
        try menu.choose("Arrange", "Send to Back")
        expectEqual(h.editor.document.shapes.map(\.id), [a, c, b])
        try require(h.secondaryClick()).choose("Arrange", "Bring to Front")
        expectEqual(h.editor.document.shapes.map(\.id), [b, a, c])
        // An arrow, drawn just above what it joins, doesn't.
        let arrow = h.add(Arrow(start: .free(CGPoint(x: 0, y: 500)), end: .free(CGPoint(x: 400, y: 500))))
        expectEqual(try require(h.secondaryClick(at: CGPoint(x: 200, y: 500))).outline,
                    ["Toggle Start Arrowhead", "Toggle End Arrowhead", "—"] + arrowColorItems + ["—", "Delete"], "no Arrange for an arrow")
        expect(!h.key("]") && !h.editor.canPerform(.bringToFront), "nor do the keys restack it")
        h.editor.selectedShapeIDs = [arrow, a]
        expect(!h.key("["), "nor a selection it's in")
    },
    test("Reordering: ], ⌥], ⌥[ and [ run Arrange's commands on the selection, each one step named for the item, and the items show the keys") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), SlashCommandsPlugin(), FixturesPlugin(), ReorderingPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 50, y: 0, width: 100, height: 100)))
        let c = h.add(Box(CGRect(x: 60, y: 0, width: 100, height: 100)))
        h.editor.selectedShapeIDs = [b, a]
        let steps: [(title: String, key: String, held: Modifiers, order: [ShapeID])] = [
            ("Bring to Front", "]", [], [c, a, b]), ("Send Backward", "[", .option, [a, b, c]),
            ("Send to Back", "[", [], [a, b, c]), ("Bring Forward", "]", .option, [c, a, b]),
        ]
        for step in steps {
            h.hold(step.held)
            expect(h.key(step.key), step.title)
            expectEqual(h.editor.document.shapes.map(\.id), step.order, step.title)
            expectEqual(h.editor.undoHistory.undoName, step.title)
        }
        h.hold([])
        h.editor.selection = nil
        expect(!h.key("]") && !h.key("["), "nothing selected: the keys go on")
        let menu = try require(h.secondaryClick(at: CGPoint(x: 10, y: 50)))
        let arrange = try require(menu.item(withTitle: "Arrange")?.submenu)
        expectEqual(arrange.items.map(\.title), ["Bring to Front", "Bring Forward", "Send Backward", "Send to Back"])
        expectEqual(arrange.items.map(\.keyEquivalent), ["]", "]", "[", "["])
        expectEqual(arrange.items.map(\.keyEquivalentModifierMask), [[], .option, .option, []])
    },
    test("Reordering: /bring-to-front and /send-to-back run Arrange's commands on the shapes typed for, each one step named as the item") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), SlashCommandsPlugin(), FixturesPlugin(), ReorderingPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        let c = h.add(Box(CGRect(x: 400, y: 0, width: 100, height: 100)))
        let state = try require(h.editor.slashCommands)
        expectEqual(state.commands(for: .selection([c, a])).map(\.name), ["bring-to-front", "send-to-back", "bring-in-front-of", "send-behind"])
        expect(state.run("send-to-back", for: .selection([c, a]), with: SlashArguments([])))
        expectEqual(h.editor.document.shapes.map(\.id), [a, c, b])
        expectEqual(h.editor.undoHistory.undoName, "Send to Back")
        expect(state.run("bring-to-front", for: .selection([c, a]), with: SlashArguments([])))
        expectEqual(h.editor.document.shapes.map(\.id), [b, a, c])
        expectEqual(h.editor.undoHistory.undoName, "Bring to Front")
        expect(!state.run("bring-to-front", for: .selection([c]), with: "now"), "it takes nothing")
    },
    test("Reordering: /bring-in-front-of and /send-behind put the shapes just above or below the shape named, in one step, those there already staying") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), SlashCommandsPlugin(), FixturesPlugin(), ReorderingPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        let c = h.add(Box(CGRect(x: 400, y: 0, width: 100, height: 100)))
        let d = h.add(Box(CGRect(x: 600, y: 0, width: 100, height: 100)))
        let state = try require(h.editor.slashCommands)
        func named(_ id: ShapeID) -> SlashArguments { SlashArguments([.shape(id, label: "Named")]) }
        let before = h.editor.document
        expect(state.run("bring-in-front-of", for: .selection([b, a]), with: named(c)))
        expectEqual(h.editor.document.shapes.map(\.id), [c, a, b, d], "just above c, a still below b")
        expectEqual(h.editor.undoHistory.undoName, "Bring in Front")
        expect(state.run("send-behind", for: .selection([d, b]), with: named(a)))
        expectEqual(h.editor.document.shapes.map(\.id), [c, b, d, a], "just below a, b still below d")
        expectEqual(h.editor.undoHistory.undoName, "Send Behind")
        expect(state.run("bring-in-front-of", for: .text(c), with: named(b)), "typed in a shape's own text")
        expectEqual(h.editor.document.shapes.map(\.id), [b, c, d, a])
        h.editor.undo()
        h.editor.undo()
        h.editor.undo()
        expectEqual(h.editor.document, before, "each one step")
        for arguments: SlashArguments in [SlashArguments([]), "c", SlashArguments([.shape(c, label: "C"), .shape(d, label: "D")])] {
            expect(!state.run("bring-in-front-of", for: .selection([a]), with: arguments), "one shape, and nothing else")
        }
    },
    test("Reordering: the shape /bring-in-front-of and /send-behind take is one they'd put a shape past, on the board shown, painted in document order") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), ContextMenusPlugin(), ArrowsPlugin(), TableOfContentsPlugin(), AdornmentsPlugin(),
                                            SlashCommandsPlugin(), ColorsPlugin(), TitlesPlugin(), MentionsPlugin(), TypesPlugin(), LanguageRulesPlugin(),
                                            FixturesPlugin(), CorralsPlugin(), ReorderingPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let corral = h.add(Corral(CGRect(x: 200, y: 0, width: 300, height: 200)))
        let b = h.add(Box(CGRect(x: 600, y: 0, width: 100, height: 100)))
        let held = h.add(Box(CGRect(x: 220, y: 20, width: 100, height: 100)))
        h.editor.put([held], in: corral)
        let arrow = h.add(Arrow(start: .free(CGPoint(x: 0, y: 500)), end: .free(CGPoint(x: 400, y: 500))))
        expectEqual(h.editor.document.shapes.map(\.id), [a, corral, b, held, arrow])
        let state = try require(h.editor.slashCommands)
        @MainActor func admitted(_ name: String, for shapes: [ShapeID]) throws -> [ShapeID] {
            let command = try require(state.command(named: name, for: .selection(shapes)))
            return h.editor.document.shapes.map(\.id).filter { command.admits($0) }
        }
        expectEqual(try admitted("bring-in-front-of", for: [a]), [corral, b, held], "what's above it, never the arrow, drawn by its ends")
        expectEqual(try admitted("send-behind", for: [a]), [], "nothing is below it")
        expectEqual(try admitted("bring-in-front-of", for: [corral]), [b], "not what it holds, which goes with it")
        expectEqual(try admitted("bring-in-front-of", for: [b]), [corral, held], "the corral too, though b is above it: in front of it is in front of what it holds")
        expectEqual(try admitted("send-behind", for: [held]), [b], "not the corral, nor what's below it: what it holds paints above it")
        expectEqual(try admitted("send-behind", for: [a, b]), [a, corral], "one of them past it is enough, a among them too")
        expect(state.command(named: "send-behind", for: .selection([arrow])) == nil, "an arrow isn't offered them")
        expect(state.run("send-behind", for: .selection([held]), with: SlashArguments([.shape(b, label: "B")])))
        expectEqual(h.editor.document.shapes.map(\.id), [a, corral, held, b, arrow])
        expectEqual(try admitted("bring-in-front-of", for: [b]), [], "in front of the corral and all it holds now")
    },
    test("Reordering: each Arrange item is one step, and undoing it puts back the order and every stacking key") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), SlashCommandsPlugin(), FixturesPlugin(), ReorderingPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 50, y: 0, width: 100, height: 100)))
        let c = h.add(Box(CGRect(x: 60, y: 0, width: 100, height: 100)))
        h.editor.selectedShapeIDs = [b, a]
        let expectedOrders: [[ShapeID]] = [[c, a, b], [a, b, c], [a, b, c], [c, a, b]]
        var documents = [h.editor.document]
        for (i, title) in ["Bring to Front", "Send Backward", "Send to Back", "Bring Forward"].enumerated() {
            try require(h.secondaryClick(at: CGPoint(x: 10, y: 50))).choose("Arrange", title)
            expectEqual(h.editor.document.shapes.map(\.id), expectedOrders[i], title)
            expectEqual(h.editor.undoHistory.undoName, title)
            documents.append(h.editor.document)
        }
        for expected in documents.dropLast().reversed() {
            h.editor.undo()
            expectEqual(h.editor.document, expected)
            expectEqual(h.editor.document.shapes.map(\.stackingKey), expected.shapes.map(\.stackingKey))
        }
        for expected in documents.dropFirst() {
            h.editor.redo()
            expectEqual(h.editor.document, expected)
        }
    },
])
