import Foundation
import Geometry

/// Reads and writes board files. A file is JSON: an envelope around the root board's shapes, back
/// to front, and each other board's, by its owner's id.
///
///     {
///       "boards" : {
///         "A1B2…" : { "shapes" : [ { "id" : "…", "index" : "a0", "kind" : "sticky-note", "props" : { … } } ] }
///       },
///       "format" : 4,
///       "shapes" : [
///         { "added" : { "checklist" : [] }, "id" : "…", "index" : "a0", "kind" : "sticky-note", "props" : { … } },
///         { "id" : "A1B2…", "index" : "a1", "kind" : "folder", "props" : { … } }
///       ],
///       "versions" : { "added" : { "checklist" : 0 }, "kinds" : { "folder" : 0, "sticky-note" : 3 } }
///     }
///
/// `format` versions the envelope and each record's own members. Format 1 has each kind's props
/// version (`ShapeProps.migrations`) in `schema`. Format 2 added a record's metadata
/// (`AnyShapeRecord.meta`), in `meta`: an object for each plugin that keeps some, by its id. Format
/// 3 added the values of the properties plugins add to a shape's kind (`ShapeProperty`), in
/// `added`, by key, beside its props (which are only its kind's own); `versions` then gives each
/// kind's version and each added property's. Format 4 added the boards shapes own (`CanvasFile`):
/// `boards`, one flat map, never nested however deep the boards are, each an object with its
/// `shapes`, records as the root's, under the same `versions`. Members a shape doesn't have are
/// left out. As with a record's, a member a board entry doesn't have yet needs a newer format: this
/// one reads only `shapes`, and would save a board without any other.
///
/// Reading never drops a shape and never stops at one: it refuses only a file that isn't a board,
/// or one in a newer format, or one with an entry in `boards` that isn't a board and can't be kept as
/// it was (a number JSON can't hold). A shape the app can't use is kept as it was, with its own version in
/// `v`: its kind isn't installed, it's from a newer version of its kind, or it didn't load. So is
/// an added value it can't use (no installed plugin declares it, the kind doesn't opt in, it's
/// from a newer version, or it didn't load), in the shape's `kept`, with its version, while the
/// shape itself stays usable, and a board it can't show (`LoadReport.KeptBoard`), with its shapes.
/// What reading had to fix, and what it kept aside, is in the report.
public struct BoardCodec: Sendable {
    /// The newest envelope this app reads. It writes the oldest that holds the file: 1, unless a
    /// shape has metadata, which needs 2, or added values, which need 3, or the file has a board
    /// besides the root, which needs 4. So an older app still opens a file it would save back
    /// whole, and refuses one it would save without what it doesn't know.
    public static let format = 4

    private let kinds: [ShapeKind: KindCodec]
    private let properties: [PropertyKey: PropertyCodec]
    private let optIns: [ShapeKind: [PropertyKey]]
    private let boardOwningKinds: Set<ShapeKind>

    /// For the kinds `registry` installs, and the properties they opt into. Build it once; it reads
    /// and writes off the main actor.
    @MainActor
    public init(registry: Registry) {
        var kinds: [ShapeKind: KindCodec] = [:]
        for kind in registry.kinds {
            if let definition = registry.definition(for: kind) { kinds[kind] = definition.kindCodec }
        }
        self.kinds = kinds
        properties = registry.propertyTable.codecs
        optIns = registry.propertyTable.byKind
        boardOwningKinds = registry.boardOwningKinds
    }

    /// An installed kind's version; nil for a kind that isn't installed.
    public func version(of kind: ShapeKind) -> Int? { kinds[kind]?.version }

    /// A declared added property's version; nil for one no installed plugin declares.
    public func version(ofProperty key: PropertyKey) -> Int? { properties[key]?.version }

    // MARK: Writing

    /// A file of this board alone: its root.
    public func encode(_ document: CanvasDocument) throws -> Data {
        try encode(root: document, children: [:], unreadable: [:])
    }

    /// Every board of the file, and what it keeps of `boards` that didn't read.
    public func encode(_ file: CanvasFile) throws -> Data {
        try encode(root: file.root, children: file.children, unreadable: file.unreadableBoards)
    }

