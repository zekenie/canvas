import Canvas
import Foundation

// What a relationship is, as values: a relationship type's ends (compiled from the arrows between it
// and other types, never stored), the rows its end types' notes get from them, and the one function that
// says whether a note fits a side. All `Sendable` and pure, so the release, the layout, the check, a
// run's reading and a query off the main actor ask the same code. `RelationshipIndex` (Fields) keeps
// them by each commit.

/// The side of a relationship type an end is on: `from` is an arrow from a type into the relationship
/// type, `to` an arrow out of it to a type.
public enum RelationshipSide: Sendable, Hashable, CaseIterable {
    case from, to

    /// The other side.
    public var other: RelationshipSide { self == .from ? .to : .from }
}

/// What a relationship type asks of one of its ends: every note at the end has a relationship
/// (`needed`), at most one (`onlyOne`). Stored as `endRule` on the end's arrow (`RelationshipEndProperty`),
/// nothing while both are false.
public struct EndRule: SchemaDefined, Sendable, Hashable {
    public static let properties = Properties<EndRule>(definition: "end-rule") {
        Property("needed", \.needed).description("Every note at this end has a relationship of the type.")
        Property("onlyOne", \.onlyOne).description("A note at this end has at most one relationship of the type.")
    }

    public var needed = false
    public var onlyOne = false

    public init() {}

    public init(needed: Bool, onlyOne: Bool) {
        self.needed = needed
        self.onlyOne = onlyOne
    }

    /// Both false: no rule.
    public var isNone: Bool { !needed && !onlyOne }

    /// Either's rule: what two ends merged into one row ask.
    func union(_ other: EndRule) -> EndRule { EndRule(needed: needed || other.needed, onlyOne: onlyOne || other.onlyOne) }
}

/// One end of a relationship type: an arrow between it and a type.
public struct RelationshipEnd: Sendable, Hashable {
    /// The type at this end, read through a pill that names one shape.
    public let type: ShapeID
    /// The end's arrow, on whichever board it is drawn.
    public let carrier: ShapeID
    /// Its words' first line, trimmed; nil when it says nothing.
    public let name: String?
    public let rule: EndRule

    public init(type: ShapeID, carrier: ShapeID, name: String? = nil, rule: EndRule = EndRule()) {
        self.type = type
        self.carrier = carrier
        self.name = name
        self.rule = rule
    }
}

/// A relationship type's ends, each side in the carriers' file order.
public struct RelationshipSides: Sendable, Equatable {
    /// Arrows from a type into the relationship type.
    public var from: [RelationshipEnd] = []
    /// Arrows out of the relationship type to a type.
    public var to: [RelationshipEnd] = []

    public init(from: [RelationshipEnd] = [], to: [RelationshipEnd] = []) {
        self.from = from
        self.to = to
    }

    public subscript(side: RelationshipSide) -> [RelationshipEnd] {
        get { side == .from ? from : to }
        set { if side == .from { from = newValue } else { to = newValue } }
    }

    /// Whether neither side has an end.
    public var isEmpty: Bool { from.isEmpty && to.isEmpty }

    /// The types on a side, each once, in file order.
    public func types(on side: RelationshipSide) -> [ShapeID] {
        var seen: Set<ShapeID> = []
        return self[side].map(\.type).filter { seen.insert($0).inserted }
    }
}

/// What a row is called before any type's title is read. `.unnamed(nil)`: unnamed ends on both sides, as
/// one row.
public enum RowLabel: Sendable, Hashable {
    case typed(String)
    case unnamed(RelationshipSide?)
}

public struct RelationshipRowKey: Sendable, Hashable {
    public let type: ShapeID
    public let label: RowLabel

    public init(type: ShapeID, label: RowLabel) {
        self.type = type
        self.label = label
    }
}

