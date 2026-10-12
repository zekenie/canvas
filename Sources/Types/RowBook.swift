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
        /// A link to a note, or several: their pills as laid out, left to right, and how many more did not fit.
        case links([ShownLink], more: Int)
    }

    /// The row's field; nil for a fold.
    public var path: FieldPath?
    public var name: String
    public var content: Content
    /// The type's dot.
    public var isNeeded: Bool
    /// An inherited row's type; nil for own rows and for `from N types`.
    public var tick: ShapeID?
    public var isFaint: Bool
    public var rect: CGRect, nameRect: CGRect, valueRect: CGRect
}

/// One pill of a pointer's row: the link, and where it is laid out.
public struct ShownLink: Equatable, Sendable {
    public let link: FieldLink
    /// The link as mention text, one mention and nothing else: what its pill is drawn from, read once with the row
    /// so a frame neither writes the token nor reads it again. The name it shows is looked up at each draw.
    public let text: MentionText
    /// The pill's left and its width, from the left of the value column (world units, at the rows' font).
    public var x: CGFloat, width: CGFloat
    /// Whether its target is a note the app shows: only a live pill is a face.
    public var isLive: Bool

    init(link: FieldLink, x: CGFloat, width: CGFloat, isLive: Bool) {
        self.link = link
        text = MentionText(stored: link.value.stringValue ?? "")
        self.x = x
        self.width = width
        self.isLive = isLive
    }
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

enum RowTemplateItem {
    case field(FieldRowTemplate)
    case fold(FoldTemplate)
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
    private var seenChain: Int
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
    /// The row of a link being picked in: its field is over its value, so the render draws no value there. Set and
    /// cleared by the rows view.
    public internal(set) var picking: (shape: ShapeID, key: String)?
    /// The one view over the rows of the shape being edited, if any.
    weak var rowsView: RowsView?
    /// The instances the last change to what a list resolves to reached (`reached(by:)`), by the revision of the
    /// commit that made it.
    var chainReached: (revision: Int, ids: Set<ShapeID>)?
    /// The rows of the notes that are one, as shown (`shownRows`): kept by shape, their rects from the block's
    /// top-left so a drag lets go of nothing, and let go of for the shapes a commit changed other than by
    /// moving.
    var shown: [ShapeID: ShownRows] = [:]
    static let shownCapacity = 2_048
    #if DEBUG
    /// What the check says of a shape's values in place of `FieldChecks`' (debug builds): tests draw marks before
    /// the check is there, and as it is.
    public var checks: ((AnyShapeRecord) -> FieldCheck)?
    #endif

    init(editor: CanvasEditor) {
        self.editor = editor
        let registry = editor.registry
        kinds = Set(registry.kinds.filter { registry.typeRows(of: $0) != nil })
        seenChain = editor.types?.chainRevision ?? 0
        sync = editor.typeSync
        // A service may reach another as it is made; both are registered ahead of this one.
        editor.types?.onChange { [weak self] changed in self?.typesChanged(changed) }
        sync?.onSpotChange { [weak self] id in self?.spotChanged(id) }
    }

    // MARK: What a shape's rows are for

    func subject(of record: AnyShapeRecord) -> RowSubject? {
        if record[TypeSchemaProperty.self] != nil { return RowSubject(list: [record.id], isType: true) }
        guard let links = record[IsAProperty.self], !links.isEmpty else { return nil }
        return RowSubject(list: links.map(\.shape), isType: false)
    }

