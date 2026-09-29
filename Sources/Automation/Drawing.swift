import Canvas
import CanvasRPC
import CoreGraphics
import DrawScript
import Geometry

// Resolving a script against the board as the run starts: each statement's kind, the shape its
// title names (restated) or a new one, its attributes read by its kind's schema, its placements'
// targets; each edge's ends and attributes; each delete's shape or connections. Problems that
// don't depend on each other are all found (up to `ScriptErrors.limit`), each statement's first.

/// A shape statement, resolved.
struct ShapeItem {
    let statement: Statement
    let shape: ShapeStatement
    let kind: ShapeKind
    /// Its title, folded; nil for an untitled shape.
    let title: String?
    /// The board shape it restates; nil for a new one.
    let existing: AnyShapeRecord?
    /// Its new title, folded (`title: "New"`), when it renames the shape.
    var rename: String?
    /// The shape as the statement leaves it, before it's placed: what the kind's tool places, or
    /// the shape restated, with its title and attributes set.
    var record: AnyShapeRecord
    /// How big it is, once drawn: as written, else what setting its attributes left it (a schema
    /// card as tall as its schema), else as it is, or as its tool places it.
    var size: CGSize
    /// What each placement's targets are, placement by placement.
    var targets: [[Found]] = []
    /// Its place among the layout's free boxes, if it moves.
    var free: Int?
    /// Where it goes: solved, or where it stays.
    var placed: CGRect?
    /// What it was pushed past, by name: only what it was kept clear of itself, not what a shape
    /// it moved along with was.
    var pushedPast: [String] = []
    /// A board shape whose title is nearly this new one's.
    var nearMiss: String?
    /// The board shapes it sits on as zones where it's placed, in paint order: each wholly holds
    /// the shape where it is now, a shape it's placed against, the shape where it lands and others
    /// too, or the view it's placed against or drawn in, and it paints above them.
    var zones: [ShapeID] = []

    /// A box a placement names, found.
    enum Found {
        /// A shape the script draws or restates: `items[index]`.
        case item(Int)
        /// A board shape the script doesn't mention.
        case shape(AnyShapeRecord)
        case board
        case view
    }

    /// Whether the layout places it: it's new, or restated with placements.
    var moves: Bool { existing == nil || !shape.clauses.isEmpty }
}

/// An edge statement, resolved.
struct EdgeItem {
    let statement: Statement
    let edge: EdgeStatement
    let from: ShapeID
    let to: ShapeID
    /// The titles its ends are named by.
    let fromTitle: String
    let toTitle: String
    let attributes: [String: String]
}

/// A delete statement, resolved: the shape it removes and every connection with an end on it (those
/// bound at both ends, and those with the other end free), or the connections `delete edge` removes.
struct DeleteItem {
    let statement: Statement
    let shape: AnyShapeRecord?
    let connections: [BoardConnection]
    /// Connections with one end on the shape and the other free: they join no two shapes, so
    /// nothing names their ends.
    var loose: [AnyShapeRecord] = []
    /// The boards the shape owns (a subboard's), the one under it and every board under that, and
    /// the shapes on them: all deleted with it.
    var boards = 0
    var boardShapes = 0
}

/// A connection on the board: which shapes it joins.
struct BoardConnection {
    let record: AnyShapeRecord
    let from: ShapeID
    let to: ShapeID
}

@MainActor
struct Drawing {
    let editor: CanvasEditor
    let registry: Registry
    let script: Script
    let naming: DrawNaming?
    let edging: DrawEdging?
    /// What edges are, if something makes them.
    let edgeKind: ShapeKind?
    /// The window's part of the board; nil when the board isn't in one.
    let view: CGRect?

    private(set) var vocabularies: [ShapeKind: KindVocabulary] = [:]
    /// The board's shapes by name as the run starts; empty without DrawNames.
    private(set) var names = BoardNames()
    /// The board's connections as the run starts; empty without DrawEdges.
    private(set) var connections: [BoardConnection] = []
    /// The board's connections that don't join two shapes (an end left free), by each shape they
    /// name, as the run starts: a delete takes them with the shape.
    private var looseConnections: [ShapeID: [AnyShapeRecord]] = [:]

    private(set) var deletes: [DeleteItem] = []
    /// The shapes `delete "X"` removes (their connections aside).
    private(set) var deletedShapes: Set<ShapeID> = []
    /// Everything the deletes remove.
    private(set) var deleted: Set<ShapeID> = []
    var items: [ShapeItem] = []
    /// Each shape statement's title, folded, and its item.
    private(set) var itemByTitle: [String: Int] = [:]
    private(set) var edges: [EdgeItem] = []
    /// Each `delete edge`'s ends, for telling one written twice.
    private var edgeDeletes: [(from: ShapeID, to: ShapeID, eitherWay: Bool, line: Int)] = []

    /// Titles of statements that couldn't be resolved: whatever names them is left unresolved,
    /// without a second error.
    private var unresolved: Set<String> = []
    /// What placing found to say: pushes, a shape resized over another.
    var notes: [DrawWarning] = []
    private var errors: [AutomationError] = []

