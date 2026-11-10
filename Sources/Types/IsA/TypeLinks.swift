import Canvas
import CoreGraphics
import Draw
import Selection
import SlashCommands
import Titles

/// What a shape is, and what makes a shape a type, in the calls every way in goes through (`/is-a`,
/// a chip's menu, the panel's Types, a shape's menu), so what a later slice settles when a type is
/// given or taken back is settled in these, inside the person's own step. The plural forms are one
/// transaction (so one step for a selection), the singular ones call them. Each leaves out a shape
/// that cannot take the change (not typeable, already what is asked) before it transacts, and
/// transacts nothing when none is left; a read-only shape stays in, so the core refuses it and it
/// shakes while the rest change in the one step.
extension CanvasEditor {
    /// Makes `shape` an instance of `type`, in one step ("Add Type"): the type goes at the end of its
    /// list, where a later one wins. Nothing for a type it is already, directly or through another, one
    /// `TypeIndex.admits` refuses (itself, what is it in turn, what isn't a type), or a shape that isn't there
    /// or can't be an instance; a read-only shape is refused by the core, and shakes.
    public func addTypeLink(_ type: ShapeID, to shape: ShapeID) { addTypeLink(type, to: [shape]) }

    /// The same for several shapes, in one step.
    public func addTypeLink(_ type: ShapeID, to shapes: [ShapeID]) {
        guard let types else { return }
        let taking = shapes.filter { shape in
            types.admits(type, for: shape) && (self.shape(inFile: shape).map { registry.isTypeable($0.kind) } ?? false)
        }
        guard !taking.isEmpty else { return }
        transact(TypesStyle.addType) { transaction in
            for shape in taking {
                transaction.update(inFile: shape) { record in
                    var list = record[IsAProperty.self] ?? []
                    list.append(TypeLink(type))
                    record[IsAProperty.self] = list
                    // A note with no title and a value already there is titled once, as the field titles it.
                    if TitleProperty.folded(record[TitleProperty.self]) == nil, record[TypeSchemaProperty.self] == nil,
                       registry.properties(for: record.kind).contains(TitleProperty.key),
                       let source = fieldBook?.titleSource(types: list.map(\.shape)),
                       let title = FieldTitling.firstTitle(values: record[FieldValuesProperty.self] ?? FieldValues(), source) {
                        record[TitleProperty.self] = title
                    }
                }
            }
        }
    }

    /// Makes `shape` no longer an instance of `type`, in one step ("Remove Type"): the entry goes from
    /// its list, and the property with the last. Nothing for a shape that isn't one; a read-only
    /// shape is refused by the core, and shakes.
    public func removeTypeLink(_ type: ShapeID, from shape: ShapeID) { removeTypeLink(type, from: [shape]) }

    /// The same for several shapes, in one step.
    public func removeTypeLink(_ type: ShapeID, from shapes: [ShapeID]) {
        let taking = shapes.filter { self.shape(inFile: $0)?[IsAProperty.self]?.contains(TypeLink(type)) == true }
        guard !taking.isEmpty else { return }
        transact(TypesStyle.removeType) { transaction in
            for shape in taking {
                transaction.update(inFile: shape) { record in
                    record[IsAProperty.self] = (record[IsAProperty.self] ?? []).filter { $0 != TypeLink(type) }
                }
            }
        }
    }

    /// Makes the shape a type, in one step ("Make Type", unless it's part of another). Its words are
    /// the schema when they are a JSON object (`TypeWordsSchema`), as written, and the sync then
    /// writes the words from the schema; else it gets the starter schema, an object with no fields,
    /// which its words are then ahead of (the sync asks the model for the schema they say once the
    /// person is done with them, as for an edit of them). Whether it's public stays as it was (public,
    /// as every shape is, unless the person made it private). Nothing for a shape that's
    /// already one, or whose kind can't be one; a read-only shape is refused by the core, and shakes.
    public func makeType(_ id: ShapeID) { makeTypes([id]) }

    /// The same for several shapes, in one step.
    public func makeTypes(_ ids: [ShapeID]) {
        var schemas: [(id: ShapeID, schema: String)] = []
        for id in ids {
            guard let record = document[id], record[TypeSchemaProperty.self] == nil, registry.canBeType(record.kind) else { continue }
            let words = registry.typeWords(of: record.kind)?.words(record)
            schemas.append((id, words.flatMap(TypeWordsSchema.schema(fromWords:)) ?? TypeSchemaProperty.starter))
        }
        guard !schemas.isEmpty else { return }
        transact(TypesStyle.makeType) { transaction in
            for (id, schema) in schemas {
                transaction.update(id) { $0[TypeSchemaProperty.self] = SchemaText(schema) }
            }
        }
    }

