import Canvas
import Topology

/// A mention, as an edge in Topology's graph: from the shape whose text holds it to the shape it
/// names (a mention of a row: to the row's shape, the edge's target part the row), in the slot of the
/// property the text is in, counted once for each time the text mentions it. A root: nothing else is
/// a kind of mention.
public enum MentionEdge {}

extension MentionEdge: EdgeType {
    public static let id: EdgeTypeID = "mention"
    public static let summary: String? = "a mention in a shape's text, from that shape to the shape it names"
}

/// Mentions' edges: every mention in the mention text of every kind whose shapes can hold names
/// (`registry.namingKinds`), wherever a shape keeps it (a property's value, or in a struct, list, set
/// or dictionary there), in text order. Only the record is read, so a commit's upkeep is its own.
@MainActor
func registerMentionEdges(into registrar: inout PluginRegistrar) {
    registrar.edgeType(MentionEdge.self)
    registrar.forShapes(adopting: .namingShapes) { naming in
        naming.edges { record, registry, sink in
            record.forEachNamingValue(in: registry) { property, value in
                value.forEachNamingLeaf { leaf in
                    guard let text = leaf as? any MentionTextHolding else { return }
                    text.forEachMentionRun { run in
                        // A row's mention reaches its row: the edge ends at the row's shape, its part the row.
                        if case .mention(let target, _) = run {
                            sink.emit(MentionEdge.id, from: record.id, to: target.shape, slot: property, toPart: target.part)
                        }
                    }
                }
            }
        }
    }
}
