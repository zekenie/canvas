import Adornments
import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import Colors
import ContextMenus
import CoreGraphics
import Keyboard
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
private let arrowColorItems = ["Color ▸", "  Gray", "  Red", "  Orange", "  Yellow", "  Green", "  Teal", "  Blue", "  Indigo", "  Purple", "  Pink", "  —", "  ✓ None"]

/// The examples' tests: each works on CanvasTesting's boxes, so none depends on a shipped kind.
@MainActor let examplesTests = Suite("Examples", [
    test("the examples' report: who contributes what") {
        let registry = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), ReorderingPlugin()])
        expectEqual(registry.report, """
        core           tool hand · command undo · command redo · command zoomIn · command zoomOut · command zoomToActualSize · command zoomToFit
        keyboard       service KeyboardState · tool tips · keyboard help · key strokes · key releases · shortcut H → tool hand · shortcut Space → Pan · shortcut ⎋ → Cancel · shortcut ⌘. → Cancel · shortcut ⌘Z → command undo · shortcut ⇧⌘Z → command redo · shortcut Q → Tool Lock · shortcut ⌘= → command zoomIn · shortcut ⌘- → command zoomOut · shortcut = → command zoomIn · shortcut - → command zoomOut · shortcut ⌘0 → command zoomToActualSize · shortcut ⇧0 → command zoomToActualSize · shortcut ⇧1 → command zoomToFit · key hint ⇧ Drag Move Along One Axis · key hint ⌘ Scroll Zoom
        selection      service SelectionState · service RefusalShake · tool select · shortcut V → tool select · default tool select · outlines · overlay GroupFocusOverlay · overlay HandlesOverlay · key hint ⇧ or ⌘ Click Add or Remove From Selection · key hint ⌘ Drag Select Shapes Wholly in the Box · key hint ⌥ Drag Drag a Copy · key hint ⇧ Resize Keep Proportions · key hint ⌥ Resize Resize From the Center · command delete · shortcut ⌫ → command delete · shortcut ⌦ → command delete · command selectAll · shortcut ⌘A → command selectAll · command goBack · shortcut ⌘[ → command goBack · command openSelection · shortcut ⌘↓ → command openSelection · shortcut ↩ → Open Selection · shortcut ⌤ → Open Selection · command zoomToSelection · shortcut ⇧2 → command zoomToSelection · command smartMagnify · shortcut ← → Nudge · shortcut ⇧← → Nudge · shortcut → → Nudge · shortcut ⇧→ → Nudge · shortcut ↑ → Nudge · shortcut ⇧↑ → Nudge · shortcut ↓ → Nudge · shortcut ⇧↓ → Nudge · shortcut ⇥ → Next Shape · shortcut ⇧⇥ → Previous Shape · shortcut ⌥⌘← → Select Nearest Shape · shortcut ⌥⇧⌘← → Add Nearest Shape to Selection · shortcut ⌥⌘→ → Select Nearest Shape · shortcut ⌥⇧⌘→ → Add Nearest Shape to Selection · shortcut ⌥⌘↑ → Select Nearest Shape · shortcut ⌥⇧⌘↑ → Add Nearest Shape to Selection · shortcut ⌥⌘↓ → Select Nearest Shape · shortcut ⌥⇧⌘↓ → Add Nearest Shape to Selection
        context-menus  service ContextMenuState · secondary-click menu · selection menu · CanvasContextMenu
        reordering     command bringToFront · shortcut ] → command bringToFront · command bringForward · shortcut ⌥] → command bringForward · command sendBackward · shortcut ⌥[ → command sendBackward · command sendToBack · shortcut [ → command sendToBack · ShapeContextMenus
        """)
    },
    test("Reordering: every kind but those painted by anchor gets Arrange; to front and to back keep the selection's order") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), ContextMenusPlugin(), ArrowsPlugin(), TableOfContentsPlugin(), AdornmentsPlugin(),
                                            SlashCommandsPlugin(), ColorsPlugin(), TitlesPlugin(), MentionsPlugin(), TypesPlugin(), FixturesPlugin(), ReorderingPlugin()])
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
        expectEqual(try require(h.secondaryClick(at: CGPoint(x: 200, y: 500))).outline, arrowColorItems + ["—", "Delete"], "no Arrange for an arrow")
        expect(!h.key("]") && !h.editor.canPerform(.bringToFront), "nor do the keys restack it")
        h.editor.selectedShapeIDs = [arrow, a]
        expect(!h.key("["), "nor a selection it's in")
    },
    test("Reordering: ], ⌥], ⌥[ and [ run Arrange's commands on the selection, each one step named for the item, and the items show the keys") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), FixturesPlugin(), ReorderingPlugin()])
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
    test("Reordering: each Arrange item is one step, and undoing it puts back the order and every stacking key") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), FixturesPlugin(), ReorderingPlugin()])
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
