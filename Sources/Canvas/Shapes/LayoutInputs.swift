import CoreGraphics
import Foundation

/// A name for something a shape's geometry reads that isn't in its record or in the shapes it looks
/// up: a layout input, set by the plugin that knows it (`editor.setLayoutInput`), read by the
/// definition (`context.layoutInput`). Mentions' names for an arrow's pills are one (a geometry
/// can't read another board, and a rename writes nothing to the shapes that mention it).
public struct LayoutInputKey<Value: Hashable & Sendable>: Sendable {
    public let name: String
    public init(_ name: String) { self.name = name }
}

/// The layout inputs of an editor's file, by shape: what `ShapeContext.layoutInput` reads. Set only
/// through the editor, which tells its index that the shape's geometry is out of date when one
/// changes.
@MainActor
final class LayoutInputs {
    private var values: [ShapeID: [String: AnyHashable]] = [:]

    func value(_ name: String, for id: ShapeID) -> AnyHashable? { values[id]?[name] }

    /// Whether it changed.
    func set(_ name: String, _ value: AnyHashable?, for id: ShapeID) -> Bool {
        if values[id]?[name] == value { return false }
        if let value {
            values[id, default: [:]][name] = value
        } else {
            values[id]?[name] = nil
            if values[id]?.isEmpty == true { values[id] = nil }
        }
        return true
    }
}

/// What a context lays shapes out with: the values set for them (`inputs`), the sizes laid out,
/// the editor's services, and the file as whoever lays them out sees it. A class, so a context
/// copies one reference, as it copied `LayoutInputs` before.
@MainActor
final class LayoutSource {
    /// Values set (`editor.setLayoutInput`).
    let inputs: LayoutInputs
    /// The laid-out sizes the editor keeps, by shape id, for the whole file.
    let sizes: LaidOutSizes
    let lend: @MainActor (ObjectIdentifier) -> (any EditorService)?
    /// A shape on any board of the file, as this source's reader sees the file.
    let shape: @MainActor (ShapeID) -> AnyShapeRecord?
    /// The board a shape is on, as this source's reader sees the file.
    let board: @MainActor (ShapeID) -> BoardID?
    /// The file's own values (`FileProperty`), as this source's reader sees the file.
    let fileValues: @MainActor () -> FileValues
    /// Whether a shape isn't as the editor keeps it; nil for the editor's own committed reading.
    let isChanged: (@MainActor (ShapeID) -> Bool)?
    var isCommitted: Bool { isChanged == nil }
    /// What this source asked afresh, for as long as it lives: nil for the editor's, which keeps in
    /// `sizes`. A context is a snapshot, so what it asked holds for it.
    let fresh: LaidOutSizes?
    /// Every write of this source's reader that is not a move, in order (what `isChanged` reads as a set); empty
    /// for the editor's own.
    let writes: [ShapeID]
    /// Which log this is: sources of one run, made as it went on, have the same number and each one's log
    /// begins with the entries of the earlier; 0 for the editor's.
    let run: Int
    /// Whether this source lays shapes out at rest: as they are when nothing is handling them, whatever a plugin shows
    /// or sets for the shape while it is (the editing view's waiting line and width, a fold peeled back while its shape is
    /// edited). What `Transaction.makeRoom()` measures a growth by.
    let isResting: Bool
    /// The shapes whose kept extent touches a rect, on a board, as the editor's committed index has them (nil: it
    /// has none for that board, or none made yet); only on the editor's own source.
    let nearby: (@MainActor (BoardID, CGRect) -> [ShapeID]?)?

    private static var runs = 0
    /// A number no other log has had.
    static func nextRun() -> Int {
        runs &+= 1
        return runs
    }

    init(inputs: LayoutInputs, sizes: LaidOutSizes, lend: @escaping @MainActor (ObjectIdentifier) -> (any EditorService)?,
         shape: @escaping @MainActor (ShapeID) -> AnyShapeRecord?, board: @escaping @MainActor (ShapeID) -> BoardID?,
         fileValues: @escaping @MainActor () -> FileValues, isChanged: (@MainActor (ShapeID) -> Bool)? = nil,
         writes: [ShapeID] = [], run: Int = 0, isResting: Bool = false,
         nearby: (@MainActor (BoardID, CGRect) -> [ShapeID]?)? = nil) {
        self.isResting = isResting
        self.nearby = nearby
        self.inputs = inputs
        self.sizes = sizes
        self.lend = lend
        self.shape = shape
        self.board = board
        self.fileValues = fileValues
        self.isChanged = isChanged
        fresh = isChanged == nil ? nil : LaidOutSizes()
        self.writes = writes
        self.run = run
    }