    init(_ script: Script, editor: CanvasEditor) throws(AutomationError) {
        let registry = editor.registry
        self.editor = editor
        self.registry = registry
        self.script = script
        naming = registry.drawNaming
        edging = registry.drawEdging
        edgeKind = registry.drawEdging.flatMap { $0.kind(registry) }
        // Where the view is headed, if it's gliding (a --reveal a moment ago): the view the drawing
        // is seen in once it settles. The part of it the host leaves clear (below the path's pill
        // over a subboard), as every fit is.
        let clear = editor.unobscuredViewport
        view = clear.isEmpty ? nil : editor.cameraTarget.toWorld(clear)
        if let naming, script.mentionsTitles { names = BoardNames(editor.document, naming: naming, registry: registry) }
        // What connects to what, for the deletes (edges read the transaction's document).
        let deletes = script.statements.contains { if case .delete = $0.body { true } else { false } }
        if deletes, let edging, let edgeKind {
            connections = Self.connections(in: editor.document, kind: edgeKind, edging: edging, registry: registry)
            looseConnections = Self.looseConnections(in: editor.shapeContext, kind: edgeKind, edging: edging)
        }

        for statement in script.statements {
            guard case .delete(let delete) = statement.body else { continue }
            do throws(AutomationError) { try resolve(delete, statement) } catch { keep(error) }
        }
        for statement in script.statements {
            guard case .shape(let shape) = statement.body else { continue }
            do throws(AutomationError) {
                try find(shape, statement)
            } catch {
                keep(error)
                if let title = shape.title { unresolved.insert(fold(title) ?? title) }
            }
        }
        for index in items.indices {
            do throws(AutomationError) { try complete(index) } catch { keep(error) }
        }
        for statement in script.statements {
            guard case .edge(let edge) = statement.body else { continue }
            do throws(AutomationError) { try resolve(edge, statement) } catch { keep(error) }
        }
        for style in script.styles {
            do throws(AutomationError) { try check(style) } catch { keep(error) }
        }
        guard errors.isEmpty else { throw collected(errors) }
    }

    /// Keeps a statement's error with the others (but one that only follows from another's).
    private mutating func keep(_ error: AutomationError) {
        if error.reason != Self.skipped { errors.append(error) }
    }

    /// What a statement that depends on one that couldn't be resolved throws: no error of its own.
    private static let skipped = "skipped"
    private func skip() -> AutomationError { AutomationError("", reason: Self.skipped) }

    /// Whether the run, placed, changes or deletes this shape (so an edit under way should end
    /// first): a shape restated as it is isn't changed.
    func changes(_ id: ShapeID) -> Bool {
        deleted.contains(id) || items.contains { $0.existing?.id == id && $0.record != $0.existing }
    }

    // MARK: Names

    func fold(_ title: String) -> String? { naming?.fold(title) }

    /// A title as written, folded, or why it can't be one.
    func folded(_ written: String, _ statement: Statement) throws(AutomationError) -> String {
        guard naming != nil else {
            throw AutomationError(statement, .noNames, "titles name shapes, and nothing here gives shapes names",
                                  hint: "leave titles out: without a plugin that names shapes, no shape can be named or found by name")
        }
        guard let folded = fold(written) else {
            throw AutomationError(statement, .syntax, "a title can't be blank", hint: "leave it out for an untitled shape")
        }
        return folded
    }

    /// The board shapes called this, but those the script deletes.
    func boardShapes(called title: String) -> [ShapeID] {
        (names.ids[title] ?? []).filter { !deletedShapes.contains($0) }
    }

    /// Whether a board shape the script doesn't delete is called this.
    func isOnBoard(_ title: String) -> Bool {
        names.ids[title]?.contains { !deletedShapes.contains($0) } == true
    }

    /// The board shape called this, if one is, or why not: none, or several.
    func boardShape(called title: String, _ statement: Statement) throws(AutomationError) -> AnyShapeRecord? {
        let found = boardShapes(called: title)
        guard found.count < 2 else {
            let each = found.compactMap { editor.document[$0] }.map { "\(indefinite($0.kind)) at \(point(middle(of: $0)))" }
            throw AutomationError(statement, .ambiguousTitle, "the board has \(found.count) shapes called \(quoted(title)): \(listed(each))",
                                  hint: "titles name shapes here, so each needs its own: ask the user to rename one")
        }
        return found.first.flatMap { editor.document[$0] }
    }

    /// A shape a statement names by title: one the script draws or restates, else one on the
    /// board; nil if it's one a statement that couldn't be resolved draws. `mine` is the title of
    /// the statement's own shape, never what it meant (placed against itself, it's `circular`).
    func find(_ title: String, _ statement: Statement, for what: String, mine: String? = nil) throws(AutomationError) -> ShapeItem.Found? {
        if let index = itemByTitle[title] { return .item(index) }
        if unresolved.contains(title) { return nil }
        if let record = try boardShape(called: title, statement) { return .shape(record) }
        if names.ids[title] != nil {
            throw AutomationError(statement, .unknownTitle, "\(what) \(quoted(title)), which this script deletes",
                                  hint: "draw \(quoted(title)) again after deleting it, or leave it out")
        }
        let drawn = items.compactMap(\.title)
        let guesses = Suggestions.closest(to: title, among: (names.ordered.filter(isOnBoard) + drawn).filter { $0 != mine })
        throw AutomationError(statement, .unknownTitle, "there's no shape called \(quoted(title))",
                              hint: guesses.isEmpty ? "a title is one the board has as the script starts, or one the script draws"
                                  : "did you mean \(listed(guesses.map(quoted), or: true))?")
    }

    // MARK: Deletes

