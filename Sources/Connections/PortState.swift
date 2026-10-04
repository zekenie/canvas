import AppKit
import Canvas
import Geometry
import Selection

/// A port's dot: its shape and the side it's on. What `editor.hoveredButton` and
/// `editor.pressedButton` are while the pointer's on one.
public struct PortDot: Hashable, Sendable {
    public let shape: ShapeID
    public let side: PortSide
    public init(shape: ShapeID, side: PortSide) {
        self.shape = shape
        self.side = side
    }
}

/// Per editor: every kind's ports (the port table, `KindPorts.table(in:)`) and the channels' colors,
/// found once (the registry is frozen); the shape whose dots show; and the connection being drawn
/// from one, while it is.
@MainActor
final class PortState {
    private unowned let editor: CanvasEditor
    let connector: ConnectorContribution?
    let kinds: [ShapeKind: KindPorts]
    let colors: [ChannelID: NSColor]
    /// The shape whose dots show: the one with ports the pointer is over, or last was, while it's
    /// still within reach of them.
    private(set) var host: ShapeID? {
        didSet { if host != oldValue { editor.setNeedsDisplay() } }
    }
    private var connection: Connection?
    private weak var connecting: (any Session)?

    init(editor: CanvasEditor) {
        self.editor = editor
        let registry = editor.registry
        connector = registry.connector
        kinds = KindPorts.table(in: registry)
        colors = Dictionary(registry.contributions(to: Channels.self).map { ($0.value.id, $0.value.color) }) { first, _ in first }
    }

    /// Whether ports show at all: there's a connector, the select tool is current, and the view isn't
    /// zoomed out past where a shape's dots can be told from its neighbors'.
    var isShowing: Bool {
        connector != nil && editor.currentToolID == .select && editor.camera.zoom >= PortStyle.minZoom
    }

    /// Whether a shape shows dots: its kind has some, and the connector can start from it (asked of
    /// the editor's document).
    func hasDots(_ id: ShapeID) -> Bool {
        guard let connector, let record = editor.document[id], !record.isOpaque,
              kinds[record.kind]?.dots.isEmpty == false else { return false }
        return connector.canConnect(id, editor.shapeContext)
    }

    /// A shape's dots, in the order of `PortSide.allCases`, with their centers in world units: just
    /// outside the middle of each side of its bounds, `PortStyle.offset` view points out.
    func dots(of id: ShapeID) -> [(dot: PortDot, center: CGPoint)] {
        guard let record = editor.document[id], let ports = kinds[record.kind], let bounds = bounds(of: id) else { return [] }
        let out = PortStyle.offset / editor.camera.zoom
        return PortSide.allCases.compactMap { side in
            guard ports.dots[side] != nil else { return nil }
            let edge = middle(of: side, of: bounds)
            let center = switch side {
            case .top: CGPoint(x: edge.x, y: edge.y - out)
            case .right: CGPoint(x: edge.x + out, y: edge.y)
            case .bottom: CGPoint(x: edge.x, y: edge.y + out)
            case .left: CGPoint(x: edge.x - out, y: edge.y)
            }
            return (PortDot(shape: id, side: side), center)
        }
    }

    private func bounds(of id: ShapeID) -> CGRect? {
        guard let bounds = editor.shapeContext.geometry(of: id)?.bounds, !bounds.isNull, !bounds.isInfinite else { return nil }
        return bounds
    }

    private func middle(of side: PortSide, of bounds: CGRect) -> CGPoint {
        switch side {
        case .top: CGPoint(x: bounds.midX, y: bounds.minY)
        case .right: CGPoint(x: bounds.maxX, y: bounds.midY)
        case .bottom: CGPoint(x: bounds.midX, y: bounds.maxY)
        case .left: CGPoint(x: bounds.minX, y: bounds.midY)
        }
    }

    /// A shape's dots that show, of those on `sides` (all, if nil): those no shape painted above it
    /// that the select tool would press covers at its center (an arrow leaving it there, a neighbor
    /// on top), so what shows is what a press there presses. A shape lying on a bigger one shows its
    /// dots over it. Each dot looks only at what's between the middle of its side and its center,
    /// where the shape itself is sure to be found, so it costs what's near the dot.
    func liveDots(of id: ShapeID, on sides: Set<PortSide>? = nil) -> [(dot: PortDot, center: CGPoint)] {
        guard let bounds = bounds(of: id) else { return [] }
        let shapes = editor.shapeContext
        return dots(of: id).filter { dot in
            guard sides?.contains(dot.dot.side) ?? true else { return false }
            let near = CGRect(enclosing: [middle(of: dot.dot.side, of: bounds), dot.center]).insetBy(dx: -1, dy: -1)
            let order = editor.paintOrder(in: near)                   // back to front
            guard let position = order.firstIndex(where: { $0.id == id }) else { return true }
            return !order[(position + 1)...].contains { shapes.hitTest(dot.center, shape: $0.id) && editor.isSelectable($0.id) }
        }
    }

