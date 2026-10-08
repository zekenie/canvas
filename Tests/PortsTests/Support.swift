import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Foundation
import Keyboard
import Selection
import Topology

// Fixtures only (CanvasTesting's boxes, discs and tags), so every test here shows the horizontal
// knows no real kind, and no arrow: connections are tags, drawn by a connector that only records.

/// Two channels, as a plugin that owns what they mean would declare them.
enum Wire {}
extension Wire: Channel {
    static let id: ChannelID = "wire"
    static var color: NSColor { .systemRed }
}

enum Pipe {}
extension Pipe: Channel {
    static let id: ChannelID = "pipe"
}

/// The family of connections the tests' connectors draw, as Topology's edge type: each channel's
/// edge type is under it.
enum Hookup {}
extension Hookup: EdgeType {
    static let id: EdgeTypeID = "hookup"
}

/// What the test connector saw: each connection begun, and each drag its session got.
@MainActor
final class ConnectionLog {
    var begun: [Connection] = []
    var drags: [CGPoint] = []
    /// Which shapes the connector says it can start from and end on.
    var canConnect: (ShapeID) -> Bool = { _ in true }
    /// Whether it draws: false, and `begin` returns nil.
    var draws = true
}

/// The session the test connector hands back: it records where it's dragged, in view points.
final class RecordingSession {
    let connections: ConnectionLog
    init(_ connections: ConnectionLog) { self.connections = connections }
}

extension RecordingSession: Session {
    func drag(_ pointer: Pointer, in editor: CanvasEditor) { connections.drags.append(pointer.view) }
}

/// A connector: tags are what connections are, and it records what it's asked to draw.
@MainActor func connectorPlugin(_ connections: ConnectionLog) -> Contributor {
    Contributor(id: "tag-connector") { registrar in
        registrar.connects(Tag.self, edgeType: Hookup.self, canConnect: { id, _ in connections.canConnect(id) }) { connection, _ in
            guard connections.draws else { return nil }
            connections.begun.append(connection)
            return RecordingSession(connections)
        }
    }
}

/// Boxes have ports on the wire channel (`sides`, `role`), and discs on the pipe; a plugin declares both.
@MainActor func channelsPlugin(boxSides: [PortSide] = PortSide.allCases, boxRole: PortRole = .both, discRole: PortRole = .both) -> Contributor {
    Contributor(id: "channels") { registrar in
        registrar.channel(Wire.self)
        registrar.channel(Pipe.self)
        registrar.ports(Box.self, on: Wire.self, sides: boxSides, role: boxRole)
        registrar.ports(Disc.self, on: Pipe.self, role: discRole)
    }
}

/// What the app has around Ports: the keys, the selection, the fixtures, the channels and a connector;
/// on one board, or on `file`'s.
@MainActor func portsHarness(_ connections: ConnectionLog = ConnectionLog(), boxSides: [PortSide] = PortSide.allCases,
                             boxRole: PortRole = .both, discRole: PortRole = .both, more: [any CanvasPlugin] = [],
                             file: CanvasFile? = nil) throws -> EditorHarness {
    let plugins: [any CanvasPlugin] = [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FixturesPlugin(), PortsPlugin(),
                                       channelsPlugin(boxSides: boxSides, boxRole: boxRole, discRole: discRole), connectorPlugin(connections)] + more
    guard let file else { return try EditorHarness(plugins: plugins) }
    return try EditorHarness(plugins: plugins, file: file)
}

/// A box at (100, 100), 200 × 100: its dots are 12 points out from the middle of each side, at zoom 1.
let boxFrame = CGRect(x: 100, y: 100, width: 200, height: 100)
let topDot = CGPoint(x: 200, y: 88), rightDot = CGPoint(x: 312, y: 150), bottomDot = CGPoint(x: 200, y: 212), leftDot = CGPoint(x: 88, y: 150)
/// Where the pointer rests on the box, clear of its dots.
let boxMiddle = CGPoint(x: 200, y: 150)
/// The box's dots, in `PortSide.allCases`'s order.
let boxDots: [(side: PortSide, center: CGPoint)] = [(.top, topDot), (.right, rightDot), (.bottom, bottomDot), (.left, leftDot)]