    func hasWords(_ record: AnyShapeRecord) -> Bool {
        guard let words = editor?.registry.typeWords(of: record.kind)?.words(record) else { return false }
        return !words.stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Templates

    func template(_ subject: RowSubject) -> RowTemplate {
        if let index = editor?.types, seenChain != index.chainRevision { dropTemplates(to: index.chainRevision) }
        if let kept = templates[subject], !kept.usesNames || kept.renames == renames { return kept }
        let made = makeTemplate(subject)
        templates[subject] = made
        return made
    }

    private func dropTemplates(to revision: Int) {
        seenChain = revision
        templates = [:]
        shown = [:]
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
        return RowTemplate(items: items, nameColumn: column, usesNames: usesNames, renames: renames)
    }

    // MARK: The spot

    /// What a type's note shows where its rows go; nil for a shape that is not a type, and for blank.
    public func spot(of id: ShapeID) -> RowSpot? {
        guard let record = editor?.shape(inFile: id), let subject = subject(of: record), subject.isType, kinds.contains(record.kind) else { return nil }
        return spot(of: record, template: template(subject))
    }

    func spot(of record: AnyShapeRecord, template: RowTemplate) -> RowSpot? {
        guard record[TypeSchemaProperty.self] != nil else { return nil }
        if !template.items.isEmpty { return .rows }
        guard let sync = editor?.typeSync else { return hasWords(record) ? .noFields : nil }
        let id = record.id
        switch sync.status(of: id) {
        case .updating(.schema): return .reading
        case .failed(let failure): return Self.spot(failure)
        default: break
        }
        guard hasWords(record) else { return nil }
        // The first words of a new type are being typed and nothing has answered: `No fields` would flash
        // under the caret and widen the note at the first keystroke.
        if sync.isWaiting(id), !sync.hasAnswered(id) { return nil }
        return .noFields
    }

    private static func spot(_ failure: TypeSyncFailure) -> RowSpot {
        let action: RowSpot.Action? = switch failure.remedy {
        case .retry: .retry
        case .key: .settings
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
    public func extent(of record: AnyShapeRecord) -> RowsExtent? {
        guard let subject = subject(of: record), kinds.contains(record.kind) else { return nil }
        let template = template(subject)
        let count: Int
        if subject.isType {
            switch spot(of: record, template: template) {
            case nil: return nil
            case .rows?: count = template.items.count + (footFailure(of: record.id) == nil ? 0 : 1)
            case .reading?: count = TypesStyle.spotBarShares.count
            case .noFields?, .failed?: count = 1
            }
        } else {
            guard !template.items.isEmpty else { return nil }
            count = template.items.count
        }
        return extent(rows: count, hasWords: hasWords(record))
    }

    private func extent(rows count: Int, hasWords: Bool) -> RowsExtent {
        RowsExtent(minimumWidth: TypesStyle.rowsMinimumWidth, height: (hasWords ? TypesStyle.rowsLead : 0) + CGFloat(count) * TypesStyle.rowHeight)
    }

    /// The provider of `TypeRows.extent`, cheapest test first: a board first shown asks it of every note,
    /// and a note in full asks it every frame.
    static func provide(_ record: AnyShapeRecord, _ reading: LayoutReading) -> RowsExtent? {
        guard record[TypeSchemaProperty.self] != nil || !(record[IsAProperty.self] ?? []).isEmpty else { return nil }
        guard let book = reading.service(RowBook.self), book.kinds.contains(record.kind) else { return nil }
        return reading.isCommitted ? book.extent(of: record) : book.extent(of: record, reading: reading)
    }

    /// The same mid-transaction (a draw, a paste, a duplicate, `/is-a` itself, a type and its instance written
    /// together): resolved over the shapes as the transaction leaves them, since what is kept is of the file
    /// before. No template is built and no text measured.
    private func extent(of record: AnyShapeRecord, reading: LayoutReading) -> RowsExtent? {
        guard let subject = subject(of: record), let book = editor?.fieldBook else { return nil }
        let resolved = Chain.resolve(types: subject.list, in: ReadingTypes(book: book, reading: reading, record: record))
        let count = RowList.count(of: resolved, own: Set(subject.list))
        let hasWords = hasWords(record)
        // A type's foot is the sync's, which knows the shape by its id whatever the transaction did to it.
        if count > 0 { return extent(rows: count + (subject.isType && footFailure(of: record.id) != nil ? 1 : 0), hasWords: hasWords) }
        // A type with no fields: as its status idle and not waiting says, blank with no words, else one row.
        return subject.isType && hasWords ? extent(rows: 1, hasWords: true) : nil
    }

    // MARK: The rows as shown

    /// Where the shape's rows are drawn on the board shown (its kind's `typeRows(drawnIn:)`), world units.
    public func rowsRect(of id: ShapeID) -> CGRect? {
        editor?.document[id].flatMap { rowsRect(of: $0) }
    }

    func rowsRect(of record: AnyShapeRecord) -> CGRect? {
        guard let editor else { return nil }
        return editor.registry.typeRows(of: record.kind)?.place(record, editor.shapeContext)
    }

    /// The rows as they are drawn now, top to bottom, with their rects (world units): tests, the gallery.
    /// Empty for a shape with none, and for a type's note not showing `.rows`.
    public func rows(of id: ShapeID) -> [ShownRow] {
        guard let editor, let record = editor.document[id], let subject = subject(of: record), kinds.contains(record.kind),
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
        let geometry = RowGeometry(block: block, hasLead: hasWords(record), longestName: template.nameColumn)
        return template.items.enumerated().map { row, item in
            let rect = geometry.rect(row), name = geometry.nameRect(row), value = geometry.valueRect(row)
            switch item {
            case .field(let field):
                return ShownRow(path: field.path, name: field.name, content: .kind(label: field.label, chip: field.chip, hasMore: field.opensOnType),
                                isNeeded: field.isNeeded, tick: field.tick, isFaint: field.isFaint, rect: rect, nameRect: name, valueRect: value)
            case .fold(let fold):
                return ShownRow(path: nil, name: fold.name, content: .fold(fold.value), isNeeded: false, tick: fold.sources.count == 1 ? fold.sources[0] : nil,
                                isFaint: !fold.isMore, rect: rect, nameRect: fold.isMore ? rect : name, valueRect: fold.isMore ? .zero : value)
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

    /// Lets go of the rows of the shapes a commit changed, and of the notes that point at a target whose name or kind it
    /// changed (a pill's width is the target's name's): those are returned.
    @discardableResult
    private func letGo(of changes: ChangeSet) -> Set<ShapeID> {
        if changes.replacedDocument {
            dropEverything()
            return []
        }
        let carriers = editor?.fieldBook?.linkCarriers(touchedBy: changes) ?? []
        if !shown.isEmpty {
            for id in changes.added.union(changes.removed).union(changes.changed.subtracting(changes.moved)).union(changes.elsewhere) { shown[id] = nil }
            for id in carriers { shown[id] = nil }
        }
        return carriers
    }

    /// The shapes a commit changes the texts of without changing them, for Find (`FieldFindPlugin`'s `affected`): the
    /// instances of the types it changed, whose rows may show their values otherwise (a date's kind, a choice's
    /// label, which rows fold). Find asks before it reads the shapes it names, and the types' own index is behind it
    /// in the services' order, so this has the index hear the commit now (a second hearing returns at its first
    /// line, so its turn costs nothing more): a shape read against the types as they were would be read again later
    /// only if it changed. A commit that only moved shapes names nothing and wakes nothing.
    public func reached(by changes: ChangeSet) -> Set<ShapeID> {
        guard let editor else { return [] }
        if !changes.replacedDocument, changes.added.isEmpty, changes.removed.isEmpty, changes.elsewhere.isEmpty,
           changes.changed.count == changes.moved.count { return [] }
        let carriers = letGo(of: changes)
        editor.types?.documentDidChange(changes, in: editor)
        guard let reached = chainReached, reached.revision == editor.revision else { return carriers }
        return reached.ids.union(carriers)
    }

    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        if change.isFileReplaced { dropEverything() }
    }

    private func dropEverything() {
        templates = [:]
        shown = [:]
        feet = [:]
        seenChain = editor?.types?.chainRevision ?? 0
    }
}

extension CanvasEditor {
    /// What a shape's rows are made of, and the room they take (`RowBook`); nil without TypesPlugin.
    public var rowBook: RowBook? { service(RowBook.self) }
}
