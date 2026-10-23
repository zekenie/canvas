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

    /// The channel alone, for a pill drawn (`drawnMismatch(of:)`): read from the kinds the reference
    /// stands for (`topology.standingKinds(of:)`), each once, never its shapes, so a frame costs the
    /// same for a reference of three shapes and of ten thousand.
    func mismatchedChannel(of id: ShapeID) -> ChannelID? {
        guard let topology = editor.topology else { return nil }
        return refusal(of: id, in: topology)?.channel
    }

    private func findMismatch(of id: ShapeID, in topology: TopologyIndex) -> ChannelMismatch? {
        guard let (channel, refusing) = refusal(of: id, in: topology) else { return nil }
        // The first shape it stands for of a kind that doesn't: a walk only once there is one.
        for target in topology.forwards(of: id) {
            if let record = editor.shape(inFile: target), refusing.contains(record.kind) { return ChannelMismatch(channel: channel, target: target) }
        }
        return nil
    }

    /// The first channel of an arrow attached to `id` that a kind it stands for doesn't take in that
    /// end's role, and those kinds (what stands for shapes is never kept aside, so a kind's ports say
    /// it all: `registry.accepts`).
    private func refusal(of id: ShapeID, in topology: TopologyIndex) -> (channel: ChannelID, refusing: Set<ShapeKind>)? {
        let kinds = topology.standingKinds(of: id)
        let registry = editor.registry
        guard !kinds.isEmpty, let connections = registry.connectorEdgeType else { return nil }
        for (direction, role) in [(EdgeDirection.incoming, PortRole.target), (.outgoing, .source)] {
            for edge in topology.edges(of: id, direction, types: .within(connections), view: .literal) {
                guard let channel = editor.shape(inFile: edge.carrier)?[ChannelProperty.self], registry.declares(channel) else { continue }
                let refusing = Set(kinds.filter { !registry.takes($0, channel, as: role) })
                if !refusing.isEmpty { return (channel, refusing) }
            }
        }
        return nil
    }
}