/// A row the notes of one type get: one relationship type's ends at that type.
public struct RelationshipRow: Sendable, Hashable {
    public let key: RelationshipRowKey
    /// The side, or both, these notes are on.
    public let sides: Set<RelationshipSide>
    /// The types at the other end(s), in file order; empty: anything.
    public let others: [ShapeID]
    /// The merged ends' rules, either set.
    public let rule: EndRule
    /// The end arrows it comes from.
    public let carriers: [ShapeID]
    /// The end type that gives it: the note's own, or one it builds on.
    public let source: ShapeID

    public init(key: RelationshipRowKey, sides: Set<RelationshipSide>, others: [ShapeID], rule: EndRule, carriers: [ShapeID], source: ShapeID) {
        self.key = key
        self.sides = sides
        self.others = others
        self.rule = rule
        self.carriers = carriers
        self.source = source
    }

    /// The side the row's note takes when the row draws an arrow.
    public var drawSide: RelationshipSide { sides.contains(.from) ? .from : .to }

    /// What the row is called, in lower case: the typed name; else, by the side its end is on, a name read from a
    /// title. A from end (`.unnamed(.from)`) and both sides merged (`.unnamed(nil)`): the relationship type's
    /// title when it has one (car's row of `owner` is `owner`), else, with exactly one type at the other end that
    /// has a title, that title. A to end: with exactly one type at the other end that has a title, that title
    /// (person's row is `car`); else the relationship type's title. Last, `untitled`. One function, read at the
    /// draw: a rename of a type changes no row's identity.
    @MainActor
    public func name(in types: TypeGraph) -> String {
        if case .typed(let name) = key.label { return name }
        let own = types.names[key.type]
        let other = others.count == 1 ? types.names[others[0]] : nil
        switch key.label {
        case .unnamed(.to): return (other ?? own ?? TypesStyle.untitledType).lowercased()
        default: return (own ?? other ?? TypesStyle.untitledType).lowercased()
        }
    }
}

/// The ends of every relationship type and the rows they give, as one commit left them.
public struct RelationshipEnds: Sendable, Equatable {
    /// By relationship type; absent: no end drawn.
    public internal(set) var sides: [ShapeID: RelationshipSides] = [:]
    /// By end type: what its own ends give its notes.
    public internal(set) var rows: [ShapeID: [RelationshipRow]] = [:]

    public init() {}

    /// The rows one relationship type's ends give the types at them, by end type: the one place the merge
    /// rule lives.
    ///
    /// 1. Ends at a type with a typed name: one row for each distinct name (exact, after trimming), on
    ///    every side that has an end of that name (Ann → Bo and Cy → Ann are one `friends` row on Ann).
    /// 2. Ends at a type with no name: if the type has unnamed ends on both sides and the relationship
    ///    type's from types equal its to types as sets, one row on both sides; else one row a side.
    /// 3. A row's rule is the union of the merged ends' rules; its others are the types on the opposite
    ///    side or sides.
    ///
    /// It never reads a title, so a rename changes no row's identity and no row count.
    public nonisolated static func rows(of relationshipType: ShapeID, sides: RelationshipSides) -> [ShapeID: [RelationshipRow]] {
        var result: [ShapeID: [RelationshipRow]] = [:]
        var order: [ShapeID] = []
        var seen: Set<ShapeID> = []
        for end in sides.from + sides.to where seen.insert(end.type).inserted { order.append(end.type) }
        let fromTypes = Set(sides.from.map(\.type)), toTypes = Set(sides.to.map(\.type))
        for type in order {
            let ends: [RelationshipSide: [RelationshipEnd]] = [.from: sides.from.filter { $0.type == type }, .to: sides.to.filter { $0.type == type }]
            func row(_ label: RowLabel, _ merged: [RelationshipEnd], on rowSides: Set<RelationshipSide>) -> RelationshipRow {
                var others: [ShapeID] = []
                for side in RelationshipSide.allCases where rowSides.contains(side) {
                    for other in sides.types(on: side.other) where !others.contains(other) { others.append(other) }
                }
                return RelationshipRow(key: RelationshipRowKey(type: relationshipType, label: label), sides: rowSides, others: others,
                                       rule: merged.reduce(EndRule()) { $0.union($1.rule) }, carriers: merged.map(\.carrier), source: type)
            }
            var rows: [RelationshipRow] = []
            // Typed names, in the order they first appear.
            let all = (ends[.from] ?? []) + (ends[.to] ?? [])
            var names: [String] = []
            for end in all { if let name = end.name, !names.contains(name) { names.append(name) } }
            for name in names {
                let named = all.filter { $0.name == name }
                var rowSides: Set<RelationshipSide> = []
                if (ends[.from] ?? []).contains(where: { $0.name == name }) { rowSides.insert(.from) }
                if (ends[.to] ?? []).contains(where: { $0.name == name }) { rowSides.insert(.to) }
                rows.append(row(.typed(name), named, on: rowSides))
            }
            let unnamedFrom = (ends[.from] ?? []).filter { $0.name == nil }, unnamedTo = (ends[.to] ?? []).filter { $0.name == nil }
            if !unnamedFrom.isEmpty, !unnamedTo.isEmpty, fromTypes == toTypes {
                rows.append(row(.unnamed(nil), unnamedFrom + unnamedTo, on: [.from, .to]))
            } else {
                if !unnamedFrom.isEmpty { rows.append(row(.unnamed(.from), unnamedFrom, on: [.from])) }
                if !unnamedTo.isEmpty { rows.append(row(.unnamed(.to), unnamedTo, on: [.to])) }
            }
            result[type] = rows
        }
        return result
    }
}

