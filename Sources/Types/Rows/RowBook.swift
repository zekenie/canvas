import Adornments
import Canvas
import CoreGraphics
import Foundation
import Mentions

/// What a type's note shows where its rows go.
public enum RowSpot: Equatable, Sendable {
    public enum Action: Equatable, Sendable { case retry, settings }
    /// One row a field its chain gives it.
    case rows
    /// The model is writing the schema: three bars.
    case reading
    case noFields
    /// The last read failed, and what can be done about it.
    case failed(String, action: Action?)
}

/// One row as it is drawn now: where it is (world units) and what it says.
public struct ShownRow: Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        /// A type's note: the kind's words, the chip of the type it names, and whether `›` ends the row (`opensOnType`).
        case kind(label: String, chip: ShapeID?, hasMore: Bool)
        /// A fold's value: `4 fields`, or "" for `+N more`.
        case fold(String)
        // A note that is one:
        case text(String), empty(String), box(Bool), choice(String?), summary(String)
        /// A row whose type is gone: its dashed chip.
        case gone(ShapeID)
        /// A note that is one, a relation row that holds relationships: their pills as laid out, left to right, and how
        /// many more did not fit. (A relation row that holds none is `.empty("add layer")`.)
        case related([ShownPill], more: Int)
        /// A type's note, a relation row: the way it runs (`→` this type is the from end, `←` the to end, `↔` both), the
        /// types at the other end (two at most) and how many more; no types: any note.
        case relationType(direction: String, chips: [ShapeID], more: Int)
    }

    /// The row's field; nil for a fold and for a relation row.
    public var path: FieldPath?
    /// The relation row this is; nil for a field and a fold.
    public var relation: RelationshipRowKey? = nil
    public var name: String
    public var content: Content
    /// The type's dot.
    public var isNeeded: Bool
    /// An inherited row's type; nil for own rows and for `from N types`.
    public var tick: ShapeID?
    public var isFaint: Bool
    public var rect: CGRect, nameRect: CGRect, valueRect: CGRect

    /// The fold: a row that is neither a field's nor a relation's.
    var isFold: Bool { path == nil && relation == nil }

    /// The pills a relation row shows.
    var pills: [ShownPill] {
        if case .related(let pills, _) = content { pills } else { [] }
    }
}

/// Which row of a note: a field's, or a relation row's.
public enum RowIdentity: Equatable, Sendable {
    case field(String)
    case relation(RelationshipRowKey)
}

extension ShownRow {
    /// Whether this is the row `identity` names.
    func isRow(_ identity: RowIdentity) -> Bool {
        switch identity {
        case .field(let key): path?.field == key
        case .relation(let key): relation == key
        }
    }
}

/// One pill of a row that names notes: a relationship the note has, seen from the row: the note at the other end
/// of its arrow and where the pill is laid out.
public struct ShownPill: Equatable, Sendable {
    /// The note it stands for: a note, or a note a pill may not stand for yet (`.notAdmitted`); nil for the rest.
    public let target: ShapeID?
    /// The pill on the arrow's far end, when the arrow ends on one (a reference): nil when it ends on the note.
    public let via: ShapeID?
    /// The relationship's arrow.
    public let arrow: ShapeID
    /// What the far end is: only a `.note` is drawn solid.
    public let state: EndReading
    /// The name the pill holds: what it shows while its target isn't live.
    public let label: String
    /// The pill as mention text, one mention and nothing else: what it is drawn from, made once with the row so a
    /// frame neither writes it nor reads it again. The name it shows is looked up at each draw.
    public let text: MentionText
    /// The pill's left and its width, from the left of the value column (world units, at the rows' font).
    public var x: CGFloat, width: CGFloat
    /// Whether the arrow breaks its relationship type's rule at this end (red, with the wave).
    public var isWrong: Bool
    /// Whether it is drawn solid: its state is a note the app shows. A live pill goes to its note; a dashed one to the pill.
    public let isLive: Bool

    init(target: ShapeID?, via: ShapeID?, arrow: ShapeID, state: EndReading, label: String, drawn: ShapeID, x: CGFloat, width: CGFloat,
         isLive: Bool, isWrong: Bool = false) {
        self.target = target
        self.via = via
        self.arrow = arrow
        self.state = state
        self.label = label
        text = MentionText([.mention(drawn, label: label)])
        self.x = x
        self.width = width
        self.isLive = isLive
        self.isWrong = isWrong
    }

