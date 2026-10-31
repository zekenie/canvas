import Canvas
import CanvasRPC
import Foundation
import Mentions
import Titles
import Topology
import Types

// What a rule sees of a shape: the shape, its types and their words, where it is, what's beside it, its edges and an
// arrow's ends, each under a label that says how it relates, and the biggest groups shrunk past a budget, first to
// names and then to counts. Built off the main actor from what one turn took of the file (`RuleWorld`). The state is
// what's sent; its footprint, the shapes it read, says which commits ask again.

/// How a kind's shapes are read: what one is called in a state, and which of its properties hold its words.
struct RuleKindReading: Sendable {
    /// "note", "arrow": the kind's name, lower-case.
    let noun: String
    /// Its name as a container's place says it: "Frame".
    let label: String
    /// The property that holds its words (mention text), if any.
    let words: String?
    /// Whether its shapes are drawn as lines (an arrow's kind): never listed as beside a shape.
    let isLine: Bool
}

/// What a check reads of the file, taken in one turn on the main actor and handed off the main actor whole: the file as
/// Topology has it (edges through every stand-in), the types, what mentions are called, how each kind is read, and
/// the day.
struct RuleWorld: Sendable {
    let snapshot: TopologySnapshot
    let graph: TypeGraph
    let labels: MentionLabels
    let kinds: [ShapeKind: RuleKindReading]
    let today: String
}

/// A group of what a check was shown, under the label it was shown under, with the shapes in it by id: what the panel
/// lists (Shown), lights and goes to. Every shape of the group, though past the budget the model was told how many of
/// each type.
public struct RuleShownGroup: Equatable, Sendable {
    /// The label it was shown under: "its types", "beside it, in the same place".
    public let label: String
    /// The shapes in it, in the order shown.
    public let shapes: [ShapeID]
    /// What it says that is no shape: "the board's top level".
    public let place: String?

    public init(label: String, shapes: [ShapeID], place: String? = nil) {
        self.label = label
        self.shapes = shapes
        self.place = place
    }
}

/// What one chip of a shape's rules found for it, with the shape bound to `:scope`: the shapes its query matched, in file
/// order, each container followed by what it holds (a container found brings what it holds), and how many its query
/// matched in all. A chip whose query was refused, or that has none yet, finds nothing to say.
struct ChipFind: Sendable, Hashable {
    let phrase: String
    /// The shapes found, a container's own shapes after it, as far as the query was asked for them.
    let listed: [ShapeID]
    /// How many shapes the query matched that `listed` leaves out.
    let more: Int
}

/// A shape's state for its rules, and what it read.
struct RuleContext: Sendable {
    /// What the decision model is shown.
    let state: JSONValue
    /// Its groups, by the shapes in them (the shape itself and the day aren't among them: the shape shows its own).
    let shown: [RuleShownGroup]
    /// Every shape it read: a commit to one of them asks again.
    let footprint: Set<ShapeID>
    /// The container it's in (nil: the board's top level in no container), whose shapes it lists as beside it: a shape
    /// put there asks again.
    let place: ShapeID?
    /// The container of every shape it read, as it was: a shape moved out of or into another asks again.
    let places: [ShapeID: ShapeID?]

    /// The most a group lists by name; past it, how many of each type.
    static let budget = 40