    private func encode(root: CanvasDocument, children: [ShapeID: CanvasDocument], unreadable: [String: JSONValue]) throws -> Data {
        var versions = Versions()
        for document in [root] + children.values {
            for record in document.shapes where !record.isOpaque {
                versions.kinds[record.kind.rawValue] = type(of: record.props).migrations.count
                for key in record.added.keys { versions.added[key.rawValue] = properties[key]?.version ?? 0 }
            }
        }
        var boards: [String: BoardEntry]?
        if !children.isEmpty || !unreadable.isEmpty {
            // A board a shape owns takes the place of an entry that didn't read under its key.
            var entries = unreadable.mapValues(BoardEntry.unreadable)
            for (owner, document) in children { entries[owner.description] = .board(document.shapes.map(Record.init)) }
            boards = entries
        }
        let format = boards != nil ? 4 : root.shapes.contains { !$0.added.isEmpty } ? 3 : root.shapes.contains { !$0.meta.isEmpty } ? 2 : 1
        return try Self.makeEncoder().encode(Envelope(format: format, versions: versions, shapes: root.shapes.map(Record.init), boards: boards))
    }

    /// One shape's props, as a board writes them: for fixtures, and tools that edit props as JSON.
    public func encodeProps(_ props: any ShapeProps) throws -> Data { try Self.makeEncoder().encode(props) }

    // MARK: Reading

    public func decode(_ data: Data) throws(BoardReadError) -> LoadedBoard {
        let decoder = Self.makeDecoder()
        decoder.userInfo[.boardCodec] = self
        let contents: Contents
        do {
            contents = try decoder.decode(Contents.self, from: data)
        } catch let error as BoardReadError {
            throw error
        } catch {
            throw .unreadable(Self.describe(error))
        }
        return assemble(contents)
    }

    /// One shape's props at `version` of `kind`, migrated to today's: for fixtures, and tools that
    /// edit props as JSON. Throws where reading a board would keep the shape aside.
    public func decodeProps(_ data: Data, kind: ShapeKind, version: Int) throws -> any ShapeProps {
        guard let codec = kinds[kind] else { throw ReadProblem("no installed plugin defines \(kind) shapes") }
        return try props(of: codec, at: version, decode: { try codec.decodeData(data) },
                         json: { try Self.makeDecoder().decode(JSONValue.self, from: data) }).props
    }

    /// One shape from its props at `version` of `kind`, migrated to today's: its props, the values
    /// its history hands over to added properties (`PropsMigration.handOver`), and the defaults of
    /// the rest its kind opts into. Stricter than reading a board: it throws where that would keep
    /// the shape, or a value handed over, aside.
    public func decodeRecord(props data: Data, kind: ShapeKind, version: Int) throws -> AnyShapeRecord {
        guard let codec = kinds[kind] else { throw ReadProblem("no installed plugin defines \(kind) shapes") }
        let (props, handedOver) = try props(of: codec, at: version, decode: { try codec.decodeData(data) },
                                            json: { try Self.makeDecoder().decode(JSONValue.self, from: data) })
        var record = AnyShapeRecord(id: ShapeID(), kind: kind, props: props, stackingKey: nil)
        for (key, handed) in handedOver {
            guard let property = properties[key], optIns[kind]?.contains(key) == true else {
                throw ReadProblem("\(kind) hands \(key) over, but it doesn't opt into that property")
            }
            let handedValue = try value(of: property, at: handed.version, direct: nil, json: { handed.json })
            record.added[key] = property.isNone(handedValue) ? nil : handedValue
        }
        fillDefaults(&record.added, kind: kind)
        return record
    }

    /// One added property's value at `version`, as JSON, migrated to today's and written as a board
    /// writes it: for fixtures, and tools that edit values as JSON. Throws where reading a board
    /// would keep the value aside.
    public func migrateValue(_ data: Data, property key: PropertyKey, version: Int) throws -> Data {
        guard let property = properties[key] else { throw ReadProblem("no installed plugin declares \(key)") }
        let value = try value(of: property, at: version, direct: { try property.decodeData(data) },
                              json: { try Self.makeDecoder().decode(JSONValue.self, from: data) })
        return try Self.makeEncoder().encode(value)
    }

    /// Today's props from a shape's props at `version`: straight into the kind's type when it's
    /// today's version, otherwise through the JSON and each migration since, which may hand members
    /// over to added properties.
    private func props(of codec: KindCodec, at version: Int, decode: () throws -> any ShapeProps,
                       json: () throws -> JSONValue) throws -> (props: any ShapeProps, handedOver: [PropertyKey: Handed]) {
        guard version <= codec.version else { throw ReadProblem("version \(version) is newer than this app's \(codec.version)") }
        if version == codec.version { return (try decode(), [:]) }
        guard case .object(var props) = try json() else { throw ReadProblem("its props aren't a JSON object") }
        var handedOver: [PropertyKey: Handed] = [:]
        for migration in codec.migrations[max(version, 0)...] {
            // A member that's null is one the props didn't have, as a property reads it: nothing to
            // hand over (a title of null was no title).
            if let handOver = migration.handOver, let member = props[handOver.member], member != .null {
                handedOver[handOver.key] = Handed(version: handOver.version, json: member)
            }
            do { try migration.body(&props) } catch {
                throw ReadProblem("the migration “\(migration.name)” failed: \(Self.describe(error))")
            }
        }
        return (try codec.decodeData(Self.makeEncoder().encode(JSONValue.object(props))), handedOver)
    }

