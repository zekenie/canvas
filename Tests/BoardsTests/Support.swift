import Adornments
import AppKit
import Boards
import Canvas
import CanvasTesting
import ContextMenus
import DetailPanel
import Keyboard
import Selection
import SwiftUI
import TestKit
import Titles

// Fixtures only: CanvasTesting's kinds and pockets, plus a local drawer, so every test here shows
// the horizontal knows no real kind.

/// A box that owns a board, opened through the kind's own sugar (`drawer.opensBoard`), and named
/// by Titles; pockets (CanvasTesting's) open through the bridge form.
struct Drawer: BoxShapeProps {
    static let kind: ShapeKind = "drawer"
    static let properties = Properties<Drawer> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
}

extension Drawer {
    init() { self.init(.zero) }
}

struct DrawerDefinition {}

extension DrawerDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Drawer>, in context: RenderContext) {
        context.fillWithShadow(CGPath(rect: shape.frame, transform: nil), .brown)
    }
}

extension DrawerDefinition: BoardOwning {}

struct DrawersPlugin: CanvasPlugin {
    var id: PluginID { "drawers" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(DrawerDefinition()) { drawer in
            drawer.title(pill: false, contents: false)
            drawer.opensBoard(placeholder: "Untitled Drawer", systemImage: "archivebox")
        }
    }
}

/// Pockets open onto their boards from a bridge, and are named by Titles.
@MainActor func pocketBoards() -> Contributor {
    Contributor(id: "pocket-boards") { r in
        r.title(Pocket.self, pill: false, contents: false)
        r.opensBoard(Pocket.self, placeholder: "Untitled Pocket", systemImage: "tray")
    }
}

/// Every plugin opening a board takes: keys, the selection, the panel, menus and titles (with the
/// adornments that show their pills).
@MainActor func boardsPlugins(_ more: [any CanvasPlugin] = []) -> [any CanvasPlugin] {
    [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), CardsPlugin(), PocketsPlugin(), DrawersPlugin(), DetailPanelPlugin(),
     ContextMenusPlugin(), AdornmentsPlugin(), TitlesPlugin(), BoardsPlugin(), pocketBoards()] + more
}

func record<P: ShapeProps>(_ id: ShapeID, _ props: P) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, props)) }

/// A root holding box A and drawer D, left to right, 100 points apart; D's board holding pocket P
/// where D is, and P's board holding box B and card C.
struct Nest {
    let a = ShapeID(), d = ShapeID(), p = ShapeID(), b = ShapeID(), c = ShapeID()
    var dBoard: BoardID { BoardID(owner: d) }
    var pBoard: BoardID { BoardID(owner: p) }

    var file: CanvasFile {
        CanvasFile(root: CanvasDocument(shapes: [record(a, Box(CGRect(x: 0, y: 0, width: 100, height: 100))),
                                                 record(d, Drawer(CGRect(x: 200, y: 0, width: 100, height: 100)))]),
                   children: [d: CanvasDocument(shapes: [record(p, Pocket(CGRect(x: 200, y: 0, width: 100, height: 100)))]),
                              p: CanvasDocument(shapes: [record(b, Box(CGRect(x: 0, y: 0, width: 100, height: 100))),
                                                         record(c, Card(CGRect(x: 200, y: 0, width: 100, height: 100)))])])
    }

    /// Where D's middle is on the root, and P's on D's board, while the camera hasn't moved.
    let dPoint = CGPoint(x: 250, y: 50), pPoint = CGPoint(x: 250, y: 50)
}

@MainActor func nestHarness(_ nest: Nest, _ more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try EditorHarness(plugins: boardsPlugins(more), file: nest.file)
}

/// A chain of `depth` pockets, each on the board of the one before, the first on the root: the
/// ids root side first.
@MainActor func chainHarness(depth: Int) throws -> (EditorHarness, [ShapeID]) {
    let ids = (0..<depth).map { _ in ShapeID() }
    let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    var children: [ShapeID: CanvasDocument] = [:]
    for (owner, inner) in zip(ids, ids.dropFirst()) { children[owner] = CanvasDocument(shapes: [record(inner, Pocket(frame))]) }
    let file = CanvasFile(root: CanvasDocument(shapes: [record(ids[0], Pocket(frame))]), children: children)
    return (try EditorHarness(plugins: boardsPlugins(), file: file), ids)
}

extension EditorHarness {
    /// Names a shape through Titles, as renaming it in its header does.
    func name(_ id: ShapeID, _ title: String?) {
        editor.transact("Rename") { $0.update(id) { $0[TitleProperty.self] = title } }
    }

    /// ⌘↑ on the canvas: whether a shortcut took it.
    func commandUp() -> Bool {
        hold(.command)
        defer { hold([]) }
        return key(String(KeyChord.upArrow.key))
    }
}

/// The path, hosted as the app hosts it, in an unshown window. The editor keeps real time, so
/// SwiftUI's updates land while the main run loop runs (`window.spin`).
@MainActor
final class PathWindow {
    let editor: CanvasEditor
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
    let hosting: NSHostingView<BoardPath>

    init(_ editor: CanvasEditor, rootName: String = "Plans") {
        self.editor = editor
        hosting = NSHostingView(rootView: BoardPath(editor: editor, rootName: rootName))
        window.contentView = hosting
        window.settle()
    }

    /// The crumbs that are buttons, leading first; "…" is a pull-down, not among them. (Their
    /// titles are drawn by SwiftUI, not the button's: `pathTests` reads them from the crumbs.)
    var buttons: [NSButton] {
        hosting.descendants(NSButton.self).filter { !($0 is NSPopUpButton) }
            .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }
    var folded: NSPopUpButton? { hosting.descendants(NSPopUpButton.self).first }
    var redrawn: Int { editor.boardCrumbs?.pathRedrawn ?? 0 }

    /// Clicks the crumb button `index` from the leading end.
    func click(_ index: Int) throws {
        try require(buttons.dropFirst(index).first, "no crumb button \(index) of \(buttons.count)").performClick(nil)
        window.settle()
    }
}
