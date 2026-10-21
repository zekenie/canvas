import AppKit
import Canvas
import Neighbors
import Topology

extension PluginID {
    public static let typeLights: PluginID = "type-lights"
}

/// Types' lights for Neighbors: hover a type and what is of it is outlined in pink; its panel lists that in two
/// lists, Instances (the shapes that are of it however far, never a type, as `:is-a` finds them: myCar, a Toyota,
/// is a Car) and Subtypes (the types built on it however far: Toyota, built on Car, is a kind of Car and no Car).
/// One pink for both, since a shape is one or the other and both are what is of the type; the lists' titles tell
/// them apart. A relationship type's instances are its arrows. Only while the shape is a type (`[schema]`): one
/// whose schema was taken away lists nothing, though shapes still name it, as their dashed chips say. A plugin
/// value of its own, after Neighbors and Types, so a list without Neighbors leaves it out; after Mentions' lights
/// in the shipped list, so a shape's arrows and mentions keep their rings.
public struct TypeLightsPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .typeLights }

    public func register(into registrar: inout PluginRegistrar) {
        let isA = IsAEdge.id.rawValue, schema = TypeSchemaProperty.key.rawValue
        registrar.neighborLight(TypesStyle.instances, color: TypesStyle.instancesLight, query: { ":\(isA)(\($0)[\(schema)]):not([\(schema)])" })
        registrar.neighborLight(TypesStyle.subtypes, color: TypesStyle.instancesLight, query: { "[\(schema)]:\(isA)(\($0)[\(schema)])" })
    }
}

/// The lights' color, chosen beside arrows' and Mentions' four (`ArrowStyle`, `MentionStyle`) by the same
/// rules: a fixed sRGB value for each appearance, clear of Validation's red and orange and of Find's orange,
/// not the accent, and at least 3:1 against the canvas in the light and the dark. Pink: 4.9:1 on the light
/// canvas and 6.6:1 on the dark. Gold, the other hue the four leave, read as a yellow note's own edge on the
/// dark canvas and sat beside Validation's orange.
extension TypesStyle {
    /// The lights' titles, over their lists in a shape's panel.
    nonisolated static let instances = "Instances"
    nonisolated static let subtypes = "Subtypes"
    /// What is of a type, an instance or a type built on it: pink.
    static let instancesLight = NeighborLight.color(light: 0xC2307A, dark: 0xF07AB5)
}
