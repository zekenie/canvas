import Adornments
import AppKit
import Automation
import Boards
import Canvas
import Clipboard
import Connections
import ContextMenus
import DetailPanel
import DrawLexicon
import Find
import Frames
import JumpTo
import Keyboard
import LanguageModels
import Locking
import Mentions
import Moving
import Neighbors
import ProseMaps
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
import TableOfContents
import Titles
import Topology
import Transform
import Validation

/// The static composition point: which plugins ship, in which order (the toolbar's order, and the
/// order overlays draw in). Tests import this, so they check exactly what ships. It joins no two
/// plugins: what one needs of another is a point the one declares and the other fills, and what a
/// window places around its canvas is the plugins' own, in the host's slots (HostSlots), which the
/// window (CanvasUI) reads from the registry.
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
            SlashCommandsPlugin(),
            // The table of contents, and its list in the detail panel where the panel has no one shape to show.
            TableOfContentsPlugin(), ContentsOverviewPlugin(),
            TitlesPlugin(),
            // After Titles, whose names its pills show, and the table of contents, whose rows it names.
            MentionsPlugin(),
            // Getting around a file's boards (a subboard's): opening one, ⌘↑, the path. Then the board shown's
            // name over the table of contents, with the way up.
            BoardsPlugin(), BoardContentsPlugin(),
            // Finding text on the board shown and every board under it (⌘F, ⌘G): after Adornments, so a
            // hit's ring draws over a title's pill, and Topology, whose walk of the file orders the hits. Then
            // its panel in the detail panel's place while it's open, and Boards' names over each board's rows.
            FindPlugin(), FindPanelPlugin(), BoardFindPlugin(),
            // What Find searches, from the plugins that draw it, each after Find and its owner: titles,
            // mention text (a note's, a schema card's description), arrows' labels.
            TitleFindPlugin(), MentionFindPlugin(), ArrowFindPlugin(),
            // Jump To (⌘K): goes to a shape by its title and where it is. After Titles, whose titles it
            // lists, and Boards, whose way of following a shape it takes.
            JumpToPlugin(),
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
            // What words say of what's lower level, asked of the model: a schema card's highlights.
            ProseMapsPlugin(),
            // The command line's commands, and what `canvas draw` takes from the plugins that own a
            // concern: titles for names, ports' connections for edges, validity for its warnings, and
            // mentions for text (`@[Title]` in a note's text names the shape called that).
            AutomationPlugin(), TitleNamesPlugin(), PortEdgesPlugin(), ValidationChecksPlugin(), MentionTextsPlugin(),
            // Reading the file: `canvas query`, and what queries take from the plugins that own a concern:
            // titles for names, boards' names, mentions for text and relations, validity and the selection
            // for their words.
            QueriesPlugin(), QueryTranslationPlugin(prompt: QueryPrompt.system, referenceRule: QueryPrompt.referenceRule), TitleQueriesPlugin(), BoardQueriesPlugin(), MentionQueriesPlugin(), ValidationQueriesPlugin(),
            SelectionQueriesPlugin(),
            QueryCommandsPlugin(),
            // Hover a shape, on the canvas or by its row in the table of contents, and what it connects to is outlined by how: after the
            // query plugins, whose engine it asks, and Selection and the table of contents, whose hovers it follows. Then the lights,
            // from the plugins that own the edges, in the order a shape's rings go: arrows' (points to, pointed to by), then
            // mentions' (mentions, mentioned by).
            NeighborsPlugin(), ArrowLightsPlugin(), MentionLightsPlugin(),
            // `/move-to` and `/move-near`: a shape moved into a frame, onto a subboard's board or beside a shape, on any board,
            // placed as `canvas draw` places one. After every plugin whose every-shape commands a note lists before them.
            MovingPlugin(),
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
}