    /// The value set for a shape, nil for one this source's reader changed: the value was made from
    /// the record as it was, and nil means "as the record says".
    func value(_ name: String, for id: ShapeID) -> AnyHashable? {
        isChanged?(id) == true ? nil : inputs.value(name, for: id)
    }

    /// The size kept for a shape, if it is as kept: the editor's, for a shape this source's reader
    /// hasn't changed (then what this source asked since), else only what this source asked.
    func keptSize(of id: ShapeID) -> LaidOutSize? {
        guard let isChanged else { return sizes.size(of: id) }
        if !isChanged(id), let size = sizes.size(of: id) { return size }
        return fresh?.size(of: id)
    }

    /// Keeps a size just worked out: in the editor's, for its committed reading of a shape in the file
    /// (so it holds until a commit changes the shape), else in what this source keeps for itself.
    func keep(_ size: LaidOutSize, for id: ShapeID) {
        if isChanged == nil {
            if shape(id) != nil { sizes.keep(size, for: id) }
        } else {
            fresh?.keep(size, for: id)
        }
    }
}

/// What a `LaidOutBox` kind answered for a shape: the size it is laid out at, and the point of its box (in unit
/// coordinates of the box: (0, 0) its top-left, (0.5, 0.5) its middle) that stays where it is while the box
/// takes that size, which is how the laid-out frame is placed on the stored one.
struct LaidOutSize: Equatable {
    var size: CGSize
    var anchor: CGPoint

    /// The frame this size makes of a box: the box's origin for the top-left anchor, else the box's anchor point
    /// kept in place as the box takes the size.
    func frame(of box: CGRect) -> CGRect {
        CGRect(origin: CGPoint(x: box.minX + (box.width - size.width) * anchor.x, y: box.minY + (box.height - size.height) * anchor.y), size: size)
    }
}

/// The sizes shapes are laid out at (`LaidOutBox`), by shape id, for the whole file: worked out when
/// first asked and let go when a commit changes the shape other than by moving it, when the owner of
/// a layout input says the layout changed, and when a file is put in place. A size doesn't depend on
/// where the shape is, so a drag, an undo of a move and a board switch keep it.
@MainActor
final class LaidOutSizes {
    private var sizes: [ShapeID: LaidOutSize] = [:]

    func size(of id: ShapeID) -> LaidOutSize? { sizes[id] }
    func keep(_ size: LaidOutSize, for id: ShapeID) { sizes[id] = size }

    func forget(_ ids: some Sequence<ShapeID>) {
        guard !sizes.isEmpty else { return }
        for id in ids { sizes[id] = nil }
    }

    func forgetAll() { sizes.removeAll() }

    /// How many are kept (tests).
    var count: Int { sizes.count }
}

/// What a layout provider reads besides the shape (`registrar.layoutInput`).
@MainActor
public struct LayoutReading {
    public let registry: Registry
    private let source: LayoutSource

    init(registry: Registry, source: LayoutSource) {
        self.registry = registry
        self.source = source
    }

    /// A shape on any board of the file, as whoever is laying the shape out sees the file: the
    /// editor's, or mid-transaction as the transaction leaves it (what it inserted, changed and
    /// moved; nil for what it deleted).
    public func shape(inFile id: ShapeID) -> AnyShapeRecord? { source.shape(id) }

    /// The board a shape is on, as whoever is laying the shape out sees the file: the editor's
    /// (`file.board(containing:)`), mid-transaction as the transaction leaves it
    /// (`Transaction.board(containing:)`: the board it moved the shape onto, or brought it in on), or,
    /// with records laid in (`layingOut(with:)`), the reading it lays over's; nil for a shape on no
    /// board of the file (deleted, `removing`, or a laid-in record the file hasn't). What a plugin
    /// that works out where a shape is from the reading's records alone (a path, through each
    /// record's container and each board's owner) reads beside them.
    public func board(containing id: ShapeID) -> BoardID? { source.board(id) }

    /// One of the file's own values (`FileProperty`), as whoever is laying the shape out sees the
    /// file: the editor's, or mid-transaction as the transaction leaves it; the property's default
    /// for a file that holds none. Nothing a shape is laid out by is worked out again because a file
    /// value changed: the plugin that reads one here says so when it does
    /// (`editor.shapesDidChangeLayout`, on hearing `ChangeSet.fileValues`), as for any layout input.
    public func fileValue<P: FileProperty>(_: P.Type) -> P.Value { source.fileValues()[P.self] }

    /// One of the editor's services.
    public func service<S: EditorService>(_: S.Type) -> S? { source.lend(ObjectIdentifier(S.self)) as? S }