/// What one end of a connection is, from records and the file alone: one classification for the check's
/// words, a row's pill, the far writer and the fit. `.note` is judged, `.free` is a free end, the rest are
/// unread.
public enum EndReading: Sendable, Hashable {
    /// A shape, or a direct pill that is live and admitted.
    case note(ShapeID)
    /// A pill whose shape is there and may not be stood for now (`needs`: the word its kind says a shape must be).
    case notAdmitted(ShapeID, needs: String)
    /// A pill whose shape is in no board (`called`: what it was called).
    case gone(called: String?)
    /// A pill whose shape is on a board the app cannot show, or kept aside.
    case unavailable(called: String?)
    /// A pill that finds shapes.
    case query(called: String?)
    /// A pill that stands for nothing.
    case empty
    /// Not bound.
    case free
}

/// One end of a connection: what the arrow is bound to there, and how that reads.
public struct ReadEnd: Sendable, Hashable {
    /// What the arrow is bound to: the note, or the pill.
    public let literal: ShapeID?
    public let reading: EndReading

    public init(literal: ShapeID?, reading: EndReading) {
        self.literal = literal
        self.reading = reading
    }

    /// The pill, when the end was read through one.
    public var via: ShapeID? {
        guard let literal else { return nil }
        switch reading {
        case .note(let id): return id == literal ? nil : literal
        case .free: return nil
        case .notAdmitted, .gone, .unavailable, .query, .empty: return literal
        }
    }
}

/// A connection's two ends, read.
public struct ConnectionReading: Sendable, Hashable {
    public let from: ReadEnd
    public let to: ReadEnd

    public init(from: ReadEnd, to: ReadEnd) {
        self.from = from
        self.to = to
    }

    public subscript(side: RelationshipSide) -> ReadEnd { side == .from ? from : to }
}

/// Whether an end fits a side of a relationship type.
public enum SideFit: Sendable, Hashable {
    /// The end is one of the side's types, or builds on one.
    case fits
    /// The side has no end drawn: anything.
    case open
    /// The end is none of the side's types (`allowed`).
    case misfit(allowed: [ShapeID])
    /// No verdict: the end is not a note that can be judged.
    case unjudged(EndReading)
}