    /// Where a click on it goes: its note while it is live, else the pill the arrow ends on.
    public var destination: ShapeID? { isLive ? target : via }
}

/// Who a shape's rows are for: a type's note, whose own types are itself, or a note that is one.
struct RowSubject: Hashable {
    var list: [ShapeID]
    var isType: Bool
}

struct FieldRowTemplate {
    /// The resolved field: what its value's summary is read by.
    var resolved: Resolved.Field
    var path: FieldPath
    var name: String
    var kind: FieldKind
    /// The kind's words on a type; the chip follows.
    var label: String
    var chip: ShapeID?
    var opensOnType: Bool
    var isNeeded: Bool
    var tick: ShapeID?
    var isFaint: Bool
    var nameWidth: CGFloat
    /// The bar zoomed out: the name's columns, counted as every skeleton counts text (never laid out), so a bar
    /// does not depend on the letters.
    var barWidth: CGFloat
}

struct FoldTemplate {
    /// `from Person`, `from 2 types`, `+12 more`.
    var name: String
    /// `4 fields`; "" for `+N more`.
    var value: String
    var isMore: Bool
    var sources: [ShapeID]
    var folded: [Resolved.Field]
}

/// A relationship row: what a relationship type's end at this type gives its notes (`RelationshipRow`), by its
/// types and the ends drawn and never by any arrow, so a note is as tall as its types and the drawn ends say.
struct RelationRowTemplate {
    var row: RelationshipRow
    /// The row's name as shown: a typed one as typed, a derived one in lower case, and `company · Employment` for
    /// the later of two relationship types' rows of one name.
    var name: String
    var nameWidth: CGFloat
    /// The bar zoomed out, counted as a field's is.
    var barWidth: CGFloat
    /// `→` this type is the from end, `←` the to end, `↔` both under one name.
    var direction: String
    /// A type's note: the type that gave an inherited row, which is then faint with a tick.
    var tick: ShapeID?
    var isFaint: Bool
    /// A type's note: the row's end is Needed, which puts the amber dot after the name (as a required field has).
    var isNeeded = false
}

enum RowTemplateItem {
    case field(FieldRowTemplate)
    case fold(FoldTemplate)
    case relation(RelationRowTemplate)
}

/// The rows of one list of types, worked out once: what a drag, a frame and ten thousand notes of the same
/// types share. Nothing of a shape is in it.
struct RowTemplate {
    var items: [RowTemplateItem]
    /// The longest shown name's width, the dot's room with it, before it is capped.
    var nameColumn: CGFloat
    /// Whether a name of a type is said in it (`from Person`), so a rename makes it again.
    var usesNames: Bool
    var renames: Int
    /// The index of the first relation row; nil with none.
    var relationStart: Int?

    init(items: [RowTemplateItem], nameColumn: CGFloat, usesNames: Bool, renames: Int, relationStart: Int? = nil) {
        self.items = items
        self.nameColumn = nameColumn
        self.usesNames = usesNames
        self.renames = renames
        self.relationStart = relationStart
    }

    /// Whether a dashed line runs between the fields and the relation rows: only with both.
    var hasRule: Bool { (relationStart ?? 0) > 0 }
}

