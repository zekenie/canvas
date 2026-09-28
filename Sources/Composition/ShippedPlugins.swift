import Adornments
import AppKit
import ArrowPorts
import Arrows
import Automation
import Boards
import Canvas
import CanvasRPC
import Checklists
import Clipboard
import ContextMenus
import CoreGraphics
import DetailPanel
import Eraser
import Keyboard
import LanguageModels
import Locking
import Mentions
import Polylines
import PortEdges
import Ports
import RectangleTitles
import Rectangles
import Reordering
import Schemas
import Selection
import Snapping
import StickyNotes
import Subboards
import SwiftUI
import TableOfContents
import TitleNames
import Titles
import Validation
import ValidationChecks
import ValidationContents
import ValidationDetails

/// The static composition point: which plugins ship, in which order (the toolbar's order, and the
/// order overlays draw in). Tests import this, so they check exactly what ships.
@MainActor
public enum ShippedPlugins {
    /// The model the app ships: Claude Haiku 4.5, over the network, with the key saved in Settings
    /// (`AnthropicKeyStore.standard`). Only the app passes it; tests pass a `ScriptedLanguageModel`.
    public static var anthropicModel: any LanguageModel { AnthropicModel(keys: .standard) }

    /// The shipped list, its clipboard on `pasteboard` and its language model `model`. The app passes
    /// the system's pasteboard and `anthropicModel`; tests pass a pasteboard of their own, so they
    /// never touch the user's, and a `ScriptedLanguageModel`, so they never reach the network (which
    /// is why `model` has no default).
    public static func plugins(pasteboard: NSPasteboard = .general, model: any LanguageModel) -> [any CanvasPlugin] {
        [
            // First: every key is registered with Keyboard; the others build on Selection, and its
            // handles draw below their view overlays.
            KeyboardPlugin(), SelectionPlugin(),
            ArrowsPlugin(), StickyNotesPlugin(), SubboardsPlugin(), SchemasPlugin(),
            // After Validation: what's shown on shapes draws over its outline.
            ValidationPlugin(), AdornmentsPlugin(), DetailPanelPlugin(), ContextMenusPlugin(), TableOfContentsPlugin(), ChecklistsPlugin(), TitlesPlugin(),
            // After Titles, whose names its pills show, and the table of contents, whose rows it names.
            MentionsPlugin(),
            // Getting around a file's boards (a subboard's): opening one, ⌘↑, the path.
            BoardsPlugin(),
            ValidationDetailsPlugin(), ValidationContentsPlugin(), ClipboardPlugin(pasteboard: pasteboard),
            LockingPlugin(),
            // What a drag moves snaps to the shapes in view: their edges, their middles and the spaces
            // between them.
            SnappingPlugin(),
            // Ports, whose arrows the bridge draws. After Adornments: a shape's dots draw above its
            // adornments (the lock chip among them), and are found before them.
            PortsPlugin(), ArrowPortsPlugin(),
            LanguageModelsPlugin(model: model),
            // The command line's commands, and what `canvas draw` takes from the plugins that own a
            // concern: titles for names, ports' connections for edges, and validity for its warnings.
            AutomationPlugin(), TitleNamesPlugin(), PortEdgesPlugin(), ValidationChecksPlugin(),
            // The examples (Examples/). Each is one line here; delete it to leave it out.
            RectanglesPlugin(), PolylinesPlugin(), EraserPlugin(), RectangleTitlesPlugin(), ReorderingPlugin(),
        ]
    }

    public static func registry(pasteboard: NSPasteboard = .general, model: any LanguageModel) throws(RegistryError) -> Registry {
        try Registry(plugins: plugins(pasteboard: pasteboard, model: model))
    }

    public static func makeEditor(document: CanvasDocument = WelcomeBoard.document(), scheduler: any Scheduler = TaskScheduler(),
                                  pasteboard: NSPasteboard = .general, model: any LanguageModel) -> CanvasEditor {
        do {
            return CanvasEditor(registry: try registry(pasteboard: pasteboard, model: model), document: document, scheduler: scheduler)
        } catch {
            fatalError("The shipped plugins don't register: \(error)")   // CompositionTests catches this first
        }
    }

    /// The Settings window's content, for the app to host (Infinite Canvas › Settings…, ⌘,): the
    /// Anthropic API key, saved where `anthropicModel` reads it.
    public static func settings() -> some View {
        AnthropicSettingsView(keys: .standard)
    }

