import AppKit
import Canvas
import Geometry
import Selection
import Topology

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
/// found once (the registry is frozen); the ports of each shape that stands for others, kept until
/// what it stands for changes (`ports(of:)`); the shape whose dots show; and the connection being
/// drawn from one, while it is.
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
    /// What each stand-in's ports were, at the revision of its edges they were worked out at. Let go
    /// of with the shape, wherever it was (`forgetStandingPorts`), and with the file.
    private var standingPorts: [ShapeID: (revision: Int, ports: KindPorts?)] = [:]
    /// The graph, and the kinds that stand in for others: nil with none (found once, on first use,
    /// when every service exists).
    private lazy var standIns: (graph: TopologyIndex, kinds: Set<ShapeKind>)? = {
        guard let graph = editor.topology, !graph.standInKinds.isEmpty else { return nil }
        return (graph, graph.standInKinds)
    }()

    init(editor: CanvasEditor) {
        self.editor = editor
        let registry = editor.registry
        connector = registry.connector
        kinds = KindPorts.table(in: registry)
        colors = Dictionary(registry.contributions(to: Channels.self).map { ($0.value.id, $0.value.color) }) { first, _ in first }
    }

    // MARK: A shape's ports

    /// The ports a shape has: its kind's, from the port table; for a shape that stands for others
    /// (Topology's stand-ins: a reference), what it stands for now decides, instance by instance, a
    /// deliberate departure from ports being per kind. With one kind of shape stood for, that
    /// kind's channels and roles, in its order, on the stand-in's own sides; with several, the
    /// channels every kind takes, in the first's order, with the roles all allow; with none (it
    /// stands for nothing: empty, pending, missing, private, unavailable), none, so no dots show
    /// and no connection ends there. Kept for each stand-in until its revision in Topology changes
    /// (re-pointed, what it stands for made private or deleted, an answer provided for it), so
    /// asking costs a dictionary hit.
    func ports(of record: AnyShapeRecord) -> KindPorts? {
        guard let own = kinds[record.kind] else { return nil }
        guard let (topology, standingKinds) = standIns, standingKinds.contains(record.kind) else { return own }
        let revision = topology.revision(of: record.id)
        if let kept = standingPorts[record.id], kept.revision == revision { return kept.ports }
        let targets = topology.forwards(of: record.id).compactMap { editor.shape(inFile: $0) }
        let ports = targets.isEmpty ? nil : own.standing(for: targets.map { kinds[$0.kind] })
        standingPorts[record.id] = (revision, ports)
        return ports
    }

    /// Whether `connection`'s end in `role` may be at `shape`, as far as what a stand-in stands for
    /// goes (the static rule, the connector's, lets every channel end at one, since its kind has
    /// ports on all): for a stand-in, the connection's channel must be one it takes now in that
    /// role. True for any other shape, and for a connection on no channel, or one no plugin
    /// declares, which binds wherever the connector's rules let it.
    func allows(_ connection: AnyShapeRecord, as role: PortRole, at shape: AnyShapeRecord) -> Bool {
        guard standIns?.kinds.contains(shape.kind) == true,
              let channel = connection[ChannelProperty.self], editor.registry.declares(channel) else { return true }
        return ports(of: shape)?.roles[channel]?.allows(role) == true
    }

    /// Whether ports show at all: there's a connector, the select tool is current, the board takes
    /// shapes (a connection draws as one, and a locked subboard's board takes none:
    /// `isBoardReadOnly`), and the view isn't zoomed out past where a shape's dots can be told from
    /// its neighbors'.
    var isShowing: Bool {
        connector != nil && editor.currentToolID == .select && !editor.isBoardReadOnly && editor.camera.zoom >= PortStyle.minZoom
    }

    /// Whether a shape shows dots: its kind has some, and the connector can start from it (asked of
    /// the editor's document).
    func hasDots(_ id: ShapeID) -> Bool {
        guard let connector, let record = editor.document[id], !record.isOpaque,
              ports(of: record)?.dots.isEmpty == false else { return false }
        return connector.canConnect(id, editor.shapeContext)
    }

    /// A shape's dots, in the order of `PortSide.allCases`, with their centers in world units: just
    /// outside the middle of each side of its bounds, `PortStyle.offset` view points out.
    func dots(of id: ShapeID) -> [(dot: PortDot, center: CGPoint)] {
        guard let record = editor.document[id], let ports = ports(of: record), let bounds = bounds(of: id) else { return [] }
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
        guard let connector, let record = editor.document[dot.shape], let channels = ports(of: record)?.dots[dot.side] else { return nil }
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
        guard let record = editor.document[dot.shape], let channel = ports(of: record)?.dots[dot.side]?.first else { return PortStyle.fallback }
        return colors[channel] ?? PortStyle.fallback
    }
}

extension PortState: EditorService {
    func toolDidChange(from old: ToolID, to new: ToolID, in editor: CanvasEditor) {
        host = nil
    }

    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        if let host, changes.removed.contains(host) { self.host = nil }
        forgetStandingPorts(changes)
    }

    /// Another board is shown: the shape whose dots showed, and any connection, were the board
    /// left's. Keeps nothing per board, so the switch's change set is never worked out; but a file
    /// put in place has none of the stand-ins kept (a shape of the same id may be one for others now).
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        host = nil
        connection = nil
        if change.isFileReplaced { standingPorts.removeAll() }
    }

    /// A stand-in's kept ports go with it: those a commit removed on the board shown, and those on a
    /// board it took or changed (`elsewhere`: one that only changed is worked out again when it's
    /// next asked, which is one miss), all of them for a board put in place. Nothing when none is
    /// kept, and a drag names no shape removed or on another board; otherwise a hit for each of the
    /// fewer of what's kept and what the commit names.
    private func forgetStandingPorts(_ changes: ChangeSet) {
        guard !standingPorts.isEmpty else { return }
        guard !changes.replacedDocument else { return standingPorts.removeAll() }
        for id in changes.removed { standingPorts[id] = nil }
        guard !changes.elsewhere.isEmpty else { return }
        if standingPorts.count < changes.elsewhere.count {
            for id in Array(standingPorts.keys) where changes.elsewhere.contains(id) { standingPorts[id] = nil }
        } else {
            for id in changes.elsewhere { standingPorts[id] = nil }
        }
    }

    #if DEBUG
    /// How many stand-ins' ports are kept (debug builds): what tests hold the upkeep to.
    var standingPortsKept: Int { standingPorts.count }
    #endif
}