/// Where a shape is in the world for it to show at `rect` (view points) at `zoom`, with the camera's
/// origin at zero.
func world(_ rect: CGRect, zoom: CGFloat) -> CGRect {
    CGRect(x: rect.minX / zoom, y: rect.minY / zoom, width: rect.width / zoom, height: rect.height / zoom)
}

extension EditorHarness {
    /// Hovers the shape at `body`, so its dots show, then moves onto the dot at `dot`.
    func hoverDot(_ dot: CGPoint, from body: CGPoint = boxMiddle) {
        move(to: body)
        move(to: dot)
    }

    /// A drag from the dot at `dot` (reached from the shape at `body`) to `point`, released unless
    /// `releasing` is false.
    func connect(from dot: CGPoint, to point: CGPoint, via body: CGPoint = boxMiddle, releasing: Bool = true) {
        hoverDot(dot, from: body)
        press()
        drag(to: point)
        if releasing { release() }
    }
}

// MARK: Drawing

let wholeView = CGRect(x: 0, y: 0, width: 600, height: 400)

@MainActor func render(_ h: EditorHarness) -> NSBitmapImageRep { renderBitmap(h.editor, size: wholeView.size) }

/// How many of the 16 points in the middle of a dot at `center` differ between two renders: all of
/// them where one draws the dot there and the other doesn't (a dot's fill covers its middle, lit or
/// not), none where neither does.
@MainActor func dotPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, at center: CGPoint) -> Int {
    changedPixels(a, b, in: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4))
}

/// A band along the top edge of `rect` (less its corners), where a shape's outline is drawn.
func topEdge(of rect: CGRect) -> CGRect {
    CGRect(x: rect.minX + 20, y: rect.minY - 3, width: rect.width - 40, height: 6)
}

// MARK: More fixtures

/// A box with one handle, at its middle: a shape with handles (Selection's `HandleProviding`).
struct Dial: BoxShapeProps {
    static let kind: ShapeKind = "dial"
    static let properties = Properties<Dial> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
}

extension Dial {
    init() { self.init(.zero) }
}

struct DialDefinition {}

extension DialDefinition: ShapeDefinition, HandleProviding {
    func render(_ shape: ShapeRecord<Dial>, in context: RenderContext) {}
    func handles(of shape: ShapeRecord<Dial>, in context: ShapeContext) -> [HandleLocation<Int>] {
        [HandleLocation(0, at: CGPoint(x: shape.frame.midX, y: shape.frame.midY))]
    }
    func pressHandle(_ handle: Int, of shape: ShapeRecord<Dial>, at pointer: Pointer, in editor: CanvasEditor) -> HandlePress { .drag }
    func dragSession(for handle: Int, of shape: ShapeRecord<Dial>, from origin: CGPoint, in editor: CanvasEditor) -> any Session {
        IdleSession()
    }
}

/// Dials, with ports on the wire on every side, through their own registrar.
@MainActor func dialsPlugin() -> Contributor {
    Contributor(id: "dials") { registrar in
        registrar.shape(DialDefinition()) { dial in dial.ports(Wire.self) }
    }
}

/// Diamonds (CanvasTesting's): a shape without ports, which draws nothing.
@MainActor func diamondsPlugin() -> Contributor {
    Contributor(id: "diamonds") { registrar in registrar.shape(DiamondDefinition()) }
}

/// An editor like `portsHarness`'s, whose board also holds a box it keeps aside (its props don't
/// read), returned with it.
@MainActor func harnessKeepingABoxAside(_ connections: ConnectionLog) throws -> (h: EditorHarness, kept: ShapeID) {
    let registry = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FixturesPlugin(), PortsPlugin(), channelsPlugin(),
                                          connectorPlugin(connections)])
    let kept = ShapeID()
    let json = """
    { "format" : 1, "schema" : { "box" : 0 }, "shapes" : [
      { "id" : "\(kept)", "index" : "a0", "kind" : "box", "props" : { "frame" : "somewhere" } } ] }
    """
    let document = try BoardCodec(registry: registry).decode(Data(json.utf8)).document
    return (EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }, kept)
}

/// A plugin's line in the registry's report, less its id.
@MainActor func reportLine(_ registry: Registry, _ plugin: PluginID) -> String? {
    registry.report.split(separator: "\n").first { $0.hasPrefix(plugin.rawValue + " ") }
        .map { $0.dropFirst(plugin.rawValue.count).trimmingCharacters(in: .whitespaces) }
}