    private mutating func resolve(_ delete: DeleteStatement, _ statement: Statement) throws(AutomationError) {
        switch delete {
        case .shape(let written):
            let title = try folded(written, statement)
            guard let record = try boardShape(called: title, statement) else {
                if deletes.contains(where: { $0.shape.flatMap(names.name(of:)) == title }) {
                    throw AutomationError(statement, .duplicate, "\(quoted(title)) is deleted twice", hint: "delete it once")
                }
                let guesses = Suggestions.closest(to: title, among: names.ordered)
                throw AutomationError(statement, .unknownTitle, "there's no shape called \(quoted(title)) to delete",
                                      hint: guesses.isEmpty ? nil : "did you mean \(listed(guesses.map(quoted), or: true))?")
            }
            try writable(record, statement, quoted(title), so: "it can't be deleted")
            // The board it owns goes with it, and every board under that (a transaction takes them):
            // not at all if one of them holds a read-only shape, as the Finder won't trash a folder
            // holding a locked file.
            let file = editor.file, boards = file.subtree(ownedBy: [record.id])
            if boards.contains(where: { file[$0].shapes.contains(where: registry.isReadOnly) }) {
                throw AutomationError(statement, .readOnly, "\(quoted(title)) holds a read-only shape (locked, say) on its board, so it can't be deleted",
                                      hint: "leave it out of the script, or ask the user to unlock what's on its board")
            }
            let attached = connections.filter { ($0.from == record.id || $0.to == record.id) && !deleted.contains($0.record.id) }
            let loose = (looseConnections[record.id] ?? []).filter { !deleted.contains($0.id) }
            for connection in attached.map(\.record) + loose {
                try writable(connection, statement, "one of \(quoted(title))'s connections", so: "\(quoted(title)) can't be deleted with it")
            }
            deletes.append(DeleteItem(statement: statement, shape: record, connections: attached, loose: loose, boards: boards.count,
                                      boardShapes: boards.reduce(0) { $0 + file[$1].shapes.count }))
            deletedShapes.insert(record.id)
            deleted.insert(record.id)
            deleted.formUnion(attached.map(\.record.id))
            deleted.formUnion(loose.map(\.id))
        case .edges(let fromWritten, let toWritten, let eitherWay):
            let written = "\(quoted(fromWritten)) \(eitherWay ? EdgeArrow.both.rawValue : EdgeArrow.forward.rawValue) \(quoted(toWritten))"
            guard edgeKind != nil else { throw noEdges(statement) }
            let from = try folded(fromWritten, statement), to = try folded(toWritten, statement)
            // An end a `delete` above deletes is still that shape: the delete takes its edges, so
            // this asks for what's done already, which is fine, as it is written the other way round.
            func end(_ title: String) throws(AutomationError) -> AnyShapeRecord? {
                try boardShape(called: title, statement)
                    ?? deletes.lazy.compactMap(\.shape).first { names.name(of: $0) == title }
            }
            func none(_ missing: String) -> AutomationError {
                let drawn = script.statements.contains { other in
                    if case .shape(let shape) = other.body, let title = shape.title { return fold(title) == missing } else { return false }
                }
                if names.ids[missing] != nil || drawn { return nothingToDelete(statement, written) }
                return AutomationError(statement, .unknownTitle, "there's no shape called \(quoted(missing))",
                                       hint: "delete edge takes shapes on the board as the script starts")
            }
            guard let a = try end(from) else { throw none(from) }
            guard let b = try end(to) else { throw none(to) }
            let pairs = eitherWay ? [(a.id, b.id), (b.id, a.id)] : [(a.id, b.id)]
            if let earlier = edgeDeletes.first(where: { other in pairs.contains { $0 == (other.from, other.to) || other.eitherWay && $0 == (other.to, other.from) } }) {
                throw AutomationError(statement, .duplicate, "delete edge \(written) is written twice, here and on line \(earlier.line)", hint: "keep one")
            }
            edgeDeletes.append((a.id, b.id, eitherWay, statement.line))
            let found = connections.filter { ($0.from == a.id && $0.to == b.id) || (eitherWay && $0.from == b.id && $0.to == a.id) }
            guard !found.isEmpty else { throw nothingToDelete(statement, written) }
            for connection in found {
                try writable(connection.record, statement, "one of the connections delete edge \(written) removes", so: "it can't be deleted")
            }
            let fresh = found.filter { !deleted.contains($0.record.id) }
            deletes.append(DeleteItem(statement: statement, shape: nil, connections: fresh))
            deleted.formUnion(fresh.map(\.record.id))
        }
    }

    private func nothingToDelete(_ statement: Statement, _ written: String) -> AutomationError {
        AutomationError(statement, .nothingToDelete, "nothing is drawn from one to the other of \(written)",
                        hint: "delete edge removes the connections drawn from the first to the second; <-> takes them either way")
    }

    func noEdges(_ statement: Statement) -> AutomationError {
        AutomationError(statement, .noEdges, "nothing here draws edges", hint: "leave the edges out: this app has no plugin that connects shapes")
    }

    /// Refuses to delete a read-only shape (a locked one): `"East" is read-only (locked, say), so it
    /// can't be deleted`.
    private func writable(_ record: AnyShapeRecord, _ statement: Statement, _ subject: String, so consequence: String) throws(AutomationError) {
        guard registry.isReadOnly(record) else { return }
        throw AutomationError(statement, .readOnly, "\(subject) is read-only (locked, say), so \(consequence)",
                              hint: "leave it out of the script, or ask the user to unlock it")
    }

    // MARK: Shapes

