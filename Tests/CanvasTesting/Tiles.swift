import AppKit
import Canvas

/// A second kind a tool places, beside the card: a box of its own size (120 × 80, where a card is
/// 100 × 60), with a label and a finish, one of two words. For tests that place, make or name
/// shapes of more than one kind (the command line's, a connector's) without a real vertical.
public struct Tile: BoxShapeProps {
    public static let kind: ShapeKind = "tile"
    public static let properties = Properties<Tile>(title: "Tile") {
        Property("frame", \.frame).required()
        Property("label", \.label).description("What the tile says.")
        Property("finish", \.finish)
    }
    public enum Finish: String, Codable, Sendable, SchemaCases {
        case matte, glossy
        public var schemaTitle: String { rawValue.capitalized }
    }
    public var frame: CGRect
    public var label: String
    public var finish: Finish

    public init(_ frame: CGRect, label: String = "", finish: Finish = .matte) {
        self.frame = frame
        self.label = label
        self.finish = finish
    }
}

extension Tile {
    public init() { self.init(.zero) }
}

struct TileDefinition {}

extension TileDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Tile>, in context: RenderContext) {
        context.fillWithShadow(CGPath(rect: shape.frame, transform: nil), shape.props.finish == .glossy ? .systemBlue : .systemGray)
    }
}

/// Tiles ("tile"), and a tool that places one, 120 × 80, centered where the canvas is pressed (no
/// key: CanvasTesting can't import Keyboard, so a test that types one registers it).
public struct TilesPlugin: CanvasPlugin {
    /// The size of what the tool places.
    public static let size = CGSize(width: 120, height: 80)

    public init() {}
    public var id: PluginID { "tiles" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.shape(TileDefinition()) { tile in
            let place = tile.placement(size: TilesPlugin.size) { Tile(.zero) }
            tile.tool(label: "Tile", systemImage: "square", placing: place)
        }
    }
}
