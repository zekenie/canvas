import Adornments
import AppKit
import Boards
@_spi(Host) import Canvas
import CanvasTesting
import ContextMenus
import DetailPanel
import Foundation
import JumpTo
import Keyboard
import Selection
import SlashCommands
import SwiftUI
import Titles
import Topology

// Fixtures only: CanvasTesting's boxes, pockets (which own boards and open onto them, from another
// plugin's line) and corrals (which hold shapes, as frames do), every one titled through Titles'
// property, so Jump To knows no real kind. A shape's number is its id.

/// Titles for the kinds the story is made of, and pockets that open their boards.
func titled() -> Contributor {
    Contributor(id: "jump-titles") { r in
        r.title(Box.self, pill: false, contents: false)
        r.title(Pocket.self, pill: false, contents: false)
        r.title(Corral.self, pill: false, contents: false)
        r.opensBoard(Pocket.self, placeholder: "Untitled Pocket", systemImage: "tray")
    }
}

/// What Composition hands Jump To from Mentions, as a fixture: a box's symbol and tint (a pocket's,
/// a corral's, nothing).
let boxTint = NSColor.systemTeal
let tinted: JumpToAppearanceProvider = { record, _ in
    record.kind == Box.kind ? JumpToAppearance(systemImage: "shippingbox", tint: boxTint) : nil
}

/// What opening a board takes (keys, the selection, the panel, menus), titles, Topology and Boards,
/// then Jump To, and the titles of the fixtures.
@MainActor func jumpPlugins() -> [any CanvasPlugin] {
    [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FixturesPlugin(), PocketsPlugin(), CorralsPlugin(), CardsPlugin(), DetailPanelPlugin(),
     ContextMenusPlugin(), AdornmentsPlugin(), SlashCommandsPlugin(), TitlesPlugin(), BoardsPlugin(), JumpToPlugin(appearance: tinted), titled()]
}

func uuid(_ n: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", n) }
func id(_ n: Int) -> ShapeID { ShapeID(UUID(uuidString: uuid(n))!) }

func shape<P: ShapeProps>(_ n: Int, _ props: P, titled title: String? = nil, in container: Int? = nil) -> AnyShapeRecord {
    var record = AnyShapeRecord(ShapeRecord(id: id(n), props))
    record[TitleProperty.self] = title
    return container.map { record.copy(as: record.id, container: id($0)) } ?? record
}

func frame(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat = 100, _ height: CGFloat = 60) -> CGRect { CGRect(x: x, y: y, width: width, height: height) }

/// "alpha gamma checkout" in a file: four Checkouts, one in each of these places:
///
///     root:        1 pocket Alpha · 2 pocket Delta · 3 box "Plan note one" · 4 box "Planned notes" · 5 pocket, untitled · 6 box, untitled
///     Alpha:       11 pocket Beta · 12 box Checkout
///     Beta:        21 corral Gamma, holding 22 box Checkout and 23 pocket Epsilon
///     Epsilon:     31 box Checkout
///     Delta:       41 box Checkout
///     the 5 pocket: 51 box Cardamom
///
/// and a box (7) with a board of its own, which is no board the app shows: 91 box "Orphan" is on it.
func storyFile() -> CanvasFile {
    CanvasFile(root: CanvasDocument(shapes: [shape(1, Pocket(frame(90, 100, 200, 150)), titled: "Alpha"),
                                             shape(2, Pocket(frame(400, 100, 200, 150)), titled: "Delta"),
                                             shape(3, Box(frame(700, 100, 200, 150)), titled: "Plan note one"),
                                             shape(4, Box(frame(100, 400, 200, 150)), titled: "Planned notes"),
                                             shape(5, Pocket(frame(400, 400, 200, 150))),
                                             shape(6, Box(frame(700, 400, 200, 150))),
                                             shape(7, Box(frame(5000, 5000, 200, 150)))]),
               children: [id(1): CanvasDocument(shapes: [shape(11, Pocket(frame(100, 100)), titled: "Beta"),
                                                         shape(12, Box(frame(400, 100)), titled: "Checkout")]),
                          id(11): CanvasDocument(shapes: [shape(21, Corral(CGRect(x: 0, y: 0, width: 4000, height: 3000)), titled: "Gamma"),
                                                          shape(22, Box(frame(200, 200)), titled: "Checkout", in: 21),
                                                          shape(23, Pocket(frame(500, 200)), titled: "Epsilon", in: 21)]),
                          id(23): CanvasDocument(shapes: [shape(31, Box(frame(100, 100)), titled: "Checkout")]),
                          id(2): CanvasDocument(shapes: [shape(41, Box(frame(100, 100)), titled: "Checkout")]),
                          id(5): CanvasDocument(shapes: [shape(51, Box(frame(100, 100)), titled: "Cardamom")]),
                          id(7): CanvasDocument(shapes: [shape(91, Box(frame(100, 100)), titled: "Orphan")])])
}

/// The view's size in these tests.
let viewSize = CGSize(width: 1000, height: 700)

@MainActor func storyHarness(file: CanvasFile = storyFile()) throws -> EditorHarness {
    let h = try EditorHarness(plugins: jumpPlugins(), file: file)
    h.editor.viewportDidResize(to: viewSize)
    return h
}

extension EditorHarness {
    var jump: JumpToState { editor.jumpTo! }

    /// ⌘K, as the shortcut and Go › Jump To… run it.
    @discardableResult func openJumpTo() -> Bool { editor.perform(.jumpTo) }

    /// What the rows of `text` say: a header as "# Recent", a shape by its id's number, an empty state in parentheses.
    func listing(_ text: String) -> [String] {
        openJumpTo()
        jump.setQuery(text)
        return jump.rows.map(Self.say)
    }

    static func say(_ row: JumpToRow) -> String {
        switch row {
        case .header(let words): "# \(words)"
        case .empty(let words): "(\(words))"
        case .match(let candidate): "\(number(of: candidate.id))"
        }
    }

    /// The candidates the query lists, in order.
    func candidates(_ text: String) -> [JumpToCandidate] {
        openJumpTo()
        jump.setQuery(text)
        return jump.rows.compactMap(\.candidate)
    }
}

/// A fixture shape's number, from its id.
func number(of shape: ShapeID) -> Int { Int(shape.rawValue.uuidString.suffix(12))! }

extension CanvasEditor {
    func rename(_ id: ShapeID, _ title: String?, on board: BoardID) {
        transact(on: board, "Rename") { $0.update(id) { $0[TitleProperty.self] = title } }
    }
}