    /// A shape statement's kind, and the shape it's about: pass one, which every title needs.
    private mutating func find(_ shape: ShapeStatement, _ statement: Statement) throws(AutomationError) {
        let kind = try drawable(shape.word, statement)
        let vocabulary = vocabulary(of: kind)
        let title = try shape.title.map { written throws(AutomationError) in try self.folded(written, statement) }
        if let title, let earlier = itemByTitle[title] {
            throw AutomationError(statement, .duplicate, "\(quoted(title)) is written twice, here and on line \(items[earlier].statement.line)",
                                  hint: "say everything about one shape in one statement")
        }
        var existing: AnyShapeRecord?
        var nearMiss: String?
        if let title {
            existing = try boardShape(called: title, statement)
            if let existing, existing.kind != kind {
                throw AutomationError(statement, .wrongKind, "\(quoted(title)) is \(indefinite(existing.kind)) on the board, not \(indefinite(kind))",
                                      hint: "to change its kind, delete \(quoted(title)) and draw it again in the same script")
            }
            if existing == nil {
                guard vocabulary.namingProperty != nil else {
                    let why = naming?.isDerived(kind, registry) == true ? "\(indefinite(kind))'s title is worked out from what it is" : "\(indefinite(kind)) has no title"
                    throw AutomationError(statement, .untitlable, "\(why), so it can't be called \(quoted(title))",
                                          hint: "leave the title out: \(shape.word) and where it goes")
                }
                nearMiss = names.nearMiss(of: title) { $0 != title && isOnBoard($0) }
            }
        }
        let placement = registry.placement(for: kind)!
        let base = existing ?? placement.shape(at: .zero)
        let size = shape.size ?? existing?.box?.size ?? placement.size
        if let title { itemByTitle[title] = items.count }
        items.append(ShapeItem(statement: statement, shape: shape, kind: kind, title: title, existing: existing, record: base, size: size,
                               nearMiss: nearMiss))
    }

    /// The kind a statement's first word names, if its tool places it: a kind drawn by a gesture
    /// (an edge) or only by plugins isn't drawn here.
    private func drawable(_ word: String, _ statement: Statement) throws(AutomationError) -> ShapeKind {
        let kind = ShapeKind(rawValue: word)
        let drawable = drawableKinds
        guard registry.definition(for: kind) != nil else {
            let guess = Suggestions.closest(to: word, among: drawable, limit: 1).first
            var hint = (guess.map { "did you mean \($0)? " } ?? "") + "the kinds drawn here: \(drawable.joined(separator: ", "))"
            if Self.connectionHabits.contains(word), edgeKind != nil {
                hint = "to join two shapes, write edge \"A\" -> \"B\"; " + hint
            } else if Self.habits.contains(word) {
                hint += "; a statement starts with its kind, as in \(guess ?? "<kind>") \"A\""
            }
            throw AutomationError(statement, .unknownKind, "there's no kind of shape called \(word)", hint: hint)
        }
        guard registry.placement(for: kind) != nil else {
            let hint = kind == edgeKind ? "to join two shapes, write edge \"A\" -> \"B\""
                : "the kinds drawn here: \(drawable.joined(separator: ", "))"
            throw AutomationError(statement, .notPlaceable, "\(indefinite(word)) isn't drawn on its own: \(unplaceable(kind, in: registry))", hint: hint)
        }
        return kind
    }

    /// Words other drawing languages start a shape with.
    private static let habits: Set<String> = ["node", "note", "box", "shape"]
    /// Words other drawing languages start a connection with.
    private static let connectionHabits: Set<String> = ["link", "connect"]

    /// Keys other languages say where a shape is with, and how big: there are no coordinates here.
    private static let coordinateKeys: Set<String> = ["x", "y", "at", "position", "pos"]
    private static let sizeKeys: Set<String> = ["width", "height"]

    /// The kinds a script can draw: those a tool places (but one named like a word of the
    /// language), by name.
    var drawableKinds: [String] {
        registry.kinds.filter { registry.placement(for: $0) != nil && Keyword(rawValue: $0.rawValue) == nil }.map(\.rawValue).sorted()
    }

    mutating func vocabulary(of kind: ShapeKind) -> KindVocabulary {
        if let known = vocabularies[kind] { return known }
        let vocabulary = KindVocabulary(kind, in: registry)
        vocabularies[kind] = vocabulary
        return vocabulary
    }

