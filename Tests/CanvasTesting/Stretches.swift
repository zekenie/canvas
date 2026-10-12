import AppKit
@_spi(Host) import Canvas

// A shape laid out larger than it stores (`LaidOutBox`), by a layout input a plugin provides: what
// tests of the laid-out frame draw with, so they never depend on Types or StickyNotes. A stretch
// stands in for a typed note, and a gauge for its type.

/// A box that names a gauge and is laid out no smaller than the gauge says: what tests make taller
/// and wider than it stores.
public struct Stretch: BoxShapeProps {
    public static let kind: ShapeKind = "stretch"
    public static let properties = Properties<Stretch> {
        Property("frame", \.frame).required()
        Property("label", \.label)
        Property("gauge", \.gauge)
    }
    public var frame: CGRect
    public var label: String
    public var gauge: GaugeLink?
    public init(_ frame: CGRect, label: String = "", gauge: ShapeID? = nil) {
        self.frame = frame
        self.label = label
        self.gauge = gauge.map(GaugeLink.init)
    }
}

extension Stretch {
    public init() { self.init(.zero) }
}

/// A box that says how big the stretches that name it are laid out, at least.
public struct Gauge: BoxShapeProps {
    public static let kind: ShapeKind = "gauge"
    public static let properties = Properties<Gauge> {
        Property("frame", \.frame).required()
        Property("label", \.label)
        Property("width", \.width)
        Property("height", \.height)
    }
    public var frame: CGRect
    public var label: String
    public var width: CGFloat
    public var height: CGFloat
    public init(_ frame: CGRect, label: String = "", width: CGFloat, height: CGFloat) {
        self.frame = frame
        self.label = label
        self.width = width
        self.height = height
    }
}

extension Gauge {
    public init() { self.init(.zero, width: 0, height: 0) }
}

/// A gauge's id, coded by hand as one string, as `Citation` is (`Naming.swift`); its schema is a
/// string that says `contentMediaType: GaugeLink.mediaType`, so a draw test can write a gauge by its
/// title with a text format of its own. A name that may outlive its gauge (`ShapeNaming`), as `is`
/// is: a copy of a stretch names the copy of its gauge when the gauge came along, and a gauge
/// deleted leaves the name.
public struct GaugeLink: Codable, Hashable, Sendable, SchemaDescribed, ShapeNaming {
    public static let mediaType = "text/x-test-gauge"
    public var shape: ShapeID

    public init(_ shape: ShapeID) { self.shape = shape }

    public init(from decoder: any Decoder) throws {
        shape = try decoder.singleValueContainer().decode(ShapeID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(shape)
    }

    public static func schema(in definitions: inout SchemaDefinitions) -> JSONObject {
        definitions.reference("gauge-link", of: Self.self) { _ in
            ["type": "string", "format": "uuid", "contentMediaType": .string(mediaType), "description": "A gauge it names, which may be gone."]
        }
    }

    public func forEachNamedShape(_ body: (ShapeID) -> Void) { body(shape) }

    public func renamingShapes(_ rename: (ShapeID) -> ShapeID?) -> GaugeLink { GaugeLink(rename(shape) ?? shape) }
}

/// What a gauge says: a value of its own, since a layout input's value must be `Hashable` and
/// nothing here hashes a `CGSize`.
public struct StretchRoom: Hashable, Sendable {
    public var width: CGFloat
    public var height: CGFloat
    public init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
    }
}

public enum Stretches {
    /// What a stretch's gauge says: nil with none, or one that isn't there.
    public static let room = LayoutInputKey<StretchRoom>("stretch-room")
}

/// Counts what was asked.
@MainActor public final class StretchLog {
    /// Each `laidOutSize` asked.
    public var sizes: [ShapeID] = []
    /// Each provider call.
    public var provided: [ShapeID] = []
    public init() {}
}

struct StretchDefinition {
    let log: StretchLog
}

extension StretchDefinition: ShapeDefinition {
    /// A fill of the laid-out frame.
    func render(_ shape: ShapeRecord<Stretch>, in context: RenderContext) {
        context.cg.setFillColor(NSColor.systemTeal.cgColor)
        context.cg.fill(context.shapes.frame(of: shape))
    }
}

