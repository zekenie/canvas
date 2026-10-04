import Adornments
import AppKit
import Boards
import Canvas
import CanvasTesting
import ContextMenus
import DetailPanel
import Keyboard
import Selection
import SlashCommands
import SwiftUI
import TestKit
import Titles

// Fixtures only: CanvasTesting's kinds and pockets, plus a local drawer, so every test here shows
// the horizontal knows no real kind.

/// A box that owns a board, opened through the kind's own sugar (`drawer.opensBoard`), and named
/// by Titles; pockets (CanvasTesting's) open through the form for another plugin's kind.
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

/// Pockets open onto their boards from another plugin, and are named by Titles.
@MainActor func pocketBoards() -> Contributor {
    Contributor(id: "pocket-boards") { r in
        r.title(Pocket.self, pill: false, contents: false)
        r.opensBoard(Pocket.self, placeholder: "Untitled Pocket", systemImage: "tray")
    }
}

/// Every plugin opening a board takes: keys, the selection, the panel, menus and titles (with the
/// adornments that show their pills, and the slash commands they offer).
@MainActor func boardsPlugins(_ more: [any CanvasPlugin] = []) -> [any CanvasPlugin] {
    [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), CardsPlugin(), PocketsPlugin(), DrawersPlugin(), DetailPanelPlugin(),
     ContextMenusPlugin(), AdornmentsPlugin(), SlashCommandsPlugin(), TitlesPlugin(), BoardsPlugin(), pocketBoards()] + more
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
    let window: NSWindow
    let hosting: NSHostingView<BoardPath>

    /// `size` is the canvas's, which a crumb's menu stays inside.
    init(_ editor: CanvasEditor, rootName: String = "Plans", size: CGSize = CGSize(width: 900, height: 120)) {
        self.editor = editor
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        hosting = NSHostingView(rootView: BoardPath(editor: editor, rootName: rootName))
        // The canvas's size, as the host's overlay proposes it; not the path's own.
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: size)
        window.contentView = hosting
        window.settle()
    }

    /// The crumbs that are buttons, leading first; "…" (`folded`) isn't among them. (Their titles
    /// are drawn by SwiftUI, not the button's: `pathTests` reads them from the crumbs.)
    var buttons: [NSButton] {
        let fold = folded
        return hosting.descendants(NSButton.self).filter { $0 !== fold && frame(of: $0).minY < Self.pillBottom }
            .sorted { frame(of: $0).minX < frame(of: $1).minX }
    }

    /// "…": the button over the view its menu is placed against (`BoardPath.foldedAnchor`). Never
    /// clicked here but on screen (`menuTests`): its menu is modal. What the menu holds is
    /// `BoardPath.foldedMenu`'s, read and chosen from without showing it.
    var folded: NSButton? {
        guard let anchor = hosting.descendants(NSView.self).first(where: { $0.identifier == BoardPath.foldedAnchor }) else { return nil }
        let place = frame(of: anchor)
        return hosting.descendants(NSButton.self).first { frame(of: $0).contains(CGPoint(x: place.midX, y: place.midY)) }
    }

    /// The buttons of the menu that shows, below the pill, top first: each row's, and a disclosure
    /// triangle's before a row with rows under it.
    var menuButtons: [NSButton] {
        hosting.descendants(NSButton.self).filter { frame(of: $0).minY >= Self.pillBottom }
            .sorted { (frame(of: $0).minY, frame(of: $0).minX) < (frame(of: $1).minY, frame(of: $1).minX) }
    }

    /// Where a view is, from the canvas's top left, in points.
    func frame(of view: NSView) -> CGRect {
        let rect = hosting.convert(view.bounds, from: view)
        return hosting.isFlipped ? rect : CGRect(x: rect.minX, y: hosting.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Below the pill, which is 8 points down and 27 tall (`BoardPath.coveredHeight`, 35).
    static let pillBottom: CGFloat = 40

    /// Whether the path draws anything: a pixel of it that isn't the window's background.
    var drawsSomething: Bool {
        let bitmap = snapshot(hosting)
        let background = pixel(bitmap, at: CGPoint(x: 1, y: hosting.bounds.height - 1))
        return stride(from: 0, to: hosting.bounds.height, by: 2).contains { y in
            stride(from: 0, to: hosting.bounds.width, by: 2).contains { pixel(bitmap, at: CGPoint(x: $0, y: y)) != background }
        }
    }
    var redrawn: Int { editor.boardCrumbs?.pathRedrawn ?? 0 }

    /// Clicks the crumb button `index` from the leading end ("…" isn't one).
    func click(_ index: Int) throws {
        try require(buttons.dropFirst(index).first, "no crumb button \(index) of \(buttons.count)").performClick(nil)
        window.settle()
    }
}