    /// Pass two, once every title is known: the rename, the attributes (and the styles that give
    /// them), and the placements' targets.
    private mutating func complete(_ index: Int) throws(AutomationError) {
        let item = items[index], statement = item.statement, shape = item.shape
        let vocabulary = vocabulary(of: item.kind)
        let subject = subject(of: item)
        var settings: JSONObject = [:]

        // Its title, on a new shape; a new one, on a shape restated.
        if let written = shape.newTitle {
            guard let existing = item.existing else {
                throw AutomationError(statement, .unsupported, "\(subject) is new, and \(LanguageKey.title.rawValue): renames a shape",
                                      hint: "the title goes after the kind, in quotes: \(shape.word) \(quoted(written))")
            }
            let new = try folded(written, statement)
            guard let property = vocabulary.namingProperty else {
                throw AutomationError(statement, .untitlable, "\(indefinite(item.kind)) can't be given a title, so \(subject) can't be renamed",
                                      hint: "leave \(LanguageKey.title.rawValue): out")
            }
            if new != item.title {
                try claim(new, for: existing, statement, subject: subject)
                items[index].rename = new
                settings[property] = .string(new)
            }
        } else if item.existing == nil, let title = item.title, let property = vocabulary.namingProperty {
            settings[property] = .string(title)
        }

        // Its attributes, its own and its styles'.
        for attribute in shape.attributes {
            let key = attribute.key
            guard vocabulary.properties[key] != nil else {
                if attribute.fromStyle != nil { continue }
                if Self.coordinateKeys.contains(key) {
                    throw AutomationError(statement, .unsupported, "\(key): would say where \(subject) is, and there are no coordinates here",
                                          hint: "say where it goes with a placement: right of \"A\", below board, inside view top-left")
                }
                if Self.sizeKeys.contains(key) {
                    throw AutomationError(statement, .unsupported, "\(key): would say how big \(subject) is, and here that's \(LanguageKey.size.rawValue):",
                                          hint: "\(LanguageKey.size.rawValue): <width>x<height>, as \(LanguageKey.size.rawValue): 300x200")
                }
                throw unknownAttribute(key, of: item, vocabulary)
            }
            if key == vocabulary.namingProperty {
                throw AutomationError(statement, .unsupported, "\(key): is what \(subject) is called",
                                      hint: item.existing == nil ? "the title goes after the kind, in quotes: \(shape.word) \"…\""
                                          : "rename it with \(LanguageKey.title.rawValue): \"…\"")
            }
            if vocabulary.coordinates.contains(key) {
                throw AutomationError(statement, .unsupported, "\(key): says where \(subject) is, and there are no coordinates here",
                                      hint: "say where it goes with a placement, and how big with \(LanguageKey.size.rawValue):")
            }
            do throws(ValueRefusal) {
                let value = try vocabulary.value(of: attribute)
                try fits(value, key, item.kind, vocabulary)
                settings[key] = value
            } catch {
                let from = attribute.fromStyle.map { " (from style \($0))" } ?? ""
                throw AutomationError(statement, .invalidValue, "\(subject): \(error.message)\(from)", hint: error.hint)
            }
        }
        for name in shape.styles {
            guard let style = script.styles.first(where: { $0.name == name }) else { continue }
            let gives = style.attributes.contains { LanguageKey(rawValue: $0.key) != nil || vocabulary.isAttribute($0.key) }
            if !gives {
                throw AutomationError(statement, .unknownAttribute, "\(subject) is \(indefinite(item.kind)), and style \(name) gives it nothing it takes",
                                      hint: "\(indefinite(item.kind)) takes \(vocabulary.everything.joined(separator: ", "))")
            }
        }
        // What a restated shape already has isn't a change, though it's written without what reading
        // it makes afresh (the id of an item in a list): a script run again changes nothing.
        if let existing = item.existing {
            settings = settings.filter { key, value in !Self.alreadyHas(existing, key, value, in: registry) }
        }
        // Every shape a script makes is built by the registry, as the kind's schema reads it.
        if !settings.isEmpty || item.existing == nil { items[index].record = try record(item.record, setting: settings, item, vocabulary) }
        try references(of: items[index].record, item)
        // A size the kind works out from what was set (a schema card's height, from its schema) is
        // the one it's placed at, unless the statement says one.
        if shape.size == nil, let before = item.record.box?.size, let after = items[index].record.box?.size, after != before {
            items[index].size = after
        }

        if let title = item.title, let existing = item.existing, items[index].rename == nil, let box = existing.box {
            var sized = items[index].record
            sized.box = CGRect(origin: box.origin, size: items[index].size)
            if vocabulary.namingProperty == nil {
                // A title only worked out (a schema card's, from its schema) is renamed by changing
                // what it's worked out from: said as a rename, and held to what a rename is.
                if let now = try renamed(sized, title, item) {
                    try claim(now, for: existing, statement, subject: subject)
                    items[index].rename = now
                }
            } else {
                // One a kind works out for the shapes nobody named (from its size, say) mustn't
                // change under it.
                try keepsName(sized, title, item)
            }
        }

        // Where it goes: what each placement names.
        var targets: [[ShapeItem.Found]] = []
        for clause in shape.clauses {
            var found: [ShapeItem.Found] = []
            for target in clause.targets {
                switch target.box {
                case .title(let written):
                    let title = try folded(written, statement)
                    if title == item.title {
                        throw AutomationError(statement, .circular, "\(subject) is placed against itself (\(clause.written))",
                                              hint: "place it against another shape")
                    }
                    guard let target = try find(title, statement, for: "\(subject) is placed against", mine: item.title) else { throw skip() }
                    found.append(target)
                case .board:
                    found.append(.board)
                case .view:
                    guard view != nil else {
                        throw AutomationError(statement, .noView, "\(subject) is \(clause.written), and the board isn't in a window",
                                              hint: "place it against a shape, or leave it unplaced to draw it where the view would be")
                    }
                    found.append(.view)
                }
            }
            targets.append(found)
        }
        items[index].targets = targets
    }

    /// The shape with its attributes set, or which one it can't take.
    private func record(_ base: AnyShapeRecord, setting settings: JSONObject, _ item: ShapeItem,
                        _ vocabulary: KindVocabulary) throws(AutomationError) -> AnyShapeRecord {
        do throws(ShapePropertiesError) {
            return try registry.shape(base, setting: settings)
        } catch {
            // Which one: each alone.
            for key in settings.keys.sorted() {
                do throws(ShapePropertiesError) {
                    _ = try registry.shape(base, setting: [key: settings[key]!])
                } catch {
                    let written = item.shape.attributes.first { $0.key == key }?.value.written ?? "\(LanguageKey.title.rawValue)"
                    throw AutomationError(item.statement, .invalidValue, "\(subject(of: item)): \(key): \(written) can't be read: \(error)",
                                          hint: "\(key): takes \(vocabulary.compactType(of: key))")
                }
            }
            throw AutomationError(item.statement, .invalidValue, "\(subject(of: item)) can't have those attributes together: \(error)")
        }
    }