    /// Today's value from a value at `version`: straight into its type when it's today's version
    /// (and `direct` can), otherwise through the JSON and each of its migrations since.
    private func value(of property: PropertyCodec, at version: Int, direct: (() throws -> any AddedValue)?,
                       json: () throws -> JSONValue) throws -> any AddedValue {
        guard version <= property.version else { throw ReadProblem("version \(version) is newer than this app's \(property.version)") }
        if version == property.version, let direct { return try direct() }
        var value = try json()
        for migration in property.migrations[max(version, 0)...] {
            do { try migration.body(&value) } catch {
                throw ReadProblem("the migration “\(migration.name)” failed: \(Self.describe(error))")
            }
        }
        return try property.decodeData(Self.makeEncoder().encode(value))
    }

    /// A default for each property the kind opts into that has one, where there's no value.
    private func fillDefaults(_ added: inout AddedValues, kind: ShapeKind) {
        for key in optIns[kind] ?? [] where added[key] == nil && added.kept[key] == nil {
            added[key] = properties[key]?.defaultValue
        }
    }

    /// One element of `shapes`. Never throws: what can't be read is kept aside.
    fileprivate func read(_ decoder: any Decoder, versions: Versions) -> ReadRecord {
        guard let container = try? decoder.container(keyedBy: RecordKeys.self) else {
            let json = (try? JSONValue(from: decoder)) ?? .null
            return ReadRecord(id: nil, kind: ShapeKind(rawValue: ""), key: nil, props: OpaqueProps(json: json, version: 0),
                              meta: ShapeMeta(), added: AddedValues(), dropped: [], keptAside: .unreadable("it isn't a JSON object"),
                              keptValues: [])
        }
        let id = try? container.decode(ShapeID.self, forKey: .id)
        let kind = ShapeKind(rawValue: (try? container.decode(String.self, forKey: .kind)) ?? "")
        let stackingKey = (try? container.decode(String.self, forKey: .index)).flatMap(StackingKey.init)
        let version = (try? container.decodeIfPresent(Int.self, forKey: .v)) ?? versions.kinds[kind.rawValue] ?? 0
        let (meta, droppedMeta) = Self.meta(Self.member(.meta, of: container))
        // Added values by key, and kept ones by key with their versions. What isn't can't be read
        // as any property's: it's left out, and the report says so.
        var dropped: Set<LoadReport.Dropped> = droppedMeta ? [.meta] : []
        let addedValues = try? container.nestedContainer(keyedBy: PropertyCodingKey.self, forKey: .added)
        if container.contains(.added), addedValues == nil { dropped.insert(.values) }
        var kept: [PropertyKey: KeptJSON] = [:]
        if let members = Self.member(.kept, of: container) {
            if let entries = members.objectValue {
                for (key, entry) in entries {
                    guard let version = entry["v"]?.numberValue.flatMap(Int.init(exactly:)), let json = entry["value"] else {
                        dropped.insert(.values)
                        continue
                    }
                    kept[PropertyKey(rawValue: key)] = KeptJSON(version: version, json: json)
                }
            } else {
                dropped.insert(.values)
            }
        }
        func addedVersion(_ key: PropertyKey) -> Int { versions.added[key.rawValue] ?? 0 }
        func addedJSON(_ key: PropertyCodingKey) -> JSONValue { (try? addedValues?.decode(JSONValue.self, forKey: key)) ?? .null }

        func keptAside(_ reason: LoadReport.KeptShape.Reason) -> ReadRecord {
            let json = (try? container.decode(JSONValue.self, forKey: .props)) ?? .null
            var values = AddedValues()
            values.kept = kept
            for codingKey in addedValues?.allKeys ?? [] {
                let property = PropertyKey(rawValue: codingKey.stringValue)
                values.kept[property] = KeptJSON(version: addedVersion(property), json: addedJSON(codingKey))
            }
            return ReadRecord(id: id, kind: kind, key: stackingKey, props: OpaqueProps(json: json, version: version), meta: meta,
                              added: values, dropped: dropped, keptAside: reason, keptValues: [])
        }
        guard let codec = kinds[kind] else { return keptAside(.unknownKind) }
        guard version <= codec.version else { return keptAside(.newerVersion(file: version, app: codec.version)) }
        let props: any ShapeProps, handedOver: [PropertyKey: Handed]
        do {
            (props, handedOver) = try self.props(of: codec, at: version, decode: { try codec.decode(container.superDecoder(forKey: .props)) },
                                                 json: { try container.decode(JSONValue.self, forKey: .props) })
        } catch {
            return keptAside(.unreadable(Self.describe(error)))
        }
        if let frame = (props as? any BoxShapeProps)?.frame, !frame.isFinite {
            return keptAside(.unreadable("its frame isn't finite"))
        }

        // Each value typed if the app can use it, else kept as it was. One written as added wins
        // over one handed over or kept.
        var values = AddedValues()
        var keptValues: [(PropertyKey, LoadReport.KeptValue.Reason)] = []
        let opted = optIns[kind] ?? []
        func take(_ key: PropertyKey, at version: Int, direct: (() throws -> any AddedValue)?, json: () -> JSONValue) {
            func keep(_ reason: LoadReport.KeptValue.Reason) {
                values.kept[key] = KeptJSON(version: version, json: json())
                keptValues.append((key, reason))
            }
            guard let property = properties[key] else { return keep(.notDeclared) }
            guard opted.contains(key) else { return keep(.notOptedIn) }
            guard version <= property.version else { return keep(.newerVersion(file: version, app: property.version)) }
            do {
                // A value that's no value at all (a blank title) is none: the shape has the default.
                let read = try value(of: property, at: version, direct: direct, json: json)
                values[key] = property.isNone(read) ? nil : read
            } catch {
                // A value written as null (no property's can be) is none too, as a missing member
                // of the props is: kept aside, it would stop the shape ever having one.
                if json() == .null { return }
                keep(.unreadable(Self.describe(error)))
            }
        }
        let written = Set((addedValues?.allKeys ?? []).map { PropertyKey(rawValue: $0.stringValue) })
        for (key, handed) in handedOver where !written.contains(key) {
            take(key, at: handed.version, direct: nil, json: { handed.json })
        }
        for codingKey in addedValues?.allKeys ?? [] {
            let key = PropertyKey(rawValue: codingKey.stringValue)
            let direct: (() throws -> any AddedValue)? = if let property = properties[key], let addedValues {
                { try property.decode(addedValues.superDecoder(forKey: codingKey)) }
            } else {
                nil
            }
            take(key, at: addedVersion(key), direct: direct, json: { addedJSON(codingKey) })
        }
        for (key, entry) in kept where !written.contains(key) && handedOver[key] == nil {
            take(key, at: entry.version, direct: nil, json: { entry.json })
        }
        fillDefaults(&values, kind: kind)
        // By key, so the same board reports the same way every time.
        keptValues.sort { $0.0.rawValue < $1.0.rawValue }
        return ReadRecord(id: id, kind: kind, key: stackingKey, props: props, meta: meta, added: values, dropped: dropped,
                          keptAside: nil, keptValues: keptValues)
    }

