import Canvas
import Connections
import Mentions
import Topology

/// An arrow attached to a reference whose channel what the reference stands for now doesn't take: it
/// ran into the pill while the pill stood for something that took it, and the pill was re-pointed
/// (or what it stood for went private or was deleted, or answers changed) since. Not a validity rule:
/// Connections has no Validation, and a rule may not read what a dynamic reference is given.
public struct ChannelMismatch: Equatable, Sendable {
    /// The channel the arrow is on.
    public let channel: ChannelID
    /// The first shape the reference stands for that doesn't take it, in the arrow's role.
    public let target: ShapeID

    public init(channel: ChannelID, target: ShapeID) {
        self.channel = channel
        self.target = target
    }
}

extension ReferenceState {
    /// The first channel of an arrow attached to the reference `id` (drawn into it, or out of it:
    /// the literal edges) that a shape it stands for doesn't take, in that end's role (a target
    /// where the arrow ends, a source where it starts); nil for none, and for a reference that
    /// stands for nothing, which the pill already says. It leaves the arrow as it is: arrows keep
    /// their bindings and their channels when what they bind to changes (tldraw's never let go);
    /// `canvas query` still reports the edge, typed as the channel. Worked out once for each
    /// revision of the reference's edges in Topology and kept, so a frame asks a dictionary.
    public func channelMismatch(of id: ShapeID) -> ChannelMismatch? {
        guard let topology = editor.topology else { return nil }
        let revision = topology.revision(of: id)
        if let kept = mismatches[id], kept.revision == revision { return kept.mismatch }
        let found = findMismatch(of: id, in: topology)
        mismatches[id] = (revision, found)
        return found
    }

    /// What the panel's status line says of the mismatch: “Order” doesn’t take note links.
    public func mismatchLine(of id: ShapeID) -> String? {
        guard let mismatch = channelMismatch(of: id) else { return nil }
        let name = editor.shape(inFile: mismatch.target).flatMap { editor.registry.mentionAppearance(of: $0)?.label } ?? ReferenceStyle.unnamed
        return ReferenceStyle.mismatchLine(name: name, channels: mismatch.channel.pluralName)
    }

    private func findMismatch(of id: ShapeID, in topology: TopologyIndex) -> ChannelMismatch? {
        let targets = topology.forwards(of: id).compactMap { editor.shape(inFile: $0) }
        let registry = editor.registry
        guard !targets.isEmpty, let connections = registry.connectorEdgeType else { return nil }
        for (direction, role) in [(EdgeDirection.incoming, PortRole.target), (.outgoing, .source)] {
            for edge in topology.edges(of: id, direction, types: .within(connections), view: .literal) {
                guard let channel = editor.shape(inFile: edge.carrier)?[ChannelProperty.self], registry.declares(channel) else { continue }
                if let culprit = targets.first(where: { !registry.accepts($0, on: channel, as: role) }) {
                    return ChannelMismatch(channel: channel, target: culprit.id)
                }
            }
        }
        return nil
    }
}
