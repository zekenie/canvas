import Canvas
import CanvasRPC
import CoreGraphics
import DrawScript
import FuzzyMatching
import Topology

// `canvas kinds`: what a script can draw, and with what. The kinds the app has, each as the language
// sees it: whether a script can draw it (and why not), its names, size, attributes with their types,
// and the sides an edge leaves it by.

/// A kind, as `kinds` lists it: the language's vocabulary for it.
public struct KindSummary: Encodable {
    let kind: String
    let title: String?
    /// The tool named for it (`ToolID(placing:)`), by its label: the one that places it, or draws
    /// it by hand.
    let tool: String?
    /// Whether a script can draw it, and why not.
    let drawable: Bool
    let why: String?
    /// Whether its shapes have titles: `named` (given one), `derived` (worked out), `none`.
    let names: String
    /// What its tool places: `200x200`.
    let size: String?
    /// The smallest its shapes are drawn (`Placement.minimumSize`), under which a `size:` is refused:
    /// `96x64`; nil where any size goes.
    let smallest: String?
    /// What a shape of it holds, which `in "X"` names it for: `board`, a board of its own (a
    /// subboard's, which the shape goes on), or `shapes` on the board it's on (a frame's, which the
    /// shape goes in); nil for neither.
    let holds: String?
    /// What a script can write on it, and what each takes: `{"status": "todo|doing|blocked|done"}`.
    let attributes: [String: String]
    /// The sides an edge may leave it by, and what it may carry from each.
    let edges: [String: [String]]?
    /// What an edge to or from one of its rows (`"orders".customer_id`) may carry, either way: a table's columns,
    /// `foreign-key`. Nil for a kind whose rows take none, or that has no rows.
    let rows: [String]?
    /// The pills that can stand for one of its shapes, so that an edge to it from another board can go
    /// through one: each kind of pill whose plugin can make a new shape of this kind one it stands for,
    /// with what that takes, in the order pills are made (`registry.standIns`' makers). Nil for none.
    let via: [StandInSummary]?
    let schema: JSONValue?
}

/// A kind of pill that can stand for a shape of a kind, as `kinds` lists it.
public struct StandInSummary: Encodable {
    let kind: String
    /// What a shape must be before the pill can stand for it, in a word (`public`), or nil for nothing.
    let needs: String?
}

/// Why a script can't place a kind no tool places: its tool draws one by hand (a line, by its
/// drag), or it has none.
@MainActor
func unplaceable(_ kind: ShapeKind, in registry: Registry) -> String {
    guard let tool = registry.tools.first(where: { $0.id == ToolID(placing: kind) }) else { return "no tool places one" }
    return "its tool (\(tool.label)) draws one by hand, so a script can't place one"
}

/// The kinds the app has, or the one called `named`, as the language sees them, with each one's JSON
/// Schema if `schema`.
@MainActor
public func kinds(named: String? = nil, schema: Bool = false, in registry: Registry) throws(DrawError) -> [KindSummary] {
    var kinds = registry.kinds.sorted { $0.rawValue < $1.rawValue }
    if let named {
        guard let kind = kinds.first(where: { $0.rawValue == named }) else {
            let all = kinds.map(\.rawValue)
            throw DrawError("there's no kind of shape called \(named)", reason: ScriptError.Reason.unknownKind.rawValue,
                            hint: (Suggestions.closest(to: named, among: all, limit: 1).first.map { "did you mean \($0)? " } ?? "")
                                + "the kinds: \(all.joined(separator: ", "))")
        }
        kinds = [kind]
    }
    let naming = registry.drawNaming, edging = registry.drawEdging, edgeKind = edging.flatMap { $0.kind(registry) }
    let standIns = registry.standIns
    return kinds.map { kind in
        let vocabulary = KindVocabulary(kind, in: registry)
        let placement = registry.placement(for: kind)
        let why: String? = if Keyword(rawValue: kind.rawValue) != nil {
            "its name is one of the language's words"
        } else if kind == edgeKind {
            "it joins two shapes: write edge \"A\" -> \"B\""
        } else if placement == nil {
            unplaceable(kind, in: registry)
        } else {
            nil
        }
        let names = if vocabulary.namingProperty != nil { "named" } else if naming?.isDerived(kind, registry) == true { "derived" } else { "none" }
        var attributes: [String: String] = [:]
        for name in vocabulary.attributes { attributes[name] = vocabulary.compactType(of: name) }
        for name in vocabulary.collisions {
            attributes[name] = "\(vocabulary.compactType(of: name)) — can't be written: \(name): is one of the language's own keys"
        }
        let sides = (edging?.sides(kind, registry) ?? [:]).filter { !$0.value.isEmpty }
        let rows = edging?.rows(kind, registry) ?? []
        // Asked of a new shape of the kind, as its placement makes one: a pill can stand for the kind when the pill's
        // plugin can make that shape one it admits (`fulfil`, which changes only a copy here).
        let via: [StandInSummary] = placement.map { placement in
            let blank = placement.shape(at: .zero)
            return standIns.makers.compactMap { maker in
                var probe = blank
                return standIns.fulfil(maker, &probe) ? StandInSummary(kind: maker.rawValue, needs: standIns.needs(maker)) : nil
            }
        } ?? []
        return KindSummary(kind: kind.rawValue, title: vocabulary.root["title"]?.stringValue,
                           tool: registry.tools.first { $0.id == ToolID(placing: kind) }?.label,
                           drawable: why == nil, why: why, names: names,
                           size: placement.map { Drawing.written($0.size) },
                           smallest: placement.flatMap { $0.minimumSize == .zero ? nil : Drawing.written($0.minimumSize) },
                           holds: registry.boardOwningKinds.contains(kind) ? "board" : registry.containingKinds.contains(kind) ? "shapes" : nil,
                           attributes: attributes,
                           edges: sides.isEmpty ? nil : Dictionary(uniqueKeysWithValues: sides.map { ($0.key.rawValue, $0.value) }),
                           rows: rows.isEmpty ? nil : rows,
                           via: via.isEmpty ? nil : via,
                           schema: schema ? .object(vocabulary.root) : nil)
    }
}
