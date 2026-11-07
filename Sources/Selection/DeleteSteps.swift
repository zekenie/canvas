import Canvas

/// What a delete says it did, for the step's name: "Delete" when it took only what it was asked for, and what went
/// when it took more ("Delete Note and 2 Arrows": a relationship type and the arrows at its ends; "Delete 2 Tables and 5
/// Arrows"), so Undo says what comes back. App-wide: every delete, whichever kind's shape it is, names its step
/// this way, and a delete that took nothing along stays "Delete". The kinds are called what the registry calls
/// them (`registry.label(of:)`), plural with an "s".
public enum DeleteSteps {
    /// `verb` and the kinds of what was asked for and what went along, each kind once with its count: the asked
    /// first, the most of a kind first, then the kinds that went along; just `verb` when nothing went along. A
    /// kind in both counts once, with both.
    @MainActor
    public static func name(_ verb: String = "Delete", asked: [ShapeKind], along: [KindCount], in registry: Registry) -> String {
        guard along.contains(where: { $0.count > 0 }) else { return verb }
        var counts: [KindCount] = []
        func add(_ batch: [KindCount]) {
            for item in batch.sorted(by: { ($0.count, label($1.kind)) > ($1.count, label($0.kind)) }) {
                if let at = counts.firstIndex(where: { $0.kind == item.kind }) { counts[at].count += item.count } else { counts.append(item) }
            }
        }
        func label(_ kind: ShapeKind) -> String { registry.label(of: kind).name }
        var askedCounts: [ShapeKind: Int] = [:]
        for kind in asked { askedCounts[kind, default: 0] += 1 }
        add(askedCounts.map { KindCount(kind: $0.key, count: $0.value) })
        add(along)
        let parts = counts.map { item in item.count == 1 ? label(item.kind) : "\(item.count) \(plural(label(item.kind)))" }
        return "\(verb) \(list(parts))"
    }

    /// "A", "A and B", "A, B and C".
    public static func list(_ parts: [String]) -> String {
        switch parts.count {
        case 0, 1: return parts.first ?? ""
        default: return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
    }

    /// A kind's name in the plural: "Notes", "Arrows", "Entries", "Boxes".
    public static func plural(_ name: String) -> String {
        if let last = name.last, last == "y", let before = name.dropLast().last, !"aeiouAEIOU".contains(before) { return name.dropLast() + "ies" }
        if name.hasSuffix("s") || name.hasSuffix("x") || name.hasSuffix("ch") || name.hasSuffix("sh") { return name + "es" }
        return name + "s"
    }
}
