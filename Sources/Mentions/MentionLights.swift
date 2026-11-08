import AppKit
import Canvas
import Neighbors
import Topology

extension PluginID {
    public static let mentionLights: PluginID = "mention-lights"
}

/// Mentions' lights for Neighbors: hover a shape with ⌃⌥ held and what its text mentions is outlined
/// in teal, what mentions it in lavender (`mention` edges, from the shape whose text holds a mention to the
/// shape it names); its panel lists each under the light's title, a shape that mentions it with its
/// text around the mention under its name. A plugin value of its own, after Neighbors and Mentions,
/// so a list without Neighbors leaves it out; after arrows' lights in the shipped list, so a shape
/// both pointed to and mentioned has its arrow's ring first.
public struct MentionLightsPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .mentionLights }

    public func register(into registrar: inout PluginRegistrar) {
        let mention = MentionEdge.id.rawValue, keys: Modifiers = [.control, .option]
        registrar.neighborLight(MentionStyle.mentions, color: MentionStyle.mentionsLight, keys: keys, query: { ":edge-from(\($0), \(mention))" })
        // What mentions a row too: a row's selector names it (`#S::part(R)`), and its list quotes each mentioner around that row.
        registrar.neighborLight(MentionStyle.mentionedBy, color: MentionStyle.mentionedByLight, keys: keys, serves: .both,
                                query: { ":edge-to(\($0), \(mention))" },
                                caption: { editor, subject, mentioner in editor.mentions?.quote(of: mentioner, around: subject) })
        registrar.keyHint("⌃⌥ Hover", "Show Mentions", while: .pointer)
    }
}

/// The lights' colors, chosen in a design audit with arrows' two (`ArrowStyle`), from renders of the
/// four over both canvases, a fixed sRGB value for each appearance rather than a system color: each
/// is clear of Validation's red and orange and of Find's orange, is not the accent, and is at least
/// 3:1 against the canvas in the light and the dark. The lavender and arrows' purple are close for
/// some color-vision deficiencies.
extension MentionStyle {
    /// The lights' titles, over their lists in a shape's panel.
    nonisolated static let mentions = "Mentions"
    nonisolated static let mentionedBy = "Mentioned By"
    /// What a shape's text mentions: teal.
    static let mentionsLight = NeighborLight.color(light: 0x0E97B0, dark: 0x329AB4)
    /// What mentions it: lavender.
    static let mentionedByLight = NeighborLight.color(light: 0xA76FE2, dark: 0xD0B0FE)
}