/// Keeps what a shape's rows are made of: a template for each distinct list of types, the room a shape's
/// rows take (the provider of `TypeRows.extent`), what a type's note says where its rows go (`spot`), and
/// the rows as they are drawn now. It announces when its answer for a shape changes with no commit of the
/// shape's own (`editor.shapesDidChangeLayout`): a type's schema, name or own types changing, the sync's
/// status or wait. It reads no shape as it is made.
@MainActor
public final class RowBook {
    weak var editor: CanvasEditor?
    /// The kinds that say where their rows go.
    let kinds: Set<ShapeKind>
    /// The sync, found once: a type's note with rows asks it each frame it is drawn (the foot), and a lookup of a
    /// service by its type costs more than the ask.
    private let sync: TypeSync<TypeSchemaProperty>?
    private var templates: [RowSubject: RowTemplate] = [:]
    /// The words of each kind that has them, found once (the registry never changes; `Registry.typeWords(of:)` makes an array
    /// of its contributions on each ask, and a layout asks for the words of every type's note).
    private let wordsOf: [ShapeKind: TypeWordsContribution]
    private var seenChain: Int
    /// The relationships, found once: a template asks whether its ends moved each time it is asked for.
    let relationships: RelationshipIndex?
    private var seenRelations: Int
    /// The types that had a relationship type's end at them when relationships were last announced: what an announcement
    /// of everything lays out, with the ones it has now.
    private var endTypes: Set<ShapeID> = []
    /// The name each pill was laid out with, by the note it names, and the notes whose rows show a pill for it: nothing
    /// announces a note's rename to the notes that show its name, so a commit compares what it changed (`letGo`) with
    /// these. Filled as the rows are built, and let go of with them.
    public internal(set) var pillLabels: [ShapeID: String] = [:]
    public internal(set) var holders: [ShapeID: Set<ShapeID>] = [:]
    /// By pill: the notes whose rows read a far end through it. A commit that changes the pill lets go of their rows.
    public internal(set) var viaHolders: [ShapeID: Set<ShapeID>] = [:]
    /// How often a type was renamed: a template that says a type's name is made again after one.
    var renames = 0
    #if DEBUG
    /// How many templates have been made (debug builds): one for each distinct list and isType, and again after a type changes.
    public private(set) var templatesMade = 0
    /// How many shapes' rows have been built (`rows(of:)`): a drag builds none.
    public internal(set) var rowsShown = 0
    /// What `openCard` asked `FieldCards` to open (debug builds): one service type takes one registration, so
    /// no double can stand in for it.
    public internal(set) var opened: [FieldCardRequest] = []
    #endif
    /// The failed read each type's note was last laid out for (`footFailure`), by shape: what `spotChanged` tells a
    /// status that moves the foot from one that does not. Only types whose read failed are in it.
    private var feet: [ShapeID: RowSpot] = [:]
    /// The row being picked in: its field is over its value, so the render draws no value there. Set and cleared by
    /// the rows view.
    public internal(set) var picking: (shape: ShapeID, row: RowIdentity)?
    /// Makes the list of notes a relation row of `shape` finds one in (`RelationPicker`, in the product); nil makes none,
    /// and a row then opens no list. The rows view hosts the list (`NotePicking`).
    public var makePicker: (@MainActor (_ shape: ShapeID, _ row: RelationshipRow) -> (any NotePicking)?)?
    /// The one view over the rows of the shape being edited, if any, and whether it's asked to follow what the change
    /// being delivered moved (`rowsChanged`).
    weak var rowsView: RowsView?
    var repositionAsked = false
    /// The instances the last change to what a list resolves to reached (`reached(by:)`), by the revision of the
    /// commit that made it.
    var chainReached: (revision: Int, ids: Set<ShapeID>)?
    /// The rows of the notes that are one, as shown (`shownRows`): kept by shape, their rects from the block's
    /// top-left so a drag lets go of nothing, and let go of for the shapes a commit changed other than by
    /// moving.
    var shown: [ShapeID: ShownRows] = [:]
    static let shownCapacity = 2_048
    /// The width each pill is laid out at, by what it is made of (`pillWidth`). The style and the fonts never change, so
    /// nothing lets an entry go but the capacity.
    var pillWidths: [PillWidthKey: CGFloat] = [:]
    #if DEBUG
    /// What the check says of a shape's values in place of `FieldChecks`' (debug builds): tests draw marks before
    /// the check is there, and as it is.
    public var checks: ((AnyShapeRecord) -> FieldCheck)?
    #endif

    init(editor: CanvasEditor) {
        self.editor = editor
        let registry = editor.registry
        let kinds = Set(registry.kinds.filter { registry.typeRows(of: $0) != nil })
        self.kinds = kinds
        wordsOf = Dictionary(uniqueKeysWithValues: registry.kinds.compactMap { kind in registry.typeWords(of: kind).map { (kind, $0) } })
        // A relation row's list: the notes that fit it, on any board (a double of the tests may replace it).
        makePicker = { [weak editor] shape, row in editor.map { RelationPicker(editor: $0, owner: shape, row: row, kinds: kinds) } }
        seenChain = editor.types?.chainRevision ?? 0
        relationships = editor.relationships
        seenRelations = relationships?.revision ?? 0
        endTypes = relationships.map { Set($0.graph.ends.rows.keys) } ?? []
        sync = editor.typeSync
        // A service may reach another as it is made; both are registered ahead of this one.
        editor.types?.onChange { [weak self] change in
            // Only a change to a type: a mark or a list alone changes nothing a chain resolves to.
            if !change.types.isEmpty { self?.typesChanged(change.types) }
        }
        relationships?.onChange { [weak self] change in self?.relationsChanged(change) }
        sync?.onSpotChange { [weak self] id in self?.spotChanged(id) }
    }

    // MARK: What a shape's rows are for

