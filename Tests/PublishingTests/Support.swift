import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import ContextMenus
import CoreGraphics
import DetailPanel
import Foundation
import Keyboard
import Neighbors
import Publishing
import Selection
import SlashCommands
import SwiftUI
import TableOfContents
import Topology

// Fixtures only (CanvasTesting's boxes and links, and the kinds below), so every test here shows
// Publishing knows no real kind: a plaque is public by choice (it holds `public`, and a name a
// stand-in title pill says, `StubTitle`), a
// seal is always public, a draft is never; a holder and a relay stand in for the shapes they cite;
// a link carries a wire between what it joins.

struct Plaque: BoxShapeProps {
    static let kind: ShapeKind = "plaque"
    static let properties = Properties<Plaque> {
        Property("frame", \.frame).required()
        Property("name", \.name)
    }
    var frame: CGRect
    /// What `StubTitle` says above it, as a title pill would.
    var name: String?
    init(_ frame: CGRect) { self.frame = frame }
}

extension Plaque {
    init() { self.init(.zero) }
}

struct Seal: BoxShapeProps {
    static let kind: ShapeKind = "seal"
    static let properties = Properties<Seal> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
}

extension Seal {
    init() { self.init(.zero) }
}

struct Draft: BoxShapeProps {
    static let kind: ShapeKind = "draft"
    static let properties = Properties<Draft> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
}

extension Draft {
    init() { self.init(.zero) }
}

/// Stands for the shapes it cites.
struct Holder: BoxShapeProps {
    static let kind: ShapeKind = "holder"
    static let properties = Properties<Holder> {
        Property("frame", \.frame).required()
        Property("stands", \.stands)
    }
    var frame: CGRect
    var stands: [Citation]
    init(_ frame: CGRect, stands: [Citation] = []) {
        self.frame = frame
        self.stands = stands
    }
}

extension Holder {
    init() { self.init(.zero) }
}

/// Stands for the shapes it cites, as a holder does.
struct Relay: BoxShapeProps {
    static let kind: ShapeKind = "relay"
    static let properties = Properties<Relay> {
        Property("frame", \.frame).required()
        Property("stands", \.stands)
    }
    var frame: CGRect
    var stands: [Citation]
    init(_ frame: CGRect, stands: [Citation] = []) {
        self.frame = frame
        self.stands = stands
    }
}

extension Relay {
    init() { self.init(.zero) }
}

struct PlaqueDefinition {}
extension PlaqueDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Plaque>, in context: RenderContext) {
        context.fillWithShadow(CGPath(rect: shape.frame, transform: nil), .white)
    }
}

struct SealDefinition {}
extension SealDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Seal>, in context: RenderContext) {
        context.fillWithShadow(CGPath(rect: shape.frame, transform: nil), .systemRed)
    }
}
extension SealDefinition: AlwaysPublic {}

struct DraftDefinition {}
extension DraftDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Draft>, in context: RenderContext) {
        context.fillWithShadow(CGPath(rect: shape.frame, transform: nil), .systemGray)
    }
}
extension DraftDefinition: NeverPublic {}

struct HolderDefinition {}
extension HolderDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Holder>, in context: RenderContext) {}
}
extension HolderDefinition: NeverPublic {}

struct RelayDefinition {}
extension RelayDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Relay>, in context: RenderContext) {}
}
extension RelayDefinition: NeverPublic {}

/// Stands for whatever is provided for what it asks (a dynamic stand-in: nothing until an answer
/// comes).
struct Lens: BoxShapeProps {
    static let kind: ShapeKind = "lens"
    static let properties = Properties<Lens> {
        Property("frame", \.frame).required()
        Property("asks", \.asks)
    }
    var frame: CGRect
    var asks: String
    init(_ frame: CGRect, asks: String = "") {
        self.frame = frame
        self.asks = asks
    }
}

extension Lens {
    init() { self.init(.zero) }
}

struct LensDefinition {}
extension LensDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Lens>, in context: RenderContext) {}
}
extension LensDefinition: NeverPublic {}

/// A tab of a plaque's own, so its panel has one before Connections.
enum PlaqueTab {}
extension PlaqueTab: DetailTab {
    static var title: String { "Plaque" }
}