    /// Whether the file read is the editor's as committed. False mid-transaction: what a service
    /// keeps is of the file before, so answer from `shape(inFile:)` there.
    public var isCommitted: Bool { source.isCommitted }

    /// Whether the shape is laid out at rest: as it is when nothing is handling it. A provider that answers something the
    /// editing view shows (more rows while a folded shape is edited, a width while a line is typed) answers as at rest
    /// here, for what measures a shape by what a step writes (`Transaction.makeRoom()`).
    public var isResting: Bool { source.isResting }

    /// Whether this reading's shape differs from the editor's committed one (always false when
    /// `isCommitted`): one the reader added, changed other than by moving it, or laid in
    /// (`layingOut(with:)`), and one it doesn't have (`shape(inFile:)` nil: deleted mid-transaction,
    /// `removing`, or never in the file). What a service that keeps the committed file's answers asks
    /// before trusting one.
    public func isChanged(_ id: ShapeID) -> Bool {
        guard let isChanged = source.isChanged else { return false }
        return isChanged(id) || source.shape(id) == nil
    }

    /// The writes this reading's reader has made that are not moves, in order, each time a shape was added,
    /// changed other than by moving it, put in or moved onto another board, or deleted (a shape written twice is
    /// in it twice): what `isChanged` reads as a set. Append-only, and empty while `isCommitted`. A service that
    /// keeps an answer over the changed shapes keeps how far it has read, and applies only the entries since
    /// (`changes[cursor...]`) when it is asked again of a reading with the same `runID`, so a run of n shapes
    /// written one at a time costs n applications, not n squared. A shape `shape(inFile:)` says nothing of is
    /// deleted or never there.
    public var changes: [ShapeID] { source.writes }

    /// How many writes there are: `changes.count`.
    public var writeCount: Int { source.writes.count }

    /// Which log `changes` is a part of: readings of one transaction, taken as it went on, have the same
    /// `runID` and the shorter one's `changes` is the start of the longer's; a reading that lays records in
    /// (`layingOut(with:)`) has a `runID` of its own. 0 while `isCommitted`.
    public var runID: Int { source.run }
}

extension ShapeContext {
    /// The file as this context reads it, as a layout provider is handed it: the editor's committed,
    /// a transaction's, or with a run's records laid in (`layingOut(with:)`); nil for a context that
    /// lays nothing out. For a rule or a check that must answer as the layout does mid-transaction.
    public var reading: LayoutReading? { layout.map { LayoutReading(registry: registry, source: $0) } }

    /// A layout input of a shape: a value set for it (`editor.setLayoutInput`), else what the key's
    /// provider answers (`registrar.layoutInput`), else nil. Nil in a context that isn't the
    /// editor's or a transaction's. Whoever sets or provides it also says when it changes, so a
    /// geometry that reads it is worked out again.
    public func layoutInput<V>(_ key: LayoutInputKey<V>, for id: ShapeID) -> V? {
        guard let layout else { return nil }
        if let value = layout.value(key.name, for: id) as? V { return value }
        guard registry.layoutProviders[key.name] != nil, let record = storedDocument[id] else { return nil }
        return provided(key, of: record)
    }

    /// The same, by the shape's record: this context's own, or one being made.
    public func layoutInput<V>(_ key: LayoutInputKey<V>, of record: AnyShapeRecord) -> V? {
        guard let layout else { return nil }
        if let value = layout.value(key.name, for: record.id) as? V { return value }
        return provided(key, of: record)
    }

    /// The same, of a typed record. The record is erased only once there is a provider to hand it to.
    public func layoutInput<V, P: ShapeProps>(_ key: LayoutInputKey<V>, of shape: ShapeRecord<P>) -> V? {
        guard let layout else { return nil }
        if let value = layout.value(key.name, for: shape.id) as? V { return value }
        guard registry.layoutProviders[key.name] != nil else { return nil }
        return provided(key, of: AnyShapeRecord(shape))
    }

    private func provided<V>(_ key: LayoutInputKey<V>, of record: AnyShapeRecord) -> V? {
        guard let layout, let provider = registry.layoutProviders[key.name] else { return nil }
        return provider.provide(record, LayoutReading(registry: registry, source: layout)) as? V
    }
}

extension ShapeContext {
    /// The frame a shape of this context's document is laid out in, in world units: its box, or,
    /// for a `LaidOutBox` kind, the box's origin at the size the kind says (larger or smaller). Nil for a shape without a box,
    /// or not there. What anything that asks how much room a shape takes reads, in place of
    /// `record.box`; `record.box` is what is stored, and what a write changes.
    public func frame(of id: ShapeID) -> CGRect? {
        shape(id).flatMap { frame(of: $0) }
    }

