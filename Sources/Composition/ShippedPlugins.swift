import Adornments
import AppKit
import Automation
import Boards
import Canvas
import CanvasRPC
import Clipboard
import Connections
import ContextMenus
import CoreGraphics
import DetailPanel
import DrawLexicon
import Find
import Frames
import JumpTo
import Keyboard
import LanguageModels
import Locking
import Mentions
import Publishing
import Queries
import QueryCommands
import QueryLexicon
import QueryTranslation
import References
import Reordering
import Schemas
import Selection
import SlashCommands
import Snapping
import StickyNotes
import Subboards
import SwiftUI
import TableOfContents
import Titles
import Topology
import Transform
import Validation

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
            // What connects to what (arrows, mentions), for the whole file: its index hears each
            // commit before the services that read it (the table of contents', Mentions').
            TopologyPlugin(),
            // The kinds. Frames beside subboards, the two ways of grouping shapes (a region of this
            // board, a board of its own), after notes: the toolbar's Note, Subboard, Frame, Schema, Reference.
            ArrowsPlugin(), StickyNotesPlugin(), SubboardsPlugin(), FramesPlugin(), SchemasPlugin(), ReferencesPlugin(),
            // After Validation: what's shown on shapes draws over its outline.
            ValidationPlugin(), AdornmentsPlugin(), DetailPanelPlugin(), ContextMenusPlugin(),
            // Slash commands: the list at a `/` in the text views Mentions hosts it in. Titles offers `/title`, Locking `/lock`.
            SlashCommandsPlugin(), TableOfContentsPlugin(), TitlesPlugin(),
            // After Titles, whose names its pills show, and the table of contents, whose rows it names.
            MentionsPlugin(),
            // Getting around a file's boards (a subboard's): opening one, ⌘↑, the path.
            BoardsPlugin(),
            // Finding text on the board shown and every board under it (⌘F, ⌘G): after Adornments, so a
            // hit's ring draws over a title's pill, and Topology, whose walk of the file orders the hits.
            FindPlugin(),
            // What Find searches, from the plugins that draw it, each after Find and its owner: titles,
            // mention text (a note's, a schema card's description), arrows' labels.
            TitleFindPlugin(), MentionFindPlugin(), ArrowFindPlugin(),
            // Jump To (⌘K): goes to a shape by its title and where it is. After Titles, whose titles it
            // lists, and Boards, whose way of following a shape it takes. Its rows' symbols are tinted as
            // a mention of the shape is (JumpTo doesn't import Mentions).
            JumpToPlugin(appearance: { record, registry in
                registry.mentionAppearance(of: record).map { JumpToAppearance(systemImage: $0.systemImage, tint: $0.tint) }
            }),
            // Turning shapes into other kinds: a frame into a subboard, from its menu.
            TransformPlugin(),
            ValidationDetailsPlugin(), ValidationContentsPlugin(), MentionValidationPlugin(), TitleValidationPlugin(),
            ClipboardPlugin(pasteboard: pasteboard),
            LockingPlugin(),
            // Public shapes, the ones another shape may stand for; its chip sits beside the lock's.
            PublishingPlugin(),
            // What a drag moves snaps to the shapes in view: their edges, their middles and the spaces
            // between them.
            SnappingPlugin(),
            // Ports, whose arrows `ArrowPortsPlugin` draws. After Adornments: a shape's dots draw
            // above its adornments (the lock chip among them), and are found before them.
            PortsPlugin(), ArrowPortsPlugin(),
            LanguageModelsPlugin(model: model),
            // The command line's commands, and what `canvas draw` takes from the plugins that own a
            // concern: titles for names, ports' connections for edges, and validity for its warnings.
            AutomationPlugin(), TitleNamesPlugin(), PortEdgesPlugin(), ValidationChecksPlugin(),
            // Reading the file: `canvas query`, and what queries take from the plugins that own a concern:
            // titles for names, boards' names, mentions for text and relations, validity and the selection
            // for their words.
            QueriesPlugin(), QueryTranslationPlugin(prompt: QueryPrompt.system, referenceRule: QueryPrompt.referenceRule), TitleQueriesPlugin(), BoardQueriesPlugin(), MentionQueriesPlugin(), ValidationQueriesPlugin(),
            SelectionQueriesPlugin(),
            QueryCommandsPlugin(),
            // The example (Examples/): one line here; delete it to leave it out.
            ReorderingPlugin(),
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
    /// its symbol and a button up (⌘↑'s `.enclosingBoard`); on the root it's `rootName` (the
    /// file's name, as the window and the path's root crumb call it), else "Board". While Find is
    /// open, its panel takes the panel over (Escape and ⌘. there close it), its boards named as the
    /// path names them and each shape's symbol tinted as a mention of it is.
    public static func detailPanel(editor: CanvasEditor, onExit: @escaping @MainActor () -> Void, rootName: String = "") -> some View {
        DetailPanelView(editor: editor, onExit: onExit, overview: {
            TableOfContentsView(editor: editor, onExit: onExit, heading: { contentsHeading(for: $0, rootName: rootName) })
        }, takeover: DetailTakeover(isActive: { $0.find?.isActive ?? false }, onEscape: { editor.find?.close() }) {
            FindPanel(editor: editor, onExit: onExit, heading: { findHeading(of: $0, in: editor, rootName: rootName) },
                      tint: { editor.registry.mentionAppearance(of: $0)?.tint })
        })
    }

    /// A board's heading over its rows in Find's panel: named as the path names it (Boards'), the
    /// root `rootName`, else "Board".
    public static func findHeading(of board: BoardID, in editor: CanvasEditor, rootName: String = "") -> FindHeading {
        FindHeading(editor.name(of: board, root: rootName.isEmpty ? "Board" : rootName), systemImage: editor.symbol(of: board))
    }

    /// The table of contents' heading in `detailPanel`: the board shown's crumb (Boards'), so it's
    /// named as the path names it and redraws as the path does, with ⌘↑'s way up, called as Go ›
    /// Enclosing Board is, with its key; on the root, `rootName`, or nil where that's empty, for
    /// the list's own, "Board".
    public static func contentsHeading(for editor: CanvasEditor, rootName: String = "") -> ContentsHeading? {
        guard let crumb = editor.boardCrumbs?.crumbs.last else { return rootName.isEmpty ? nil : ContentsHeading(rootName) }
        return ContentsHeading(crumb.title, systemImage: crumb.systemImage, up: .enclosingBoard, upTitle: enclosingBoard,
                               upHelp: editor.registry.help(enclosingBoard, forCommand: .enclosingBoard))
    }

    /// What going up is called in the list, as the Go menu calls it.
    private static let enclosingBoard = "Enclosing Board"

    /// Where the board shown is in its file (Boards' `BoardPath`), for the app to place over the top
    /// middle of the canvas (`.overlay(alignment: .top)`): a pill of crumbs, the root's named
    /// `rootName` (the file's name), nothing on the root. Only the pill takes clicks.
    public static func boardPath(editor: CanvasEditor, rootName: String) -> some View {
        BoardPath(editor: editor, rootName: rootName)
    }

    /// How far down over the canvas `boardPath` reaches on a board, for the app to tell the editor
    /// (`BoardConfiguration.coveredTop`): a fit leaves the path's pill clear.
    public static func coveredTop(on board: BoardID) -> CGFloat {
        BoardPath.coveredHeight(on: board)
    }

    /// What the board shown is called, for its window's subtitle (`BoardConfiguration.boardName`):
    /// its crumb's title, as the path and the list's heading name it; nil on the root, which the
    /// window's title, the file's name, names.
    public static func boardName(of editor: CanvasEditor) -> String? {
        editor.boardCrumbs?.crumbs.last?.title
    }

    /// A toolbar tool's tooltip, for the app's tool picker: its label, and the key that switches to
    /// it ("Note (N)").
    public static func help(for tool: ToolDescriptor, in registry: Registry) -> String {
        registry.help(for: tool)
    }

    /// The commands the plugins give the command line (Automation's), for the app's command server:
    /// what `canvas` shows of each, and how to run one, by name, on a board's editor (nil for a
    /// command about the app as a whole), answering when it's done: at once for most, later for
    /// one that waits.
    public static func commands(in registry: Registry)
        -> (specs: [CommandSpec], run: @MainActor (_ name: String, _ params: JSON, _ editor: CanvasEditor?) async throws(RPCError) -> JSON) {
        (registry.automationCommands, { name, params, editor async throws(RPCError) in
            try await registry.runAutomationCommand(name, params: params, editor: editor)
        })
    }
}

public enum WelcomeBoard {
    /// The six notes' text: the top row left to right, then the bottom row.
    public static let texts = [
        "Double-click empty space to add a note. Drag a note to move it.",
        "Double-click a note (or select it and press Return) to edit it.",
        "Pinch to zoom, scroll with two fingers to pan. Press H for the hand tool; drag the background to select.",
        "Point at a note, then drag one of its dots to another note to link them.",
        "Pause inside a note while linking to aim at that spot. Hold ⌥ to go all the way in.",
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