    /// A record's member as JSON, if it has one (`.null` if it doesn't read as JSON).
    private static func member(_ key: RecordKeys, of container: KeyedDecodingContainer<RecordKeys>) -> JSONValue? {
        // Not a ternary: JSONValue is ExpressibleByNilLiteral, so `nil` there would be `.null`.
        var json: JSONValue?
        if container.contains(key) { json = (try? container.decode(JSONValue.self, forKey: key)) ?? .null }
        return json
    }

    /// A record's metadata: an object with an object for each plugin. What isn't can't be any
    /// plugin's, so it's left out, and the second value says so.
    private static func meta(_ json: JSONValue?) -> (ShapeMeta, dropped: Bool) {
        guard let json else { return (ShapeMeta(), false) }
        guard let members = json.objectValue else { return (ShapeMeta(), true) }
        let kept = members.filter { $0.value.objectValue != nil }
        return (ShapeMeta(json: kept), kept.count != members.count)
    }

    /// The file, after the repairs it may need: an id for each shape that has none or repeats one
    /// (the first keeps it, on whichever board), and stacking keys that rise on each board. A file
    /// written by this app needs none.
    ///
    /// Boards are read in tree order, which decides who keeps a repeated id, and with it the board
    /// that id owns: the root, then the boards it reaches, breadth first, each board's in its
    /// shapes' order; then those it doesn't reach, by key, each with the boards it reaches. A board
    /// that can't be shown is kept, and the report says why.
    private func assemble(_ contents: Contents) -> LoadedBoard {
        var report = LoadReport()
        var seen = Set<ShapeID>()
        var unread = contents.boards
        var children: [ShapeID: CanvasDocument] = [:]

        /// One board's shapes, with ids unique across the file and keys that rise.
        func place(_ read: [ReadRecord], on board: BoardID) -> [AnyShapeRecord] {
            var records: [AnyShapeRecord] = []
            records.reserveCapacity(read.count)
            for item in read {
                let id: ShapeID
                if let old = item.id, seen.insert(old).inserted {
                    id = old
                } else {
                    id = ShapeID()
                    seen.insert(id)
                    report.repairs.append(.newID(old: item.id, new: id))
                }
                if let reason = item.keptAside {
                    report.keptAside.append(LoadReport.KeptShape(id: id, kind: item.kind, reason: reason, board: board))
                }
                if item.dropped.contains(.meta) { report.repairs.append(.droppedMeta(id)) }
                if item.dropped.contains(.values) { report.repairs.append(.droppedValues(id)) }
                for (key, reason) in item.keptValues {
                    report.keptValues.append(LoadReport.KeptValue(id: id, kind: item.kind, key: key, reason: reason, board: board))
                }
                var record = AnyShapeRecord(id: id, kind: item.kind, props: item.props, stackingKey: item.key, meta: item.meta)
                record.added = item.added
                records.append(record)
            }
            return risingKeys(records, repairs: &report.repairs)
        }

        /// The boards `records` own that are yet to be read, in their order, each with why it
        /// can't be shown (nil if it can), on a board that can't be for `kept` (nil if it can).
        func owned(by records: [AnyShapeRecord], kept: LoadReport.KeptBoard.Reason?) -> [(ShapeID, LoadReport.KeptBoard.Reason?)] {
            records.compactMap { record in
                guard unread[record.id] != nil else { return nil }
                let reason: LoadReport.KeptBoard.Reason? = if record.isOpaque {
                    .ownerKeptAside(record.kind)
                } else if !boardOwningKinds.contains(record.kind) {
                    .ownerNotABoard(record.kind)
                } else if kept == .unreachable {
                    .unreachable
                } else if kept != nil {
                    .insideKeptBoard
                } else {
                    nil
                }
                return (record.id, reason)
            }
        }

        /// These boards, then the boards they own, and so on, breadth first.
        func walk(_ boards: [(ShapeID, LoadReport.KeptBoard.Reason?)]) {
            var queue = boards, next = 0
            while next < queue.count {
                let (owner, kept) = queue[next]
                next += 1
                guard let read = unread.removeValue(forKey: owner) else { continue }
                let records = place(read, on: BoardID(owner: owner))
                guard !records.isEmpty else { continue }
                children[owner] = CanvasDocument(shapes: records)
                if let kept { report.keptBoards.append(LoadReport.KeptBoard(key: owner.description, shapeCount: records.count, reason: kept)) }
                queue += owned(by: records, kept: kept)
            }
        }

        let root = place(contents.records, on: .root)
        walk(owned(by: root, kept: nil))
        for owner in unread.keys.sorted(by: { $0.description < $1.description }) where unread[owner] != nil {
            walk([(owner, .unreachable)])
        }
        for (key, entry) in contents.unreadableBoards.sorted(by: { $0.key < $1.key }) {
            report.keptBoards.append(LoadReport.KeptBoard(key: key, shapeCount: 0, reason: .unreadable(entry.why)))
        }
        var file = CanvasFile(root: CanvasDocument(shapes: root), children: children)
        file.unreadableBoards = contents.unreadableBoards.mapValues(\.json)
        return LoadedBoard(file: file, report: report)
    }