/// An arrow's fit against one relationship type: one verdict a side.
public struct Fit: Sendable, Hashable {
    public let from: SideFit
    public let to: SideFit

    public init(from: SideFit, to: SideFit) {
        self.from = from
        self.to = to
    }

    public subscript(side: RelationshipSide) -> SideFit { side == .from ? from : to }

    /// Either side is a misfit.
    public var isMisfit: Bool {
        if case .misfit = from { return true }
        if case .misfit = to { return true }
        return false
    }

    /// Each side fits or is open.
    public var holds: Bool { [from, to].allSatisfy { $0 == .fits || $0 == .open } }
}

/// The types and the ends of one commit, together: the fit's whole input, and the query fact.
public struct RelationshipGraph: Sendable {
    public let types: TypeGraph
    public let ends: RelationshipEnds

    public init(types: TypeGraph, ends: RelationshipEnds) {
        self.types = types
        self.ends = ends
    }
}

extension RelationshipGraph {
    /// Whether the shape is a relationship type now: a type that holds the mark.
    public nonisolated func isRelationshipType(_ id: ShapeID) -> Bool { types.relationshipTypes.contains(id) }

    /// A relationship type's ends. Its own alone today; the one place a later union with what it builds on
    /// goes.
    public nonisolated func sides(of type: ShapeID) -> RelationshipSides { ends.sides[type] ?? RelationshipSides() }

    /// THE rule: whether `end` fits `side` of `type`. Everything else calls it.
    ///
    /// 1. An end that is not a note has no verdict.
    /// 2. The side's types are its ends' types that are still types; none: open.
    /// 3. An end that is itself a type is a misfit: a type's own note is never an instance.
    /// 4. The end fits when what its types lead to meets the side's types; else it is a misfit. A note of no
    ///    type has no ancestors, so it fits only an open side.
    public nonisolated func side(_ end: EndReading, at side: RelationshipSide, of type: ShapeID) -> SideFit {
        guard case .note(let note) = end else { return .unjudged(end) }
        // The verdict a file's arrows mostly get, without making the side's list or the note's ancestors: an end with no type
        // among the side's is open, and a note one of whose own types is one of the side's fits (an ancestor, the first step).
        let ends = sides(of: type)[side]
        guard ends.contains(where: { types.types.contains($0.type) }) else { return .open }
        if !types.types.contains(note), let own = types.links[note],
           own.contains(where: { link in ends.contains { $0.type == link.shape && types.types.contains($0.type) } }) { return .fits }
        let allowed = sides(of: type).types(on: side).filter { types.types.contains($0) }
        guard !types.types.contains(note) else { return .misfit(allowed: allowed) }
        let ancestors = types.ancestors(of: note)
        return allowed.contains(where: ancestors.contains) ? .fits : .misfit(allowed: allowed)
    }

    /// Two calls of `side`. Nil when `type` is no relationship type now (gone, unmarked): not judged.
    public nonisolated func fit(of type: ShapeID, from: EndReading, to: EndReading) -> Fit? {
        guard isRelationshipType(type) else { return nil }
        return Fit(from: side(from, at: .from, of: type), to: side(to, at: .to, of: type))
    }

    /// The relationship types an arrow between two ends may take, each list by name, untitled last.
    /// `taken`: both sides hold and at least one fits by a drawn end. `open`: no end drawn on either side
    /// (offered after, never taken alone). Both empty when either end is itself a type's note, or is not a
    /// note.
    public nonisolated func fitting(from: EndReading, to: EndReading) -> (taken: [ShapeID], open: [ShapeID]) {
        guard case .note(let a) = from, case .note(let b) = to, !types.types.contains(a), !types.types.contains(b) else { return ([], []) }
        var taken: [ShapeID] = [], open: [ShapeID] = []
        for type in types.relationshipTypes {
            guard let fit = fit(of: type, from: from, to: to) else { continue }
            if fit.holds, fit.from == .fits || fit.to == .fits {
                taken.append(type)
            } else if fit.from == .open, fit.to == .open {
                open.append(type)
            }
        }
        return (sorted(taken), sorted(open))
    }

