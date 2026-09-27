import Arrows
import Canvas
import Ports

extension PluginID {
    public static let arrowPorts: PluginID = "arrow-ports"
}

/// Arrows are what ports draw, though neither plugin has heard of the other: a drag from a port
/// draws an arrow, its end binding (by tldraw's rules, as the arrow tool's does) only to shapes that
/// take one of the port's channels, and an arrow so drawn keeps its channel (`ChannelProperty`).
/// Released on nothing, nothing is drawn. An arrow with a channel, re-aimed or moved, binds only to
/// shapes that take its channel, at that end; one without (the arrow tool's), or with a channel no
/// installed plugin declares, binds wherever an arrow can.
public struct ArrowPortsPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .arrowPorts }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.connects(Arrow.self, canConnect: { id, editor in editor.canBindArrow(to: id) }) { connection, editor in
            editor.beginArrow(from: connection.shape, at: connection.origin,
                              canBind: { editor.channel(of: connection, endingAt: $0) != nil },
                              complete: { arrow, end in
                                  guard let shape = editor.document[end] else { return }
                                  arrow[ChannelProperty.self] = editor.channel(of: connection, endingAt: shape)
                              })
        }
        registrar.arrowBindingRule { query in
            guard let channel = query.arrow[ChannelProperty.self], query.registry.declares(channel) else { return true }
            return query.registry.accepts(query.shape, on: channel, as: query.end == .start ? .source : .target)
        }
    }
}