    /// The dot under a view point, for the select tool (`CanvasButtons`): the nearest that shows
    /// within `PortStyle.hitRadius` of it, of the shape whose dots show, the shape under the point,
    /// or any shape with a dot there (a dot the pointer comes to straight from empty canvas shows its
    /// shape's, as data-canvas's halo does). Asked as the pointer moves, it also settles whose dots
    /// show: the dot's shape; else none while a handle is under the pointer (it takes the hover); else
    /// the shape under the pointer, if it has ports; else the one that showed them, while the pointer
    /// is within reach of them (over empty canvas, or a shape without ports); else none.
    func dot(atViewPoint point: CGPoint) -> PortDot? {
        // Nothing where the select tool hasn't seen the pointer move (just after a tool change, or a
        // first click into the window): no dots show there, so a press there presses what's under it.
        guard isShowing, editor.pointerOverCanvas != nil else {
            host = nil
            return nil
        }
        let camera = editor.camera, world = camera.toWorld(point)
        let under = editor.selectableShape(at: world)
        let underHasDots = under.map(hasDots) ?? false
        var shapes: [ShapeID] = []
        if let host, isNear(host, point), hasDots(host) { shapes.append(host) }
        if let under, !shapes.contains(under), underHasDots { shapes.append(under) }
        let reach = (PortStyle.offset + PortStyle.hitRadius) / camera.zoom
        for record in editor.paintOrder(in: CGRect(x: world.x - reach, y: world.y - reach, width: reach * 2, height: reach * 2)).reversed()
        where !shapes.contains(record.id) && hasDots(record.id) {
            shapes.append(record.id)
        }
        let near: [(dot: PortDot, distance: CGFloat)] = shapes.flatMap(dots(of:))
            .map { (dot: $0.dot, distance: camera.toView($0.center).distance(to: point)) }
            .filter { $0.distance <= PortStyle.hitRadius }
            .sorted { $0.distance < $1.distance }
        // Whether a dot shows is worked out only for the few this near.
        let hit = near.first { !liveDots(of: $0.dot.shape, on: [$0.dot.side]).isEmpty }?.dot
        if hit == nil, editor.handle(atViewPoint: point) != nil {
            // A handle takes the hover, as the select tool has it: no shape is hovered, so none shows
            // its dots.
            host = nil
            return nil
        }
        if let hit {
            host = hit.shape
        } else if let under, underHasDots {
            host = under
        } else if let host, !(isNear(host, point) && hasDots(host)) {
            self.host = nil
        }
        return hit
    }

    /// Whether a view point is within reach of a shape's dots: its bounds, grown by a dot's reach.
    func isNear(_ id: ShapeID, _ point: CGPoint) -> Bool {
        guard let bounds = editor.shapeContext.geometry(of: id)?.bounds, !bounds.isNull, !bounds.isInfinite else { return false }
        let reach = PortStyle.offset + PortStyle.hitRadius
        return editor.camera.toView(bounds).insetBy(dx: -reach, dy: -reach).contains(point)
    }

    /// A drag from a dot, past the drag threshold: the connector's session drawing the connection,
    /// from where the dot was pressed (world units).
    func connect(from dot: PortDot, at origin: CGPoint) -> (any Session)? {
        guard let connector, let record = editor.document[dot.shape], let channels = kinds[record.kind]?.dots[dot.side] else { return nil }
        let connection = Connection(shape: dot.shape, side: dot.side, channels: channels, origin: origin)
        guard let session = connector.begin(connection, editor) else { return nil }
        self.connection = connection
        connecting = session
        // Its dots go with the drag; the release (or the next move) finds whose show then.
        host = nil
        return session
    }

    /// The connection being drawn from a port, while its session runs.
    var activeConnection: Connection? {
        guard let connecting, editor.session === connecting else { return nil }
        return connection
    }

    /// The color of a dot: its first channel's.
    func color(of dot: PortDot) -> NSColor {
        guard let record = editor.document[dot.shape], let channel = kinds[record.kind]?.dots[dot.side]?.first else { return PortStyle.fallback }
        return colors[channel] ?? PortStyle.fallback
    }
}

extension PortState: EditorService {
    func toolDidChange(from old: ToolID, to new: ToolID, in editor: CanvasEditor) {
        host = nil
    }

    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        if let host, changes.removed.contains(host) { self.host = nil }
    }

    /// Another board is shown: the shape whose dots showed, and any connection, were the board
    /// left's. Keeps nothing per board, so the switch's change set is never worked out.
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        host = nil
        connection = nil
    }
}