    /// The detail panel, for the app to place beside the canvas. It follows the editor's selection:
    /// one shape's details, or, with nothing or several selected, the table of contents (the whole
    /// board, or the selection), as data-canvas's details panel does. `onExit` must give the
    /// keyboard back to the canvas. Inside a subboard, the list's header names its board, with
    /// its symbol and a button up (⌘↑'s `.enclosingBoard`); on the root it's "Board".
    public static func detailPanel(editor: CanvasEditor, onExit: @escaping @MainActor () -> Void) -> some View {
        DetailPanelView(editor: editor, onExit: onExit) {
            TableOfContentsView(editor: editor, onExit: onExit, heading: { contentsHeading(for: $0) })
        }
    }

    /// The table of contents' heading in `detailPanel`: the board shown's crumb (Boards'), so it's
    /// named as the path names it and redraws as the path does, with ⌘↑'s way up; nil on the root,
    /// where it's the list's own, "Board".
    public static func contentsHeading(for editor: CanvasEditor) -> ContentsHeading? {
        editor.boardCrumbs?.crumbs.last.map { ContentsHeading($0.title, systemImage: $0.systemImage, up: .enclosingBoard) }
    }

    /// Where the board shown is in its file (Boards' `BoardPath`), for the app to place over the top
    /// middle of the canvas (`.overlay(alignment: .top)`): a pill of crumbs, the root's named
    /// `rootName` (the file's name), nothing on the root. Only the pill takes clicks.
    public static func boardPath(editor: CanvasEditor, rootName: String) -> some View {
        BoardPath(editor: editor, rootName: rootName)
    }

    /// A toolbar tool's tooltip, for the app's tool picker: its label, and the key that switches to
    /// it ("Note (N)").
    public static func help(for tool: ToolDescriptor, in registry: Registry) -> String {
        registry.help(for: tool)
    }

    /// The commands the plugins give the command line (Automation's), for the app's command server:
    /// what `canvas` shows of each, and how to run one, by name, on a board's editor (nil for a
    /// command about the app as a whole).
    public static func commands(in registry: Registry)
        -> (specs: [CommandSpec], run: @MainActor (_ name: String, _ params: JSON, _ editor: CanvasEditor?) throws(RPCError) -> JSON) {
        (registry.automationCommands, { name, params, editor throws(RPCError) in
            try registry.runAutomationCommand(name, params: params, editor: editor)
        })
    }
}

public enum WelcomeBoard {
    /// The six notes' text: the top row left to right, then the bottom row.
    public static let texts = [
        "Double-click empty space to add a note. Drag a note to move it.",
        "Double-click a note (or select it and press Return) to edit it.",
        "Pinch to zoom, scroll with two fingers to pan. Press H for the hand tool; drag the background to select.",
        "Press A for the arrow tool, then drag from one shape to another.",
        "Pause inside a note while drawing to aim at that spot. Hold ⌥ to go all the way in, ⌘ to not attach.",
        "Select an arrow and drag its middle handle to bend it.",
    ]

    /// The board, its notes saying `texts` in that order.
    public static func document(texts: [String] = WelcomeBoard.texts) -> CanvasDocument {
        precondition(texts.count == 6, "the welcome board has six notes")
        let origins = [CGPoint(x: 80, y: 80), CGPoint(x: 460, y: 80), CGPoint(x: 840, y: 80),
                       CGPoint(x: 80, y: 420), CGPoint(x: 460, y: 420), CGPoint(x: 840, y: 420)]
        let notes = zip(origins, texts).map { origin, text in
            ShapeRecord(StickyNote(frame: CGRect(origin: origin, size: StickyNote.defaultSize), text: MentionText(plain: text)))
        }
        func bound(_ note: ShapeRecord<StickyNote>) -> ArrowTerminal {
            .bound(ArrowBinding(shapeID: note.id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
        }
        let arrows = [
            Arrow(start: bound(notes[0]), end: bound(notes[1])),
            Arrow(start: bound(notes[3]), end: bound(notes[4])),
            Arrow(start: bound(notes[4]), end: bound(notes[5]), bend: 70),
        ]
        return CanvasDocument(shapes: notes.map(AnyShapeRecord.init) + arrows.map { AnyShapeRecord(ShapeRecord($0)) })
    }
}
