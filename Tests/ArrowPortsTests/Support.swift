import Adornments
@_spi(Host) import Canvas
import CanvasTesting
import Colors
import Connections
import ContextMenus
import CoreGraphics
import Keyboard
import Mentions
import Selection
import SlashCommands
import TableOfContents
import Titles
import Topology
import Types

// Fixture shapes only, with channels of the tests' own, so nothing here imports a real vertical
// (the arrows come with Connections): boxes take the wire channel, discs the pipe. Boxes A and B
// sit where the POC's first two welcome notes do, and a disc below.
enum Wire {}
extension Wire: Channel {
    static let id: ChannelID = "wire"
}

enum Pipe {}
extension Pipe: Channel {
    static let id: ChannelID = "pipe"
}

let boxA = CGRect(x: 80, y: 80, width: 200, height: 200)
let boxB = CGRect(x: 460, y: 80, width: 200, height: 200)
let discC = CGRect(x: 460, y: 400, width: 200, height: 200)
/// Below A, clear of everything: another box, for ends re-aimed onto one.
let boxD = CGRect(x: 80, y: 400, width: 200, height: 200)
let fast: CGFloat = 3, slow: CGFloat = 0.1
let center = CGPoint(x: 0.5, y: 0.5)

/// A's right dot, 12 points outside the middle of its right side.
let aRightDot = CGPoint(x: 292, y: 180)

@MainActor
struct PortBoard {
    let h: EditorHarness
    let a: ShapeID
    let b: ShapeID
    let c: ShapeID

    init(more: [any CanvasPlugin] = []) throws {
        h = try EditorHarness(plugins: Self.plugins(more: more))
        a = h.add(Box(boxA))
        b = h.add(Box(boxB))
        c = h.add(Disc(discC))
    }

    /// What every board here has: the keys, the selection, the fixtures, arrows (whose labels are mention text, so
    /// Mentions and what it stands on), ports, `ArrowPortsPlugin`, and the tests' channels (boxes on the wire, discs on the pipe), then `more`.
    static func plugins(more: [any CanvasPlugin] = []) -> [any CanvasPlugin] {
        let channels = Contributor(id: "channels") { registrar in
            registrar.channel(Wire.self)
            registrar.channel(Pipe.self)
            registrar.ports(Box.self, on: Wire.self)
            registrar.ports(Disc.self, on: Pipe.self)
        }
        return [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FixturesPlugin(), ArrowsPlugin(), TableOfContentsPlugin(),
                AdornmentsPlugin(), ContextMenusPlugin(), SlashCommandsPlugin(), ColorsPlugin(), TitlesPlugin(), MentionsPlugin(), TypesPlugin(),
                PortsPlugin(), ArrowPortsPlugin(), channels] + more
    }

    var arrows: [ShapeRecord<Arrow>] { h.editor.document.shapes.compactMap { $0.typed(as: Arrow.self) } }

    func arrow(_ id: ShapeID) -> ShapeRecord<Arrow>? { h.editor.document[id]?.typed(as: Arrow.self) }

    /// Hovers A, then presses its dot at `dot`.
    func pressDot(_ dot: CGPoint = aRightDot) {
        h.move(to: CGPoint(x: 180, y: 180))
        h.move(to: dot)
        h.press()
    }

    /// Hovers A, then drags from its right dot to `point` at `speed`, and releases.
    func connect(from dot: CGPoint = aRightDot, to point: CGPoint, speed: CGFloat = fast, release: Bool = true) {
        pressDot(dot)
        h.drag(to: point, speed: speed)
        if release { h.release() }
    }

    /// An arrow from A's center to B's, both ends imprecise, on `channel`; nil, on none, as `canvas
    /// draw`'s `channel: none` makes them.
    @discardableResult
    func addArrow(channel: ChannelID?) -> ShapeID {
        var record = ShapeRecord(Arrow(start: .bound(ArrowBinding(shapeID: a, normalizedAnchor: center, isPrecise: false, isExact: false)),
                                       end: .bound(ArrowBinding(shapeID: b, normalizedAnchor: center, isPrecise: false, isExact: false))))
        record[ChannelProperty.self] = channel
        h.editor.transact { $0.insert(record) }
        return record.id
    }

    /// Selects `arrow` and drags its handle at `handle` (view points) to `point` at `speed`.
    func reaim(_ arrow: ShapeID, from handle: CGPoint, to point: CGPoint, speed: CGFloat = fast, release: Bool = true) {
        h.editor.selection = arrow
        h.move(to: handle)
        h.press()
        h.drag(to: point, speed: speed)
        if release { h.release() }
    }
}

/// A plugin giving `kind` ports on `channel` as well, with `role`.
@MainActor func morePorts<K: ShapeProps, C: Channel>(_ kind: K.Type, on channel: C.Type, role: PortRole = .both) -> Contributor {
    Contributor(id: "more-ports") { $0.ports(K.self, on: C.self, role: role) }
}

/// A binding at `anchor` in `shape`.
func binding(_ shape: ShapeID, _ anchor: CGPoint = center, precise: Bool = false, exact: Bool = false) -> ArrowTerminal {
    .bound(ArrowBinding(shapeID: shape, normalizedAnchor: anchor, isPrecise: precise, isExact: exact))
}

/// Whether `angle` is a whole number of 15° steps.
func isOnStep(_ angle: CGFloat) -> Bool { abs(angle - (angle / (.pi / 12)).rounded() * (.pi / 12)) < 1e-9 }