    /// The same, of a record: this context's own (what a definition is handed, what a loop over
    /// `document.shapes` has), or a shape being made that is in no document yet (`layingOut(with:)`).
    /// A caller with a changed copy of a shape that is on the board reads through `layingOut(with:)`,
    /// which never reads that id from what is kept.
    public func frame(of record: AnyShapeRecord) -> CGRect? {
        guard let box = record.box else { return nil }
        guard let layout, !record.isOpaque, let definition = registry.laidOutBoxes[record.kind] else { return box }
        return laidOut(box, id: record.id, in: layout) {
            definition.erasedLaidOut(of: record, in: self)
        }
    }

    public func frame<P: BoxShapeProps>(of shape: ShapeRecord<P>) -> CGRect {
        guard let layout, registry.laidOutBoxes[P.kind] != nil else { return shape.frame }
        return laidOut(shape.frame, id: shape.id, in: layout) {
            registry.laidOutBoxes[P.kind]?.erasedLaidOut(of: AnyShapeRecord(shape), in: self)
        }
    }

    /// `frame(of:)` for a definition that is asked: a kept size is read by id with nothing erased.
    /// What a `LaidOutBox` kind's default geometry is, every shape of a board on its first frame.
    func frame<D: LaidOutBox>(of shape: ShapeRecord<D.Props>, laidOutBy definition: D) -> CGRect {
        guard let layout else { return shape.frame }
        return laidOut(shape.frame, id: shape.id, in: layout) {
            LaidOutSize(size: definition.laidOutSize(of: shape, in: self), anchor: definition.laidOutAnchor(of: shape, in: self))
        }
    }

    /// The kept size on the box (at its origin, or about the anchor point the kind says), else the kind's as it says
    /// it (larger or smaller than the box, but finite and above zero on both sides, else the box's), kept.
    private func laidOut(_ box: CGRect, id: ShapeID, in layout: LayoutSource, asking ask: () -> LaidOutSize?) -> CGRect {
        if let kept = layout.keptSize(of: id) { return kept.frame(of: box) }
        var laid = LaidOutSize(size: box.size, anchor: .zero)
        if let asked = ask(), asked.size.width.isFinite, asked.size.height.isFinite, asked.size.width > 0, asked.size.height > 0,
           asked.anchor.x.isFinite, asked.anchor.y.isFinite {
            laid = asked
        }
        layout.keep(laid, for: id)
        return laid.frame(of: box)
    }

    /// This context, for sizing shapes that aren't in the file yet: `records` are read by layout
    /// providers as shapes of the file, in place of any the file has under their ids, and are laid out
    /// afresh whatever the editor keeps for those ids (and so is anything this context's own source
    /// reads as changed: made from a transaction's `shapes`, a shape the transaction changed stays asked
    /// afresh). It keeps no geometry and no size, and never
    /// touches what the editor keeps. Draw's, for a script's shapes and the connections it draws, laid over the
    /// editor's own context (`canvas measure` lays a script over the open file's, which it reads and never writes). A
    /// context that lays nothing out (a plain one) gives one that lays nothing out.
    /// `removing` are shapes of the file the caller is deleting: read as not there.
    public func layingOut(with records: [AnyShapeRecord], removing removed: Set<ShapeID> = []) -> ShapeContext {
        guard let layout else { return ShapeContext(document: storedDocument, registry: registry, camera: storedCamera) }
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        // What it lays in and removes are writes of its own, after those of the reader it lays over.
        let source = LayoutSource(inputs: layout.inputs, sizes: layout.sizes, lend: layout.lend,
                                  shape: { byID[$0] ?? (removed.contains($0) ? nil : layout.shape($0)) },
                                  board: { removed.contains($0) ? nil : layout.board($0) },
                                  fileValues: layout.fileValues, isChanged: { id in byID[id] != nil || layout.isChanged?(id) == true },
                                  writes: layout.writes + records.map(\.id) + Array(removed),
                                  run: LayoutSource.nextRun())
        return ShapeContext(document: storedDocument, registry: registry, camera: storedCamera, index: nil, layout: source)
    }

    /// This context's reading of the file, over another board's shapes: lookups in `document` (another board as
    /// this context's reader has it: `transaction.contents(of:)`, `editor.contents(of:)`), each laid out as this
    /// context lays shapes out, its services and its `reading` the same. For what checks a shape on a board other
    /// than the one this context is over, mid-transaction too. It keeps no geometry.
    public func over(_ document: CanvasDocument) -> ShapeContext {
        ShapeContext(document: document, registry: registry, camera: storedCamera, index: nil, layout: layout)
    }
}