    /// The state of `id` in `world`, with what its rules' chips found (`finds`, each under `found by "<phrase>"`, as the
    /// prototype sent them); nil for a shape that isn't there.
    static func build(for id: ShapeID, in world: RuleWorld, finds: [ChipFind] = []) -> RuleContext? {
        let reader = Reader(world: world)
        guard let shape = reader.record(id) else { return nil }
        var state: [String: JSONValue] = ["today": .string(world.today), "shape": reader.full(shape)]
        var shown: [RuleShownGroup] = []
        let types = world.graph.lineage(of: id).filter { world.graph.types.contains($0) }
        state["its types"] = .array(types.compactMap { type in
            guard let record = reader.record(type) else { return nil }
            var entry: [String: JSONValue] = ["type": .string(world.graph.names[type] ?? "Untitled"), "words": .string(reader.words(record) ?? "")]
            let builds = reader.typeNames(record)
            if !builds.isEmpty { entry["builds on"] = .array(builds.map { .string($0) }) }
            return .object(entry)
        })
        shown.append(RuleShownGroup(label: "its types", shapes: types.filter { reader.record($0) != nil }))
        let place = world.snapshot.parent(of: id)
        let containers = world.snapshot.ancestors(of: id).reversed().filter { reader.record($0) != nil }
        let path = containers.compactMap { reader.record($0).map(reader.placeName) }
        state["in"] = path.isEmpty ? ["board": "the board's top level"] : ["container": .string(path.last!), "path": .array(path.map { .string($0) })]
        shown.append(path.isEmpty ? RuleShownGroup(label: "in", shapes: [], place: "the board's top level") : RuleShownGroup(label: "in", shapes: Array(containers)))
        if let connection = reader.connection(of: id) {
            let start = reader.record(connection.from), end = reader.record(connection.to)
            state["starts at"] = start.map(reader.full) ?? "missing"
            state["ends at"] = end.map(reader.full) ?? "missing"
            shown.append(RuleShownGroup(label: "starts at", shapes: start.map { [$0.id] } ?? [], place: start == nil ? "missing" : nil))
            shown.append(RuleShownGroup(label: "ends at", shapes: end.map { [$0.id] } ?? [], place: end == nil ? "missing" : nil))
            let mine = Set((shape[IsAProperty.self] ?? []).map(\.shape))
            let names = mine.compactMap { world.graph.names[$0] }.sorted().joined(separator: ", ")
            for (side, endShape) in [(Side.start, start), (Side.end, end)] {
                guard let endShape else { continue }
                let others = reader.ordered(reader.connections(at: endShape.id).filter { other in
                    other.arrow != id && (side == .start ? other.from == endShape.id : other.to == endShape.id)
                        && !mine.isDisjoint(with: (reader.record(other.arrow)?[IsAProperty.self] ?? []).map(\.shape))
                }, at: endShape.id)
                guard !others.isEmpty else { continue }
                let at = reader.title(endShape) ?? "it"
                let label = side == .start ? "beside it at its start (other \(names) arrows at \(at))" : "beside it at its end (other \(names) arrows at \(at))"
                state[label] = reader.shrunk(others.map(\.arrow)) { reader.arrowItem($0, side: side, from: endShape.id) }
                shown.append(RuleShownGroup(label: label, shapes: others.map(\.arrow)))
            }
        } else {
            // Every arrow at it, as the prototype listed them; past the budget, counted (the prototype never met a hub).
            let edges = reader.ordered(reader.connections(at: id).filter { $0.arrow != id }, at: id)
            if !edges.isEmpty {
                let starts = Set(edges.filter { $0.from == id }.map(\.arrow))
                state["along its edges"] = reader.shrunk(edges.map(\.arrow)) { arrow in
                    reader.arrowItem(arrow, side: starts.contains(arrow) ? .start : .end, from: id)
                }
                shown.append(RuleShownGroup(label: "along its edges", shapes: edges.map(\.arrow)))
            }
        }
        let siblings = (place.map(world.snapshot.children(of:)) ?? world.snapshot.topLevel).filter { sibling in
            sibling != id && reader.record(sibling).map { !(world.kinds[$0.kind]?.isLine ?? false) } ?? false
        }
        if !siblings.isEmpty {
            state["beside it, in the same place"] = reader.shrunk(siblings) { reader.brief($0) }
            shown.append(RuleShownGroup(label: "beside it, in the same place", shapes: siblings))
        }
        // What each chip found, in full while there's room, then how many more.
        for find in finds {
            let label = "found by \"\(find.phrase)\""
            let listed = find.listed.filter { reader.record($0) != nil }
            var items = listed.prefix(budget).compactMap { reader.record($0).map(reader.full) }
            let more = listed.count - min(listed.count, budget) + find.more
            if more > 0 { items.append(["and": .string("\(more) more")]) }
            state[label] = .array(items)
            shown.append(RuleShownGroup(label: label, shapes: listed))
        }
        let places = Dictionary(uniqueKeysWithValues: reader.read.map { ($0, world.snapshot.parent(of: $0)) })
        return RuleContext(state: .object(state), shown: shown, footprint: reader.read, place: place, places: places)
    }

    enum Side { case start, end }

    /// Reads shapes for one state, noting each it reads.
    final class Reader {
        let world: RuleWorld
        var read: Set<ShapeID> = []

        init(world: RuleWorld) { self.world = world }

        func record(_ id: ShapeID) -> AnyShapeRecord? {
            read.insert(id)
            guard let record = world.snapshot.shape(id), !record.isOpaque else { return nil }
            return record
        }

        func noun(_ record: AnyShapeRecord) -> String {
            record[TypeSchemaProperty.self] != nil ? "type" : world.kinds[record.kind]?.noun ?? record.kind.rawValue
        }

        func title(_ record: AnyShapeRecord) -> String? { TitleProperty.folded(record[TitleProperty.self]) }

        /// What a container is called in a shape's place: its title, else its kind's name.
        func placeName(_ record: AnyShapeRecord) -> String { title(record) ?? world.kinds[record.kind]?.label ?? record.kind.rawValue }

        /// Its types by name, each type read (a rename asks again).
        func typeNames(_ record: AnyShapeRecord) -> [String] {
            (record[IsAProperty.self] ?? []).compactMap { link in
                read.insert(link.shape)
                return world.graph.names[link.shape]
            }
        }