    /// The records, with keys that rise: those with keys in key order, ties broken by id, each key
    /// that doesn't rise replaced by one that does; those without a key on top, in the order they
    /// came.
    private func risingKeys(_ records: [AnyShapeRecord], repairs: inout [LoadReport.Repair]) -> [AnyShapeRecord] {
        guard !CanvasDocument.keysRise(records) else { return records }
        let keyed = records.filter { $0.stackingKey != nil }.sorted {
            ($0.stackingKey!, $0.id.rawValue.uuidString) < ($1.stackingKey!, $1.id.rawValue.uuidString)
        }
        var ordered: [AnyShapeRecord] = []
        for (i, var record) in keyed.enumerated() {
            if let previous = ordered.last?.stackingKey, record.stackingKey! <= previous {
                let next = keyed[(i + 1)...].lazy.compactMap(\.stackingKey).first { $0 > previous }
                record.stackingKey = .between(previous, next)
                repairs.append(.newStackingKey(record.id))
            }
            ordered.append(record)
        }
        for var record in records where record.stackingKey == nil {
            record.stackingKey = .between(ordered.last?.stackingKey, nil)
            repairs.append(.newStackingKey(record.id))
            ordered.append(record)
        }
        return ordered
    }

    // MARK: Settings

    /// Pinned, since migrations and fixtures depend on them: sorted keys, pretty-printed, `CGRect`
    /// as `[[x, y], [width, height]]` (CoreGraphics' own), dates in ISO 8601 to the second, and
    /// NaN and the infinities as the strings "nan", "inf" and "-inf", so a save never fails on them.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }

    /// A decoding error, said briefly: where, and what.
    static func describe(_ error: any Error) -> String {
        func path(_ codingPath: [any CodingKey]) -> String {
            let text = codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
            return text.hasPrefix(".") ? String(text.dropFirst()) : text
        }
        switch error {
        case let problem as ReadProblem:
            return problem.message
        case DecodingError.keyNotFound(let key, let context):
            return "\(path(context.codingPath + [key])) is missing"
        case DecodingError.dataCorrupted(let context), DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            let at = path(context.codingPath)
            return at.isEmpty ? context.debugDescription : "\(at): \(context.debugDescription)"
        default:
            return "\(error)"
        }
    }
}

/// A board file, read: what to open, and what reading it took.
public struct LoadedBoard: Sendable {
    public let file: CanvasFile
    public let report: LoadReport
    /// The root board.
    public var document: CanvasDocument { file.root }
}

/// What opening a board file kept aside and repaired. Repairs are part of the file now, so it
/// should be marked edited; kept-aside shapes, values and boards are saved back as they were.
public struct LoadReport: Equatable, Sendable {
    public var keptAside: [KeptShape]
    public var keptValues: [KeptValue]
    public var keptBoards: [KeptBoard]
    public var repairs: [Repair]
    public var isEmpty: Bool { keptAside.isEmpty && keptValues.isEmpty && keptBoards.isEmpty && repairs.isEmpty }

    public init(keptAside: [KeptShape] = [], keptValues: [KeptValue] = [], keptBoards: [KeptBoard] = [], repairs: [Repair] = []) {
        self.keptAside = keptAside
        self.keptValues = keptValues
        self.keptBoards = keptBoards
        self.repairs = repairs
    }

    /// A shape the file keeps but the app can't use (`AnyShapeRecord.isOpaque`).
    public struct KeptShape: Equatable, Sendable {
        public let id: ShapeID
        public let kind: ShapeKind
        public let reason: Reason
        /// The board it's on.
        public let board: BoardID

        public init(id: ShapeID, kind: ShapeKind, reason: Reason, board: BoardID = .root) {
            self.id = id
            self.kind = kind
            self.reason = reason
            self.board = board
        }

        public enum Reason: Equatable, Sendable {
            /// No installed plugin defines the kind.
            case unknownKind
            /// Written by a newer version of the kind's plugin.
            case newerVersion(file: Int, app: Int)
            /// It didn't load: bad props, a failed migration, a frame that isn't finite.
            case unreadable(String)
        }
    }

    /// An added property's value the board keeps, on a shape the app can use, but the app can't
    /// (`AnyShapeRecord.keptProperties`).
    public struct KeptValue: Equatable, Sendable {
        public let id: ShapeID
        public let kind: ShapeKind
        public let key: PropertyKey
        public let reason: Reason
        /// The board its shape is on.
        public let board: BoardID

        public init(id: ShapeID, kind: ShapeKind, key: PropertyKey, reason: Reason, board: BoardID = .root) {
            self.id = id
            self.kind = kind
            self.key = key
            self.reason = reason
            self.board = board
        }

        public enum Reason: Equatable, Sendable {
            /// No installed plugin declares the property.
            case notDeclared
            /// The shape's kind doesn't opt into it.
            case notOptedIn
            /// Written by a newer version of the property's plugin.
            case newerVersion(file: Int, app: Int)
            /// It didn't load: a bad value, or a failed migration.
            case unreadable(String)
        }
    }

    /// A board the file keeps but the app can't show (`CanvasFile.children`, or, when it didn't
    /// read, `CanvasFile.unreadableBoards`), with its shapes.
    public struct KeptBoard: Equatable, Sendable {
        /// Its key in the file's `boards`, as written: its owner's id, when it has one.
        public let key: String
        /// How many shapes are on it (not on the boards under it); 0 for one that didn't read.
        public let shapeCount: Int
        public let reason: Reason

        public init(key: String, shapeCount: Int, reason: Reason) {
            self.key = key
            self.shapeCount = shapeCount
            self.reason = reason
        }