    /// Makes the shape a relationship type, in one step ("Make Relationship Type"): a plain note first becomes a
    /// type, as `makeType` makes one, and the type is marked. Nothing for a shape that is one already or whose kind
    /// cannot hold the mark; a read-only shape is refused by the core, and shakes.
    public func makeRelationshipType(_ id: ShapeID) { makeRelationshipTypes([id]) }

    /// The same for several shapes, in one step.
    public func makeRelationshipTypes(_ ids: [ShapeID]) {
        var taking: [(id: ShapeID, schema: String?)] = []
        for id in ids {
            guard let record = document[id], registry.canBeRelationshipType(record.kind) else { continue }
            if record[TypeSchemaProperty.self] == nil {
                guard registry.canBeType(record.kind) else { continue }
                let words = registry.typeWords(of: record.kind)?.words(record)
                taking.append((id, words.flatMap(TypeWordsSchema.schema(fromWords:)) ?? TypeSchemaProperty.starter))
            } else if record[RelationshipProperty.self] != true {
                taking.append((id, nil))
            }
        }
        guard !taking.isEmpty else { return }
        transact(TypesStyle.makeRelationshipType) { transaction in
            for (id, schema) in taking {
                transaction.update(id) { record in
                    if let schema { record[TypeSchemaProperty.self] = SchemaText(schema) }
                    record[RelationshipProperty.self] = true
                }
            }
        }
    }

    /// Takes the mark off a relationship type, in one step ("Make Plain Type"): it is still a type, with its words,
    /// rows and instances. Nothing for a shape that isn't marked; a read-only shape is refused by the core, and shakes.
    public func makePlainType(_ id: ShapeID) { makePlainTypes([id]) }

    /// The same for several shapes, in one step.
    public func makePlainTypes(_ ids: [ShapeID]) {
        let taking = ids.filter { document[$0]?[RelationshipProperty.self] == true }
        guard !taking.isEmpty else { return }
        transact(TypesStyle.makePlainType) { transaction in
            for id in taking { transaction.update(id) { $0[RelationshipProperty.self] = nil } }
        }
    }

    /// Gives each arrow the relationship type, in the place of the one it has, in one step ("Add Type"): the entry
    /// goes and the new one comes, so an arrow is of one relationship type at a time. The writer for outside a
    /// press (a port's release gives its one type by `addTypeLink` alone, inside its own step). Nothing for a
    /// shape that is no arrow of a relating kind, or that the type isn't admitted to in the place of its own
    /// (`TypeIndex.admits(_:for:replacing:)`), which keeps its own; `addTypeLink` is still the one way a type is given.
    public func setRelationshipType(_ type: ShapeID, of connections: [ShapeID]) {
        guard let index = types else { return }
        let marked = index.graph.relationshipTypes
        let taking = connections.filter { id in
            guard let record = shape(inFile: id), registry.relates(record.kind) else { return false }
            let own = Set((record[IsAProperty.self] ?? []).map(\.shape)).intersection(marked)
            return own.contains(type) || index.admits(type, for: id, replacing: own)
        }
        guard !taking.isEmpty else { return }
        undoHistory.group(TypesStyle.addType) {
            for id in taking {
                for old in shape(inFile: id)?[IsAProperty.self]?.map(\.shape) ?? [] where old != type && marked.contains(old) { removeTypeLink(old, from: id) }
                addTypeLink(type, to: id)
            }
        }
    }

    /// Gives the type the way a person asks for it, from `/is-a` and Is a ▸: an arrow given a relationship type
    /// has it replace the one it has; any other shape has the type added. One step, "Add Type".
    func giveType(_ type: ShapeID, to ids: [ShapeID]) {
        // The role partition: an arrow is given relationship types only, and no other shape is.
        let isRelationship = types?.graph.relationshipTypes.contains(type) == true
        let arrows = ids.filter { id in shape(inFile: id).map { registry.relates($0.kind) } ?? false }
        let replacing = isRelationship ? arrows : []
        let rest = isRelationship ? [] : ids.filter { !arrows.contains($0) }
        undoHistory.group(TypesStyle.addType) {
            if !replacing.isEmpty { setRelationshipType(type, of: replacing) }
            if !rest.isEmpty { addTypeLink(type, to: rest) }
        }
    }

