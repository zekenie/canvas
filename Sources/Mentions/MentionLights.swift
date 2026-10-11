import AppKit
import Canvas
import Neighbors
import Topology

extension PluginID {
    public static let mentionLights: PluginID = "mention-lights"
}

/// Mentions' lights for Neighbors: hover a shape and what its text mentions is outlined in teal,
/// what mentions it in lavender (`mention` edges, from the shape whose text holds a mention to the
/// shape it names). A plugin value of its own, after Neighbors and Mentions, so a list without
/// Neighbors leaves it out; after arrows' lights in the shipped list, so a shape both pointed to
/// and mentioned has its arrow's ring first.
public struct MentionLightsPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .mentionLights }

    public func register(into registrar: inout PluginRegistrar) {
        let mention = MentionEdge.id.rawValue
        registrar.neighborLight(color: MentionStyle.mentionsLight) { ":edge-from(\($0), \(mention))" }
        registrar.neighborLight(color: MentionStyle.mentionedByLight) { ":edge-to(\($0), \(mention))" }
    }
}

/// The lights' colors, chosen in a design audit with arrows' two (`ArrowStyle`), from renders of the
/// four over both canvases, a fixed sRGB value for each appearance rather than a system color: each
/// is clear of Validation's red and orange and of Find's orange, is not the accent, and is at least
/// 3:1 against the canvas in the light and the dark. The lavender and arrows' purple are close for
/// some color-vision deficiencies.
extension MentionStyle {
    /// What a shape's text mentions: teal.
    static let mentionsLight = NeighborLight.color(light: 0x0E97B0, dark: 0x329AB4)
    /// What mentions it: lavender.
    static let mentionedByLight = NeighborLight.color(light: 0xA76FE2, dark: 0xD0B0FE)
}