extension StretchDefinition: LaidOutBox {
    func laidOutSize(of shape: ShapeRecord<Stretch>, in context: ShapeContext) -> CGSize {
        log.sizes.append(shape.id)
        guard let room = context.layoutInput(Stretches.room, of: shape) else { return shape.frame.size }
        return CGSize(width: room.width, height: room.height)
    }
}

extension StretchDefinition: Editable {
    func makeEditingView(for shape: ShapeRecord<Stretch>, context: EditContext<Stretch>) -> EditingView {
        let view = NSView()
        return EditingView(view: view, firstResponder: view)
    }
}

struct GaugeDefinition {}

extension GaugeDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Gauge>, in context: RenderContext) {
        context.cg.setFillColor(NSColor.systemOrange.cgColor)
        context.cg.fill(shape.frame)
    }
}

/// Keeps who names which gauge from each commit, and says the stretches that name a gauge a commit
/// added, changed or removed, and those it added or changed, are laid out again
/// (`editor.shapesDidChangeLayout`): the stretches the same commit added too, which a service that
/// heard first may have asked for already.
@MainActor final class StretchState: EditorService {
    private var gaugeOf: [ShapeID: ShapeID] = [:]
    private var namers: [ShapeID: Set<ShapeID>] = [:]

    init(editor: CanvasEditor) { scan(editor) }

    private func scan(_ editor: CanvasEditor) {
        gaugeOf = [:]
        namers = [:]
        for document in [editor.file.root] + Array(editor.file.children.values) {
            for record in document.shapes { learn(record) }
        }
    }

    private func learn(_ record: AnyShapeRecord?, id: ShapeID? = nil) {
        guard let id = record?.id ?? id else { return }
        if let old = gaugeOf[id] {
            namers[old]?.remove(id)
            if namers[old]?.isEmpty == true { namers[old] = nil }
            gaugeOf[id] = nil
        }
        if let gauge = record?.typed(as: Stretch.self)?.props.gauge?.shape {
            gaugeOf[id] = gauge
            namers[gauge, default: []].insert(id)
        }
    }

    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        if changes.replacedDocument { scan(editor) }
        var touched = changes.added.union(changes.removed).union(changes.elsewhere)
        for id in changes.changed where !changes.moved.contains(id) { touched.insert(id) }
        guard !touched.isEmpty else { return }
        var affected: Set<ShapeID> = []
        for id in touched {
            let record = editor.shape(inFile: id)
            learn(record, id: id)
            if record?.typed(as: Stretch.self)?.props.gauge != nil { affected.insert(id) }
            if let named = namers[id] { affected.formUnion(named) }
        }
        editor.shapesDidChangeLayout(affected)
    }
}

/// The "stretch" and "gauge" kinds, with a tool each (100 × 60 and 60 × 40, so draw can make them),
/// and a provider of `Stretches.room`: the size of the gauge a stretch names, as the file holds it.
/// Apart from `FixturesPlugin`, as `CorralsPlugin` is, so the registry reports tests pin don't change.
public struct StretchesPlugin: CanvasPlugin {
    public let log: StretchLog
    public init(log: StretchLog = StretchLog()) { self.log = log }
    public var id: PluginID { "stretches" }

    public func register(into registrar: inout PluginRegistrar) {
        let log = log
        registrar.shape(StretchDefinition(log: log)) { stretch in
            stretch.tool(label: "Stretch", systemImage: "arrow.up.left.and.arrow.down.right",
                         placing: stretch.placement(size: CGSize(width: 100, height: 60)) { Stretch(.zero) })
        }
        registrar.shape(GaugeDefinition()) { gauge in
            gauge.tool(label: "Gauge", systemImage: "ruler", placing: gauge.placement(size: CGSize(width: 60, height: 40)) { Gauge() })
        }
        registrar.layoutInput(Stretches.room) { record, reading in
            guard let link = record.typed(as: Stretch.self)?.props.gauge else { return nil }
            log.provided.append(record.id)
            guard let gauge = reading.shape(inFile: link.shape)?.typed(as: Gauge.self)?.props else { return nil }
            return StretchRoom(width: gauge.width, height: gauge.height)
        }
        registrar.service { StretchState(editor: $0) }
    }
}