    /// Makes the shape no longer a type, in one step ("Remove Type"): its schema goes, and its words
    /// stay, as does whether it's public. Undo brings the schema back. Nothing for a shape that isn't
    /// one; a read-only shape is refused by the core, and shakes.
    public func removeType(_ id: ShapeID) { removeTypes([id]) }

    /// The same for several shapes, in one step.
    public func removeTypes(_ ids: [ShapeID]) {
        let taking = ids.filter { document[$0]?[TypeSchemaProperty.self] != nil }
        guard !taking.isEmpty else { return }
        transact(TypesStyle.removeType) { transaction in
            for id in taking {
                transaction.update(id) {
                    $0[TypeSchemaProperty.self] = nil
                    $0[RelationshipProperty.self] = nil
                }
            }
        }
    }
}

extension CanvasEditor {
    /// A new type titled `name`, put down beside `owner` as `/move-near` puts a shape beside another
    /// (`Surroundings.near`), on a side in the clear part of the view where one is free (`PutBeside`), with the starter schema and no words, and `owner` made an instance of
    /// it: one step, "New Type", which stays open while the new note is edited, as a placed note's
    /// does. For an owner that is an arrow (a kind that relates) it is a relationship type, with no ends,
    /// in the step "New Relationship Type", and it replaces the relationship type the arrow had. Nil, with nothing changed, when nothing could be put down: `owner` is not on the board
    /// shown, no kind can be a type or has a tool to place it, `owner` has no box, or the board or
    /// the container it lands in is read-only (the core refuses it, and it shakes).
    @discardableResult
    public func newType(named name: String, besides owner: ShapeID) -> ShapeID? { newType(named: name, besides: [owner]) }

    /// The same beside several shapes, which the new type is made for together: put down beside the box around them
    /// (`Surroundings.near` a box that is no shape of the board, keeping clear of each one's frame), every owner that may
    /// take it made one of it (`giveType`: the role partition and `admits` decide), in the one step, "New Type", which stays
    /// open while the new note is edited. It is a relationship type when every owner is an arrow of a kind that relates,
    /// and a plain type otherwise (an arrow among other shapes takes none). An owner not on the board shown is left out,
    /// and one with nothing drawn adds nothing to the box; nil, with nothing changed, when none is left or none has a box,
    /// and as for one owner. One owner is the case of one: beside that shape itself.
    @discardableResult
    public func newType(named name: String, besides owners: [ShapeID]) -> ShapeID? {
        newType(named: name, besides: owners, givingType: true, editing: true)
    }

