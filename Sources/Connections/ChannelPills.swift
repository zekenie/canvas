import Adornments
import AppKit
import Canvas

// A titled channel's pill on the line (`writes`, `reads`, `calls`): where a connection on it has its label, a capsule in the
// channel's tint with its title in white, the same in both appearances; the line stays ink, and a person's own color for the
// connection colors the line, never the pill (arrow-look 2.2). The adornment at a label's lead (`AdornmentPlacement.inLabelLead`,
// Adornments'): the connector keeps room for it, and the label's words come after it; zoomed out, the skeleton's capsule is its
// tint. A plugin value of its own, so a list without Adornments leaves it out.

extension PluginID {
    public static let connectionPills: PluginID = "connection-pills"
}

/// The pill that leads the label of a connection on a titled channel.
public enum ChannelPill {}

extension ChannelPill: Adornment {
    public static var placement: AdornmentPlacement { .inLabelLead }
}

/// Each titled channel's pill, made once: a tint is equal to itself only, so one is kept per channel (its title and tint are the
/// channel's, whatever registry declares it).
@MainActor
enum ChannelPills {
    private static var kept: [ChannelID: AdornmentLabel] = [:]

    /// The pill for a connection on `channel`: its title in white on its tint; nil for an untitled channel.
    static func label(of channel: ChannelID, in registry: Registry) -> AdornmentLabel? {
        guard let title = registry.channelTitle(channel) else { return nil }
        if let known = kept[channel], known.text == title { return known }
        guard let tint = registry.channelTint(channel) else { return nil }
        let label = AdornmentLabel(title).tinted(AdornmentTint(tint, ink: .white, style: .solid))
        kept[channel] = label
        return label
    }
}

/// A titled channel's pill on its connections: the shapes holding a channel (the connector's kind), each showing its channel's
/// title in its tint. After `PortsPlugin`, whose channels it reads, and Adornments.
public struct ConnectionPillsPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .connectionPills }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.forShapes(holding: ChannelProperty.self) { connections in
            connections.adornment(ChannelPill.self) { shape, context in
                shape[ChannelProperty.self].flatMap { ChannelPills.label(of: $0, in: context.registry) }
            }
        }
    }
}