    func subject(of record: AnyShapeRecord) -> RowSubject? {
        if record[TypeSchemaProperty.self] != nil { return RowSubject(list: [record.id], isType: true) }
        guard let links = record[IsAProperty.self], !links.isEmpty else { return nil }
        return RowSubject(list: links.map(\.shape), isType: false)
    }

    func hasWords(_ record: AnyShapeRecord) -> Bool {
        guard let words = wordsOf[record.kind]?.words(record) else { return false }
        // Whatever is not white space: the string trimmed is not empty, without making the trimmed string.
        return !words.stored.unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains)
    }

    /// The shape is being edited: its words have a line however empty they are (`RowsExtent.wordsLine`), and its rows
    /// their lead under them. The core lays a shape out afresh as its editing begins and ends.
    func isEdited(_ record: AnyShapeRecord) -> Bool { record.id == editor?.editingShapeID }

    /// The rows have their lead and the hairline over it: under words, or under the line an edited shape's words keep.
    func hasLead(_ record: AnyShapeRecord) -> Bool { isEdited(record) || hasWords(record) }

    // MARK: Templates

    func template(_ subject: RowSubject) -> RowTemplate {
        // Two compares an ask: what a list resolves to, and what ends are drawn.
        if let index = editor?.types, seenChain != index.chainRevision { dropTemplates(to: index.chainRevision) }
        if let relationships, seenRelations != relationships.revision { dropTemplates(toRelations: relationships.revision) }
        if let kept = templates[subject], !kept.usesNames || kept.renames == renames { return kept }
        let made = makeTemplate(subject)
        templates[subject] = made
        return made
    }

    private func dropTemplates(to revision: Int) {
        seenChain = revision
        letGoOfTemplates()
    }

    private func dropTemplates(toRelations revision: Int) {
        seenRelations = revision
        letGoOfTemplates()
    }

    /// Every template goes, and the rows built from them with what is kept to compare them by.
    private func letGoOfTemplates() {
        templates = [:]
        letGoOfShown()
    }

    /// Every note's rows as shown go, and with them the names their pills were laid out with.
    func letGoOfShown() {
        shown = [:]
        pillLabels = [:]
        holders = [:]
        viaHolders = [:]
    }

    private func makeTemplate(_ subject: RowSubject) -> RowTemplate {
        #if DEBUG
        templatesMade += 1
        #endif
        guard let editor, let book = editor.fieldBook else { return RowTemplate(items: [], nameColumn: 0, usesNames: false, renames: renames) }
        let own = Set(subject.list)
        let resolved = book.fields(types: subject.list)
        let list = RowList(resolved, own: own)
        let dotRoom = TypesStyle.neededDotGap + TypesStyle.neededDotSize
        var items: [RowTemplateItem] = [], column: CGFloat = 0, usesNames = false
        for item in list.items {
            switch item {
            case .field(let field):
                let kind = book.kind(of: field)
                let inherited = subject.isType && !own.contains(field.introducedBy)
                let name = FieldName.words(of: field.field)
                let width = FieldLines.width(of: name, .name)
                let memberCount: Int
                if case .group = kind { memberCount = book.members(of: field).count } else { memberCount = 0 }
                column = max(column, width + (subject.isType && field.field.isRequired ? dotRoom : 0))
                items.append(.field(FieldRowTemplate(resolved: field, path: FieldPath(field: field.field.name), name: name, kind: kind,
                                                     label: kind.typeLabel(memberCount: memberCount), chip: kind.chip,
                                                     opensOnType: kind.opensOnType, isNeeded: field.field.isRequired,
                                                     tick: inherited ? field.introducedBy : nil, isFaint: inherited, nameWidth: width,
                                                     barWidth: CGFloat(SkeletonText.columns(of: name)) * TypesStyle.skeletonRowColumn)))
            case .fold(let fold):
                let name: String
                if fold.isMore {
                    name = FieldWords.more(fold.folded.count)
                } else if let source = fold.from {
                    usesNames = true
                    name = FieldWords.from(editor.types.map { TypesStyle.menuName($0.name(of: TypeLink(source))) } ?? TypesStyle.deletedType)
                } else {
                    name = FieldWords.fromTypes(fold.sources.count)
                }
                // `+N more` runs from the left edge and is no name; `from Person` is one.
                if !fold.isMore { column = max(column, FieldLines.width(of: name, .faint)) }
                items.append(.fold(FoldTemplate(name: name, value: fold.isMore ? "" : FieldWords.fields(fold.folded.count), isMore: fold.isMore,
                                                sources: fold.sources, folded: fold.folded)))
            }
        }
        // The relationship rows come after the fields, whatever the note's arrows are.
        let relationStart = items.count
        var relationsMade = 0
        if let relationships, let types = editor.types {
            var named: Set<String> = []
            for row in relationships.rows(for: subject.list, isType: subject.isType) {
                let derived: Bool
                if case .typed = row.key.label { derived = false } else { derived = true }
                var name = row.name(in: types.graph)
                // The later of two relationship types' rows of one name says whose it is.
                if !named.insert(name).inserted { name += " · " + (types.graph.names[row.key.type] ?? TypesStyle.untitledType) }
                usesNames = usesNames || derived || name != row.name(in: types.graph)
                let inherited = subject.isType && row.source != subject.list[0]
                let width = FieldLines.width(of: name, inherited ? .faint : .name)
                let needed = subject.isType && row.rule.needed
                column = max(column, width + (needed ? dotRoom : 0))
                items.append(.relation(RelationRowTemplate(row: row, name: name, nameWidth: width,
                                                           barWidth: CGFloat(SkeletonText.columns(of: name)) * TypesStyle.skeletonRowColumn,
                                                           direction: Self.direction(of: row), tick: inherited ? row.source : nil, isFaint: inherited,
                                                           isNeeded: needed)))
                relationsMade += 1
            }
        }
        return RowTemplate(items: items, nameColumn: column, usesNames: usesNames, renames: renames, relationStart: relationsMade > 0 ? relationStart : nil)
    }

    /// `→` the type is the row's from end, `←` its to end, `↔` both: a word that needs no translation.
    private static func direction(of row: RelationshipRow) -> String {
        row.sides.count == 2 ? "↔" : row.sides.contains(.from) ? "→" : "←"
    }

    /// What a type's note says of a relation row: its direction, the first two types at the other end and how many
    /// more; no types: any note.
    static func relationType(_ relation: RelationRowTemplate) -> ShownRow.Content {
        let others = relation.row.others
        return .relationType(direction: relation.direction, chips: Array(others.prefix(2)), more: max(0, others.count - 2))
    }

    // MARK: The spot

    /// What a type's note shows where its rows go; nil for a shape that is not a type, and for blank.
    public func spot(of id: ShapeID) -> RowSpot? {
        guard let record = editor?.shape(inFile: id), let subject = subject(of: record), subject.isType, kinds.contains(record.kind) else { return nil }
        return spot(of: record, template: template(subject))
    }

    /// `hasWords` is what the caller already knows of the record's words, else it is read (only when the answer needs it).
    /// A layout (`observing: false`) is told of a change by `spotChanged`, and reads the status without observing it.
    func spot(of record: AnyShapeRecord, template: RowTemplate, hasWords known: Bool? = nil, observing: Bool = true) -> RowSpot? {
        guard record[TypeSchemaProperty.self] != nil else { return nil }
        if !template.items.isEmpty { return .rows }
        guard let sync = editor?.typeSync else { return (known ?? hasWords(record)) ? .noFields : nil }
        let id = record.id
        switch observing ? sync.status(of: id) : sync.statusUnobserved(of: id) {
        case .updating(.schema): return .reading
        case .failed(let failure): return Self.spot(failure)
        default: break
        }
        guard known ?? hasWords(record) else { return nil }
        // The first words of a new type are being typed and nothing has answered: `No fields` would flash
        // under the caret and widen the note at the first keystroke.
        if sync.isWaiting(id), !sync.hasAnswered(id) { return nil }
        return .noFields
    }

    private static func spot(_ failure: TypeSyncFailure) -> RowSpot {
        let action: RowSpot.Action? = switch failure.remedy {
        case .retry: .retry
        case .signIn: .settings
        case .editByHand: nil
        }
        return .failed(failure.message, action: action)
    }

    /// What a type that has rows says at their foot, one row more: why its words were not read (no key, a refusal,
    /// too long), so the rows it keeps, the last good ones, are not taken for what the words say now. Always a
    /// `.failed`; nil while nothing failed, and for a failure to write the words, under which the rows say what the
    /// schema says. While a read is out the rows stay as they are: no bars.
    public func foot(of id: ShapeID) -> RowSpot? {
        guard let record = editor?.shape(inFile: id), let subject = subject(of: record), subject.isType, kinds.contains(record.kind),
              !template(subject).items.isEmpty else { return nil }
        return footFailure(of: id)
    }

    /// The same, for a type whose rows are known to be there: the sync's status alone, not observed (a frame asks it
    /// of every type's note in view, drawn in full or as a skeleton).
    func footFailure(of id: ShapeID) -> RowSpot? {
        guard let failure = sync?.failure(of: id), failure.writing == .schema else { return nil }
        return Self.spot(failure)
    }

    // MARK: The extent

    /// The room a shape's rows take, from what is kept: nil for a shape with none. The provider's answer
    /// for the committed file.
    public func extent(of record: AnyShapeRecord) -> RowsExtent? { extent(of: record, edited: isEdited(record)) }

    /// The extent as it is while the shape is edited (`true`) or at rest (`false`): the same rows, with or without the lead and
    /// the words' line editing gives. A kind that lays a press made at rest out against the rows edited asks both.
    public func extent(ofShape id: ShapeID, edited: Bool) -> RowsExtent? {
        editor?.shape(inFile: id).flatMap { extent(of: $0, edited: edited) }
    }

    private func extent(of record: AnyShapeRecord, edited: Bool) -> RowsExtent? {
        guard let subject = subject(of: record), kinds.contains(record.kind) else { return nil }
        let template = template(subject)
        let count: Int
        if subject.isType {
            switch spot(of: record, template: template, observing: false) {
            case nil: return nil
            case .rows?: count = template.items.count + (footFailure(of: record.id) == nil ? 0 : 1)
            case .reading?: count = TypesStyle.spotBarShares.count
            case .noFields?, .failed?: count = 1
            }
        } else {
            guard !template.items.isEmpty else { return nil }
            count = template.items.count
        }
        return extent(rows: count, hasLead: edited || hasWords(record), wordsLine: edited, hasRule: template.hasRule)
    }

    /// `count` rows with their lead or not, and the dashed line when fields and relation rows both are there; `wordsLine`
    /// while the shape is edited.
    private func extent(rows count: Int, hasLead: Bool, wordsLine: Bool = false, hasRule: Bool = false) -> RowsExtent {
        RowsExtent(height: (hasLead ? TypesStyle.rowsLead : 0) + CGFloat(count) * TypesStyle.rowHeight + (hasRule ? TypesStyle.relationRuleHeight : 0),
                   wordsLine: wordsLine)
    }

    /// The provider of `TypeRows.extent`, cheapest test first: a board first shown asks it of every note,
    /// and a note in full asks it every frame. A relationship type has no rows: it is a pill (`TypeRows.pill`).
    static func provide(_ record: AnyShapeRecord, _ reading: LayoutReading) -> RowsExtent? {
        guard record[TypeSchemaProperty.self] != nil || !(record[IsAProperty.self] ?? []).isEmpty else { return nil }
        guard record[RelationshipProperty.self] != true || record[TypeSchemaProperty.self] == nil else { return nil }
        guard let book = reading.service(RowBook.self), book.kinds.contains(record.kind) else { return nil }
        return reading.isCommitted ? book.extent(of: record) : book.extent(of: record, reading: reading)
    }

    /// The same mid-transaction (a draw, a paste, a duplicate, `/is-a` itself, a type and its instance written
    /// together): resolved over the shapes as the transaction leaves them, since what is kept is of the file
    /// before. No template is built and no text measured.
    private func extent(of record: AnyShapeRecord, reading: LayoutReading) -> RowsExtent? {
        guard let subject = subject(of: record), let book = editor?.fieldBook else { return nil }
        let resolved = Chain.resolve(types: subject.list, in: ReadingTypes(book: book, reading: reading, record: record))
        let fields = RowList.count(of: resolved, own: Set(subject.list))
        let relations = relationCount(of: subject, reading: reading)
        let count = fields + relations
        let hasWords = hasWords(record)
        // A type's foot is the sync's, which knows the shape by its id whatever the transaction did to it.
        if count > 0 {
            return extent(rows: count + (subject.isType && footFailure(of: record.id) != nil ? 1 : 0), hasLead: hasWords || isEdited(record),
                          wordsLine: isEdited(record), hasRule: fields > 0 && relations > 0)
        }
        // A type with no fields: as its status idle and not waiting says, blank with no words, else one row.
        return subject.isType && hasWords ? extent(rows: 1, hasLead: true, wordsLine: isEdited(record)) : nil
    }

    /// How many relation rows the subject gets from the ends the reading has, none of its arrows: the graph the
    /// reading sees, which is the committed one until a run's own ends are read (so a transaction that makes an end and
    /// the notes of its types together sizes the notes without the new rows, and the announcement after the commit
    /// lays them out).
    private func relationCount(of subject: RowSubject, reading: LayoutReading) -> Int {
        guard let relationships else { return 0 }
        let graph = relationships.graph(in: reading)
        guard !graph.ends.rows.isEmpty else { return 0 }
        return graph.rows(for: subject.list, isType: subject.isType).count
    }

    // MARK: The rows as shown

    /// Where the shape's rows are drawn (its kind's `typeRows(drawnIn:)`), in the world units of its board: the board shown's,
    /// or another's for a shape edited through a mirror there.
    public func rowsRect(of id: ShapeID) -> CGRect? {
        editor?.shape(inFile: id).flatMap { rowsRect(of: $0) }
    }

    func rowsRect(of record: AnyShapeRecord) -> CGRect? {
        guard let editor else { return nil }
        return editor.registry.typeRows(of: record.kind)?.place(record, editor.shapeContext)
    }

    /// The rows as they are drawn now, top to bottom, with their rects (world units): tests, the gallery.
    /// Empty for a shape with none, and for a type's note not showing `.rows`.
    public func rows(of id: ShapeID) -> [ShownRow] {
        guard let editor, let record = editor.shape(inFile: id), let subject = subject(of: record), kinds.contains(record.kind),
              let block = rowsRect(of: id) else { return [] }
        let template = template(subject)
        if !subject.isType {
            guard !template.items.isEmpty else { return [] }
            return shownRows(of: record, subject: subject, template: template, block: block).rows.map { $0.offset(by: block.origin) }
        }
        if spot(of: record, template: template) != .rows { return [] }
        #if DEBUG
        rowsShown += 1
        #endif
        let geometry = RowGeometry(block: block, hasLead: hasLead(record), template: template)
        return template.items.enumerated().map { row, item in
            let rect = geometry.rect(row), name = geometry.nameRect(row), value = geometry.valueRect(row)
            switch item {
            case .field(let field):
                return ShownRow(path: field.path, name: field.name, content: .kind(label: field.label, chip: field.chip, hasMore: field.opensOnType),
                                isNeeded: field.isNeeded, tick: field.tick, isFaint: field.isFaint, rect: rect, nameRect: name, valueRect: value)
            case .fold(let fold):
                return ShownRow(path: nil, name: fold.name, content: .fold(fold.value), isNeeded: false, tick: fold.sources.count == 1 ? fold.sources[0] : nil,
                                isFaint: !fold.isMore, rect: rect, nameRect: fold.isMore ? rect : name, valueRect: fold.isMore ? .zero : value)
            case .relation(let relation):
                return ShownRow(path: nil, relation: relation.row.key, name: relation.name, content: Self.relationType(relation), isNeeded: false,
                                tick: relation.tick, isFaint: relation.isFaint, rect: rect, nameRect: name, valueRect: value)
            }
        }
    }

    // MARK: Announcements

    /// A type came, went, or changed its schema, name or own types. When what a list resolves to may have
    /// moved, every template goes and the type, its instances near and far, and the instances this very
    /// commit added or changed (the index has filed them already) are laid out again: a service ahead of
    /// Types may have asked for their frames against the index of the file before. A rename moves no size.
    private func typesChanged(_ changed: Set<ShapeID>) {
        guard let editor, let index = editor.types else { return }
        if index.chainRevision != seenChain {
            dropTemplates(to: index.chainRevision)
            let instances = index.affected(by: changed)
            chainReached = (editor.revision, instances)
            editor.shapesDidChangeLayout(changed.union(instances))
            // A pill's label (hidden where its title is the field's value) is made again with no commit on the shape.
            editor.adornmentsDidChange(for: instances)
            rowsChanged()
        } else {
            renames += 1
            editor.setNeedsDisplay()
        }
    }

    /// What a commit changed in the relationships (`RelationshipIndex`), told after the index has it. An end drawn,
    /// deleted or re-aimed changes the room the notes of its types take: those, near and far, and the type notes (the
    /// types are in `layout` themselves) are laid out again. A relationship drawn or deleted changes no note's room, only
    /// what its two notes show: their rows, and the rows of any note whose pill is on one of the arrows, are let go of.
    /// A row's name or its other types changing with no change of count is a redraw.
    private func relationsChanged(_ change: RelationshipChange) {
        guard let editor, let index = editor.types, let relationships else { return }
        let before = endTypes
        endTypes = Set(relationships.graph.ends.rows.keys)
        if change.everything {
            // Anything may have changed: every table goes, and the types that had an end and have one now, with their notes.
            letGoOfTemplates()
            seenRelations = relationships.revision
            let ended = before.union(endTypes)
            editor.shapesDidChangeLayout(ended.union(index.affected(by: ended)))
            rowsChanged()
            return
        }
        for id in change.notes { shown[id] = nil }
        if !change.arrows.isEmpty, !shown.isEmpty {
            let stale = shown.filter { !$0.value.arrows.isDisjoint(with: change.arrows) }.keys
            for id in stale { shown[id] = nil }
        }
        if !change.layout.isEmpty {
            letGoOfTemplates()
            seenRelations = relationships.revision
            editor.shapesDidChangeLayout(change.layout.union(index.affected(by: change.layout)))
        }
        editor.setNeedsDisplay()
        rowsChanged()
    }

    /// The sync's status or wait changed for a shape: a type with no rows has a spot that moved with no
    /// commit to show it (bars to a reason), and its height or presence may be another. One with rows
    /// shows the same but for a failed read, a row more at their foot: it is laid out again only when
    /// that failure came, went or reads otherwise (a wait or a call changes nothing it shows).
    private func spotChanged(_ id: ShapeID) {
        let failure = footFailure(of: id)
        let moved = failure != feet[id]
        feet[id] = failure
        guard let editor, let record = editor.shape(inFile: id), kinds.contains(record.kind), record[TypeSchemaProperty.self] != nil else { return }
        guard moved || template(RowSubject(list: [id], isType: true)).items.isEmpty else { return }
        editor.shapesDidChangeLayout([id])
        rowsChanged()
    }
}