    /// The same, with what goes with it said: `givingType` false makes no owner an instance of it (what names the new type is
    /// the caller's: an endpoint's body), and `editing` false puts it down settled, nothing selected and nothing edited, so the
    /// keyboard stays where it is (the core's `Placement.settled()`). Either way one step, "New Type", into which the caller
    /// may write what names it, in a group of its own of that name.
    ///
    /// Put down settled where no clear spot in view is left (the view full), it lands at the clear spot (beside what it is kept
    /// with, beside each owner, anywhere) whose least pan into view takes none of what the person works with out of view (`keeping`,
    /// else the owners, the owners, and what is joined to `keeping`), the nearest of those, and the view pans the least to show it,
    /// all of `keeping` (else the owners) in view as well where it all fits, else its first, else the anchor of a card shown (the
    /// row it was made from), so the card stays up (Selection's `revealIfOffscreen(_:keepingFirstOf:)`).
    @discardableResult
    public func newType(named name: String, besides owners: [ShapeID], givingType: Bool, editing: Bool, keeping: [ShapeID] = []) -> ShapeID? {
        var seen = Set<ShapeID>()
        let owners = owners.filter { seen.insert($0).inserted && file.board(containing: $0) == board }
        guard !owners.isEmpty, let kind = newTypeKind(for: owners), let base = registry.placement(for: kind) else { return nil }
        // Told which shape it made by the transform each record goes through.
        final class Made { var id: ShapeID? }
        let made = Made()
        let marks = givingType && owners.allSatisfy(ownerRelates) && registry.canBeRelationshipType(kind)
        var placement = (editing ? base : base.settled()).setting(TitleProperty.self, to: name)
            .setting(TypeSchemaProperty.self, to: SchemaText(TypeSchemaProperty.starter))
        if marks { placement = placement.setting(RelationshipProperty.self, to: true) }
        placement = placement.mapping { record in made.id = record.id; return record }
        guard let surroundings = Surroundings(on: board, moving: placement.size, in: self) else { return nil }
        let landing: Landing?
        // Put down for the person: on a side of them in the clear part of the view, where one is free.
        let put = PutBeside.inView(of: self)
        if owners.count == 1 {
            landing = surroundings.near(owners[0], put: put)
        } else {
            // Beside the box around them all, as a shape that is not on the board yet is landed beside, clear of every owner.
            let shapes = surroundings.reading.shapes
            landing = shapes.bounds(of: owners).flatMap { box in
                surroundings.near(box, avoiding: owners.compactMap { shapes.geometry(of: $0)?.bounds }, put: put)
            }
        }
        guard var landing else { return nil }
        // No side of them in view: the nearest clear spot in view instead, so the type made is seen (one edited is brought
        // into view as it's selected, wherever it lands).
        let kept = keeping.isEmpty ? owners : keeping
        // Brought into view keeping what it was made for: all of it where it fits with it (an API and the types its line names),
        // else the first (the API), else the row a card hangs from (made from a row's card, the card stays up, the caret in it).
        let alternatives = [shapeContext.bounds(of: kept), shapeContext.bounds(of: Array(kept.prefix(1))), card?.anchor].compactMap { $0 }
        if !editing, !surroundings.shows(landing.rect, put: put) {
            let anywhere = surroundings.anywhere(put: put)
            if surroundings.shows(anywhere.rect, put: put) {
                landing = anywhere
            } else if let view = surroundings.reading.view {
                landing = fallbackSpot(among: landing, surroundings, near: card?.anchor ?? shapeContext.bounds(of: kept) ?? view,
                                       keeping: kept, owners: owners, alternatives: alternatives)
            }
        }
        let inView = editing || surroundings.shows(landing.rect, put: put)
        let newID = undoHistory.group(marks ? TypesStyle.newRelationshipType : TypesStyle.newType) { () -> ShapeID? in
            place(placement, in: landing.rect)
            guard let id = made.id, document[id] != nil else { return nil }
            if givingType { giveType(id, to: owners) }
            return id
        }
        // Nowhere clear in view: brought into view by the least pan, what it was made for kept in view as above.
        if let id = newID, !inView { revealIfOffscreen([id], keepingFirstOf: alternatives) }
        return newID
    }

    /// Where a new type goes when the view is full (no clear spot in it): of the clear spots beside what the person is at (`at`:
    /// the row a card hangs from, else what it is kept beside, else the view) on each side, beside each owner on each side, beside
    /// the box `near` found and anywhere, the one whose least pan into view (`revealPan`, keeping the first of `alternatives` that
    /// fits, as the reveal will) takes none of what the person works with out of view (the shapes `keeping`, the owners and what
    /// is joined to what it is kept beside, wholly in the clear view now: U11's rule for a put, UX walk 5 apis-5-1, a second new
    /// type made from a line panned the first, which the same line names, out of view), a pan that takes the first of `keeping`
    /// (the API the card hangs from) out of view ranking under every one that keeps it; then the one that takes fewest; then the
    /// nearest `at`, the earlier on a tie.
    private func fallbackSpot(among found: Landing, _ surroundings: Surroundings, near at: CGRect, keeping: [ShapeID], owners: [ShapeID],
                              alternatives: [CGRect]) -> Landing {
        var spots = [found, surroundings.anywhere()]
        func add(_ spot: Landing?) { if let spot, !spots.contains(spot) { spots.append(spot) } }
        // Beside a shape, never beside a part of one (the row a card hangs from): the gap is the shape's, so a spot above a row is
        // above its shape's title row, not flush on its edge (U14-E1). `at` itself weighs only as the nearness.
        let held = card != nil || keeping.count == 1 ? keeping.first : nil
        let visible = surroundings.reading.view
        var besides: [ShapeID] = held.map { [$0] } ?? []
        // Owners out of view are left out: a spot beside one is out of view, and its pan takes more than the ones in view do.
        for owner in owners where !besides.contains(owner) {
            if let bounds = shapeContext.bounds(of: [owner]), visible.map(bounds.intersects) ?? true { besides.append(owner) }
        }
        if held == nil { for side in PlacingStyle.sides { add(surroundings.near(at, avoiding: [at], sides: [side])) } }
        for beside in besides { for side in PlacingStyle.sides { add(surroundings.near(beside, sides: [side])) } }
        // What the person works with, each shape once: the shapes `keeping`, the owners, and what is joined to what it is kept with.
        var working = surroundings.joinedInView(to: keeping)
        for id in keeping + owners {
            if let bounds = shapeContext.bounds(of: [id]), !working.contains(bounds) { working.append(bounds) }
        }
        // What it is kept beside first (the API, the card's shape) weighs more than all the rest: a spot whose pan takes it out of
        // view ranks under every one that keeps it.
        let first = shapeContext.bounds(of: Array(keeping.prefix(1)))
        func lost(_ spot: Landing) -> (first: Bool, count: Int) {
            guard let count = revealTakesAway(working, bringing: spot.rect, keepingFirstOf: alternatives) else { return (true, working.count + 1) }
            let lostFirst = first.flatMap { revealTakesAway([$0], bringing: spot.rect, keepingFirstOf: alternatives) }.map { $0 > 0 } ?? false
            return (lostFirst, count)
        }
        func away(_ rect: CGRect) -> CGFloat { let x = rect.midX - at.midX, y = rect.midY - at.midY; return (x * x + y * y).squareRoot() }
        let ranked = spots.map { (spot: $0, lost: lost($0), away: away($0.rect)) }
        return ranked.min { a, b in
            if a.lost.first != b.lost.first { return !a.lost.first }
            return a.lost.count != b.lost.count ? a.lost.count < b.lost.count : a.away < b.away - 0.5
        }?.spot ?? found
    }

