import Foundation
import Geometry

/// Reads and writes boards. A board is JSON: an envelope around every shape, back to front.
///
///     {
///       "format" : 3,
///       "shapes" : [
///         { "added" : { "checklist" : [] }, "id" : "…", "index" : "a0", "kind" : "sticky-note", "props" : { … } }
///       ],
///       "versions" : { "added" : { "checklist" : 0 }, "kinds" : { "arrow" : 0, "sticky-note" : 1 } }
///     }
///
/// `format` versions the envelope and each record's own members. Format 1 has each kind's props
/// version (`ShapeProps.migrations`) in `schema`. Format 2 added a record's metadata
/// (`AnyShapeRecord.meta`), in `meta`: an object for each plugin that keeps some, by its id. Format
/// 3 added the values of the properties plugins add to a shape's kind (`ShapeProperty`), in
/// `added`, by key, beside its props (which are only its kind's own); `versions` then gives each
/// kind's version and each added property's. Members a shape doesn't have are left out.
///
/// Reading never drops a shape and never stops at one: it refuses only a file that isn't a board,
/// or one in a newer format. A shape the app can't use is kept as it was, with its own version in
/// `v`: its kind isn't installed, it's from a newer version of its kind, or it didn't load. So is
/// an added value it can't use (no installed plugin declares it, the kind doesn't opt in, it's
/// from a newer version, or it didn't load), in the shape's `kept`, with its version, while the
/// shape itself stays usable. What reading had to fix, and what it kept aside, is in the report.
public struct BoardCodec: Sendable {
    /// The newest envelope this app reads. It writes the oldest that holds the board: 1, unless a
    /// shape has metadata, which needs 2, or added values, which need 3. So an older app still
    /// opens a board it would save back whole, and refuses one it would save without what it
    /// doesn't know.
    public static let format = 3

    private let kinds: [ShapeKind: KindCodec]
    private let properties: [PropertyKey: PropertyCodec]
    private let optIns: [ShapeKind: [PropertyKey]]

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
    }

    /// An installed kind's version; nil for a kind that isn't installed.
    public func version(of kind: ShapeKind) -> Int? { kinds[kind]?.version }

    /// A declared added property's version; nil for one no installed plugin declares.
    public func version(ofProperty key: PropertyKey) -> Int? { properties[key]?.version }

    // MARK: Writing

    public func encode(_ document: CanvasDocument) throws -> Data {
        var versions = Versions()
        for record in document.shapes where !record.isOpaque {
            versions.kinds[record.kind.rawValue] = type(of: record.props).migrations.count
            for key in record.added.keys { versions.added[key.rawValue] = properties[key]?.version ?? 0 }
        }
        let format = document.shapes.contains { !$0.added.isEmpty } ? 3 : document.shapes.contains { !$0.meta.isEmpty } ? 2 : 1
        return try Self.makeEncoder().encode(Envelope(format: format, versions: versions, shapes: document.shapes.map(Record.init)))
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
        return assemble(contents.records)
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

    /// The document, after the repairs a board may need: an id for each shape that has none or
    /// repeats one (the first keeps it), and stacking keys that rise. A board written by this app
    /// needs none.
    private func assemble(_ read: [ReadRecord]) -> LoadedBoard {
        var report = LoadReport()
        var seen = Set<ShapeID>()
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
            if let reason = item.keptAside { report.keptAside.append(LoadReport.KeptShape(id: id, kind: item.kind, reason: reason)) }
            if item.dropped.contains(.meta) { report.repairs.append(.droppedMeta(id)) }
            if item.dropped.contains(.values) { report.repairs.append(.droppedValues(id)) }
            for (key, reason) in item.keptValues {
                report.keptValues.append(LoadReport.KeptValue(id: id, kind: item.kind, key: key, reason: reason))
            }
            var record = AnyShapeRecord(id: id, kind: item.kind, props: item.props, stackingKey: item.key, meta: item.meta)
            record.added = item.added
            records.append(record)
        }
        if !CanvasDocument.keysRise(records) {
            // Shapes with keys in key order, ties broken by id; each key that doesn't rise is
            // replaced by one that does. Shapes without a key go on top, in the order they came.
            let keyed = records.filter { $0.stackingKey != nil }.sorted {
                ($0.stackingKey!, $0.id.rawValue.uuidString) < ($1.stackingKey!, $1.id.rawValue.uuidString)
            }
            var ordered: [AnyShapeRecord] = []
            for (i, var record) in keyed.enumerated() {
                if let previous = ordered.last?.stackingKey, record.stackingKey! <= previous {
                    let next = keyed[(i + 1)...].lazy.compactMap(\.stackingKey).first { $0 > previous }
                    record.stackingKey = .between(previous, next)
                    report.repairs.append(.newStackingKey(record.id))
                }
                ordered.append(record)
            }
            for var record in records where record.stackingKey == nil {
                record.stackingKey = .between(ordered.last?.stackingKey, nil)
                report.repairs.append(.newStackingKey(record.id))
                ordered.append(record)
            }
            records = ordered
        }
        return LoadedBoard(document: CanvasDocument(shapes: records), report: report)
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

/// A board, read: what to open, and what reading it took.
public struct LoadedBoard: Sendable {
    public let document: CanvasDocument
    public let report: LoadReport
}

/// What opening a board kept aside and repaired. Repairs are part of the document now, so the
/// board should be marked edited; kept-aside shapes and values are saved back as they were.
public struct LoadReport: Equatable, Sendable {
    public var keptAside: [KeptShape]
    public var keptValues: [KeptValue]
    public var repairs: [Repair]
    public var isEmpty: Bool { keptAside.isEmpty && keptValues.isEmpty && repairs.isEmpty }

    public init(keptAside: [KeptShape] = [], keptValues: [KeptValue] = [], repairs: [Repair] = []) {
        self.keptAside = keptAside
        self.keptValues = keptValues
        self.repairs = repairs
    }

    /// A shape the board keeps but the app can't use (`AnyShapeRecord.isOpaque`).
    public struct KeptShape: Equatable, Sendable {
        public let id: ShapeID
        public let kind: ShapeKind
        public let reason: Reason

        public init(id: ShapeID, kind: ShapeKind, reason: Reason) {
            self.id = id
            self.kind = kind
            self.reason = reason
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

        public init(id: ShapeID, kind: ShapeKind, key: PropertyKey, reason: Reason) {
            self.id = id
            self.kind = kind
            self.key = key
            self.reason = reason
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
    var version: Int { migrations.count }

    init<P: ShapeProps>(_: P.Type) {
        migrations = P.migrations
        decode = { try P(from: $0) }
        decodeData = { try BoardCodec.makeDecoder().decode(P.self, from: $0) }
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

    private enum Keys: String, CodingKey { case format, schema, versions, shapes }
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

/// The whole file, read in one pass: the envelope, then each shape.
private struct Contents: Decodable {
    var records: [ReadRecord] = []

    private enum Keys: String, CodingKey { case format, schema, versions, shapes }
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
    }
}

extension CodingUserInfoKey {
    fileprivate static let boardCodec = CodingUserInfoKey(rawValue: "boardCodec")!
}