extension RowBook: EditorService {
    /// A file put in place: every table goes. A shape another commit changed (other than by moving) or took
    /// lets go of its rows. (Everything else is told by the index and the sync.)
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        letGo(of: changes)
        // The shape being edited may have grown, or its rows changed: the view over them follows.
        rowsChanged()
    }

    /// Lets go of the rows of the shapes a commit changed.
    private func letGo(of changes: ChangeSet) {
        if changes.replacedDocument {
            dropEverything()
            return
        }
        if !shown.isEmpty {
            for id in changes.added.union(changes.removed).union(changes.changed.subtracting(changes.moved)).union(changes.elsewhere) { shown[id] = nil }
        }
        // A pill is laid out with the name of the note it stands for, and nothing tells the notes that show it when that
        // is renamed (or when the note goes or comes back): compare what the commit changed with the names the pills
        // were laid out with. A commit that changed no note a pill names costs a dictionary miss for each shape.
        if !viaHolders.isEmpty {
            for ids in [changes.added, changes.removed, changes.elsewhere, changes.changed.subtracting(changes.moved)] {
                for id in ids { for holder in viaHolders[id] ?? [] { shown[holder] = nil } }
            }
        }
        guard !pillLabels.isEmpty else { return }
        for ids in [changes.added, changes.removed, changes.elsewhere, changes.changed.subtracting(changes.moved)] {
            for id in ids {
                guard let kept = pillLabels[id] else { continue }
                let now = pillLabel(of: id)
                guard now != kept else { continue }
                pillLabels[id] = now
                for holder in holders[id] ?? [] { shown[holder] = nil }
            }
        }
    }

    /// The name a pill for this note shows now: what Mentions calls it while it is live, else nothing.
    func pillLabel(of id: ShapeID) -> String {
        editor?.mentions?.resolve(id).appearance?.label ?? ""
    }

    /// The shapes a commit changes the texts of without changing them, for Find (`FieldFindPlugin`'s `affected`): the
    /// instances of the types it changed, whose rows may show their values otherwise (a date's kind, a choice's
    /// label, which rows fold). Find asks once every service has the commit, so the types' index has told this book
    /// what the commit reached. A commit that only moved shapes names nothing.
    public func reached(by changes: ChangeSet) -> Set<ShapeID> {
        guard let editor, let reached = chainReached, reached.revision == editor.revision else { return [] }
        return reached.ids
    }

    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        if change.isFileReplaced { dropEverything() }
    }

    private func dropEverything() {
        templates = [:]
        letGoOfShown()
        feet = [:]
        seenChain = editor?.types?.chainRevision ?? 0
        seenRelations = relationships?.revision ?? 0
    }
}

extension CanvasEditor {
    /// What a shape's rows are made of, and the room they take (`RowBook`); nil without TypesPlugin.
    public var rowBook: RowBook? { service(RowBook.self) }
}
