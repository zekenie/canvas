import AppKit
import Canvas
import Neighbors
import Topology

extension PluginID {
    public static let typeLights: PluginID = "type-lights"
}

/// Types' light for Neighbors: hover a type and the shapes that are of it are outlined in pink; its panel
/// lists them under Instances (`is-a` edges, from a shape to each type its `is` list names). Direct, as the
/// chips are: a type that builds on it is listed, what is of that type is not (`:is-a` would follow them).
/// A relationship type's instances are its arrows. Only while the shape is a type (`[schema]`): one whose schema
/// was taken away lists nothing, though shapes still name it, as their dashed chips say. A plugin value of its own, after Neighbors and Types, so
/// a list without Neighbors leaves it out; after Mentions' lights in the shipped list, so a shape's arrows
/// and mentions keep their rings.
public struct TypeLightsPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .typeLights }

    public func register(into registrar: inout PluginRegistrar) {
        let isA = IsAEdge.id.rawValue, schema = TypeSchemaProperty.key.rawValue
        registrar.neighborLight(TypesStyle.instances, color: TypesStyle.instancesLight, query: { ":edge-to(\($0)[\(schema)], \(isA))" })
    }
}

/// The light's color, chosen beside arrows' and Mentions' four (`ArrowStyle`, `MentionStyle`) by the same
/// rules: a fixed sRGB value for each appearance, clear of Validation's red and orange and of Find's orange,
/// not the accent, and at least 3:1 against the canvas in the light and the dark. Pink: 4.9:1 on the light
/// canvas and 6.6:1 on the dark. Gold, the other hue the four leave, read as a yellow note's own edge on the
/// dark canvas and sat beside Validation's orange.
extension TypesStyle {
    /// The light's title, over its list in a shape's panel.
    nonisolated static let instances = "Instances"
    /// What is of a type: pink.
    static let instancesLight = NeighborLight.color(light: 0xC2307A, dark: 0xF07AB5)
}