        public enum Reason: Equatable, Sendable {
            /// Its owner is kept aside (`KeptShape`): a kind no plugin installs, a newer version,
            /// or it didn't load.
            case ownerKeptAside(ShapeKind)
            /// Its owner's kind owns no board (`BoardOwning`).
            case ownerNotABoard(ShapeKind)
            /// Its owner is on a board kept for one of these reasons, so it can't be reached.
            case insideKeptBoard
            /// Going up from it never reaches the root: its owner isn't in the file, or owners
            /// hold each other's boards.
            case unreachable
            /// It isn't a board, an object with a list of shapes, or its key isn't a shape's id:
            /// it's kept as it was, and nothing in it is read.
            case unreadable(String)
        }
    }

    public enum Repair: Equatable, Sendable {
        /// The shape had no id, or another shape had it first.
        case newID(old: ShapeID?, new: ShapeID)
        /// Its stacking key was missing, malformed, or not above the shape below it.
        case newStackingKey(ShapeID)
        /// Some of its metadata wasn't an object for a plugin, so no plugin's: it was left out.
        case droppedMeta(ShapeID)
        /// Some of its added or kept values weren't a value by key (a kept one with its version), so
        /// no property's: they were left out.
        case droppedValues(ShapeID)
    }

    /// What a record had that couldn't be read as anything's, and was left out.
    enum Dropped: Hashable, Sendable { case meta, values }
}

/// Why a board won't open.
public enum BoardReadError: Error, Equatable, CustomStringConvertible {
    /// Not a board: not JSON, or not the envelope.
    case unreadable(String)
    /// A newer version of the app wrote it.
    case newerFormat(Int)

    public var description: String {
        switch self {
        case .unreadable(let why): "It isn't a board this app can read: \(why)"
        case .newerFormat(let format): "A newer version of the app wrote it (format \(format); this one reads up to \(BoardCodec.format))."
        }
    }
}

/// How a board reads one kind's props: its migrations, and its type.
struct KindCodec: Sendable {
    let migrations: [PropsMigration]
    let decode: @Sendable (any Decoder) throws -> any ShapeProps
    let decodeData: @Sendable (Data) throws -> any ShapeProps
    /// Props of this kind, with the members a JSON object has read over them
    /// (`SchemaDefined.patching(_:with:)`).
    let patchData: @Sendable (any ShapeProps, Data) throws -> any ShapeProps
    var version: Int { migrations.count }

    init<P: ShapeProps>(_: P.Type) {
        migrations = P.migrations
        decode = { try P(from: $0) }
        decodeData = { try BoardCodec.makeDecoder().decode(P.self, from: $0) }
        patchData = { base, data in
            guard let base = base as? P else { throw ReadProblem("these aren't \(P.kind) props") }
            return try P.patching(base, with: data)
        }
    }
}

private struct ReadProblem: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// A member a kind's history handed over to an added property, at the property's version.
private struct Handed {
    let version: Int
    let json: JSONValue
}

private struct ReadRecord {
    let id: ShapeID?
    let kind: ShapeKind
    let key: StackingKey?
    let props: any ShapeProps
    let meta: ShapeMeta
    let added: AddedValues
    /// What it had that was left out (`LoadReport.Repair.droppedMeta`, `droppedValues`).
    let dropped: Set<LoadReport.Dropped>
    /// Nil when the props are the kind's own type.
    let keptAside: LoadReport.KeptShape.Reason?
    /// Its added values the app can't use, on a shape it can.
    let keptValues: [(PropertyKey, LoadReport.KeptValue.Reason)]
}

private enum RecordKeys: String, CodingKey { case id, kind, index, props, v, meta, added, kept }

/// Each kind's version and, from format 3, each added property's.
private struct Versions {
    var kinds: [String: Int] = [:]
    var added: [String: Int] = [:]
}

/// A kept value as a board writes it.
private struct KeptEntry: Encodable {
    let v: Int
    let value: JSONValue
}

private struct Envelope: Encodable {
    let format: Int
    let versions: Versions
    let shapes: [Record]
    /// From format 4.
    let boards: [String: BoardEntry]?

    private enum Keys: String, CodingKey { case format, schema, versions, shapes, boards }
    private enum VersionKeys: String, CodingKey { case kinds, added }

    /// Before format 3, the kinds' versions are the envelope's `schema`.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(format, forKey: .format)
        if format < 3 {
            try container.encode(versions.kinds, forKey: .schema)
        } else {
            var nested = container.nestedContainer(keyedBy: VersionKeys.self, forKey: .versions)
            try nested.encode(versions.kinds, forKey: .kinds)
            if !versions.added.isEmpty { try nested.encode(versions.added, forKey: .added) }
        }
        try container.encode(shapes, forKey: .shapes)
        try container.encodeIfPresent(boards, forKey: .boards)
    }
}