    /// The rows a shape with this `is` list gets: its types' and what they build on, in the order the
    /// types' blocks are read (the general type's first, as the fields are), each type's rows in its
    /// ends' order. For a type's own note, `list` is `[itself]`. Nothing for a relationship type's own
    /// note, and nothing from a relationship type in the list or among what it builds on. A row two blocks
    /// give alike (same relationship type, same label) is the more specific type's, where the general one's
    /// stood.
    public nonisolated func rows(for list: [ShapeID], isType: Bool) -> [RelationshipRow] {
        guard !ends.rows.isEmpty, !list.isEmpty else { return [] }
        if isType, let own = list.first, types.relationshipTypes.contains(own) { return [] }
        let order = TypeOrder.linearized(TypeOrder.heads(of: list), parents: types.parents(of:))
        var rows: [RelationshipRow] = []
        var places: [RelationshipRowKey: Int] = [:]
        for type in order.reversed() where types.types.contains(type) && !types.relationshipTypes.contains(type) {
            for row in ends.rows[type] ?? [] {
                if let place = places[row.key] {
                    rows[place] = row
                } else {
                    places[row.key] = rows.count
                    rows.append(row)
                }
            }
        }
        return rows
    }

    /// Whether a shape may sit at the other end of a row: it fits the row's other side (either of them, for
    /// a row on both). A type's own note never does.
    public nonisolated func fits(_ shape: ShapeID, otherEndOf row: RelationshipRow) -> Bool {
        for side in row.sides {
            switch self.side(.note(shape), at: side.other, of: row.key.type) {
            case .fits, .open: return !types.types.contains(shape)
            case .misfit, .unjudged: continue
            }
        }
        return false
    }

    /// The side the row's note takes when it is related to `other`: the row's one side; for a row on both, the `from` end
    /// when `other` fits the `to` side, else the `to` end (so the arrow runs from the note whose type is at the `from` end,
    /// whichever row set it).
    public nonisolated func drawSide(of row: RelationshipRow, picking other: ShapeID) -> RelationshipSide {
        guard row.sides.count > 1 else { return row.drawSide }
        switch side(.note(other), at: .to, of: row.key.type) {
        case .fits, .open: return .from
        case .misfit, .unjudged: return .to
        }
    }

    /// The relationship types that join the two types, one at each side whichever way round, a type that builds on an
    /// end's type counting as it: the guard of an offer to relate a type to another when a relationship type between them
    /// is there already.
    public nonisolated func relationshipTypes(joining a: ShapeID, and b: ShapeID) -> [ShapeID] {
        guard !types.relationshipTypes.isEmpty else { return [] }
        let ofA = types.ancestors(of: a).union([a]), ofB = types.ancestors(of: b).union([b])
        return sorted(types.relationshipTypes.filter { type in
            let sides = sides(of: type)
            let from = sides.types(on: .from), to = sides.types(on: .to)
            func meets(_ list: [ShapeID], _ set: Set<ShapeID>) -> Bool { list.contains { set.contains($0) } }
            return (meets(from, ofA) && meets(to, ofB)) || (meets(from, ofB) && meets(to, ofA))
        })
    }

    /// By name (case aside), an untitled one last, the id the tie.
    private nonisolated func sorted<S: Sequence>(_ ids: S) -> [ShapeID] where S.Element == ShapeID {
        let keyed = ids.map { (id: $0, name: types.names[$0]?.lowercased(), uuid: $0.rawValue.uuidString) }
        return keyed.sorted { a, b in
            switch (a.name, b.name) {
            case (nil, nil): a.uuid < b.uuid
            case (nil, _): false
            case (_, nil): true
            case (let x?, let y?): x == y ? a.uuid < b.uuid : x < y
            }
        }.map(\.id)
    }
}