    /// Whether the owner is an arrow of a kind that relates, whose new type is a relationship type.
    func ownerRelates(_ owner: ShapeID) -> Bool { document[owner].map { registry.relates($0.kind) } ?? false }

    /// The kind a new type beside `owners` is: the kind of the first that can be a type; for owners that all relate, the first
    /// kind that can hold the mark as well; else the first that can be a type (with no owners, the kind any new type is: a
    /// note, as shipped). What a plugin that makes types names the kind by, never a literal (the kit's OpenAPI paste).
    public func newTypeKind(for owners: [ShapeID] = []) -> ShapeKind? {
        func usable(_ kind: ShapeKind) -> Bool { registry.canBeType(kind) && registry.placement(for: kind) != nil }
        if let kind = owners.lazy.compactMap({ self.document[$0]?.kind }).first(where: { registry.canBeType($0) }) { return kind }
        if !owners.isEmpty, owners.allSatisfy(ownerRelates), let kind = registry.kinds.first(where: { usable($0) && registry.canBeRelationshipType($0) }) { return kind }
        return registry.kinds.first(where: usable)
    }
}

/// `/is-a`: typed on a line of a shape's words, or for the shapes selected, lists `Type` (while the shape can be one and
/// isn't), `Relationship Type` (while it can be one and isn't) and the types it may be (`editor.typeChoices(for:)`: of the
/// kinds that can be types, across the file, never the shape itself, a type it is already, one that is it in turn, or a pill; an
/// arrow is offered relationship types, any other shape plain types), and a pick runs at once: `Type` makes the
/// shape one ("Make Type"), `Relationship Type` one that relates ("Make Relationship Type"), a type adds it to the
/// shape's types ("Add Type"; an arrow's relationship type is replaced). On any kind that holds `is`: a note, an
/// arrow in its label, a subboard in its description, a frame in the command bar alone. On several shapes it is `.together` (`SlashCommand.together`): the rows are Is a ▸'s for a selection less what
/// every shape is already (`TypeChoices.rows(for:in:)`, a type some would take saying how many: `2 of 3`), `Type` and
/// `Relationship Type` only while every shape can be one and none is, `New type` while they are all arrows that relate or none
/// is, and a pick goes to the shapes that may take it, in one step.
@MainActor
func registerIsACommand(into registrar: inout PluginRegistrar) {
    registrar.forShapes(holding: IsAProperty.self) { typeable in
        typeable.slashCommands {
            SlashCommand.together("is-a", argument: TypesStyle.isAArgument,
                                  choices: { owners, editor in TypeChoices.rows(for: owners, in: editor) },
                                  otherwise: { typed, owners, editor in TypeChoices.newRow(typed: typed, owners: owners, editor: editor) },
                                  step: TypesStyle.addType) { owners, choice, editor in
                // Asked again: the line was run as it was found. An arrow that is an end of a relationship type is of nothing.
                let takers = TypeChoices.takers(among: owners, in: editor)
                switch TypeChoice(choice) {
                case .type: editor.makeTypes(takers)
                case .relationshipType: editor.makeRelationshipTypes(takers)
                case .existing(let type): editor.giveType(type, to: takers)
                case .new(let name): editor.newType(named: name, besides: takers)
                case .none: break
                }
            }
        }
    }
}