    /// Refuses JSON (an object or a list) that its property's schema says has a member it hasn't, or
    /// a value of the wrong type, anywhere inside: reading it would drop the member, or the whole
    /// value, without a word. Its bounds aren't refused: a shape past one is drawn, and warned about.
    private func fits(_ value: JSONValue, _ key: String, _ kind: ShapeKind, _ vocabulary: KindVocabulary) throws(ValueRefusal) {
        switch value {
        case .object, .array: break
        default: return
        }
        let violations = registry.schemaViolations(of: [key: value], kind: kind).filter { violation in
            guard violation.path.first == .member(key) else { return false }
            switch violation.keyword {
            case "additionalProperties": return true
            // Null inside reads as the member's default, as it does for a whole property.
            case "type": return Self.value(at: violation.path.dropFirst(), in: value) != .null
            default: return false
            }
        }
        guard let violation = violations.first else { return }
        let takes = "\(key): takes \(vocabulary.compactType(of: key))"
        guard violation.keyword == "additionalProperties", case .member(let member)? = violation.path.last else {
            var message = violation.message
            if message.hasSuffix(".") { message.removeLast() }
            throw ValueRefusal(message: "\(key): \(message)", hint: takes)
        }
        let inside = violation.path.dropFirst().dropLast()
        let place = inside.isEmpty ? key : inside.map { step in
            switch step {
            case .member(let name): name
            case .element(let index): "item \(index + 1)"
            }
        }.joined(separator: " › ")
        let members = vocabulary.members(of: key, at: inside) ?? []
        let guess = Suggestions.closest(to: member, among: members, limit: 1).first
        throw ValueRefusal(message: "\(key): \(member) isn't a member of \(place)" + (members.isEmpty ? "" : " (it has \(listed(members)))"),
                           hint: (guess.map { "did you mean \($0)? " } ?? "") + takes)
    }

    /// The part of a JSON value a path leads to.
    static func value(at path: some Collection<JSONPathComponent>, in value: JSONValue) -> JSONValue? {
        var value = value
        for step in path {
            switch (step, value) {
            case let (.member(name), .object(members)):
                guard let member = members[name] else { return nil }
                value = member
            case let (.element(index), .array(elements)):
                guard elements.indices.contains(index) else { return nil }
                value = elements[index]
            default:
                return nil
            }
        }
        return value
    }

    /// Whether setting `key` to `value` would leave the shape as it is: what the value reads as is
    /// what the shape has, but for what reading it makes afresh each time (the id an item in a list
    /// written without one gets), found by reading it twice.
    static func alreadyHas(_ record: AnyShapeRecord, _ key: String, _ value: JSONValue, in registry: Registry) -> Bool {
        guard let now = record.propertiesJSON?[key],
              let once = try? registry.shape(record, setting: [key: value]).propertiesJSON?[key],
              let twice = try? registry.shape(record, setting: [key: value]).propertiesJSON?[key] else { return false }
        return matches(once, now, fresh: twice)
    }

    /// Whether `a` is `b` wherever `a` agrees with `fresh`, another reading of what `a` was read
    /// from: where the two differ, it's made afresh, and anything matches it.
    static func matches(_ a: JSONValue, _ b: JSONValue, fresh: JSONValue) -> Bool {
        if a == b { return true }
        switch (a, b, fresh) {
        case let (.object(a), .object(b), .object(fresh)):
            return Set(a.keys) == Set(b.keys) && a.allSatisfy { key, value in fresh[key].map { matches(value, b[key]!, fresh: $0) } ?? false }
        case let (.array(a), .array(b), .array(fresh)):
            return a.count == b.count && a.count == fresh.count && a.indices.allSatisfy { matches(a[$0], b[$0], fresh: fresh[$0]) }
        default:
            return a != fresh
        }
    }

    /// Refuses a shape bound to shapes that aren't on the board as the script leaves it (an arrow's
    /// ends, `ShapeReferencing`): it would stay bound to one, and nothing would ever let go of it;
    /// one on another board of the file is no better. What it only names (a mention, `ShapeNaming`)
    /// may be anywhere in the file, or gone: that's said, not refused (`namingWarnings`).
    private func references(of record: AnyShapeRecord, _ item: ShapeItem) throws(AutomationError) {
        let away = record.boundShapes(in: editor.shapeContext).filter { editor.document[$0] == nil || deleted.contains($0) }
        guard let first = away.first else { return }
        let elsewhere = editor.document[first] == nil && editor.file.record(first) != nil
        throw AutomationError(item.statement, .invalidValue,
                              "\(subject(of: item)) is bound to a shape \(elsewhere ? "on another board of the file" : "that isn't on this board")",
                              hint: "a shape can be bound only to shapes on its own board")
    }

    /// Refuses a new title for a restated shape that another shape has, or will have: one the
    /// script draws, renames to it, or the board has.
    private func claim(_ new: String, for existing: AnyShapeRecord, _ statement: Statement, subject: String) throws(AutomationError) {
        if let other = itemByTitle[new] {
            throw AutomationError(statement, .duplicate, "\(quoted(new)) is taken: line \(items[other].statement.line) is about it",
                                  hint: "give \(subject) a title of its own")
        }
        if let other = items.firstIndex(where: { $0.rename == new }) {
            throw AutomationError(statement, .duplicate, "\(quoted(new)) is written twice, here and on line \(items[other].statement.line)",
                                  hint: "give each shape a title of its own")
        }
        if boardShapes(called: new).contains(where: { $0 != existing.id }) {
            throw AutomationError(statement, .duplicate, "\(quoted(new)) is taken: the board has a shape called that",
                                  hint: "give \(subject) a title of its own")
        }
    }

