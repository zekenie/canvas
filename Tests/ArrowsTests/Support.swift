import Adornments
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import ContextMenus
import DetailPanel
import CoreGraphics
import Geometry
import Keyboard
import Mentions
import Selection
import SlashCommands
import TableOfContents
import Titles
import Topology

// Two boxes where the POC's first two welcome notes are. Fixture shapes only: nothing here can
// import a real vertical, which is the proof that arrows don't know concrete kinds.
let boxA = CGRect(x: 80, y: 80, width: 200, height: 200)
let boxB = CGRect(x: 460, y: 80, width: 200, height: 200)
let fast: CGFloat = 3, slow: CGFloat = 0.1

/// What a board of arrows needs: the keys and the selection, the fixtures (`before` them arrows, if the
/// test has kinds that go ahead), arrows, and what their labels stand on: they're mention text, so
/// Mentions, after Titles (which draws its adornments) and the table of contents, on Topology, ContextMenus and SlashCommands.
@MainActor
func arrowsPlugins(before: [any CanvasPlugin] = [], more: [any CanvasPlugin] = []) -> [any CanvasPlugin] {
    [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FixturesPlugin()] + before
        + [ArrowsPlugin(), TableOfContentsPlugin(), AdornmentsPlugin(), ContextMenusPlugin(), SlashCommandsPlugin(), TitlesPlugin(), MentionsPlugin()] + more
}

/// What a label's mention text needs of the fixtures: boxes that are titled and mentioned (by their
/// titles), and a command arrows offer, `head`, which toggles the arrowhead at the end.
struct LabelFixturesPlugin: CanvasPlugin {
    var id: PluginID { "label-fixtures" }

    func register(into registrar: inout PluginRegistrar) {
        registrar.title(Box.self)
        registrar.mentionable(Box.self)
        registrar.slashCommands(Arrow.self) {
            SlashCommand("head", edit: { arrow, _ in arrow.endArrowhead.toggle() })
        }
    }
}

/// A board for labels that mention: `arrowsPlugins` with the detail panel (the kind that is mentioned
/// brings its Mentioned In tab to it) and `LabelFixturesPlugin`.
@MainActor
func labelPlugins(before: [any CanvasPlugin] = []) -> [any CanvasPlugin] {
    arrowsPlugins(before: before, more: [DetailPanelPlugin(), LabelFixturesPlugin()])
}

extension CanvasEditor {
    /// A box called `title`, in a transaction of its own (on the board shown).
    @discardableResult
    func addBox(_ title: String, at frame: CGRect) -> ShapeID {
        var box = ShapeRecord(Box(frame))
        box[TitleProperty.self] = title
        transact { $0.insert(box) }
        return box.id
    }

    func rename(_ id: ShapeID, to title: String) {
        transact { $0.update(id) { $0[TitleProperty.self] = title } }
    }
}

@MainActor
struct Board {
    let h: EditorHarness
    let a: ShapeID
    let b: ShapeID
    let arrow: ShapeID?
    /// Where B is.
    let second: CGRect

    /// Two boxes, optionally with an arrow between their centers.
    init(arrow bend: CGFloat? = nil, second: CGRect = boxB) throws {
        h = try EditorHarness(plugins: arrowsPlugins())
        a = h.add(Box(boxA))
        b = h.add(Box(second))
        self.second = second
        if let bend {
            let arrow = Arrow(start: .bound(ArrowBinding(shapeID: a, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)),
                              end: .bound(ArrowBinding(shapeID: b, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)),
                              bend: bend)
            self.arrow = h.add(arrow)
        } else {
            self.arrow = nil
        }
    }

    var arrows: [Arrow] { h.editor.document.shapes.compactMap { $0.typed(as: Arrow.self)?.props } }
    var arrowIDs: [ShapeID] { h.editor.document.shapes.filter { $0.kind == Arrow.kind }.map(\.id) }

    /// Selects the arrow and presses its end's handle, where the end is bound: B's center.
    func pressEnd() {
        h.editor.selection = arrow
        h.move(to: h.view(second.center))
        h.press()
    }

    /// Re-aims the arrow's end, the drag a port's connection is drawn with too: presses the end's
    /// handle (`pressEnd`), drags it off B at `fast` to `via`, empty canvas, where it lets go, then
    /// on to `to` at `speed`. Points are the view's.
    func reaimEnd(via: CGPoint = CGPoint(x: 400, y: 120), to: CGPoint, speed: CGFloat = fast, release: Bool = true) {
        pressEnd()
        h.drag(to: via, speed: fast)
        h.drag(to: to, speed: speed)
        if release { h.release() }
    }
}