        /// Its words as plain text, each mention as its name, each shape mentioned read (a rename asks again): nil for
        /// none.
        func words(_ record: AnyShapeRecord) -> String? {
            guard let key = world.kinds[record.kind]?.words, let stored = record.propertiesJSON?[key]?.stringValue else { return nil }
            if stored.contains("@[") {
                for case let .mention(target, _) in MentionText(stored: stored).runs { read.insert(target) }
            }
            let text = MentionText.plainText(stored: stored, label: world.labels.label(of:)).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }

        func values(_ record: AnyShapeRecord) -> JSONValue? {
            guard let values = record[FieldValuesProperty.self]?.values, !values.isEmpty else { return nil }
            return .object(values)
        }

        /// A shape in full: what it is, its title, its types, its words and its values.
        func full(_ record: AnyShapeRecord) -> JSONValue {
            var out: [String: JSONValue] = ["kind": .string(noun(record))]
            if let title = title(record) { out["title"] = .string(title) }
            let types = typeNames(record)
            if !types.isEmpty { out["is"] = .array(types.map { .string($0) }) }
            if let words = words(record) { out["words"] = .string(words) }
            if let values = values(record) { out["values"] = values }
            return .object(out)
        }

        /// A shape by name: its title (an arrow by its ends) and its types.
        func brief(_ id: ShapeID) -> JSONValue {
            guard let record = record(id) else { return "missing" }
            var out: [String: JSONValue] = [:]
            if let connection = connection(of: id) {
                out["from"] = .string(self.record(connection.from).flatMap(title) ?? "untitled")
                out["to"] = .string(self.record(connection.to).flatMap(title) ?? "untitled")
            } else {
                out["title"] = .string(title(record) ?? "untitled \(noun(record))")
            }
            let types = typeNames(record)
            if !types.isEmpty { out["is"] = .array(types.map { .string($0) }) }
            return .object(out)
        }

        /// Another arrow at a shape: its far end by name, and its values.
        func arrowItem(_ arrow: ShapeID, side: Side, from near: ShapeID) -> JSONValue {
            guard let connection = connection(of: arrow) else { return "missing" }
            let far = connection.from == near ? connection.to : connection.from
            var out: [String: JSONValue] = [connection.from == near ? "to" : "from": brief(far)]
            if let record = record(arrow), case .object(let values)? = self.values(record) { out.merge(values) { kept, _ in kept } }
            return .object(out)
        }

        /// A group in full while it's small, else counted by type.
        func shrunk(_ ids: [ShapeID], _ item: (ShapeID) -> JSONValue) -> JSONValue {
            guard ids.count > RuleContext.budget else { return .array(ids.map(item)) }
            var counts: [String: Int] = [:]
            for id in ids {
                guard let record = record(id) else { continue }
                let types = typeNames(record)
                counts[types.isEmpty ? noun(record) : types.joined(separator: ", "), default: 0] += 1
            }
            return ["count": .number(Double(ids.count)), "by type": .object(counts.mapValues { .number(Double($0)) })]
        }

        /// The connection a shape carries (an arrow's), its two ends as the view resolves them.
        func connection(of id: ShapeID) -> (from: ShapeID, to: ShapeID)? {
            world.snapshot.edges(carriedBy: id).first { $0.slot.isEmpty }.map { ($0.source, $0.target) }
        }

        /// Connections at `near` in an order of the file's own, the far end's title and then the arrow's id, never the
        /// order Topology filed them in, which is the order they came (a commit's shapes in any order, an edited arrow
        /// last, a file opened again in its boards' order): what a rule sees of a shape is then the same in every
        /// session, so an answer kept today is found again when the file is opened again.
        func ordered(_ connections: [(arrow: ShapeID, from: ShapeID, to: ShapeID)], at near: ShapeID) -> [(arrow: ShapeID, from: ShapeID, to: ShapeID)] {
            connections.map { connection in
                let far = connection.from == near ? connection.to : connection.from
                return (key: (world.snapshot.shape(far).flatMap(title) ?? "", connection.arrow.description), connection: connection)
            }.sorted { $0.key < $1.key }.map(\.connection)
        }

        /// The connections that start or end at a shape, by the arrows that carry them, in the order Topology filed them.
        func connections(at id: ShapeID) -> [(arrow: ShapeID, from: ShapeID, to: ShapeID)] {
            var seen: Set<ShapeID> = []
            var out: [(arrow: ShapeID, from: ShapeID, to: ShapeID)] = []
            for edge in world.snapshot.edges(of: id) where edge.slot.isEmpty && edge.carrier != id && seen.insert(edge.carrier).inserted {
                read.insert(edge.carrier)
                out.append((edge.carrier, edge.source, edge.target))
            }
            return out
        }
    }
}
