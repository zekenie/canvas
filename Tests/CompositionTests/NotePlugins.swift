import Adornments
import Canvas
import Colors
import Connections
import ContextMenus
import DetailPanel
import Keyboard
import Mentions
import Selection
import SlashCommands
import StickyNotes
import TableOfContents
import Titles
import Topology
import Types

/// The plugins a note stands on, as StickyNotesTests have them, for the tests of a note's relation rows over real
/// arrows (`noteRelationRowsTests`, `noteRelationFreshTests`, `noteCompactTests`), which add Arrows' plugins: they
/// are here and not in StickyNotesTests, since a test of a note may not import Arrows.
@MainActor var notePlugins: [any CanvasPlugin] {
    [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), StickyNotesPlugin(), AdornmentsPlugin(), DetailPanelPlugin(),
     ContextMenusPlugin(), SlashCommandsPlugin(), ColorsPlugin(), TableOfContentsPlugin(), TitlesPlugin(), MentionsPlugin(), PortsPlugin(), TypesPlugin()]
}