    /// The title a restated shape of a kind whose titles are only worked out (a schema card's, from
    /// its schema's "title") has once changed, if that's another; refused if it has none, as a
    /// script can't take a title away.
    private func renamed(_ record: AnyShapeRecord, _ title: String, _ item: ShapeItem) throws(AutomationError) -> String? {
        guard let naming else { return nil }
        guard let now = naming.name(record, registry) else {
            throw AutomationError(item.statement, .renames, "this would leave \(quoted(title)) without a title",
                                  hint: "its title is worked out from what it is: keep what it's worked out from giving it one")
        }
        return now == title ? nil : now
    }

    /// Refuses a change that would change a restated shape's title (one its kind works out).
    func keepsName(_ record: AnyShapeRecord, _ title: String, _ item: ShapeItem) throws(AutomationError) {
        guard let naming, let now = naming.name(record, registry), now != title else { return }
        let size = item.shape.size.map { "\(LanguageKey.size.rawValue): \(Self.written($0))" }
        throw AutomationError(item.statement, .renames, "\(size ?? "this") would rename \(quoted(title)) to \(quoted(now))",
                              hint: "its title is worked out from what it is: give it one with \(LanguageKey.title.rawValue): \"…\" first, or leave it as it is")
    }

    static func written(_ size: CGSize) -> String {
        "\(KindVocabulary.number(size.width))x\(KindVocabulary.number(size.height))"
    }

    private func unknownAttribute(_ key: String, of item: ShapeItem, _ vocabulary: KindVocabulary) -> AutomationError {
        let takes = vocabulary.everything
        var hints: [String] = []
        if let guess = Suggestions.closest(to: key, among: takes, limit: 1).first { hints.append("did you mean \(guess)?") }
        hints.append("\(indefinite(item.kind)) takes \(takes.map { "\($0):" }.joined(separator: ", "))")
        let others = registry.kinds.filter { $0 != item.kind && registry.placement(for: $0) != nil }
            .filter { KindVocabulary($0, in: registry).isAttribute(key) }.map(\.rawValue).sorted()
        if !others.isEmpty { hints.append("\(key): belongs to \(listed(others))") }
        let who = item.title.map { "\(quoted($0)) is \(indefinite(item.kind)) and" } ?? "\(subject(of: item))"
        return AutomationError(item.statement, .unknownAttribute, "\(who) has \(key):, which isn't one of \(indefinite(item.kind))'s attributes",
                               hint: hints.joined(separator: "; "))
    }

    // MARK: Edges

    private mutating func resolve(_ edge: EdgeStatement, _ statement: Statement) throws(AutomationError) {
        guard let edging, edgeKind != nil else { throw noEdges(statement) }
        let written = "\(Keyword.edge.rawValue) \(edge.written)"
        let fromTitle = try folded(edge.from, statement), toTitle = try folded(edge.to, statement)
        func end(_ title: String) throws(AutomationError) -> ShapeID {
            guard let target = try find(title, statement, for: "\(written) is drawn to") else { throw skip() }
            switch target {
            case .item(let index): return items[index].record.id
            case .shape(let record): return record.id
            case .board, .view: throw skip()
            }
        }
        let from = try end(fromTitle), to = try end(toTitle)
        var attributes: [String: String] = [:]
        for attribute in edge.attributes {
            guard edging.attributes.contains(attribute.key) else {
                let takes = EdgeKey.allCases.map(\.rawValue) + edging.attributes
                let guess = Suggestions.closest(to: attribute.key, among: takes, limit: 1).first
                throw AutomationError(statement, .unknownAttribute, "an edge has no \(attribute.key): attribute",
                                      hint: (guess.map { "did you mean \($0)? " } ?? "") + "an edge takes \(takes.map { "\($0):" }.joined(separator: ", "))")
            }
            attributes[attribute.key] = attribute.value.text
        }
        let pairs = edge.bothHeads ? [(from, to), (to, from)] : [(from, to)]
        if let earlier = edges.first(where: { other in
            let theirs = other.edge.bothHeads ? [(other.from, other.to), (other.to, other.from)] : [(other.from, other.to)]
            return pairs.contains { pair in theirs.contains { $0 == pair } }
        }) {
            throw AutomationError(statement, .duplicate, "\(written) is written twice, here and on line \(earlier.statement.line)",
                                  hint: "say everything about one edge in one statement")
        }
        edges.append(EdgeItem(statement: statement, edge: edge, from: from, to: to, fromTitle: fromTitle, toTitle: toTitle, attributes: attributes))
    }

    // MARK: Styles

    /// Refuses a style that gives an attribute no kind drawn here has (a typo, most likely).
    private mutating func check(_ style: StyleDefinition) throws(AutomationError) {
        let kinds = drawableKinds.map { vocabulary(of: ShapeKind(rawValue: $0)) }
        let everything = Set(kinds.flatMap(\.attributes))
        for attribute in style.attributes where LanguageKey(rawValue: attribute.key) == nil && !everything.contains(attribute.key) {
            let guess = Suggestions.closest(to: attribute.key, among: everything.sorted(), limit: 1).first
            throw AutomationError("style \(style.name) has \(attribute.key):, which is an attribute of nothing drawn here",
                                  reason: ScriptError.Reason.unknownAttribute.rawValue,
                                  hint: guess.map { "did you mean \($0)?" } ?? "\(RPC.commandName) kinds lists each kind's attributes",
                                  line: style.line, statement: style.text)
        }
    }

    // MARK: Messages

    /// How a message names a statement's shape: `"API"`, or `the card on line 3`.
    func subject(of item: ShapeItem) -> String {
        item.title.map(quoted) ?? "the \(item.kind) on line \(item.statement.line)"
    }