/// A kind adopting both dials, which the registry refuses.
struct Both: BoxShapeProps {
    static let kind: ShapeKind = "both"
    static let properties = Properties<Both> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
}

extension Both {
    init() { self.init(.zero) }
}

struct BothDefinition {}
extension BothDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Both>, in context: RenderContext) {}
}
extension BothDefinition: NeverPublic, AlwaysPublic {}

enum WireEdge {}
extension WireEdge: EdgeType {
    static let id: EdgeTypeID = "wire"
}

/// The kinds above, and the wires their links carry.
struct KindsPlugin: CanvasPlugin {
    var id: PluginID { "kinds" }

    func register(into registrar: inout PluginRegistrar) {
        registrar.edgeType(WireEdge.self)
        registrar.edges(Link.self) { record, _, sink in
            guard let link = record.props as? CanvasTesting.Link, let from = link.from, let to = link.to else { return }
            sink.emit(WireEdge.id, from: from, to: to)
        }
        registrar.shape(PlaqueDefinition()) { plaque in
            plaque.details { DetailSection("Look", in: PlaqueTab.self) { _ in Text("A plaque") } }
        }
        registrar.shape(SealDefinition())
        registrar.shape(DraftDefinition())
        registrar.shape(HolderDefinition()) { holder in
            holder.standsIn(admitting: { target, registry in registry.isPublic(target) }) { shape, _ in .shapes(shape.props.stands.map(\.shape)) }
        }
        registrar.shape(LensDefinition()) { lens in
            lens.standsIn(admitting: { target, registry in registry.isPublic(target) }) { shape, _ in
                shape.props.asks.isEmpty ? nil : .provided(ForwardingKey(shape.props.asks))
            }
        }
        registrar.shape(RelayDefinition()) { relay in
            relay.standsIn(admitting: { target, registry in registry.isPublic(target) }) { shape, _ in .shapes(shape.props.stands.map(\.shape)) }
        }
    }
}

let plaqueFrame = CGRect(x: 100, y: 100, width: 150, height: 100)

/// What the app has around Publishing: the keys, the selection, the graph, the context menu, the
/// table of contents, the panel, adornments and slash commands; `before` just ahead of Publishing,
/// where the shipped list has Locking (the fixture lock); and `more` after them (fixture chips and a
/// title pill, read-only shapes), on `file`.
@MainActor func publishingPlugins(_ more: [any CanvasPlugin] = [], before: [any CanvasPlugin] = []) -> [any CanvasPlugin] {
    [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FixturesPlugin(), LinksPlugin(), KindsPlugin(), ContextMenusPlugin(),
     TableOfContentsPlugin(), DetailPanelPlugin(), AdornmentsPlugin(), SlashCommandsPlugin()] + before + [PublishingPlugin()] + more
}

@MainActor func publishingHarness(_ more: [any CanvasPlugin] = [], before: [any CanvasPlugin] = [], file: CanvasFile = CanvasFile()) throws -> EditorHarness {
    try EditorHarness(plugins: publishingPlugins(more, before: before), file: file)
}

extension EditorHarness {
    /// Makes a shape public: a transaction of its own, whatever the shape.
    func publish(_ ids: ShapeID...) { editor.makePublic(ids) }

    /// A lens asking `asks`, answered with `shapes` (provided as topology would be by whoever asks).
    @discardableResult
    func lens(_ asks: String, answering shapes: [ShapeID] = [], revision: Int = 1, at frame: CGRect = CGRect(x: 600, y: 650, width: 60, height: 20)) -> ShapeID {
        let id = add(Lens(frame, asks: asks))
        if !shapes.isEmpty { provide(id, asks, shapes, revision: revision) }
        return id
    }

    /// An answer for a lens.
    func provide(_ lens: ShapeID, _ asks: String, _ shapes: [ShapeID], revision: Int = 1) {
        editor.topology?.provide([lens: ProvidedForwarding(key: ForwardingKey(asks), shapes: shapes, revision: revision)])
    }

    /// A holder standing for `shapes`.
    @discardableResult
    func hold(_ shapes: [ShapeID], at frame: CGRect = CGRect(x: 600, y: 600, width: 60, height: 20)) -> ShapeID {
        add(Holder(frame, stands: shapes.map(Citation.init)))
    }
}