/// An entry of `boards`: a board's shapes, or what didn't read as a board, as it was.
private enum BoardEntry: Encodable {
    case board([Record])
    case unreadable(JSONValue)

    private enum Keys: String, CodingKey { case shapes }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .board(let shapes):
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(shapes, forKey: .shapes)
        case .unreadable(let json):
            try json.encode(to: encoder)
        }
    }
}

private struct Record: Encodable {
    let record: AnyShapeRecord

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: RecordKeys.self)
        try container.encode(record.id, forKey: .id)
        try container.encode(record.kind.rawValue, forKey: .kind)
        try container.encodeIfPresent(record.stackingKey, forKey: .index)
        try record.props.encode(to: container.superEncoder(forKey: .props))
        if let opaque = record.opaqueProps { try container.encode(opaque.version, forKey: .v) }
        if !record.meta.isEmpty { try container.encode(record.meta.json, forKey: .meta) }
        if !record.added.keys.isEmpty {
            var added = container.nestedContainer(keyedBy: PropertyCodingKey.self, forKey: .added)
            for key in record.added.keys {
                try record.added[key]?.encode(to: added.superEncoder(forKey: PropertyCodingKey(key.rawValue)))
            }
        }
        if !record.added.kept.isEmpty {
            try container.encode(Dictionary(uniqueKeysWithValues: record.added.kept.map { ($0.key.rawValue, KeptEntry(v: $0.value.version, value: $0.value.json)) }),
                                 forKey: .kept)
        }
    }
}

/// The whole file, read in one pass: the envelope, then each shape, on each board.
private struct Contents: Decodable {
    /// The root's.
    var records: [ReadRecord] = []
    /// The boards in `boards` (from format 4), by owner.
    var boards: [ShapeID: [ReadRecord]] = [:]
    /// What's in `boards` that isn't a board, by key, and why.
    var unreadableBoards: [String: (json: JSONValue, why: String)] = [:]

    private enum Keys: String, CodingKey { case format, schema, versions, shapes, boards }
    private enum BoardKeys: String, CodingKey { case shapes }
    private enum VersionKeys: String, CodingKey { case kinds, added }

    init(from decoder: any Decoder) throws {
        let codec = decoder.userInfo[.boardCodec] as! BoardCodec
        let container = try decoder.container(keyedBy: Keys.self)
        let format = try container.decode(Int.self, forKey: .format)
        guard format <= BoardCodec.format else { throw BoardReadError.newerFormat(format) }
        guard format >= 1 else { throw BoardReadError.unreadable("format \(format) isn't a board format") }
        var versions = Versions()
        if format < 3 {
            versions.kinds = (try? container.decode([String: Int].self, forKey: .schema)) ?? [:]
        } else if let nested = try? container.nestedContainer(keyedBy: VersionKeys.self, forKey: .versions) {
            versions.kinds = (try? nested.decode([String: Int].self, forKey: .kinds)) ?? [:]
            versions.added = (try? nested.decode([String: Int].self, forKey: .added)) ?? [:]
        }
        var shapes = try container.nestedUnkeyedContainer(forKey: .shapes)
        while !shapes.isAtEnd {
            records.append(codec.read(try shapes.superDecoder(), versions: versions))
        }
        guard format >= 4, container.contains(.boards) else { return }
        guard let entries = try? container.nestedContainer(keyedBy: PropertyCodingKey.self, forKey: .boards) else {
            throw BoardReadError.unreadable("its boards aren't an object")
        }
        for key in entries.allKeys {
            // A key as this app writes it: the owner's id, in capitals.
            let owner = BoardID(key.stringValue).flatMap { $0.description == key.stringValue ? $0.owner : nil }
            if let owner, let board = try? entries.nestedContainer(keyedBy: BoardKeys.self, forKey: key),
               var shapes = try? board.nestedUnkeyedContainer(forKey: .shapes) {
                var read: [ReadRecord] = []
                while !shapes.isAtEnd {
                    read.append(codec.read(try shapes.superDecoder(), versions: versions))
                }
                boards[owner] = read
            } else {
                // Kept only to be written back, so kept whole, or the file isn't read: a save would lose it.
                guard let json = try? entries.decode(JSONValue.self, forKey: key) else {
                    throw BoardReadError.unreadable("boards.\(key.stringValue) isn't a board, and can't be kept as it is")
                }
                unreadableBoards[key.stringValue] = (json, owner == nil ? "its key isn't a shape's id" : "it isn't an object with a list of shapes")
            }
        }
    }
}

extension CodingUserInfoKey {
    fileprivate static let boardCodec = CodingUserInfoKey(rawValue: "boardCodec")!
}