    /// A board shape's middle.
    func middle(of record: AnyShapeRecord) -> CGPoint {
        (editor.shapeContext.geometry(of: record.id)?.bounds ?? record.box).map { CGPoint(x: $0.midX, y: $0.midY) } ?? .zero
    }

    /// A board shape, named for a message: `"DB"`, or `card at 400,300` (its middle); unquoted, as
    /// a row names it.
    func named(_ record: AnyShapeRecord, quote: Bool = true) -> String {
        guard let title = Drawing.title(of: record, names: names, naming: naming, registry: registry) else {
            return Drawing.location(of: record, in: editor.shapeContext)
        }
        return quote ? quoted(title) : title
    }

    // MARK: The board

    static func connections(in document: CanvasDocument, kind: ShapeKind, edging: DrawEdging, registry: Registry) -> [BoardConnection] {
        document.shapes.compactMap { record in
            guard record.kind == kind, !record.isOpaque, let ends = edging.ends(record, registry) else { return nil }
            return BoardConnection(record: record, from: ends.from, to: ends.to)
        }
    }

    /// The connections that don't join two shapes (an end left free, re-aimed off every shape),
    /// by each shape they're bound to (`ShapeReferencing`), in document order.
    static func looseConnections(in context: ShapeContext, kind: ShapeKind, edging: DrawEdging) -> [ShapeID: [AnyShapeRecord]] {
        var found: [ShapeID: [AnyShapeRecord]] = [:]
        for record in context.document.shapes where record.kind == kind && !record.isOpaque && edging.ends(record, context.registry) == nil {
            for id in record.boundShapes(in: context) { found[id, default: []].append(record) }
        }
        return found
    }
}

/// The board's shapes by what they're called, as the run starts.
@MainActor
struct BoardNames {
    /// Each name's shapes, in document order.
    private(set) var ids: [String: [ShapeID]] = [:]
    /// Each name once, in document order: what "did you mean" picks from.
    private(set) var ordered: [String] = []
    private var byID: [ShapeID: String] = [:]
    /// Each name, with its place in `ordered`, by its length as titles are compared: a near miss is
    /// at most 2 letters longer or shorter, so a new title is held only to names about its length.
    private var byLength: [Int: [(order: Int, name: String)]] = [:]

    init() {}

    init(_ document: CanvasDocument, naming: DrawNaming, registry: Registry) {
        for record in document.shapes where !record.isOpaque {
            guard let name = naming.name(record, registry) else { continue }
            if ids[name] == nil {
                byLength[Self.comparedLength(name), default: []].append((ordered.count, name))
                ordered.append(name)
            }
            ids[name, default: []].append(record.id)
            byID[record.id] = name
        }
    }

    func name(of record: AnyShapeRecord) -> String? { byID[record.id] }

    /// The first name, in document order, that `title` is a slip of (`Suggestions.isNearMiss`),
    /// among those `included`.
    func nearMiss(of title: String, where included: (String) -> Bool) -> String? {
        let length = Self.comparedLength(title)
        let nearby = (length - Self.slip...length + Self.slip).flatMap { byLength[$0] ?? [] }.sorted { $0.order < $1.order }
        return nearby.first { included($0.name) && Suggestions.isNearMiss(title, $0.name) }?.name
    }

    /// The most letters a near miss is off by.
    private static let slip = 2

    /// A title's length as `Suggestions` compares titles: runs of whitespace one space, the ends
    /// trimmed (lowercasing it, and writing × as x, keep its length).
    static func comparedLength(_ title: String) -> Int {
        let words = title.split(whereSeparator: \.isWhitespace)
        return words.reduce(0) { $0 + $1.count } + max(words.count - 1, 0)
    }
}

extension Script {
    /// Whether any statement names a shape by title (so the board's names are needed).
    var mentionsTitles: Bool {
        statements.contains { statement in
            switch statement.body {
            case .shape(let shape): shape.title != nil || shape.clauses.contains { $0.targets.contains { if case .title = $0.box { true } else { false } } }
            case .edge, .delete: true
            }
        }
    }
}

extension Attribute.Value {
    /// Its text, whatever it is: a word, a quoted string's, a JSON value's as written.
    var text: String {
        switch self {
        case .word(let text), .quoted(let text), .json(let text): text
        }
    }
}

/// A title in straight double quotes, escaped as a script writes it.
func quoted(_ title: String) -> String {
    var escaped = ""
    for character in title {
        switch character {
        case "\"": escaped += "\\\""
        case "\\": escaped += "\\\\"
        case "\n": escaped += "\\n"
        case "\t": escaped += "\\t"
        default: escaped.append(character)
        }
    }
    return "\"\(escaped)\""
}

/// A word with its article, as a message names one of a kind: `a sticky-note`, `an arrow`.
func indefinite(_ word: some CustomStringConvertible) -> String {
    let text = word.description
    return (text.first.map { "aeiou".contains($0.lowercased()) } ?? false ? "an " : "a ") + text
}

/// `a`, `a and b`, `a, b and c` (or `or`).
func listed(_ items: [String], or: Bool = false) -> String {
    guard let last = items.last else { return "" }
    return items.count == 1 ? last : "\(items.dropLast().joined(separator: ", ")) \(or ? "or" : "and") \(last)"
}

/// A point as a message writes it: `400,300`, to the unit (a coordinate too far out for a whole
/// number, as it is).
func point(_ point: CGPoint) -> String {
    func unit(_ value: CGFloat) -> String { Int(exactly: value.rounded()).map(String.init) ?? "\(value)" }
    return "\(unit(point.x)),\(unit(point.y))"
}
